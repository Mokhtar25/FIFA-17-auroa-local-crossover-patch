"""Run with python3 -m unittest discover -s tests -v.

Installer entry points are exercised only with arguments that must exit before
side effects. Diagnostics run with stubbed reporting in a temporary directory.
"""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


class ScriptTests(unittest.TestCase):
    def test_syntax(self):
        scripts = list(ROOT.rglob("*.sh")) + list(ROOT.rglob("*.command"))
        scripts += list(ROOT.rglob("*.zsh"))
        for script in scripts:
            with self.subTest(script=script.name):
                subprocess.run(["/bin/zsh", "-n", str(script)], check=True)

    def test_cli_validation(self):
        cases = [
            ("setup.sh", ["--help"], 0),
            ("setup.sh", ["--verify", "--offline"], 2),
            ("setup.sh", ["one.app", "two.app"], 2),
            ("setup.sh", ["--fifa15", "--unknown"], 2),
            ("setup.sh", ["--fifa15", "one.app", "two.app"], 2),
            ("setup-both.sh", ["--help"], 0),
            ("setup-both.sh", ["--unknown"], 2),
            ("setup-both.sh", ["--verify", "--offline"], 2),
            ("setup-both.sh", ["--agent", "extra"], 2),
            ("setup-both.sh", ["one.app", "two.app"], 2),
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
collect_crash_reports() { print -r -- "stub" > "$2"; }
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
                    self.assertTrue(any(name.endswith("/crash-reports.txt")
                                        for name in bundle.namelist()))
            self.assertFalse(list(work.glob("aurora17-bundle-*")))


class BothGamesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fifa-both-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("AURORA_", "FIFA15_", "FIFA17_", "CX_"))}
        self.env.update(CX_BOTTLE_PATH=str(self.work / "bottles"),
                        AURORA_TARGET=str(self.work / "missing.app"),
                        AURORA_RECEIPT_DIR=str(self.work / "receipts"))

    def run_both(self, args=(), **env):
        shutil.copy2(ROOT / "setup-both.sh", self.work / "setup-both.sh")
        stub = self.work / "setup.sh"
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
game = os.environ['AURORA_GAME']
with Path('calls.jsonl').open('a') as f:
    f.write(json.dumps([game, os.environ['AURORA_BOTTLE'], sys.argv[1:]]) + '\\n')
sys.exit(int(os.environ.get('TEST_RC_' + game, '0')))
''')
        stub.chmod(0o755)
        log = self.work / "calls.jsonl"
        log.unlink(missing_ok=True)
        result = subprocess.run(
            ["/bin/zsh", str(self.work / "setup-both.sh"), *args],
            env={**self.env, **env}, capture_output=True, text=True, timeout=10)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_combined_installer_keeps_profiles_and_paths_separate(self):
        for args, first_args in [([], []), (["--offline"], ["--offline"]),
                                 (["/tmp/Custom CrossOver.app"], ["/tmp/Custom CrossOver.app"])]:
            with self.subTest(args=args):
                result, calls = self.run_both(args, AURORA_GAME="fifa15",
                                             FIFA17_BOTTLE="My 17", FIFA15_BOTTLE="My 15")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(calls, [
                    ["fifa17", "My 17", first_args],
                    ["fifa15", "My 15", ["--fifa15", *[a for a in args if a != "--offline"]]],
                ])

    def test_combined_failure_and_verification(self):
        for args, rc17, rc15, expected, count in [
            ([], "5", "0", 5, 1), ([], "0", "4", 4, 2),
            (["--verify"], "5", "0", 5, 2),
            (["--verify"], "0", "4", 4, 2),
        ]:
            with self.subTest(args=args, rc17=rc17, rc15=rc15):
                result, calls = self.run_both(args, TEST_RC_fifa17=rc17, TEST_RC_fifa15=rc15)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(len(calls), count)
                self.assertEqual(calls[0][:2], ["fifa17", "Aurora17"])
                if args == ["--verify"]:
                    self.assertEqual(calls[1], ["fifa15", "Aurora15", ["--fifa15", "--verify"]])

    def test_combined_rejects_shared_bottle_before_running_setup(self):
        bottles = self.work / "bottles"
        (bottles / "shared").mkdir(parents=True)
        (bottles / "alias").symlink_to(bottles / "shared", target_is_directory=True)
        cases = [dict(AURORA_BOTTLE="shared"),
                 dict(FIFA17_BOTTLE="shared", FIFA15_BOTTLE="shared"),
                 dict(FIFA17_BOTTLE="Shared", FIFA15_BOTTLE="shared"),
                 dict(FIFA17_BOTTLE="shared", FIFA15_BOTTLE="alias")]
        for env in cases:
            with self.subTest(env=env):
                result, calls = self.run_both(**env)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(calls, [])

    def test_profile_payload_and_settings(self):
        # Run the actual read-only initialization, stopping before platform
        # checks or installation. This inspects what each real install uses.
        source = (ROOT / "setup.sh").read_text().split(
            "# --------------------------------------------------------- safety guards", 1)[0]
        probe = self.work / "profile.sh"
        probe.write_text(source + '\nprint -rl -- "$GAME" "$BOTTLE" $BOTTLE_SETTINGS $FILES\n')
        for game, bottle, setting, excluded in [
            ("fifa17", "Aurora17", "CX_DR_TRAP=2", "CX_TOPDOWN_LIMIT="),
            ("fifa15", "Aurora15", "CX_TOPDOWN_LIMIT=0x1ffffffff", "CX_DR_TRAP="),
        ]:
            with self.subTest(game=game):
                result = subprocess.run(["/bin/zsh", str(probe), "--verify"],
                                        env={**self.env, "AURORA_GAME": game},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[:2], [game, bottle])
                self.assertIn(setting, lines)
                self.assertFalse(any(line.startswith(excluded) for line in lines))
                self.assertIn("x86_64-windows/gdiplus.dll", lines)

    def test_single_profile_refuses_other_games_bottle(self):
        for game, other, setting in [("fifa15", "Aurora17", "CX_DR_TRAP"),
                                      ("fifa17", "Aurora15", "CX_TOPDOWN_LIMIT")]:
            for bottle in (other, "custom"):
                with self.subTest(game=game, bottle=bottle):
                    folder = self.work / "bottles" / bottle
                    folder.mkdir(parents=True, exist_ok=True)
                    conf = folder / "cxbottle.conf"
                    contents = f'[EnvironmentVariables]\n"{setting}" = "2"\n'
                    conf.write_text(contents)
                    result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--verify"],
                                            env={**self.env, "AURORA_GAME": game, "AURORA_BOTTLE": bottle},
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("needs its own bottle", result.stdout)
                    self.assertEqual(conf.read_text(), contents)

    def test_fifa15_refuses_fifa17_only_actions(self):
        for action in ("--offline", "--play-offline", "--play-log", "--reseed-licence", "--bundle"):
            with self.subTest(action=action):
                result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), action],
                                        env={**self.env, "AURORA_GAME": "fifa15"},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("FIFA 17", result.stdout)


if __name__ == "__main__":
    unittest.main()
