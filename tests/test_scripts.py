"""Run with python3 -m unittest discover -s tests -v.

Installer entry points are exercised only with arguments that must exit before
side effects. Diagnostics run with stubbed reporting in a temporary directory.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


class ScriptTests(unittest.TestCase):
    def test_syntax(self):
        scripts = list(ROOT.glob("*.sh")) + list(ROOT.rglob("*.command"))
        scripts += list(ROOT.rglob("*.zsh"))
        for script in scripts:
            with self.subTest(script=script.name):
                subprocess.run(["/bin/zsh", "-n", str(script)], check=True)

    def test_cli_validation(self):
        cases = [
            ("setup.sh", ["--help"], 0),
            ("setup.sh", ["--verify", "--offline"], 2),
            ("setup.sh", ["one.app", "two.app"], 2),
            ("uninstall.sh", ["--help"], 0),
            ("uninstall.sh", ["--unknown"], 2),
            ("uninstall.sh", ["one.app", "two.app"], 2),
            ("build.sh", ["--help"], 0),
            ("build.sh", ["--unknown"], 2),
            ("build.sh", ["--deps", "extra"], 2),
            ("build.sh", [], 2),
        ]
        for shell in ("/bin/zsh", "/bin/bash", "/bin/sh"):
            for script, args, expected in cases:
                with self.subTest(shell=shell, script=script, args=args):
                    result = subprocess.run(
                        [shell, str(ROOT / script), *args],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_bundle_empty_logs_and_unique_archives(self):
        source = (ROOT / "setup.sh").read_text()
        function = source.split("bundle_mode() {", 1)[1].split("\n}\n", 1)[0]
        with tempfile.TemporaryDirectory(prefix="a17-tests-") as directory:
            work = Path(directory)
            (work / "diagnostics").mkdir()
            (work / "fixes").mkdir()
            (work / "aurora17").mkdir()
            (work / "unrelated.txt").write_text("must not appear in logs")
            harness = r'''
set -eu
HERE="$PWD"
BOTTLE_DIR="$PWD/bottles"
BOTTLE=missing
RECEIPT="$PWD/missing-receipt"
FILES=()
RESOLVER=missing
say() { :; }
date() { print -r -- 20260905-120000; }
diagnostics_dir() { print -r -- "$PWD/diagnostics"; }
report_mode() { print -r -- "test report"; }
bottle_hosts_file() { print -r -- "$PWD/missing-hosts"; }
hosts_receipt_file() { return 1; }
shasum() { return 0; }
'''
            harness += "\nbundle_mode() {" + function + "\n}\n"
            harness += '\nbundle_mode "$PWD/missing.app"\nbundle_mode "$PWD/missing.app"\n'
            result = subprocess.run(
                ["/bin/zsh", "-c", harness], cwd=work,
                env={**os.environ, "TMPDIR": directory},
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            archives = list((work / "diagnostics").glob("*.zip"))
            self.assertEqual(len(archives), 2)
            for archive in archives:
                with zipfile.ZipFile(archive) as bundle:
                    self.assertFalse(any("unrelated.txt" in name for name in bundle.namelist()))
                    self.assertTrue(any(name.endswith("/report.txt") for name in bundle.namelist()))
            self.assertFalse(list(work.glob("aurora17-bundle-*")))


if __name__ == "__main__":
    unittest.main()
