"""Exercise the generated cleanup lifecycle without signalling real processes."""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'setup.sh').read_text()


class CleanupTests(unittest.TestCase):
    def run_cleanup(self, scenario):
        with tempfile.TemporaryDirectory(prefix='fifa-cleanup-test-') as directory:
            work = Path(directory)
            (work / '101').touch()
            body = SOURCE.split("<<'CLEANUP_EOF'\n", 1)[1].split('\nCLEANUP_EOF', 1)[0]
            body = body.replace('BASE="$HOME/Library/Application Support/FIFA-CrossOver"',
                                'BASE=' + shlex.quote(directory))
            body = body.replace('/usr/sbin/lsof', 'lsof').replace('/bin/sleep 1', ':')
            stubs = r'''
SCENARIO=SCENARIO_VALUE
crossovers_running() {
    [ "$SCENARIO" = gui ] || [ -f "$BASE/reopened" ] || return 0
    print -r -- /Applications/CrossOver-FIFA.app
}
wine_pids() { local p; for p in 101 202; do [ ! -f "$BASE/$p" ] || print -r -- "$p"; done; return 0; }
game_pids() { wine_pids; }
wineserver_pids() { :; }
stale_wine_sockets() { :; }
lsof() { :; }
kill() {
    local sig="$1" p; shift
    if [ "$sig" = -0 ]; then [ -f "$BASE/$1" ]; return $?; fi
    for p in "$@"; do
        print -r -- "$sig $p" >> "$BASE/signals"
        if [ "$SCENARIO" = stubborn ] && [ "$sig" = -TERM ]; then continue; fi
        if [ "$SCENARIO" = restart ] && [ "$sig" = -TERM ]; then
            touch "$BASE/reopened"; continue
        fi
        rm -f "$BASE/$p"
        if [ "$SCENARIO" = respawn ] && [ "$p" = 101 ]; then touch "$BASE/202"; fi
    done
    return 0
}
'''.replace('SCENARIO_VALUE', shlex.quote(scenario))
            body = body.replace('HOLD="$BASE/session-hold"', stubs + '\nHOLD="$BASE/session-hold"')
            if scenario == 'hold':
                (work / 'session-hold').write_text('101')
            if scenario == 'grace':
                import time
                (work / 'last-gui-seen').write_text(str(int(time.time())))
            result = subprocess.run(['/bin/zsh', '-c', body], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            signals = (work / 'signals').read_text().splitlines() if (work / 'signals').exists() else []
            remaining = [p for p in ('101', '202') if (work / p).exists()]
            return signals, remaining

    def test_cleanup_rescans_children_created_during_shutdown(self):
        signals, remaining = self.run_cleanup('respawn')
        self.assertEqual(remaining, [], f'Children left behind: {remaining}; signals: {signals}')
        self.assertIn('-TERM 202', signals)

    def test_cleanup_escalates_only_stubborn_processes(self):
        signals, remaining = self.run_cleanup('stubborn')
        self.assertEqual(signals, ['-TERM 101', '-KILL 101'])
        self.assertEqual(remaining, [])

    def test_cleanup_preserves_live_gui_session_hold_and_grace(self):
        for scenario in ('gui', 'hold', 'grace'):
            with self.subTest(scenario=scenario):
                signals, remaining = self.run_cleanup(scenario)
                self.assertEqual(signals, [])
                self.assertEqual(remaining, ['101'])

    def test_cleanup_stops_if_crossover_reopens(self):
        signals, remaining = self.run_cleanup('restart')
        self.assertEqual(signals, ['-TERM 101'])
        self.assertEqual(remaining, ['101'])

    def test_fifa15_bottle_setup_refreshes_cleanup(self):
        body = SOURCE.split('if [ "$MODE" = bottle ]; then', 1)[1].split('\n# Replaces the EA licence file', 1)[0]
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
install_cleanup_agent() { touch "$BOTTLE_DIR/agent-refreshed"; }
'''
            harness += '\nif [ "$MODE" = bottle ]; then' + body
            result = subprocess.run(['/bin/zsh', '-c', harness], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((work / 'agent-refreshed').exists(), 'FIFA 15 setup never refreshed cleanup')

    def test_generated_helper_preserves_custom_bottles_and_check_detects_stale_agent(self):
        generation = SOURCE.split('write_cleanup_helper() {', 1)[1].split('\nwrite_cleanup_plist() {', 1)[0]
        verification = SOURCE.split('verify_cleanup_agent() {', 1)[1].split('\nwrite_cleanup_helper() {', 1)[0]
        with tempfile.TemporaryDirectory(prefix='fifa-agent-test-') as directory:
            work = Path(directory)
            helper = work / 'cleanup'
            bottle_path = str(work / 'Bottles with spaces & punctuation')
            harness = 'set -eu\nCLEANUP_HELPER=' + shlex.quote(str(helper)) + '\n'
            harness += 'BOTTLE_DIR=' + shlex.quote(bottle_path) + '\n'
            harness += 'CLEANUP_REVISION=2\nwrite_cleanup_helper() {' + generation
            result = subprocess.run(['/bin/zsh', '-c', harness + '\nwrite_cleanup_helper\n'],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            header = '\n'.join(helper.read_text().splitlines()[:3])
            result = subprocess.run(['/bin/zsh', '-c', header + '\nprint -r -- "$CX_BOTTLE_PATH"'],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.stdout.strip(), bottle_path)
            plist = work / 'agent.plist'
            plist.touch()
            harness += '\nverify_cleanup_agent() {' + verification
            harness += '\nCLEANUP_PLIST=' + shlex.quote(str(plist)) + '\n'
            harness += 'CLEANUP_LABEL=test; ok() { :; }; bad() { print -r -- "$*"; }; say() { :; }\n'
            for kind, expected, text in [('loaded', 0, ''), ('unloaded', 1, 'not loaded'),
                                          ('stale', 1, 'outdated'), ('missing', 1, 'missing')]:
                with self.subTest(kind=kind):
                    if kind == 'stale':
                        helper.write_text(helper.read_text().replace('FIFA_CLEANUP_REVISION=2', 'FIFA_CLEANUP_REVISION=1'))
                    elif kind == 'missing':
                        helper.unlink()
                    launchctl_rc = '1' if kind == 'unloaded' else '0'
                    result = subprocess.run(['/bin/zsh', '-c', harness +
                                             f'launchctl() {{ return {launchctl_rc}; }}\nverify_cleanup_agent\n'],
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertIn(text, result.stdout)


if __name__ == '__main__':
    unittest.main()
