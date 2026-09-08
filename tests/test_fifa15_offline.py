"""Patch synthetic DLL-shaped data; never store or modify game files in tests."""
import hashlib
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL_SHA = '4463ce725e2af8b858095511801901630355fe1eba66fbb8fc7a5ba3b0f0300b'
PATCHED_SHA = 'e6b423c536823be4379681dad8bd9d7334e4db53a394025b86b7af7a8a9cda71'


def digest(data):
    return hashlib.sha256(data).hexdigest()


class OfflineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fifa-offline-test-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.game = self.work / 'FIFA 15'
        self.game.mkdir()
        self.original = bytes(25088)
        patched = bytearray(self.original)
        patched[0x9ed] = 0xeb
        patched[0xa6a:0xa6c] = b'\x90\x90'
        self.patched = bytes(patched)
        self.connector = b'synthetic connector-installed DLL'
        self.dll = self.game / 'ItsAMe_Origin.dll'
        self.aurora = self.game / 'ItsAMe_Origin.dll.aurora15.bak'
        self.keep = self.game / 'ItsAMe_Origin.dll.offline-orig'
        self.script = self.work / 'offline.sh'
        # The real shell and byte-patching logic, with only fixture hashes
        # substituted so copyrighted game binaries are not test fixtures.
        source = (ROOT / 'fifa15/fifa15-offline.sh').read_text()
        self.script.write_text(source.replace(ORIGINAL_SHA, digest(self.original))
                              .replace(PATCHED_SHA, digest(self.patched)))
        pgrep = self.work / 'pgrep'
        pgrep.write_text('#!/bin/sh\nexit "${TEST_PROCESS_STATUS:-1}"\n')
        pgrep.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.work) + os.pathsep + os.environ['PATH']}

    def run_action(self, action, **env):
        return subprocess.run(['/bin/zsh', str(self.script), action, str(self.game)],
                              env={**self.env, **env}, capture_output=True, text=True, timeout=10)

    def test_original_apply_idempotent_and_revert(self):
        self.dll.write_bytes(self.original)
        for _ in range(2):
            result = self.run_action('apply')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.dll.read_bytes(), self.patched)
            self.assertEqual(self.keep.read_bytes(), self.original)
        check = self.run_action('check')
        self.assertIn('offline-patched', check.stdout)
        self.assertIn('revert is available', check.stdout)
        self.assertEqual(self.run_action('revert').returncode, 0)
        self.assertEqual(self.dll.read_bytes(), self.original)

    def test_connector_installed_dll_uses_verified_aurora_backup(self):
        self.dll.write_bytes(self.connector)
        self.aurora.write_bytes(self.original)
        before = {p.name: p.read_bytes() for p in self.game.iterdir()}
        check = self.run_action('check')
        self.assertEqual(check.returncode, 3)
        self.assertIn('Verified original found', check.stdout)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.game.iterdir()})
        result = self.run_action('apply')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.dll.read_bytes(), self.patched)
        self.assertEqual(self.keep.read_bytes(), self.original)
        self.assertEqual(self.aurora.read_bytes(), self.original)
        preserved = self.game / ('ItsAMe_Origin.dll.before-offline-' + digest(self.connector))
        self.assertEqual(preserved.read_bytes(), self.connector)
        self.assertEqual(self.run_action('revert').returncode, 0)
        self.assertEqual(self.dll.read_bytes(), self.original)
        self.assertEqual(preserved.read_bytes(), self.connector)

    def test_existing_offline_original_can_recover_connector_replacement(self):
        self.dll.write_bytes(self.connector)
        self.keep.write_bytes(self.original)
        self.assertEqual(self.run_action('apply').returncode, 0)
        self.assertEqual(self.dll.read_bytes(), self.patched)

    def test_unrecognized_dll_without_verified_backup_is_untouched(self):
        for backup in (None, b'invalid original backup'):
            with self.subTest(backup=backup):
                self.dll.write_bytes(self.connector)
                if backup is not None:
                    self.aurora.write_bytes(backup)
                before = {p.name: p.read_bytes() for p in self.game.iterdir()}
                self.assertEqual(self.run_action('apply').returncode, 3)
                self.assertEqual(before, {p.name: p.read_bytes() for p in self.game.iterdir()})

    def test_conflicting_original_backup_is_preserved(self):
        self.dll.write_bytes(self.connector)
        self.aurora.write_bytes(self.original)
        self.keep.write_bytes(b'keep this existing backup')
        self.assertEqual(self.run_action('apply').returncode, 1)
        self.assertEqual(self.dll.read_bytes(), self.connector)
        self.assertEqual(self.keep.read_bytes(), b'keep this existing backup')
        self.assertFalse(list(self.game.glob('.fifa15-offline.*')))

    def test_running_or_uninspectable_processes_prevent_changes(self):
        self.dll.write_bytes(self.original)
        for status in ('0', '3'):
            with self.subTest(status=status):
                self.assertEqual(self.run_action('apply', TEST_PROCESS_STATUS=status).returncode, 1)
                self.assertEqual(self.dll.read_bytes(), self.original)
                self.assertFalse(self.keep.exists())

    def test_cli_reexec_and_extra_arguments(self):
        for shell in ('/bin/sh', '/bin/bash', '/bin/zsh'):
            result = subprocess.run([shell, str(self.script), 'apply', str(self.game), 'extra'],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_installer_check_reports_recoverable_dll_without_changing_it(self):
        self.dll.write_bytes(self.connector)
        self.aurora.write_bytes(self.original)
        (self.game / 'fifa15.exe').touch()
        helper = self.work / 'fifa15/fifa15-offline.sh'
        helper.parent.mkdir()
        helper.write_text(self.script.read_text())
        helper.chmod(0o755)
        source = (ROOT / 'setup.sh').read_text()
        functions = source.split('f15_game_dir() {', 1)[1].split(
            '# ------------------------------------------------------------- signing', 1)[0]
        harness = 'set -eu\nHERE=' + shlex.quote(str(self.work)) + '\n'
        harness += 'FIFA15_DIR=' + shlex.quote(str(self.game)) + '\n'
        harness += 'say() { print -r -- "$*"; }; ok() { say "$@"; }; note() { say "$@"; }\n'
        harness += 'f15_game_dir() {' + functions + '\nf15_check_game\n'
        result = subprocess.run(['/bin/zsh', '-c', harness], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('direct offline play is not ready', result.stdout)
        self.assertIn('Verified original found', result.stdout)
        self.assertEqual(self.dll.read_bytes(), self.connector)


if __name__ == '__main__':
    unittest.main()
