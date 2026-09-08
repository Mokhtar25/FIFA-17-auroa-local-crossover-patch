"""The package must install nothing that runs on its own, and must take off
whatever an older version already installed."""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'setup.sh').read_text()


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class NoBackgroundAgentTests(unittest.TestCase):
    def test_nothing_installs_a_launchagent(self):
        """The generator, the plist and the bootstrap are gone, not disabled."""
        for banned in ('launchctl bootstrap', 'StartInterval', 'write_cleanup_helper',
                       'write_cleanup_plist', 'install_cleanup_agent', 'CLEANUP_EOF'):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, SOURCE)
        # bootout stays: it is how an already-installed agent comes off.
        self.assertIn('launchctl bootout', SOURCE)

    def test_uninstall_still_removes_an_older_agent(self):
        self.assertIn('launchctl bootout', (ROOT / 'uninstall.sh').read_text())


class RemovalTests(unittest.TestCase):
    """remove_cleanup_agent() runs on every install, so shipping this takes the
    agent off the machines that already have one."""

    def harness(self, work, launchctl_rc='0'):
        body = section('cleanup_agent_present() {', '\nif [ "$MODE" = agent ]; then')
        return ('set -u\n'
                'CLEANUP_PLIST=' + shlex.quote(str(work / 'agent.plist')) + '\n'
                'CLEANUP_HELPER=' + shlex.quote(str(work / 'cleanup')) + '\n'
                'CLEANUP_BASE=' + shlex.quote(str(work)) + '\n'
                'CLEANUP_LABEL=test\n'
                f'launchctl() {{ return {launchctl_rc}; }}\n'
                'ok() { print -r -- "OK $*"; }; bad() { print -r -- "BAD $*"; }; say() { :; }\n'
                'cleanup_agent_present() {' + body + '\n')

    def plant(self, work):
        (work / 'agent.plist').write_text('<plist/>')
        (work / 'cleanup').write_text('#!/bin/zsh\n')
        (work / 'last-gui-seen').write_text('1')
        (work / 'last-report').write_text('1')
        (work / 'cleanup.lock').mkdir()

    def run_zsh(self, script):
        return subprocess.run(['/bin/zsh', '-c', script], capture_output=True, text=True, timeout=10)

    def test_removal_deletes_every_piece_and_says_it_found_one(self):
        with tempfile.TemporaryDirectory(prefix='fifa-agent-') as directory:
            work = Path(directory)
            self.plant(work)
            (work / 'cleanup.log').write_text('kept as the record\n')
            result = self.run_zsh(self.harness(work, launchctl_rc='1') + 'remove_cleanup_agent\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for gone in ('agent.plist', 'cleanup', 'last-gui-seen', 'last-report', 'cleanup.lock'):
                self.assertFalse((work / gone).exists(), f'{gone} survived removal')
            self.assertTrue((work / 'cleanup.log').exists(), 'the log is evidence; keep it')

    def test_removal_reports_nothing_to_do_on_a_clean_machine(self):
        with tempfile.TemporaryDirectory(prefix='fifa-agent-') as directory:
            result = self.run_zsh(self.harness(Path(directory), launchctl_rc='1')
                                  + 'remove_cleanup_agent\n')
            self.assertEqual(result.returncode, 1, 'nothing was there, so nothing was removed')

    def test_a_job_still_loaded_counts_even_with_the_files_gone(self):
        with tempfile.TemporaryDirectory(prefix='fifa-agent-') as directory:
            result = self.run_zsh(self.harness(Path(directory), launchctl_rc='0')
                                  + 'remove_cleanup_agent\n')
            self.assertEqual(result.returncode, 0, 'a loaded launchd job is an agent to remove')

    def test_verify_fails_while_an_agent_is_still_installed(self):
        with tempfile.TemporaryDirectory(prefix='fifa-agent-') as directory:
            work = Path(directory)
            self.plant(work)
            script = self.harness(work, launchctl_rc='1') + 'verify_no_cleanup_agent\n'
            result = self.run_zsh(script)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn('BAD', result.stdout)
            self.assertIn('30 s', result.stdout)
            (work / 'agent.plist').unlink()
            (work / 'cleanup').unlink()
            result = self.run_zsh(self.harness(work, launchctl_rc='1') + 'verify_no_cleanup_agent\n')
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('OK', result.stdout)
            self.assertIn('no background agent', result.stdout)

    def test_agent_flag_now_removes_rather_than_installs(self):
        block = section('if [ "$MODE" = agent ]; then', '\n# Frees a bottle whose Wine session')
        with tempfile.TemporaryDirectory(prefix='fifa-agent-') as directory:
            work = Path(directory)
            self.plant(work)
            script = (self.harness(work, launchctl_rc='1')
                      + 'MODE=agent\nif [ "$MODE" = agent ]; then' + block + '\n')
            result = self.run_zsh(script)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('removed', result.stdout)
            self.assertFalse((work / 'agent.plist').exists())


class InstallPathTests(unittest.TestCase):
    def test_fifa15_bottle_setup_takes_an_old_agent_off(self):
        body = section('if [ "$MODE" = bottle ]; then', '\n# Replaces the EA licence file')
        with tempfile.TemporaryDirectory(prefix='fifa-bottle-test-') as directory:
            work = Path(directory)
            (work / 'app').mkdir()
            (work / 'Aurora15').mkdir()
            harness = 'set -eu\nTARGET=' + shlex.quote(str(work / 'app')) + '\n'
            harness += 'BOTTLE_DIR=' + shlex.quote(directory) + '\n'
            harness += r'''
MODE=bottle; TARGET_EXPLICIT=1; F15_ONE=1; BOTTLE=Aurora15; GAME=fifa15
E_PAYLOAD=4; E_UNSUPPORTED=2; E_INCOMPLETE=5
say() { :; }; ok() { :; }; green() { :; }; note() { :; }
f15_add_ntdll() { :; }; f15_add_gdiplus() { :; }; f15_check_game() { :; }
configure_bottle() { BOTTLE_OK=1; PS_OK=1; HOSTS_OK=1; }
crossovers_running() { :; }; wineserver_pids() { :; }
remove_cleanup_agent() { touch "$BOTTLE_DIR/agent-removed"; }
'''
            harness += '\nif [ "$MODE" = bottle ]; then' + body
            result = subprocess.run(['/bin/zsh', '-c', harness], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((work / 'agent-removed').exists(),
                            'FIFA 15 setup left an older background agent in place')


if __name__ == '__main__':
    unittest.main()
