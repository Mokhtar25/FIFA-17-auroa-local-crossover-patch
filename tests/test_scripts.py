"""Run with python3 -m unittest discover -s tests -v.

Installer entry points are exercised only with arguments that must exit before
side effects. Diagnostics run with stubbed reporting in a temporary directory.
"""
import hashlib
import os
import re
import json
from pathlib import Path
from shlex import quote as shlex_quote
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
            ("setup.sh", ["--choose-folder"], 2),
            ("setup.sh", ["--choose-folder", "fifa99", "/tmp"], 2),
            ("setup.sh", ["--choose-folder", "fifa15"], 2),
            ("setup.sh", ["--choose-folder", "fifa15", "/tmp", "extra"], 2),
            ("setup.sh", ["--forget-folder"], 2),
            ("setup.sh", ["--forget-folder", "fifa99"], 2),
            ("setup.sh", ["--forget-folder", "fifa15", "extra"], 2),
            ("setup.sh", ["--verify", "--offline"], 2),
            ("setup.sh", ["one.app", "two.app"], 2),
            ("setup.sh", ["--fifa15", "--unknown"], 2),
            ("setup.sh", ["--fifa15", "one.app", "two.app"], 2),
            ("setup.sh", ["--repair", "--offline"], 2),
            ("setup.sh", ["--fix-folder", "--offline"], 2),
            ("setup.sh", ["--fifa15", "--fix-folder"], 2),
            ("setup.sh", ["--fifa15", "--repair"], 2),
            ("setup.sh", ["--fifa16", "--unknown"], 2),
            ("setup.sh", ["--fifa16", "one.app", "two.app"], 2),
            ("setup.sh", ["--fifa16", "--repair"], 2),
            ("setup.sh", ["--fifa21", "--unknown"], 2),
            ("setup.sh", ["--fifa21", "one.app", "two.app"], 2),
            ("setup.sh", ["--fifa21", "--repair"], 2),
            ("setup.sh", ["--fifa21", "--offline"], 2),
            ("setup-both.sh", ["--repair", "extra"], 2),
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
                        env={**os.environ, "CX_NO_DIALOGS": "1"},
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
GATE=missing
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
    f.write(json.dumps([game, os.environ.get('AURORA_BOTTLE') or 'pick:' + os.environ.get('FIFA17_BOTTLE', ''), sys.argv[1:]]) + '\\n')
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
                    ["fifa17", "pick:My 17", first_args],
                    ["fifa15", "My 15", ["--fifa15", *[a for a in args if a != "--offline"]]],
                ])

    def test_combined_failure_and_verification(self):
        # Exit 5 from FIFA 17 means the copy is patched and only its bottle is
        # incomplete; FIFA 15 needs only the copy, so it still runs. Any other
        # stop leaves FIFA 15 unattempted. FIFA 17's code wins when both fail.
        for args, rc17, rc15, expected, count in [
            ([], "5", "0", 5, 2), ([], "5", "4", 5, 2),
            ([], "3", "0", 3, 1), ([], "0", "4", 4, 2),
            (["--verify"], "5", "0", 5, 2),
            (["--verify"], "0", "4", 4, 2),
        ]:
            with self.subTest(args=args, rc17=rc17, rc15=rc15):
                result, calls = self.run_both(args, TEST_RC_fifa17=rc17, TEST_RC_fifa15=rc15)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(len(calls), count)
                self.assertEqual(calls[0][:2], ["fifa17", "pick:Aurora17"])
                if args == ["--verify"]:
                    self.assertEqual(calls[1], ["fifa15", "pick:Aurora17", ["--fifa15", "--verify"]])
                if args == [] and rc17 == "5":
                    self.assertIn("FIFA 15 needs only the copy", result.stdout)

    def test_combined_lets_fifa15_go_where_aurora_is(self):
        # No Aurora15 is forced any more: FIFA 15's half picks the bottle Aurora
        # starts it from (FIFA 17's by default), unless FIFA15_BOTTLE names one.
        for env, f17, f15 in [({}, "pick:Aurora17", "pick:Aurora17"),
                              (dict(FIFA17_BOTTLE="shared"), "pick:shared", "pick:shared"),
                              (dict(FIFA17_BOTTLE="shared", FIFA15_BOTTLE="shared"), "pick:shared", "shared"),
                              (dict(FIFA15_BOTTLE="Aurora15"), "pick:Aurora17", "Aurora15")]:
            with self.subTest(env=env):
                result, calls = self.run_both(**env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([c[:2] for c in calls], [["fifa17", f17], ["fifa15", f15]])

    def test_combined_rejects_aurora_bottle_before_running_setup(self):
        result, calls = self.run_both(AURORA_BOTTLE="shared")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(calls, [])

    def test_profile_payload_and_settings(self):
        # Run the actual read-only initialization, stopping before platform
        # checks or installation. Explicit bottles keep the legacy profiles
        # test independent of the new common-bottle default.
        source = (ROOT / "setup.sh").read_text().split(
            "# --------------------------------------------------------- safety guards", 1)[0]
        probe = self.work / "profile.sh"
        probe.write_text(source + '\nprint -rl -- "$GAME" "$BOTTLE" $BOTTLE_SETTINGS $FILES\n')
        for game, bottle, setting, excluded in [
            ("fifa17", "Aurora17", "CX_DR_TRAP=2", "CX_TOPDOWN_LIMIT="),
            ("fifa15", "Aurora15", "CX_TOPDOWN_LIMIT=0x1ffffffff", "CX_DR_TRAP="),
            ("fifa16", "FIFA16", "CX_FIFA16_DSTFIX=0", "CX_TOPDOWN_LIMIT="),
            # FIFA 21 has no bottle of its own: the Aurora launcher's, Aurora17.
            ("fifa21", "Aurora17", "CX_DR_TRAP=2", "CX_TOPDOWN_LIMIT="),
        ]:
            with self.subTest(game=game):
                result = subprocess.run(["/bin/zsh", str(probe), "--verify"],
                                        env={**self.env, "AURORA_GAME": game, "AURORA_BOTTLE": bottle},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[:2], [game, bottle])
                self.assertIn(setting, lines)
                self.assertFalse(any(line.startswith(excluded) for line in lines))
                self.assertIn("x86_64-windows/gdiplus.dll", lines)
                self.assertIn("x86_64-windows/ole32.dll", lines)
                self.assertIn("x86_64-unix/win32u.so", lines)
                if game == "fifa16":
                    # Mode 3, not FIFA 17's 2: the debug-register emulation.
                    self.assertIn("CX_DR_TRAP=3", lines)
                # The WebView2 pin is FIFA 17's: FIFA 15 and 16 have no RebornFUT.
                pin = r"WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=C:\webview2-fixed\99.0.1150.52"
                if game == "fifa17":
                    self.assertIn(pin, lines)
                else:
                    self.assertFalse(any(line.startswith("WEBVIEW2_") for line in lines))

    def test_single_profile_refuses_other_games_bottle(self):
        # FIFA 17's marker is CX_DR_TRAP=2 exactly: FIFA 16 sets CX_DR_TRAP too.
        for game, other, setting in [("fifa15", "Aurora17", "CX_DR_TRAP"),
                                      ("fifa17", "Aurora15", "CX_TOPDOWN_LIMIT"),
                                      ("fifa16", "Aurora17", "CX_DR_TRAP"),
                                      ("fifa16", "Aurora15", "CX_TOPDOWN_LIMIT"),
                                      ("fifa17", "FIFA16", "CX_FIFA16_DSTFIX"),
                                      ("fifa15", "FIFA16", "CX_FIFA16_DSTFIX")]:
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
        for game, action in [(game, action) for game in ("fifa15", "fifa16", "fifa21")
                             for action in ("--offline", "--play-offline", "--play-log",
                                            "--reseed-licence", "--bundle", "--repair")]:
            with self.subTest(game=game, action=action):
                result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), action],
                                        env={**self.env, "AURORA_GAME": game},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("FIFA 17", result.stdout)


def file_size_limit(blocks):
    """A shell prefix after which a write past blocks x 512 bytes fails with
    EFBIG (SIGXFSZ ignored, so it is an error, not a kill)."""
    return f"trap '' XFSZ; ulimit -f {blocks}; "


def function_source(name):
    """One shell function out of setup.sh, for running against stubs."""
    source = (ROOT / "setup.sh").read_text()
    body = source.split(name + "() {", 1)[1].split("\n}\n", 1)[0]
    return name + "() {" + body + "\n}\n"


# What game_dir_candidates needs out of setup.sh, for a harness that runs it
# against a fake bottle. The path mapping is the folder gate's own.
RESOLVER_FUNCTIONS = ["game_exe_of", "reg_value", "bottle_appdata", "aurora_launcher_dir",
                      "aurora_ini_dir", "connector_game_dir", "win_path_to_unix",
                      "fifa17_dir_candidates", "game_dir_choice", "game_dir_choice_lost",
                      "game_dir_candidates", "game_dir_line", "game_dir_of",
                      "game_dir_source_says"]


def resolver_source():
    source = (ROOT / "setup.sh").read_text()
    lines = [line for line in source.splitlines()
             if line.startswith(("IMPULSUM_UNINSTALL_KEY=", "CHOICES_FILE=", "VOLUMES_DIR=",
                                 "bottle_user_reg()", "bottle_system_reg()"))]
    return ("\n".join(lines) + "\nsource " + shlex_quote(str(GATE_SCRIPT)) + "\n"
            + "".join(function_source(n) for n in RESOLVER_FUNCTIONS))


class VersionTests(unittest.TestCase):
    """Every output a tester sends back names the package that made it."""

    def version_of(self, version_text):
        with tempfile.TemporaryDirectory(prefix="fifa-version-") as directory:
            package = Path(directory)
            shutil.copy2(ROOT / "setup.sh", package / "setup.sh")
            if version_text is not None:
                (package / "VERSION").write_text(version_text)
            result = subprocess.run(["/bin/zsh", str(package / "setup.sh"), "--version"],
                                    env={"PATH": os.environ["PATH"], "HOME": directory},
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout.strip()

    def test_version_file_is_a_number_and_a_git_archive_placeholder(self):
        lines = (ROOT / "VERSION").read_text().splitlines()
        self.assertRegex(lines[0], r"^\d+\.\d+\.\d+$")
        self.assertEqual(lines[1], "$Format:%h$")
        self.assertIn("VERSION export-subst", (ROOT / ".gitattributes").read_text().splitlines())

    def test_version_names_the_commit_only_when_a_zip_carries_one(self):
        number = (ROOT / "VERSION").read_text().splitlines()[0]
        self.assertEqual(self.version_of((ROOT / "VERSION").read_text()),
                         f"FIFA CrossOver patch {number}")
        self.assertEqual(self.version_of("2.3.4\nabc1234\n"), "FIFA CrossOver patch 2.3.4 (abc1234)")
        self.assertEqual(self.version_of("2.3.4"), "FIFA CrossOver patch 2.3.4")
        self.assertEqual(self.version_of(None), "FIFA CrossOver patch unknown")


class FolderChoiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fifa-choices-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.choices = self.work / "Library/Application Support/FIFA-CrossOver/choices.conf"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("AURORA_", "FIFA", "CX_", "SSH_"))}
        self.env.update(HOME=str(self.work), CX_NO_DIALOGS="1",
                        CX_BOTTLE_PATH=str(self.work / "no-bottles"),
                        AURORA_TARGET=str(self.work / "no-app.app"))

    def run_setup(self, *args, **env):
        return subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), *args],
                              cwd=self.work, env={**self.env, **env},
                              capture_output=True, text=True, timeout=10)

    def game(self, path, exe="fifa15.exe"):
        folder = self.work / path
        folder.mkdir(parents=True, exist_ok=True)
        (folder / exe).write_bytes(b"MZ")
        return folder

    def test_save_and_forget_change_only_the_selected_choice(self):
        self.choices.parent.mkdir(parents=True)
        original = "# My choices\nbottle.shared=yes\nfifa16.shared_pae=no\nfifa17.folder=/other\n"
        self.choices.write_text(original + "fifa15.folder=/old\n")
        folder = self.game('Games/$(touch PWNED) " FIFA 15')
        result = self.run_setup("--choose-folder", "fifa15", str(folder))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.choices.read_text(), original + f"fifa15.folder={folder.resolve()}\n")
        self.assertFalse((self.work / "PWNED").exists())
        before = self.choices.stat().st_mtime_ns
        again = self.run_setup("--choose-folder", "fifa15", str(folder))
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(self.choices.stat().st_mtime_ns, before)
        forgotten = self.run_setup("--forget-folder", "fifa15")
        self.assertEqual(forgotten.returncode, 0, forgotten.stdout + forgotten.stderr)
        self.assertEqual(self.choices.read_text(), original)
        self.assertFalse((self.work / "no-bottles").exists())
        self.assertFalse((self.work / "no-app.app").exists())

    def test_parent_folder_is_accepted_only_when_the_game_is_unambiguous(self):
        folder = self.game("Disc/FIFA 15")
        result = self.run_setup("--choose-folder", "fifa15", str(folder.parent))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"fifa15.folder={folder.resolve()}\n", self.choices.read_text())
        before = self.choices.read_bytes()
        self.game("Disc/Another FIFA 15")
        result = self.run_setup("--choose-folder", "fifa15", str(folder.parent))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("more than one", result.stdout + result.stderr)
        self.assertEqual(self.choices.read_bytes(), before)

    def test_each_game_requires_its_own_executable(self):
        for game, exe in [("fifa13", "fifa13.exe"), ("fifa15", "fifa15.exe"),
                          ("fifa16", "fifa16.exe"), ("fifa17", "FIFA17.exe"),
                          ("fifa21", "FIFA21.exe")]:
            with self.subTest(game=game):
                folder = self.game(game, exe)
                result = self.run_setup("--choose-folder", game, str(folder))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"{game}.folder={folder.resolve()}\n", self.choices.read_text())
        before = self.choices.read_bytes()
        result = self.run_setup("--choose-folder", "fifa15", str(self.work / "fifa21"))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("no fifa15.exe", result.stdout + result.stderr)
        self.assertEqual(self.choices.read_bytes(), before)

    def test_invalid_arguments_and_control_characters_never_save_a_choice(self):
        for args in [("--choose-folder",), ("--forget-folder",),
                     ("--choose-folder", "fifa99", str(self.work)),
                     ("--forget-folder", "fifa99"),
                     ("--forget-folder", "fifa15", "extra"),
                     ("--choose-folder", "fifa15", str(self.work), "extra")]:
            with self.subTest(args=args):
                result = self.run_setup(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse(self.choices.exists())
        for control in ("\t", "\n", "\r"):
            folder = self.game("Games/FIFA" + control + "15")
            result = self.run_setup("--choose-folder", "fifa15", str(folder))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse(self.choices.exists())
        result = self.run_setup("--forget-folder", "fifa15")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.choices.parent.exists())

    def test_a_failed_atomic_replace_preserves_the_previous_choices(self):
        self.choices.parent.mkdir(parents=True)
        original = b"fifa15.folder=/old\nfifa17.folder=/other\n"
        self.choices.write_bytes(original)
        folder = self.game("FIFA 15")
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        move = bin_dir / "mv"
        move.write_text("#!/bin/sh\nexit 1\n")
        move.chmod(0o755)
        result = self.run_setup("--choose-folder", "fifa15", str(folder),
                                PATH=str(bin_dir) + ":" + self.env["PATH"])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(self.choices.read_bytes(), original)
        self.assertEqual(list(self.choices.parent.glob(".choices-*")), [])

    def test_a_failed_write_of_the_new_choices_keeps_the_previous_ones(self):
        # The old choices fit under the limit and the new line does not, so
        # the temporary file would be the old file minus this game's line.
        self.choices.parent.mkdir(parents=True)
        original = ("# My choices\nfifa17.folder=/other\n"
                    + "fifa16.shared_pae=no\n" * 20 + "fifa15.folder=/old\n").encode()
        self.assertLess(len(original), 512)
        self.choices.write_bytes(original)
        folder = self.game("FIFA 15 " + "x" * 40)
        result = subprocess.run(
            ["/bin/zsh", "-c", file_size_limit(1) + "exec /bin/zsh \"$0\" \"$@\"",
             str(ROOT / "setup.sh"), "--choose-folder", "fifa15", str(folder)],
            cwd=self.work, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("The previous choices were kept", result.stdout)
        self.assertNotIn("saved", result.stdout)
        self.assertEqual(self.choices.read_bytes(), original)
        self.assertEqual(list(self.choices.parent.glob(".choices-*")), [])
        # And with no choices yet, nothing is left behind.
        self.choices.unlink()
        result = subprocess.run(
            ["/bin/zsh", "-c", file_size_limit(0) + "exec /bin/zsh \"$0\" \"$@\"",
             str(ROOT / "setup.sh"), "--choose-folder", "fifa15", str(folder)],
            cwd=self.work, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertFalse(self.choices.exists())
        self.assertEqual(list(self.choices.parent.glob(".choices-*")), [])


class DialogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fifa-dialogs-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.log = self.work / "dialogs.jsonl"
        self.calls = self.work / "setup.jsonl"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("AURORA_", "FIFA", "CX_", "SSH_"))}
        self.env.update(HOME=str(self.work), CX_DIALOGS="1", UI_LOG=str(self.log),
                        SETUP_LOG=str(self.calls), PATH=str(self.bin) + ":" + self.env["PATH"],
                        CX_BOTTLE_PATH=str(self.work / "no-bottles"),
                        AURORA_TARGET=str(self.work / "no-app.app"))
        launcher = self.bin / "launchctl"
        launcher.write_text("#!/bin/sh\necho Aqua\n")
        launcher.chmod(0o755)
        osa = self.bin / "osascript"
        osa.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
log = Path(os.environ['UI_LOG'])
count = len(log.read_text().splitlines()) if log.exists() else 0
with log.open('a') as out:
    out.write(json.dumps({'args': sys.argv[1:], 'script': sys.stdin.read()}) + '\\n')
replies = json.loads(os.environ.get('UI_REPLIES', '[]'))
reply = replies[count] if count < len(replies) else ''
if reply == '__cancel__': sys.exit(1)
print(reply)
''')
        osa.chmod(0o755)
        self.package = self.work / "package"
        (self.package / "lib").mkdir(parents=True)
        shutil.copy2(ROOT / "lib/ui.zsh", self.package / "lib/ui.zsh")
        shutil.copy2(ROOT / "Choose game folders.command", self.package / "Choose game folders.command")
        stub = self.package / "setup.sh"
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ['SETUP_LOG']).open('a') as out:
    out.write(json.dumps(args) + '\\n')
if os.environ.get('SETUP_ENV_LOG'):
    with Path(os.environ['SETUP_ENV_LOG']).open('a') as out:
        out.write(json.dumps([os.environ.get('CX_DIALOGS'), os.environ.get('AURORA_GAME')]) + '\\n')
if args and args[0] == '--shutdown': sys.exit(int(os.environ.get('SHUTDOWN_RC', '0')))
if args and args[0] == '--choose-folder' and os.environ.get('VALID_FOLDER'):
    sys.exit(0 if args[-1] == os.environ['VALID_FOLDER'] else 2)
sys.exit(int(os.environ.get('SETUP_RC', '0')))
''')
        # The command deliberately invokes setup.sh through zsh; use a shell
        # stub that forwards its arguments to the Python fixture.
        stub.rename(self.package / "setup-fixture.py")
        stub.write_text('#!/bin/zsh\nexec python3 "${0:A:h}/setup-fixture.py" "$@"\n')

    def run_shell(self, command, replies=(), **env):
        return subprocess.run(["/bin/zsh", "-c", command], cwd=self.work,
                              env={**self.env, "UI_REPLIES": json.dumps(replies), **env},
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)

    def run_chooser(self, replies, **env):
        self.log.unlink(missing_ok=True)
        self.calls.unlink(missing_ok=True)
        return self.run_shell('/bin/zsh ' + shlex_quote(str(self.package / "Choose game folders.command")),
                              replies, **env)

    def setup_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def run_setup_preflight(self, args=(), replies=(), prefix='', **env):
        # Run the actual initialization, resolver, and folder preflight. Stop
        # before install actions so fixtures never reach real apps/processes.
        fixes = self.package / "fixes/x86_64-unix"
        fixes.mkdir(parents=True, exist_ok=True)
        (fixes / "ntdll.so").write_bytes(b"CX_GAME_PROFILES")
        shutil.copy2(ROOT / "fixes/x86_64-unix/cx-fifa17-gate", fixes / "cx-fifa17-gate")
        source = (ROOT / "setup.sh").read_text().split(
            "# ------------------------------------------------- the launch that is watched", 1)[0]
        script = self.package / "preflight.sh"
        script.write_text(source + '\nprint -r -- "CONTINUED folder=$(game_dir_of "$GAME" || true)"\n')
        command = prefix + '/bin/zsh ' + shlex_quote(str(script))
        command += ''.join(' ' + shlex_quote(arg) for arg in args)
        return self.run_shell(command, replies, CX_VOLUMES_DIR=str(self.work / 'no-volumes'), **env)

    def test_missing_game_files_prompt_before_any_install_changes(self):
        choices = self.work / 'Library/Application Support/FIFA-CrossOver/choices.conf'
        for game, exe, args in [('fifa15', 'fifa15.exe', ['--fifa15']),
                                ('fifa16', 'fifa16.exe', ['--fifa16']),
                                ('fifa17', 'FIFA17.exe', []),
                                ('fifa21', 'FIFA21.exe', ['--fifa21'])]:
            with self.subTest(game=game):
                self.log.unlink(missing_ok=True)
                choices.unlink(missing_ok=True)
                folder = self.work / ('Selected ' + game)
                folder.mkdir()
                (folder / exe).write_bytes(b'MZ')
                result = self.run_setup_preflight(args, [str(folder)], AURORA_GAME=game)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('CONTINUED folder=' + str(folder.resolve()), result.stdout)
                record = json.loads(self.log.read_text())
                self.assertIn('Select FIFA ' + game[4:] + ' game files', record['args'][1])
                self.assertIn(exe, record['args'][1])
                self.assertIn(f'{game}.folder={folder.resolve()}\n', choices.read_text())
                self.assertFalse((self.work / 'no-app.app').exists())
                self.assertFalse((self.work / 'no-bottles').exists())

    def test_missing_files_prompt_stops_when_the_choice_cannot_be_saved(self):
        # The prompt runs with set -e off (prompt_for_missing_game_files ||
        # exit): a failed write must stop setup, not move a short file into
        # place and carry on.
        choices = self.work / 'Library/Application Support/FIFA-CrossOver/choices.conf'
        choices.parent.mkdir(parents=True)
        original = ('# My choices\nfifa17.folder=/other\n'
                    + 'fifa16.shared_pae=no\n' * 22).encode()
        self.assertLess(len(original), 512)
        choices.write_bytes(original)
        folder = self.work / ('Selected FIFA 15 ' + 'x' * 60)
        folder.mkdir()
        (folder / 'fifa15.exe').write_bytes(b'MZ')
        result = self.run_setup_preflight(['--fifa15'], [str(folder)],
                                          prefix=file_size_limit(1))
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn('The previous choices were kept', result.stdout)
        self.assertNotIn('CONTINUED', result.stdout)
        self.assertNotIn('saved FIFA 15', result.stdout)
        self.assertEqual(choices.read_bytes(), original)
        self.assertEqual(list(choices.parent.glob('.choices-*')), [])
        self.assertFalse((self.work / 'no-app.app').exists())
        self.assertFalse((self.work / 'no-bottles').exists())

    def test_missing_files_cancel_or_disabled_dialogs_never_save_a_choice(self):
        choices = self.work / 'Library/Application Support/FIFA-CrossOver/choices.conf'
        result = self.run_setup_preflight(['--fifa15'], ['__cancel__'])
        self.assertEqual(result.returncode, 130, result.stdout + result.stderr)
        self.assertNotIn('CONTINUED', result.stdout)
        self.assertFalse(choices.exists())
        for env in ({'CX_NO_DIALOGS': '1'}, {'SSH_CONNECTION': 'test'}, {'CX_DIALOGS': '0'}):
            with self.subTest(env=env):
                self.log.unlink(missing_ok=True)
                result = self.run_setup_preflight(['--fifa15'], **env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('CONTINUED', result.stdout)
                self.assertFalse(self.log.exists())
                self.assertFalse(choices.exists())

    def test_found_game_files_and_read_only_modes_never_prompt(self):
        folder = self.work / 'Found FIFA 15'
        folder.mkdir()
        (folder / 'fifa15.exe').write_bytes(b'MZ')
        result = self.run_setup_preflight(['--fifa15'], FIFA15_DIR=str(folder))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CONTINUED folder=' + str(folder.resolve()), result.stdout)
        self.assertFalse(self.log.exists())
        for args in (['--fifa15', '--verify'], ['--shutdown'], ['--report'], ['--bundle']):
            with self.subTest(args=args):
                result = self.run_setup_preflight(args, AURORA_BOTTLE='Explicit bottle',
                                                  AURORA_GAME='fifa15' if '--fifa15' in args else 'fifa17')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.log.exists())

    def test_install_wrappers_enable_prompts_and_report_cancel_without_success(self):
        env_log = self.work / 'setup-env.jsonl'
        cases = [('FIFA 15.command', [], ['--fifa15'], None),
                 ('FIFA 16.command', [], ['--fifa16'], None),
                 ('START HERE.command', [], [], 'fifa17'),
                 ('START HERE offline.command', [], ['--offline'], 'fifa17'),
                 ('diagnostics/_action.zsh', ['--repair'], ['--repair'], 'fifa17')]
        for name, args, wanted, game in cases:
            with self.subTest(name=name):
                self.calls.unlink(missing_ok=True)
                env_log.unlink(missing_ok=True)
                target = self.package / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
                if name.startswith('diagnostics/'):
                    (target.parent / 'placeholder.command').write_text('#!/bin/zsh\n')
                command = '/bin/zsh ' + shlex_quote(str(target))
                command += ''.join(' ' + shlex_quote(arg) for arg in args)
                result = self.run_shell(command, SETUP_RC='130', SETUP_ENV_LOG=str(env_log))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.setup_calls(), [wanted])
                self.assertEqual(json.loads(env_log.read_text()), ['1', game])
                self.assertIn('Cancelled. No app or bottle was changed.', result.stdout)
                self.assertNotIn('Finished.', result.stdout)

    def test_missing_files_invalid_selection_can_be_retried_before_save(self):
        folder = self.work / 'Selected FIFA 15'
        folder.mkdir()
        (folder / 'fifa15.exe').write_bytes(b'MZ')
        result = self.run_setup_preflight(['--fifa15'], ['/wrong', 'Select again', str(folder)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CONTINUED folder=' + str(folder.resolve()), result.stdout)
        choices = self.work / 'Library/Application Support/FIFA-CrossOver/choices.conf'
        self.assertIn(f'fifa15.folder={folder.resolve()}\n', choices.read_text())

    def test_native_game_selection_handles_a_pick_and_cancel(self):
        # Execute the real AppleScript through its assignment and return path.
        # Replace only the interactive command, so no GUI interaction is needed.
        helper = (ROOT / "lib/ui.zsh").read_text().split("ui_pick_game() {", 1)[1]
        script = re.search(r"<<'EOS'\n(.*?)\nEOS", helper, re.S).group(1)
        for selection, expected in [('{"FIFA 17"}', "FIFA 17"), ('false', '')]:
            with self.subTest(selection=selection):
                runtime_script, replaced = re.subn(
                    r'(set \w+ to) choose from list[^\n]+',
                    lambda match: match.group(1) + ' ' + selection, script)
                self.assertEqual(replaced, 1)
                result = subprocess.run(
                    ["/usr/bin/osascript", "-", "Choose game folders", "1"],
                    input=runtime_script, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_disabled_dialogs_and_ssh_never_call_osascript(self):
        command = ('source ' + shlex_quote(str(ROOT / "lib/ui.zsh"))
                   + '; ui_ask Title Text Yes No no; ask=$?; '
                   'ui_choose_folder Prompt /Volumes; folder=$?; print -r -- "$ask $folder"')
        for env in ({"CX_NO_DIALOGS": "1"}, {"SSH_CONNECTION": "test"},
                    {"SSH_TTY": "/dev/test"}, {"CX_DIALOGS": "0"}):
            with self.subTest(env=env):
                result = self.run_shell(command, **env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), "1 1")
                self.assertFalse(self.log.exists())

    def test_prompt_text_and_paths_are_arguments_not_applescript(self):
        location = self.work / 'Drive " with $(touch PWNED)'
        location.mkdir()
        prompt = 'Choose "this" folder; $(touch PWNED)'
        command = ('source ' + shlex_quote(str(ROOT / "lib/ui.zsh"))
                   + '; ui_choose_folder ' + shlex_quote(prompt) + ' ' + shlex_quote(str(location)))
        result = self.run_shell(command, [str(location)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = json.loads(self.log.read_text())
        self.assertEqual(record['args'], ['-', prompt, str(location)])
        self.assertNotIn(prompt, record['script'])
        self.assertNotIn(str(location), record['script'])
        self.assertFalse((self.work / "PWNED").exists())

    def test_later_cancel_and_timeout_never_apply_or_quit_crossover(self):
        for replies, wanted in [
            ([''], []), (['FIFA 15', '__cancel__'], []),
            (['FIFA 15', '/game/FIFA 15', 'Later'], [['--choose-folder', 'fifa15', '/game/FIFA 15']]),
            (['FIFA 15', '/game/FIFA 15', 'timeout'], [['--choose-folder', 'fifa15', '/game/FIFA 15']]),
        ]:
            with self.subTest(replies=replies):
                result = self.run_chooser(replies)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.setup_calls(), wanted)

    def test_apply_requires_the_button_and_a_successful_shutdown(self):
        for shutdown_rc, expected_rc, count in [("0", 0, 3), ("3", 3, 2)]:
            with self.subTest(shutdown_rc=shutdown_rc):
                result = self.run_chooser(['FIFA 16', '/game/FIFA 16', 'Apply and quit CrossOver', ''],
                                          SHUTDOWN_RC=shutdown_rc)
                self.assertEqual(result.returncode, expected_rc, result.stdout + result.stderr)
                expected = [['--choose-folder', 'fifa16', '/game/FIFA 16'],
                            ['--shutdown'], ['--fifa16']]
                self.assertEqual(self.setup_calls(), expected[:count])

    def test_choose_again_and_forget_do_not_apply_settings(self):
        result = self.run_chooser(['FIFA 15', '/wrong', 'Choose again', '/valid', 'Later'],
                                  VALID_FOLDER='/valid')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.setup_calls(), [['--choose-folder', 'fifa15', '/wrong'],
                                             ['--choose-folder', 'fifa15', '/valid']])
        result = self.run_chooser(['Forget a choice…', 'FIFA 17', ''])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.setup_calls(), [['--forget-folder', 'fifa17']])

    def test_cli_folder_dialog_saves_a_choice_but_cancel_keeps_it(self):
        folder = self.work / 'FIFA 15'
        folder.mkdir()
        (folder / 'fifa15.exe').write_bytes(b'MZ')
        command = '/bin/zsh ' + shlex_quote(str(ROOT / 'setup.sh')) + ' --choose-folder fifa15'
        result = self.run_shell(command, [str(folder)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = json.loads(self.log.read_text())
        self.assertIn('Select FIFA 15 game files', record['args'][1])
        self.assertIn('fifa15.exe', record['args'][1])
        choices = self.work / 'Library/Application Support/FIFA-CrossOver/choices.conf'
        before = choices.read_bytes()
        self.log.unlink()
        result = self.run_shell(command, ['__cancel__'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(choices.read_bytes(), before)


class SharedBottleTests(unittest.TestCase):
    """One bottle, every game. With a CrossOver-FIFA whose ntdll.so has the
    per-game profile table (marker: CX_GAME_PROFILES), a game is added to
    another game's bottle and the bottle gets only what the games share.
    Without it the old one-game-one-bottle rule stands, and the stop says why
    and what would let them share. Nothing here touches a real bottle: every
    path is under a temporary directory."""

    WINE = "Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fifa-shared-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.bottles = self.work / "bottles"
        self.bottles.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("AURORA_", "FIFA1", "FIFA2", "CX_", "WEBVIEW2_",
                                         "REBORN_"))}
        # The drives are the test's own: this Mac may have FIFA folders on a
        # real one, and game_dir_candidates looks there.
        self.env.update(CX_BOTTLE_PATH=str(self.bottles), HOME=str(self.work),
                        AURORA_RECEIPT_DIR=str(self.work / "receipts"), NO_COLOR="1",
                        CX_VOLUMES_DIR=str(self.work / "Volumes"))
        # The read-only start of setup.sh, up to where anything could change,
        # run from the temporary directory so its fixes/ is the test's own.
        source = (ROOT / "setup.sh").read_text().split(
            "# --------------------------------------------------------- safety guards", 1)[0]
        self.probe = self.work / "probe.sh"
        self.probe.write_text(source + '\nprint -r -- "PROFILES=$PROFILES"\n'
                              'print -r -- "SHARED=${(j:,:)SHARED_WITH}"\n'
                              'print -rl -- $BOTTLE_SETTINGS\n')

    def copy(self, marker, name="CrossOver-FIFA.app"):
        ntdll = self.work / name / self.WINE
        ntdll.parent.mkdir(parents=True, exist_ok=True)
        ntdll.write_bytes(b"\x7fELF ntdll" + (b" CX_GAME_PROFILES\x00" if marker else b"\x00"))
        return self.work / name

    def shipped(self, marker):
        ntdll = self.work / "fixes/x86_64-unix/ntdll.so"
        ntdll.parent.mkdir(parents=True, exist_ok=True)
        ntdll.write_bytes(b"ntdll" + (b" CX_GAME_PROFILES" if marker else b""))

    def bottle(self, name, *settings):
        folder = self.bottles / name
        folder.mkdir(parents=True, exist_ok=True)
        conf = folder / "cxbottle.conf"
        conf.write_text("[EnvironmentVariables]\n"
                        + "".join(f'"{k}" = "{v}"\n' for k, v in settings))
        return conf

    def run_probe(self, *args, **env):
        result = subprocess.run(["/bin/zsh", str(self.probe), *args],
                                env={**self.env, **env}, capture_output=True, text=True,
                                timeout=20)
        return result, result.stdout.splitlines()

    def test_with_the_table_a_game_is_added_to_another_games_bottle(self):
        app = self.copy(marker=True)
        self.bottle("Aurora17", ("CX_GRAPHICS_BACKEND", "d3dmetal"), ("CX_DR_TRAP", "2"))
        self.bottle("Aurora15", ("CX_TOPDOWN_LIMIT", "0x1ffffffff"))
        for game, bottle, other, wanted, unwanted in [
            ("fifa15", "Aurora17", "FIFA 17", [], ["CX_TOPDOWN_LIMIT=", "CX_DR_TRAP="]),
            ("fifa16", "Aurora17", "FIFA 17", ["CX_PF_PAE=1"],
             ["CX_DR_TRAP=", "CX_FIFA16_DSTFIX=", "CX_TOPDOWN_LIMIT="]),
            # FIFA 17 keeps its bare CX_DR_TRAP=2: the launchers were proven with it.
            ("fifa17", "Aurora15", "FIFA 15", ["CX_DR_TRAP=2"], ["CX_TOPDOWN_LIMIT="]),
        ]:
            with self.subTest(game=game):
                result, lines = self.run_probe("--verify", AURORA_GAME=game,
                                               AURORA_BOTTLE=bottle, AURORA_TARGET=str(app))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PROFILES=1", lines)
                self.assertIn(other, lines[1])
                for setting in ["CX_GRAPHICS_BACKEND=d3dmetal", "WINE_SIMULATE_WRITECOPY=1", *wanted]:
                    self.assertIn(setting, lines)
                for prefix in unwanted:
                    self.assertFalse(any(line.startswith(prefix) for line in lines[2:]), prefix)

    def test_without_the_table_each_game_still_needs_its_own_bottle_and_is_told_why(self):
        conf = self.bottle("Aurora17", ("CX_DR_TRAP", "2"))
        contents = conf.read_text()
        cases = [
            # (copy has it, package has it, extra setting, what the stop says)
            (False, True, None, "./setup.sh --repair"),
            (False, False, None, "Download the current package"),
            (None, True, None, "Install it first"),
            (True, True, ("CX_GAME_PROFILES", "0"), "turns that table off"),
        ]
        for copy_marker, shipped_marker, extra, says in cases:
            with self.subTest(copy=copy_marker, shipped=shipped_marker, extra=extra):
                self.shipped(shipped_marker)
                if copy_marker is None:
                    app = self.work / "missing.app"
                else:
                    app = self.copy(copy_marker, name=f"copy-{copy_marker}.app")
                if extra:
                    conf.write_text(contents + f'"{extra[0]}" = "{extra[1]}"\n')
                else:
                    conf.write_text(contents)
                before = conf.read_text()
                result, _ = self.run_probe("--verify", AURORA_GAME="fifa15",
                                           AURORA_BOTTLE="Aurora17", AURORA_TARGET=str(app))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("needs its own bottle", result.stdout)
                self.assertIn("per-game profile table", result.stdout)
                self.assertIn(says, result.stdout)
                self.assertEqual(conf.read_text(), before)

    def test_setting_a_game_up_judges_by_the_ntdll_it_will_install(self):
        # --fifa15 on an existing copy brings the shipped ntdll.so in
        # (add_game_ntdll), so the package's file is the one that counts.
        app = self.copy(marker=False)
        self.shipped(True)
        self.bottle("Aurora17", ("CX_DR_TRAP", "2"))
        result, lines = self.run_probe("--fifa15", AURORA_BOTTLE="Aurora17", AURORA_TARGET=str(app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PROFILES=1", lines)
        # A mode that leaves the copy alone goes by the copy.
        result, _ = self.run_probe("--fifa15", "--verify", AURORA_BOTTLE="Aurora17",
                                   AURORA_TARGET=str(app))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("./setup.sh --repair", result.stdout)

    def test_add_game_ntdll_brings_the_table_into_an_older_copy(self):
        body = function_source("add_game_ntdll")
        self.assertIn('ntdll_has_profiles "$wine/$f" || ! ntdll_has_profiles "$HERE/fixes/$f"', body)

    # ------------------------------------------------------- add_setting

    def add_setting(self, conf, soft, key, value):
        harness = ("set -eu\nE_INCOMPLETE=5\nGAME_LABEL='FIFA 17'\n"
                   "CONF=" + shlex_quote(str(conf)) + "\n"
                   f"SOFT_SETTINGS=( {soft} )\n"
                   'ok() { print -r -- "OK $*"; }\nnote() { print -r -- "NOTE $*"; }\n'
                   'say() { print -r -- "SAY $*"; }\n'
                   'die() { print -r -- "DIE $*"; exit "$1"; }\n'
                   + function_source("add_setting")
                   + f"add_setting {key} {value}\n")
        return subprocess.run(["/bin/zsh", "-c", harness], capture_output=True, text=True,
                              timeout=10)

    def test_adding_a_second_game_never_trips_over_the_first_games_value(self):
        conf = self.bottle("FIFA16", ("CX_DR_TRAP", "3"), ("CX_FIFA16_DSTFIX", "0"))
        before = conf.read_text()
        result = self.add_setting(conf, "CX_DR_TRAP", "CX_DR_TRAP", "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NOTE CX_DR_TRAP is 3 in this bottle", result.stdout)
        self.assertEqual(conf.read_text(), before, "the other game's value was changed")
        # Any other key with a wrong value is still a stop, as it always was.
        conf.write_text(before + '"CX_GRAPHICS_BACKEND" = "dxvk"\n')
        result = self.add_setting(conf, "CX_DR_TRAP", "CX_GRAPHICS_BACKEND", "d3dmetal")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        # And without the table CX_DR_TRAP is not soft either.
        conf.write_text(before)
        result = self.add_setting(conf, "", "CX_DR_TRAP", "2")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)

    # ------------------------------------------- FIFA 16 on Wine's own runtime

    def pin_harness(self, reg):
        source = (ROOT / "setup.sh").read_text()
        return ("set -u\n"
                "OVERRIDE_SECTION='[Software\\\\Wine\\\\DllOverrides]'\n"
                "bottle_user_reg() { print -r -- " + shlex_quote(str(reg)) + "; }\n"
                + [line for line in source.splitlines() if line.startswith("F16_CRT_PIN=")][0] + "\n"
                + "appdefaults_section() {" + source.split("appdefaults_section() {", 1)[1].split("\n", 1)[0] + "\n"
                + function_source("reg_line_is_set") + function_source("set_reg_line")
                + function_source("f16_crt_pin_needed") + function_source("f16_crt_is_pinned")
                + function_source("f16_pin_crt"))

    def test_fifa16_is_kept_on_wines_runtime_only_where_fifa15s_is_bottle_wide(self):
        reg = self.work / "user.reg"
        plain = ('WINE REGISTRY Version 2\n\n'
                 '[Software\\\\Wine\\\\DllOverrides] 1758000000\n'
                 '"version"="native,builtin"\n')
        reg.write_text(plain)
        script = self.pin_harness(reg) + 'f16_crt_pin_needed && print -r -- NEEDED\n'
        result = subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True, timeout=10)
        self.assertNotIn("NEEDED", result.stdout)

        reg.write_text(plain + '"msvcr110"="native,builtin"\n"msvcp110"="native,builtin"\n')
        script = (self.pin_harness(reg) + 'f16_crt_pin_needed && print -r -- NEEDED\n'
                  'f16_crt_is_pinned && print -r -- EARLY\n'
                  'f16_pin_crt && f16_crt_is_pinned && print -r -- PINNED\n')
        result = subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NEEDED", result.stdout)
        self.assertNotIn("EARLY", result.stdout)
        self.assertIn("PINNED", result.stdout)
        text = reg.read_text()
        self.assertIn('[Software\\\\Wine\\\\AppDefaults\\\\fifa16.exe\\\\DllOverrides] 0\n'
                      '"msvcr110"="builtin"\n"msvcp110"="builtin"\n', text)
        # The bottle-wide values FIFA 15 relies on are left where they are.
        self.assertIn('"msvcr110"="native,builtin"', text)

    # --------------------------------------------------- the table in --verify

    def shared_bottle(self):
        app = self.copy(marker=True)
        conf = self.bottle("Shared", ("CX_GRAPHICS_BACKEND", "d3dmetal"), ("CX_DR_TRAP", "2"),
                           ("WINE_SIMULATE_WRITECOPY", "1"), ("CX_PF_PAE", "1"))
        root = self.bottles / "Shared"
        local = root / "drive_c/users/crossover/AppData/Local"
        aurora = local / "Aurora15Connector"
        aurora.mkdir(parents=True)
        (aurora / "Aurora15Connector.exe").write_bytes(b"MZ")
        (aurora / "Aurora15Connector.ini").write_text("FifaPath=\r\nFifa21Path=Y:\\Games\\FIFA 21\r\n")
        (local / "CAS").mkdir()
        (local / "CAS/cas.exe").write_bytes(b"MZ")
        (root / "dosdevices").mkdir()
        # Resolved: the temporary folder is under /var, which is /private/var,
        # and the game folder is compared after its symlinks are resolved.
        (root / "dosdevices/y:").symlink_to(self.work.resolve(), target_is_directory=True)
        fifa21 = self.work / "Games/FIFA 21"
        fifa21.mkdir(parents=True)
        (fifa21 / "FIFA21.exe").write_bytes(b"MZ")
        fifa16 = self.work / "Downloads/FIFA 16"
        fifa16.mkdir(parents=True)
        (fifa16 / "fifa16.exe").write_bytes(b"MZ")
        (root / "user.reg").write_text(
            'WINE REGISTRY Version 2\n\n'
            '[Software\\\\Wine\\\\AppDefaults\\\\fifa16.exe\\\\CrossOver-FIFA] 0\n'
            '"Profile"="fifa16"\n"DrTrap"="3"\n\n'
            '[Software\\\\Wine\\\\AppDefaults\\\\FIFA21.exe\\\\DllOverrides] 0\n'
            '"ucrtbase"="native,builtin"\n')
        return app, conf

    def verify(self, app, **env):
        return subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--verify"],
                              env={**self.env, "AURORA_BOTTLE": "Shared",
                                   "AURORA_TARGET": str(app), **env},
                              capture_output=True, text=True, timeout=120)

    @staticmethod
    def tables(stdout):
        """The games table as {game: cells} and the launcher table as
        {(launcher, game): state}. Columns are two or more spaces apart."""
        games, launchers, which, last = {}, {}, None, ""
        for line in stdout.splitlines():
            if line.startswith("  game "):
                which = "games"; continue
            if line.startswith("  launcher "):
                which = "launchers"; continue
            if not line.strip() or line.strip().startswith("─"):
                if not line.strip():
                    which = None
                continue
            if which == "games":
                cells = re.split(r"\s{2,}", line.strip())
                games[cells[0]] = cells
            elif which == "launchers":
                name = line[2:].split("  ")[0].strip() if line[2] != " " else ""
                last = name or last
                rest = re.split(r"\s{2,}", line[2 + len(name):].strip())
                launchers[(last, rest[0])] = rest[1]
        return games, launchers

    @staticmethod
    def table(stdout):
        return SharedBottleTests.tables(stdout)[0]

    def test_verify_names_the_package_that_last_installed(self):
        app, _ = self.shared_bottle()
        receipt = self.work / "receipts/install-receipt.conf"
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text("mode=copy\nversion=26.3.0\npatch_version=0.9.0 (1234abc)\n")
        out = self.verify(app).stdout
        self.assertIn("last install or repair: 0.9.0 (1234abc)", out)
        receipt.write_text("mode=copy\nversion=26.3.0\n")
        out = self.verify(app).stdout
        self.assertIn("last install or repair: a package from before version numbers", out)

    def test_plain_verify_prints_every_game_and_launcher_and_changes_nothing(self):
        app, conf = self.shared_bottle()
        before = {p: p.read_bytes() for p in (self.bottles / "Shared").rglob("*") if p.is_file()}
        result = self.verify(app)
        self.assertIn(result.returncode, (0, 5), result.stdout + result.stderr)
        out = result.stdout
        self.assertIn("Every game in the Shared bottle", out)
        self.assertIn(f"CrossOver copy   {app.resolve()}", out)
        number = (ROOT / "VERSION").read_text().splitlines()[0]
        self.assertIn(f"patch version    this package {number}; last install or repair: none recorded",
                      out)
        self.assertIn("per-game table   yes", out)
        self.assertIn("CX_PF_PAE        1", out)
        self.assertIn("  game ", out)
        self.assertNotIn("| ", out)
        rows, launchers = self.tables(out)
        self.assertEqual(sorted(rows), ["FIFA 13", "FIFA 15", "FIFA 16", "FIFA 17", "FIFA 21"])
        # game | folder | settings | DLL overrides | offline
        self.assertEqual(rows["FIFA 21"][1:4], ["found (Aurora.exe)", "table", "ucrtbase"])
        self.assertEqual(rows["FIFA 16"][1:4],
                         ["found (guess)", "AppDefaults (Profile=fifa16, DrTrap=3)", "none needed"])
        self.assertEqual(rows["FIFA 15"][1], "missing")
        self.assertEqual(rows["FIFA 13"][2], "bare env")
        # No offline start for FIFA 13 and 21; FIFA 16 run by hand: found,
        # and y: reaches it.
        self.assertEqual(rows["FIFA 13"][4], "-")
        self.assertEqual(rows["FIFA 21"][4], "-")
        self.assertEqual(rows["FIFA 16"][4], "ready")
        # Which launcher starts which game: only those rows are there.
        self.assertEqual(sorted(g for l, g in launchers if l == "Aurora.exe"),
                         ["FIFA 13", "FIFA 15", "FIFA 16", "FIFA 17", "FIFA 21"])
        self.assertEqual(sorted(l for l, _ in launchers), sorted(
            ["Aurora.exe"] * 5 + ["Impulsum17", "CAS", "RebornFUT"]))
        self.assertNotIn("unsupported", out.split("FIFA 17 in detail")[0])
        # Present but not ready, each saying what it lacks first.
        self.assertEqual(launchers[("Aurora.exe", "FIFA 15")], "missing game folder")
        self.assertEqual(launchers[("Aurora.exe", "FIFA 16")], "missing proxy setting")
        self.assertEqual(launchers[("Impulsum17", "-")], "not installed")
        self.assertEqual(launchers[("CAS", "FIFA 17")], "missing game folder")
        self.assertEqual(launchers[("RebornFUT", "-")], "not installed")
        # FIFA 17's own checks still follow, as they always did.
        self.assertIn("FIFA 17 in detail", out)
        after = {p: p.read_bytes() for p in (self.bottles / "Shared").rglob("*") if p.is_file()}
        self.assertEqual(after, before, "--verify changed the bottle")

    def test_without_the_table_the_bare_variables_decide(self):
        app = self.copy(marker=False)
        self.bottle("Shared", ("CX_DR_TRAP", "2"))
        result = self.verify(app)
        rows = self.table(result.stdout)
        self.assertIn("per-game table   no", result.stdout)
        self.assertEqual(rows["FIFA 17"][2], "bare env")
        self.assertEqual(rows["FIFA 21"][2], "bare env")
        self.assertEqual(rows["FIFA 15"][2], "missing CX_TOPDOWN_LIMIT")
        self.assertEqual(rows["FIFA 16"][2], "missing CX_DR_TRAP=3 CX_FIFA16_DSTFIX")

    def test_a_named_game_checks_that_game_only(self):
        app, _ = self.shared_bottle()
        result = self.verify(app, AURORA_GAME="fifa16")
        self.assertNotIn("Every game in the", result.stdout)
        self.assertIn("FIFA 16's own settings: AppDefaults (Profile=fifa16, DrTrap=3)", result.stdout)
        self.assertIn("ok    CX_PF_PAE", result.stdout)


    # ------------------------------------------- PAE from a bare CX_DR_TRAP=3

    def fifa16_bottle(self):
        app = self.copy(marker=True)
        conf = self.bottle("FIFA16", ("CX_GRAPHICS_BACKEND", "d3dmetal"),
                           ("WINE_SIMULATE_WRITECOPY", "1"), ("CX_DR_TRAP", "3"),
                           ("CX_FIFA16_DSTFIX", "0"))
        return app, conf

    def test_a_fifa16_bottle_from_before_the_table_already_has_pae(self):
        # ntdll's cx_pf_pae is true for a bare CX_DR_TRAP=3, so such a bottle
        # needs no CX_PF_PAE. --fifa16 --verify used to say "BAD CX_PF_PAE is
        # not set to 1" (exit 5) and "ok ...; missing CX_PF_PAE=1".
        app, conf = self.fifa16_bottle()
        result, lines = self.run_probe("--verify", AURORA_GAME="fifa16", AURORA_TARGET=str(app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PROFILES=1", lines)
        self.assertFalse(any(l.startswith("CX_PF_PAE=") for l in lines[2:]), lines)
        before = conf.read_text()
        result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--fifa16", "--verify"],
                                env={**self.env, "AURORA_TARGET": str(app)},
                                capture_output=True, text=True, timeout=120)
        out = result.stdout
        self.assertNotIn("CX_PF_PAE is not set", out)
        self.assertIn("FIFA 16's own settings: table (", out)
        for line in out.splitlines():
            if line.strip().startswith("ok"):
                self.assertNotIn("missing", line)
        self.assertEqual(conf.read_text(), before)
        # Without a bare 3 it is still asked for, and its absence still said.
        conf.write_text(before.replace('"CX_DR_TRAP" = "3"', '"CX_DR_TRAP" = "2"'))
        result, lines = self.run_probe("--verify", AURORA_GAME="fifa16", AURORA_TARGET=str(app))
        self.assertIn("CX_PF_PAE=1", lines)
        result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--fifa16", "--verify"],
                                env={**self.env, "AURORA_TARGET": str(app)},
                                capture_output=True, text=True, timeout=120)
        self.assertIn("CX_PF_PAE is not set to 1", result.stdout)
        self.assertIn("note  FIFA 16's own settings: table; missing CX_PF_PAE=1", result.stdout)

    def test_the_table_counts_a_bare_dr_trap_3_as_pae(self):
        app, conf = self.fifa16_bottle()
        result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--verify"],
                                env={**self.env, "AURORA_BOTTLE": "FIFA16", "AURORA_TARGET": str(app)},
                                capture_output=True, text=True, timeout=120)
        self.assertIn("PAE is on: the bottle's CX_DR_TRAP is 3", result.stdout)
        self.assertEqual(self.table(result.stdout)["FIFA 16"][2], "table")

    # ------------------------------------- leftover single-game variables

    def removal(self, conf, *names):
        harness = ('ok() { print -r -- "OK $*"; }\nnote() { print -r -- "NOTE $*"; }\n'
                   'say() { print -r -- "SAY $*"; }\n'
                   + function_source("remove_leftover_game_vars")
                   + 'LEFTOVER_GAME_VARS=( CX_TOPDOWN_LIMIT CX_FIFA16_DSTFIX )\n'
                   + function_source("leftover_game_vars")
                   + 'stray=( ${(f)"$(leftover_game_vars ' + shlex_quote(str(conf)) + ')"} )\n'
                   + 'print -r -- "STRAY ${stray[*]}"\n'
                   + 'remove_leftover_game_vars ' + shlex_quote(str(conf)) + ' $stray\n')
        return subprocess.run(["/bin/zsh", "-c", harness], capture_output=True, text=True, timeout=10)

    def test_a_shared_bottle_loses_the_single_game_variables_and_keeps_a_backup(self):
        conf = self.bottle("FIFA16", ("CX_GRAPHICS_BACKEND", "d3dmetal"), ("CX_DR_TRAP", "3"),
                           ("CX_FIFA16_DSTFIX", "0"), ("CX_TOPDOWN_LIMIT", "0x1ffffffff"))
        before = conf.read_text()
        result = self.removal(conf)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("STRAY CX_TOPDOWN_LIMIT CX_FIFA16_DSTFIX", result.stdout)
        self.assertIn("OK removed CX_TOPDOWN_LIMIT from this bottle's settings", result.stdout)
        self.assertIn("OK removed CX_FIFA16_DSTFIX from this bottle's settings", result.stdout)
        after = conf.read_text()
        self.assertNotIn("CX_TOPDOWN_LIMIT", after)
        self.assertNotIn("CX_FIFA16_DSTFIX", after)
        # CX_DR_TRAP is the launchers' baseline and stays.
        self.assertIn('"CX_DR_TRAP" = "3"', after)
        self.assertIn('"CX_GRAPHICS_BACKEND" = "d3dmetal"', after)
        backups = list(conf.parent.glob("cxbottle.conf.bak-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), before)

    def test_configure_removes_them_only_where_another_game_is(self):
        body = function_source("configure_bottle")
        self.assertIn('if [ ${#stray} -gt 0 ] && [ ${#SHARED_WITH} -gt 0 ]; then\n'
                      '                remove_leftover_game_vars "$CONF" $stray', body)
        self.assertNotIn("sees it exactly as before", body)

    def test_verify_does_not_call_a_leftover_reaching_launchers_ok(self):
        app, conf = self.shared_bottle()
        conf.write_text(conf.read_text().replace('"CX_DR_TRAP" = "2"', '"CX_DR_TRAP" = "3"')
                        + '"CX_TOPDOWN_LIMIT" = "0x1ffffffff"\n')
        result = self.verify(app, AURORA_GAME="fifa16")
        out = result.stdout
        self.assertIn("note  CX_TOPDOWN_LIMIT = 0x1ffffffff is still bottle-wide here", out)
        self.assertIn("AURORA_BOTTLE='Shared' ./setup.sh --fifa16", out)
        for line in out.splitlines():
            if line.strip().startswith("ok"):
                self.assertNotIn("CX_TOPDOWN_LIMIT", line)
        # CX_DR_TRAP=3 is left, and named because the bottle has FIFA 17 launchers (CAS, Aurora.exe).
        self.assertIn("note  CX_DR_TRAP is 3 bottle-wide here", out)
        self.assertIn("Aurora.exe, CAS", out)

    # ----------------------------------------------- version stays bottle-wide

    def test_the_launchers_need_version_bottle_wide(self):
        app, _ = self.shared_bottle()
        reg = self.bottles / "Shared/user.reg"
        rows = self.table(self.verify(app).stdout)
        # Only the bottle-wide override counts for version.
        self.assertEqual(rows["FIFA 17"][3], "missing version (bottle-wide) msvcr120 msvcp120")
        reg.write_text(reg.read_text() + '\n[Software\\\\Wine\\\\DllOverrides] 0\n"version"="native,builtin"\n')
        rows = self.table(self.verify(app).stdout)
        self.assertEqual(rows["FIFA 17"][3], "missing msvcr120 msvcp120")
        body = function_source("gt_cell")
        self.assertIn('aurora|impulsum) dll_native_global version || { print -r -- "missing version override"', body)

    def fifa15_bottle_choice(self, **env):
        self.shipped(True)
        source = (ROOT / "setup.sh").read_text().split(
            "# --------------------------------------------------------- safety guards", 1)[0]
        script = self.work / "bottle-choice.sh"
        script.write_text(source + '\nprint -r -- "CHOSEN=$BOTTLE"\n')
        return subprocess.run(["/bin/zsh", str(script), "--fifa15"],
                              env={**self.env, **env}, capture_output=True,
                              text=True, timeout=10)

    def test_fifa15_defaults_to_the_multi_game_aurora_bottle(self):
        self.aurora_bottle("Aurora17", "FifaPath=\r\nFifa21Path=\r\n")
        before = self.snapshot("Aurora17")
        result = self.fifa15_bottle_choice()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHOSEN=Aurora17", result.stdout)
        self.assertFalse((self.bottles / "Aurora15").exists())
        self.assertEqual(self.snapshot("Aurora17"), before)

    def test_fifa15_default_setup_writes_its_overrides_in_auroras_bottle(self):
        # The tester regression: the launcher lives in Aurora17, so dinput8
        # and the CRT overrides must be written there by the plain --fifa15.
        app = self.copy(marker=True)
        self.shipped(True)
        self.aurora_bottle("Aurora17", "FifaPath=\r\nFifa21Path=\r\n")
        reg = self.bottles / "Aurora17/user.reg"
        reg.write_text("WINE REGISTRY Version 2\n")
        source = (ROOT / "setup.sh").read_text().split(
            "# ------------------------------------------------- the launch that is watched", 1)[0]
        script = self.work / "setup15.sh"
        # CRT file provisioning has separate real-file coverage. This test
        # runs the actual settings and registry writes in the selected bottle.
        script.write_text(source + '\nf15_ensure_crt_dlls() { return 0; }\n'
                          'configure_bottle "$TARGET"\n')
        result = subprocess.run(["/bin/zsh", str(script), "--fifa15"],
                                env={**self.env, "AURORA_TARGET": str(app),
                                     "TMPDIR": str(self.work)},
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        values = self.section_lines(reg, r'[Software\\Wine\\AppDefaults\\fifa15.exe\\DllOverrides]')
        self.assertEqual(values, ['"dinput8"="native,builtin"',
                                  '"msvcp110"="native,builtin"', '"msvcr110"="native,builtin"'])
        self.assertFalse((self.bottles / "Aurora15").exists())

    def test_fifa15_keeps_explicit_bottles_and_the_installed_legacy_connector(self):
        self.aurora_bottle("Aurora15", "FifaPath=\r\n")
        for env, name in [({}, "Aurora15"), ({"FIFA15_BOTTLE": "My 15"}, "My 15"),
                          ({"FIFA15_BOTTLE": "My 15", "AURORA_BOTTLE": "Explicit"}, "Explicit")]:
            with self.subTest(env=env):
                result = self.fifa15_bottle_choice(**env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("CHOSEN=" + name, result.stdout)
        self.aurora_bottle("Aurora17", "Fifa21Path=\r\n")
        result = self.fifa15_bottle_choice()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHOSEN=Aurora17", result.stdout)

    def test_fifa15_finds_the_renamed_multi_game_launcher_before_its_first_run(self):
        ini = self.aurora_bottle("Aurora15", "FifaPath=\r\n")
        ini.unlink()
        (ini.parent / "Aurora15Connector.exe").write_bytes(b"MZ get_Fifa21Path")
        result = self.fifa15_bottle_choice()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHOSEN=Aurora15", result.stdout)

    def test_fifa15_uses_the_common_default_without_a_launcher_and_ignores_stale_ini(self):
        ini = self.aurora_bottle("Aurora15", "Fifa21Path=\r\n")
        (ini.parent / "Aurora15Connector.exe").unlink()
        result = self.fifa15_bottle_choice(FIFA17_BOTTLE="Common")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHOSEN=Common", result.stdout)

    def test_fifa15_requires_an_explicit_choice_for_an_unrelated_aurora_bottle(self):
        self.aurora_bottle("Other Games", "Fifa21Path=\r\n")
        before = self.snapshot("Other Games")
        result = self.fifa15_bottle_choice()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("AURORA_BOTTLE='Other Games'", result.stdout + result.stderr)
        self.assertFalse((self.bottles / "Aurora17").exists())
        self.assertEqual(self.snapshot("Other Games"), before)

    # ---------------------------------------------------- where each game is

    def game_folder(self, path, exe="fifa15.exe"):
        folder = self.work / path
        folder.mkdir(parents=True, exist_ok=True)
        (folder / exe).write_bytes(b"MZ")
        return folder

    def choose(self, game, folder):
        """The player's choice, as choices.conf holds it."""
        choices = self.work / "Library/Application Support/FIFA-CrossOver/choices.conf"
        choices.parent.mkdir(parents=True, exist_ok=True)
        choices.write_text("# Your choices for the FIFA CrossOver fixes. Delete a line to forget it.\n"
                           f"{game}.folder={folder}\n")
        return choices

    def aurora_bottle(self, name, ini):
        """A bottle with the Aurora launcher in it, its ini as given, and z: on
        the temporary folder, so Z:\\Volumes\\Untitled is the fake drive."""
        self.bottle(name, ("CX_GRAPHICS_BACKEND", "d3dmetal"), ("CX_DR_TRAP", "2"),
                    ("WINE_SIMULATE_WRITECOPY", "1"))
        root = self.bottles / name
        aurora = root / "drive_c/users/crossover/AppData/Local/Aurora15Connector"
        aurora.mkdir(parents=True)
        (aurora / "Aurora15Connector.exe").write_bytes(b"MZ")
        (aurora / "Aurora15Connector.ini").write_text(ini)
        (root / "dosdevices").mkdir()
        (root / "dosdevices/z:").symlink_to(self.work.resolve(), target_is_directory=True)
        return aurora / "Aurora15Connector.ini"

    def candidates(self, game, bottle, **env):
        script = ("set -eu\nBOTTLE_DIR=" + shlex_quote(str(self.bottles)) + f"\nBOTTLE={bottle}\n"
                  + resolver_source() + f"game_dir_candidates {game}\n")
        result = subprocess.run(["/bin/zsh", "-f", "-c", script], env={**self.env, **env},
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return [tuple(line.split("\t")) for line in result.stdout.splitlines()]

    def test_fifa17_loader_operations_use_the_saved_game_files(self):
        chosen = self.game_folder('Selected FIFA 17', 'FIFA17.exe')
        (chosen / '_fifa17.exe').write_bytes(b'MZ')
        stray = self.game_folder('Downloads/FIFA 17', 'FIFA17.exe')
        (stray / '_fifa17.exe').write_bytes(b'MZ')
        self.choose('fifa17', chosen)
        harness = ('set -eu\nBOTTLE_DIR=' + shlex_quote(str(self.bottles))
                   + '\nBOTTLE=Aurora17\n' + resolver_source() + function_source('game_dir_find')
                   + '\ngame_dir_find\n')
        for env, wanted in [({}, chosen), ({'AURORA_GAME_DIR': str(stray)}, stray)]:
            with self.subTest(env=env):
                result = subprocess.run(['/bin/zsh', '-c', harness],
                                        env={**self.env, **env}, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), str(wanted.resolve()))

    def test_a_folder_is_what_was_said_then_chosen_then_recorded_then_guessed(self):
        app = self.copy(marker=True)
        on_drive = self.game_folder("Volumes/Untitled/FIFA 15")
        stray = self.game_folder("Downloads/FIFA 15")
        chosen = self.game_folder("Chosen/FIFA 15")
        given = self.game_folder("Given/FIFA 15")
        self.aurora_bottle("Aurora17", "FifaPath=Z:\\Volumes\\Untitled\\FIFA 15\r\n"
                                       "Fifa17Path=Z:\\Volumes\\Untitled\\FIFA 17\r\n")
        choices = self.choose("fifa15", chosen)
        r = lambda p: str(p.resolve())
        self.assertEqual(self.candidates("fifa15", "Aurora17", FIFA15_DIR=str(given)), [
            ("FIFA15_DIR", r(given)), ("chosen", r(chosen)),
            # The drive is a guess too; one folder is one line.
            ("Aurora.exe, guess", r(on_drive)), ("guess", r(stray))])
        # The folder Aurora.exe plays beats a stray copy in ~/Downloads, and
        # --verify says where it came from.
        choices.unlink()
        result = self.verify(app, AURORA_BOTTLE="Aurora17")
        self.assertEqual(self.table(result.stdout)["FIFA 15"][1], "found (Aurora.exe)")
        self.assertIn(f"  FIFA 15: {r(on_drive)}  (Aurora.exe's record)", result.stdout)
        self.choose("fifa15", chosen)
        result = self.verify(app, AURORA_BOTTLE="Aurora17")
        self.assertEqual(self.table(result.stdout)["FIFA 15"][1], "found (chosen)")
        self.assertIn(f"  FIFA 15: {r(chosen)}  (your choice)", result.stdout)
        # FIFA 17 keeps its own order of records, after AURORA_GAME_DIR and
        # the player's choice.
        fifa17 = self.game_folder("Volumes/Untitled/FIFA 17", "FIFA17.exe")
        own = self.game_folder("Chosen/FIFA 17", "FIFA17.exe")
        self.choose("fifa17", own)
        self.assertEqual(self.candidates("fifa17", "Aurora17"), [
            ("chosen", r(own)), ("Aurora.exe, guess", r(fifa17))])
        self.assertEqual(self.candidates("fifa17", "Aurora17", AURORA_GAME_DIR=str(fifa17)), [
            ("AURORA_GAME_DIR, Aurora.exe, guess", r(fifa17)), ("chosen", r(own))])

    def test_fifa15_in_aurora_exes_bottle_is_found_where_aurora_exe_recorded_it(self):
        # The tester's case: AURORA_BOTTLE=Aurora17 ./setup.sh --fifa15 --verify
        # said "no FIFA 15 folder found" and that every C runtime FIFA 15 can
        # reach is Wine's own, for a game on an external drive that only
        # Aurora.exe's ini names and that has Microsoft's pair beside it.
        app = self.copy(marker=True)
        game = self.game_folder("Volumes/Untitled/FIFA 15")
        for dll in ("msvcr110", "msvcp110"):
            (game / f"{dll}.dll").write_bytes(CrtOverrideTests.MICROSOFT)
        self.aurora_bottle("Aurora17", "FifaPath=Z:\\Volumes\\Untitled\\FIFA 15\r\n")
        self.game_folder("Downloads/FIFA 15")   # a stray copy with no pair in it
        result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--fifa15", "--verify"],
                                env={**self.env, "AURORA_BOTTLE": "Aurora17",
                                     "AURORA_TARGET": str(app),
                                     # Only the ini can find it, not a drive guess.
                                     "CX_VOLUMES_DIR": str(self.work / "no-drives")},
                                capture_output=True, text=True, timeout=120)
        out = result.stdout
        self.assertNotIn("no FIFA 15 folder found", out)
        self.assertIn(f"fifa15.exe in {game.resolve()}  (Aurora.exe's record)", out)
        self.assertIn(f"msvcr110 + msvcp110 — Microsoft's own, in {game.resolve()}", out)
        self.assertNotIn("every copy of the C runtime FIFA 15 can reach is Wine's own", out)

    def test_a_chosen_folder_that_is_not_there_is_said_and_not_quietly_replaced(self):
        app = self.copy(marker=True)
        on_drive = self.game_folder("Volumes/Untitled/FIFA 15")
        ini = self.aurora_bottle("Aurora17", "FifaPath=Z:\\Volumes\\Untitled\\FIFA 15\r\n")
        lost = self.work / "Volumes/X/FIFA 15"
        self.choose("fifa15", lost)
        says = f"your choice {lost} is not reachable (drive not connected?); using "
        result = self.verify(app, AURORA_BOTTLE="Aurora17")
        self.assertEqual(self.table(result.stdout)["FIFA 15"][1], "found (Aurora.exe)")
        self.assertIn(f"  FIFA 15: {says}{on_drive.resolve()}  (Aurora.exe's record)",
                      result.stdout)
        # With nothing else to go by the game is missing, and the line says why.
        ini.write_text("FifaPath=\r\n")
        nothing = {"AURORA_BOTTLE": "Aurora17", "CX_VOLUMES_DIR": str(self.work / "no-drives")}
        result = self.verify(app, **nothing)
        self.assertEqual(self.table(result.stdout)["FIFA 15"][1], "missing")
        self.assertIn(f"  FIFA 15: {says}none", result.stdout)
        result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), "--fifa15", "--verify"],
                                env={**self.env, "AURORA_TARGET": str(app), **nothing},
                                capture_output=True, text=True, timeout=120)
        self.assertIn(f"note  your choice {lost} is not reachable (drive not connected?)",
                      result.stdout)
        self.assertIn("no FIFA 15 folder found", result.stdout)

    # ------------------------------------------------- FIFA 21 (--fifa21)

    STUB = b"MZ Wine's own powershell stub"
    DNSCACHE = r'[System\\CurrentControlSet\\Services\\Dnscache]'

    def fifa21_bottle(self, name, *settings, powershell=STUB, cas=False):
        """A bottle the Aurora launcher is installed in, with FIFA 21 where its
        ini says, and Wine's own powershell.exe (or CAS's stand-in)."""
        conf = self.bottle(name, *settings)
        root = self.bottles / name
        local = root / "drive_c/users/crossover/AppData/Local"
        aurora = local / "Aurora15Connector"
        aurora.mkdir(parents=True)
        (aurora / "Aurora15Connector.exe").write_bytes(b"MZ")
        (aurora / "Aurora15Connector.ini").write_text("Fifa21Path=Y:\\Games\\FIFA 21\r\n")
        if cas:
            (local / "CAS").mkdir()
            (local / "CAS/cas.exe").write_bytes(b"MZ")
        (root / "dosdevices").mkdir()
        (root / "dosdevices/y:").symlink_to(self.work.resolve(), target_is_directory=True)
        fifa21 = self.work / "Games/FIFA 21"
        fifa21.mkdir(parents=True, exist_ok=True)
        (fifa21 / "FIFA21.exe").write_bytes(b"MZ")
        (root / "user.reg").write_text('WINE REGISTRY Version 2\n\n'
                                       '[Software\\\\Wine\\\\DllOverrides] 1758000000\n'
                                       '"*d3dcompiler_47"="native"\n')
        # A fresh bottle has a Dnscache key with Start and Type only.
        (root / "system.reg").write_text('WINE REGISTRY Version 2\n\n'
                                         + self.DNSCACHE + ' 1758000000\n'
                                         '"Start"=dword:00000003\n"Type"=dword:00000020\n')
        psdir = root / "drive_c/windows/system32/WindowsPowerShell/v1.0"
        psdir.mkdir(parents=True)
        (psdir / "powershell.exe").write_bytes(powershell)
        return conf, psdir

    def set_up_fifa21(self, app, **env):
        """--fifa21 on an existing copy, up to and including configure_bottle,
        as setup.sh runs it: its own start (arguments, the per-game settings,
        the shared-bottle guard) and every function, from a package in the
        temporary directory. Stops before the session and lock handling, which
        reach for real processes."""
        source = (ROOT / "setup.sh").read_text().split(
            "# ------------------------------------------------- the launch that is watched", 1)[0]
        for path in ("aurora17/powershell.exe", "fixes/x86_64-windows/cas-powershell.exe",
                     "fixes/x86_64-unix/cx-fifa17-gate"):
            (self.work / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, self.work / path)
        script = self.work / "setup21.sh"
        script.write_text(source + '\nconfigure_bottle "$TARGET"\nf21_check_game\n'
                          'print -r -- "MODE=$MODE OK=$BOTTLE_OK$PS_OK$HOSTS_OK '
                          'SHARED=${(j:,:)SHARED_WITH}"\n'
                          'if setup_steps_ok; then print -r -- "VERDICT=done"; '
                          'else print -r -- "VERDICT=incomplete"; fi\n')
        return subprocess.run(["/bin/zsh", str(script), "--fifa21"],
                              env={**self.env, "AURORA_TARGET": str(app),
                                   "TMPDIR": str(self.work), **env},
                              capture_output=True, text=True, timeout=60)

    @staticmethod
    def section_lines(reg, section):
        found, out = False, []
        for line in reg.read_text().splitlines():
            if line.startswith("["):
                found = line.lower().startswith(section.lower())
                continue
            if found and line.startswith('"'):
                out.append(line)
        return sorted(out)

    def snapshot(self, name):
        root = self.bottles / name
        return {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}

    def test_fifa21_outside_aurora17_gets_what_the_aurora_launcher_needs(self):
        # Test 11 of HANDOFF-per-game-setup.md: Aurora.exe in Aurora15 (a
        # FIFA 15 bottle from before the table) -> Dnscache, the PowerShell
        # stand-in in the bottle, version bottle-wide; no hosts, no licence.
        app = self.copy(marker=True)
        self.shipped(True)
        conf, psdir = self.fifa21_bottle("Aurora15", ("CX_GRAPHICS_BACKEND", "d3dmetal"),
                                         ("WINE_SIMULATE_WRITECOPY", "1"),
                                         ("CX_TOPDOWN_LIMIT", "0x1ffffffff"))
        root = self.bottles / "Aurora15"
        result = self.set_up_fifa21(app, AURORA_BOTTLE="Aurora15")
        out = result.stdout
        self.assertEqual(result.returncode, 0, out + result.stderr)
        self.assertIn("MODE=bottle OK=111 SHARED=FIFA 15", out)
        self.assertIn("VERDICT=done", out)
        self.assertEqual(self.section_lines(root / "system.reg", self.DNSCACHE), sorted([
            '"DisplayName"="DNS Client"', '"ErrorControl"=dword:00000001',
            r'"ImagePath"=str(2):"C:\\windows\\system32\\spoolsv.exe"',
            '"ObjectName"="LocalSystem"', '"Start"=dword:00000002', '"Type"=dword:00000010']))
        reg = root / "user.reg"
        self.assertEqual(self.section_lines(reg, r'[Software\\Wine\\DllOverrides]'),
                         ['"*d3dcompiler_47"="native"', '"version"="native,builtin"'])
        self.assertEqual(self.section_lines(reg, r'[Software\\Wine\\AppDefaults\\FIFA21.exe\\DllOverrides]'),
                         ['"ucrtbase"="native,builtin"'])
        proxy = self.section_lines(
            reg, r'[Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections]')
        self.assertTrue(proxy and proxy[0].startswith('"DefaultConnectionSettings"=hex:46,'), proxy)
        # The stand-in Aurora17 and FIFA 21 share, with Wine's stub kept once.
        self.assertEqual((psdir / "powershell.exe").read_bytes(),
                         (ROOT / "aurora17/powershell.exe").read_bytes())
        self.assertEqual((psdir / "powershell.exe.wine-stub-orig").read_bytes(), self.STUB)
        self.assertFalse((psdir / "aurora17-powershell.exe").exists())
        # Only what the games share; FIFA 15's leftover goes, with a backup.
        settings = conf.read_text()
        self.assertIn('"CX_GRAPHICS_BACKEND" = "d3dmetal"', settings)
        for absent in ("CX_DR_TRAP", "WEBVIEW2_", "CX_TOPDOWN_LIMIT"):
            self.assertNotIn(absent, settings)
        self.assertEqual(len(list(root.glob("cxbottle.conf.bak-*"))), 1)
        # Nothing of FIFA 17's: no hosts file, no licence, no WebView2.
        self.assertFalse((root / "drive_c/windows/system32/drivers/etc/hosts").exists())
        self.assertEqual(list(root.rglob("*.dlf")), [])
        self.assertFalse((root / "drive_c/webview2-fixed").exists())
        self.assertIn("ok    the Aurora launcher is in the Aurora15 bottle", out)

        # Idempotent: a second run says so and changes not one byte.
        before = self.snapshot("Aurora15")
        again = self.set_up_fifa21(app, AURORA_BOTTLE="Aurora15")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        for line in ("version = native,builtin for the whole bottle — already set",
                     "ucrtbase = native,builtin for FIFA21.exe — already set",
                     "proxy auto-detect off — already set",
                     "already answered in the Aurora15 bottle"):
            self.assertIn(line, again.stdout)
        self.assertEqual(self.snapshot("Aurora15"), before, "a second --fifa21 changed the bottle")

        # And the games table now calls FIFA 21 from Aurora.exe ready.
        verify = self.verify(app, AURORA_BOTTLE="Aurora15")
        self.assertEqual(self.tables(verify.stdout)[1][("Aurora.exe", "FIFA 21")], "ready",
                         verify.stdout)
        named = self.verify(app, AURORA_BOTTLE="Aurora15", AURORA_GAME="fifa21")
        for line in ("ok    PowerShell stand-in in the bottle",
                     "ok    Dnscache stand-in in the bottle",
                     "ok    ucrtbase = native,builtin for FIFA21.exe in the Aurora15 bottle",
                     "ok    FIFA 21: no Aurora ports to check"):
            self.assertIn(line, named.stdout)
        self.assertEqual(self.snapshot("Aurora15"), before, "--verify changed the bottle")

    def test_fifa21_is_not_done_without_the_dns_client_stand_in(self):
        # Every other step works; the bottle's system.reg cannot be written.
        app = self.copy(marker=True)
        self.shipped(True)
        self.fifa21_bottle("Aurora15", ("CX_GRAPHICS_BACKEND", "d3dmetal"),
                           ("WINE_SIMULATE_WRITECOPY", "1"))
        system = self.bottles / "Aurora15/system.reg"
        before = system.read_bytes()
        system.chmod(0o444)
        self.addCleanup(system.chmod, 0o644)
        result = self.set_up_fifa21(app, AURORA_BOTTLE="Aurora15")
        out = result.stdout
        self.assertEqual(result.returncode, 0, out + result.stderr)
        self.assertIn("MODE=bottle OK=111", out)
        self.assertIn("could not add the DNS Client stand-in to the Aurora15 bottle", out)
        self.assertIn("run ./setup.sh --fifa21 again", out)
        self.assertIn("VERDICT=incomplete", out)
        self.assertEqual(system.read_bytes(), before)
        # Writable again (and the backup the first run made of it), it is done.
        for reg in system.parent.glob("system.reg*"):
            reg.chmod(0o644)
        result = self.set_up_fifa21(app, AURORA_BOTTLE="Aurora15")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("VERDICT=done", result.stdout)

    def test_fifa21_leaves_cas_its_device_check(self):
        # In a bottle CAS is set up in, powershell.exe is CAS's stand-in and
        # hands every other command line to aurora17-powershell.exe. FIFA 21's
        # stand-in is Aurora17's, so it goes there and CAS's stays.
        app = self.copy(marker=True)
        self.shipped(True)
        cas = (ROOT / "fixes/x86_64-windows/cas-powershell.exe").read_bytes()
        conf, psdir = self.fifa21_bottle("Aurora17", ("CX_GRAPHICS_BACKEND", "d3dmetal"),
                                         ("CX_DR_TRAP", "2"), ("WINE_SIMULATE_WRITECOPY", "1"),
                                         powershell=cas, cas=True)
        (psdir / "powershell.exe.wine-stub").write_bytes(self.STUB)
        result = self.set_up_fifa21(app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SHARED=FIFA 17", result.stdout)
        self.assertIn("as aurora17-powershell.exe behind CAS's stand-in", result.stdout)
        self.assertEqual((psdir / "powershell.exe").read_bytes(), cas)
        self.assertEqual((psdir / "aurora17-powershell.exe").read_bytes(),
                         (ROOT / "aurora17/powershell.exe").read_bytes())
        self.assertEqual((psdir / "powershell.exe.wine-stub").read_bytes(), self.STUB)
        self.assertFalse((psdir / "powershell.exe.wine-stub-orig").exists())
        # FIFA 17's own value stays; nothing of FIFA 17's is added or taken.
        self.assertIn('"CX_DR_TRAP" = "2"', conf.read_text())
        self.assertFalse((self.bottles / "Aurora17/drive_c/webview2-fixed").exists())
        _, launchers = self.tables(self.verify(app, AURORA_BOTTLE="Aurora17").stdout)
        self.assertEqual(launchers[("Aurora.exe", "FIFA 21")], "ready")

    def test_fifa21_shares_fifa17s_settings_with_or_without_the_table(self):
        self.bottle("Aurora17", ("CX_DR_TRAP", "2"))
        self.bottle("Aurora15", ("CX_TOPDOWN_LIMIT", "0x1ffffffff"))
        # With the table FIFA 21 goes anywhere and the bottle keeps mode 2 out.
        app = self.copy(marker=True)
        result, lines = self.run_probe("--fifa21", "--verify", AURORA_BOTTLE="Aurora15",
                                       AURORA_TARGET=str(app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SHARED=FIFA 15", lines)
        self.assertEqual(sorted(lines[2:]), ["CX_GRAPHICS_BACKEND=d3dmetal", "WINE_SIMULATE_WRITECOPY=1"])
        # Without it, FIFA 17's bottle is still FIFA 21's (the same settings),
        # and FIFA 15's is not.
        old = self.copy(marker=False, name="old.app")
        result, lines = self.run_probe("--fifa21", "--verify", AURORA_TARGET=str(old))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SHARED=FIFA 17", lines)
        self.assertIn("CX_DR_TRAP=2", lines)
        result, _ = self.run_probe("--fifa21", "--verify", AURORA_BOTTLE="Aurora15",
                                   AURORA_TARGET=str(old))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("needs its own bottle", result.stdout)


class RepairTests(unittest.TestCase):
    """--repair is wired end to end, and refresh_fixes replaces exactly what is
    stale and signs only when it has to. The repair itself is never run here:
    it quits CrossOver and rewrites an app."""

    def test_fix_my_installation_is_wired(self):
        for command in ("Fix my installation.command",
                        "diagnostics/15 Fix my installation.command"):
            self.assertIn("_action.zsh --repair", (ROOT / command).read_text())
        self.assertIn("--repair)", (ROOT / "diagnostics" / "_action.zsh").read_text())
        setup = (ROOT / "setup.sh").read_text()
        self.assertIn("--repair) MODE=repair", setup)
        self.assertIn('if [ "$MODE" = repair ]; then', setup)
        for doc in ("README.md", "SETUP.md", "diagnostics/README.md"):
            self.assertIn("Fix my installation.command", (ROOT / doc).read_text(), doc)

    def test_repair_without_fifa17_skips_its_steps_and_judges_fifa15(self):
        # The real --repair block, with the helpers it calls stubbed. Players
        # with only FIFA 15 used to end NOT FIXED on FIFA 17's licence check.
        source = (ROOT / "setup.sh").read_text()
        block = 'if [ "$MODE" = repair ]; then' + source.split('if [ "$MODE" = repair ]; then', 1)[1]
        block = block.split("\n# ------------------------------------------------------- --resign", 1)[0]
        with tempfile.TemporaryDirectory(prefix="fifa-repair-") as directory:
            work = Path(directory)
            app = work / "CrossOver-FIFA.app"
            app.mkdir()
            script = work / "setup.sh"
            script.write_text('#!/bin/zsh\nprint -r -- "$*" >> "$CALLS"\n'
                              'case "$*" in --verify) exit "${VERIFY_RC:-0}" ;; esac\nexit 0\n')
            script.chmod(0o755)
            harness = f'''set -eu
MODE=repair HERE={shlex_quote(str(work))} TARGET={shlex_quote(str(app))} TARGET_EXPLICIT=1
BOTTLE=Aurora17 E_PAYLOAD=4 E_INCOMPLETE=5 SETUP_LOCK={shlex_quote(str(work / "lock"))}
say() {{ print -r -- "$*"; }}; ok() {{ say "$@"; }}; note() {{ say "$@"; }}
red() {{ say "RED $*"; }}; green() {{ say "GREEN $*"; }}
require_supported_mac() {{ :; }}; require_clt() {{ :; }}; is_crossover_bundle() {{ :; }}
crossover_version() {{ print 26.3; }}; take_setup_lock() {{ :; }}; refresh_fixes() {{ :; }}
bottle_licence_file() {{ print -r -- /nonexistent/licence; }}
seed_bottle_licence() {{ print -r -- "SEEDED" >> "$CALLS"; }}
game_dir_of() {{ [ "$1" = fifa17 ] && [ -n "$F17" ] && return 0; [ "$1" = fifa15 ] && [ -n "$F15" ]; }}
add_fifa15_to_bottle() {{ [ -n "$F15" ] || return 0; FIFA15_FOUND=1; FIFA15_IN=Aurora15; FIFA15_OK="$F15_OK"; }}
FIFA15_OK=1 FIFA15_FOUND=0 FIFA15_IN=""
''' + block
            calls = work / "calls"
            for f17, f15, f15_ok, verify_rc, rc, says, ran_bottle in [
                ("yes", "yes", "1", "0", 0, "GREEN Fixed. Open CrossOver-FIFA, then the Aurora17", True),
                ("yes", "yes", "1", "1", 5, "RED NOT FIXED — the check above", True),
                ("", "yes", "1", "1", 0, "GREEN Fixed. Open CrossOver-FIFA, then the Aurora15 bottle, and play FIFA 15", False),
                ("", "yes", "0", "0", 5, "RED NOT FIXED — FIFA 15's setup", False),
                ("", "", "1", "0", 5, "RED NOT FIXED — no FIFA 17 or FIFA 15 folder", False),
            ]:
                with self.subTest(f17=f17, f15=f15, f15_ok=f15_ok, verify_rc=verify_rc):
                    calls.unlink(missing_ok=True)
                    result = subprocess.run(
                        ["/bin/zsh", "-c", harness], cwd=work, stdin=subprocess.DEVNULL,
                        env={**os.environ, "CALLS": str(calls), "F17": f17, "F15": f15,
                             "F15_OK": f15_ok, "VERIFY_RC": verify_rc},
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
                    self.assertIn(says, result.stdout)
                    made = calls.read_text().splitlines()
                    self.assertEqual("--bottle" in made, ran_bottle, made)
                    self.assertEqual("--verify" in made, bool(f17), made)
                    if not f17:
                        self.assertIn("no FIFA 17 folder found", result.stdout)
                        self.assertNotIn("SEEDED", made)

    def test_install_and_repair_add_fifa15_to_the_common_bottle_and_keep_going(self):
        with tempfile.TemporaryDirectory(prefix="fifa15-repair-") as directory:
            work = Path(directory)
            script = work / "setup.sh"
            script.write_text('#!/bin/zsh\nprint -r -- "$AURORA_BOTTLE|$*" >> "$CALLS"\n'
                              'if [ "$#" = 2 ]; then exit "$TEST_VERIFY_RC"; fi\n'
                              'exit "${TEST_RC:-0}"\n')
            script.chmod(0o755)
            calls = work / "calls"
            harness = '''set -eu
HERE="$PWD"
BOTTLE="Shared Aurora"
FIFA15_OK=1
AURORA_BOTTLE_GIVEN="${GIVEN:-}"
say() { print -r -- "$*"; }
ok() { print -r -- "$*"; }
note() { print -r -- "$*"; }
game_dir_of() { [ -n "$FOLDER" ] && print -r -- "$FOLDER"; }
# The real choice is f15_default_bottle; here it says what it was given.
f15_default_bottle() {
    [ -n "$AURORA_BOTTLE" ] && { print -r -- "$AURORA_BOTTLE"; return 0; }
    [ -n "$PICK" ] && print -r -- "$PICK"
}
'''
            harness += function_source("add_fifa15_to_bottle")
            harness += '\nadd_fifa15_to_bottle\nprint -r -- "NEXT OK=$FIFA15_OK"\n'
            both = ["--fifa15", "--fifa15 --verify"]
            for pick, given, folder, rc, verify_rc, ok, bottle, wanted in [
                ("Shared Aurora", "", "/game/FIFA 15", "0", "0", "1", "Shared Aurora", both),
                ("Shared Aurora", "", "/game/FIFA 15", "5", "0", "0", "Shared Aurora", ["--fifa15"]),
                ("Shared Aurora", "", "/game/FIFA 15", "0", "5", "0", "Shared Aurora", both),
                ("Shared Aurora", "", "", "0", "0", "1", "", []),
                # Aurora.exe in Aurora15 beside an Aurora17: FIFA 15 goes where Aurora is,
                # not into the bottle FIFA 17 is being repaired in.
                ("Aurora15", "", "/game/FIFA 15", "0", "0", "1", "Aurora15", both),
                # A bottle the person named wins.
                ("Aurora15", "Mine", "/game/FIFA 15", "0", "0", "1", "Mine", both),
                # Aurora is in some other bottle: nothing is guessed, and it is not Fixed.
                ("", "", "/game/FIFA 15", "0", "0", "0", "", []),
            ]:
                with self.subTest(pick=pick, given=given, folder=folder, rc=rc):
                    calls.unlink(missing_ok=True)
                    result = subprocess.run(
                        ["/bin/zsh", "-c", harness], cwd=work,
                        env={**os.environ, "CALLS": str(calls), "PICK": pick, "GIVEN": given,
                             "AURORA_BOTTLE": "Repair Export",
                             "FOLDER": folder, "TEST_RC": rc, "TEST_VERIFY_RC": verify_rc},
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("NEXT OK=" + ok, result.stdout)
                    actual = calls.read_text().splitlines() if calls.exists() else []
                    self.assertEqual(actual, [bottle + "|" + args for args in wanted])
            source = (ROOT / "setup.sh").read_text().split('if [ "$MODE" = repair ]; then', 1)[1]
            self.assertIn('        "$HERE/setup.sh" --bottle || exit $?\n    fi\n    add_fifa15_to_bottle', source)
            self.assertIn('"$HERE/setup.sh" --verify && [ "$FIFA15_OK" = 1 ]', source)
            # The full FIFA 17 install (START HERE) adds FIFA 15 to its bottle too,
            # after giving up the lock, and is not Done while FIFA 15 failed.
            install = (ROOT / "setup.sh").read_text().split("end_own_wine_session\n# The copy is finished", 1)[1]
            install = install.split("# ------------------------------------------------------------- the receipt", 1)[0]
            self.assertIn('if [ "$GAME" = fifa17 ]; then\n    rm -rf "$SETUP_LOCK"', install)
            self.assertIn("    add_fifa15_to_bottle\nfi", install)
            verdict = (ROOT / "setup.sh").read_text().rsplit("# ------------------------------------------------------------- the verdict", 1)[1]
            self.assertIn('if [ "$FIFA15_OK" != 1 ]; then', verdict.split("exit 0\nfi", 1)[0])

    def refresh(self, stale_dll, signature_ok):
        with tempfile.TemporaryDirectory(prefix="a17-refresh-") as directory:
            work = Path(directory)
            fixes = work / "fixes"
            (fixes / "x86_64-unix").mkdir(parents=True)
            (fixes / "x86_64-windows").mkdir()
            shipped = {
                "x86_64-windows/version.dll": b"fixed version.dll",
                "x86_64-unix/ntdll.so": b"fixed ntdll.so",
                "x86_64-unix/a17hosts.dylib": b"resolver",
                "x86_64-unix/cx-fifa17-gate": b"#!/bin/zsh\n# gate\n",
            }
            sums = []
            for rel, data in shipped.items():
                (fixes / rel).write_bytes(data)
                sums.append(hashlib.sha256(data).hexdigest() + "  " + rel)
            (fixes / "SHA256SUMS").write_text("\n".join(sums) + "\n")
            wine = work / "App.app/Contents/SharedSupport/CrossOver/lib/wine"
            (wine / "x86_64-unix").mkdir(parents=True)
            (wine / "x86_64-windows").mkdir()
            (wine / "x86_64-windows/version.dll").write_bytes(
                b"stock version.dll" if stale_dll else shipped["x86_64-windows/version.dll"])
            (wine / "x86_64-unix/ntdll.so").write_bytes(shipped["x86_64-unix/ntdll.so"])
            (wine / "x86_64-unix/a17hosts.dylib").write_bytes(shipped["x86_64-unix/a17hosts.dylib"])
            (wine / "x86_64-unix/cx-fifa17-gate").write_bytes(shipped["x86_64-unix/cx-fifa17-gate"])
            (wine / "x86_64-unix/ws2_32.so").write_bytes(b"ws2_32")
            harness = r"""
set -eu
HERE="$PWD"
FILES=( x86_64-windows/version.dll x86_64-unix/ntdll.so )
RESOLVER=x86_64-unix/a17hosts.dylib
GATE=x86_64-unix/cx-fifa17-gate
RECEIPT="$PWD/no-receipt"
E_PAYLOAD=4; E_PERMISSION=3
APP_MGMT_HINT=hint
LIBSYSTEM=/usr/lib/libSystem.B.dylib
RESOLVER_PATH=@rpath/a17hosts.dylib
RPATH_LIB64=@loader_path/../../../lib64
ok() { print -r -- "ok $*"; }
die() { print -r -- "die $*"; exit "$1"; }
macho_uuid() { shasum "$1" | cut -c1-16; }
ws2_32_is_patched() { return 0; }
has_lib64_rpath() { return 0; }
sign_payload() { print -r -- "SIGNED payload $1"; }
resign_app() { print -r -- "SIGNED app $1"; }
"""
            harness += "codesign() { return %d; }\n" % (0 if signature_ok else 1)
            harness += function_source("refresh_fixes")
            harness += '\nrefresh_fixes "$PWD/App.app"\n'
            result = subprocess.run(["/bin/zsh", "-c", harness], cwd=work,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            installed = (wine / "x86_64-windows/version.dll").read_bytes()
            return result.stdout, installed

    def test_refresh_replaces_a_stale_file_and_signs(self):
        out, installed = self.refresh(stale_dll=True, signature_ok=True)
        self.assertEqual(installed, b"fixed version.dll")
        self.assertIn("version.dll — replaced", out)
        self.assertIn("SIGNED app", out)

    def test_refresh_leaves_a_right_signed_copy_alone(self):
        out, installed = self.refresh(stale_dll=False, signature_ok=True)
        self.assertEqual(installed, b"fixed version.dll")
        self.assertNotIn("SIGNED", out)
        self.assertIn("left as it is", out)

    def test_refresh_resigns_a_copy_macos_calls_damaged(self):
        out, _ = self.refresh(stale_dll=False, signature_ok=False)
        self.assertIn("all 2 fix files are the shipped versions", out)
        self.assertIn("SIGNED app", out)


class Fifa16UpdateTests(unittest.TestCase):
    """./setup.sh --fifa16 on an existing copy brings both halves of the
    stutter fix: the ntdll.so its marker names, and win32u.so by LC_UUID."""

    def test_shipped_ntdll_carries_the_fifa16_marker(self):
        source = (ROOT / "setup.sh").read_text().split(
            "# --------------------------------------------------------- safety guards", 1)[0]
        with tempfile.TemporaryDirectory(prefix="a17-marker-") as directory:
            probe = Path(directory) / "marker.sh"
            probe.write_text(source + '\nprint -r -- "$NTDLL_MARKER"\n')
            result = subprocess.run(["/bin/zsh", str(probe), "--verify"],
                                    env={**os.environ, "AURORA_GAME": "fifa16", "NO_COLOR": "1"},
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        marker = result.stdout.splitlines()[-1]
        self.assertIn("Wine builtin", marker)
        self.assertIn(marker.encode(), (ROOT / "fixes/x86_64-unix/ntdll.so").read_bytes())
        setup = (ROOT / "setup.sh").read_text()
        self.assertIn('add_game_ntdll "$TARGET"\n        f16_add_win32u "$TARGET"', setup)

    def add_win32u(self, installed):
        with tempfile.TemporaryDirectory(prefix="a17-win32u-") as directory:
            work = Path(directory)
            (work / "fixes/x86_64-unix").mkdir(parents=True)
            (work / "fixes/x86_64-unix/win32u.so").write_bytes(b"fixed win32u.so")
            wine = work / "App.app/Contents/SharedSupport/CrossOver/lib/wine"
            (wine / "x86_64-unix").mkdir(parents=True)
            (wine / "x86_64-unix/win32u.so").write_bytes(installed)
            harness = r"""
set -eu
HERE="$PWD"
E_PAYLOAD=4; E_PERMISSION=3
APP_MGMT_HINT=hint
RPATH_LIB64=@loader_path/../../../lib64
ok() { print -r -- "ok $*"; }
say() { print -r -- "say $*"; }
note() { print -r -- "note $*"; }
die() { print -r -- "die $*"; exit "$1"; }
macho_uuid() { shasum "$1" | cut -c1-16; }
require_app_closed() { :; }
require_clt() { :; }
has_lib64_rpath() { return 1; }
install_name_tool() { print -r -- "RPATH $*"; }
sign_payload() { print -r -- "SIGNED payload"; }
resign_app() { print -r -- "SIGNED app"; }
"""
            harness += function_source("f16_add_win32u")
            harness += '\nf16_add_win32u "$PWD/App.app"\n'
            result = subprocess.run(["/bin/zsh", "-c", harness], cwd=work,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            orig = wine / "x86_64-unix/win32u.so.orig"
            return (result.stdout, (wine / "x86_64-unix/win32u.so").read_bytes(),
                    orig.read_bytes() if orig.exists() else None)

    def test_an_older_win32u_is_replaced_and_signed(self):
        out, installed, orig = self.add_win32u(b"older win32u.so")
        self.assertEqual(installed, b"fixed win32u.so")
        self.assertEqual(orig, b"older win32u.so")
        self.assertIn("win32u.so search path -- added", out)
        self.assertIn("SIGNED app", out)

    def test_the_shipped_win32u_is_left_alone(self):
        out, installed, orig = self.add_win32u(b"fixed win32u.so")
        self.assertEqual(installed, b"fixed win32u.so")
        self.assertIsNone(orig)
        self.assertIn("already the shipped build", out)
        self.assertNotIn("SIGNED", out)


class ProcessScopeTests(unittest.TestCase):
    """The process helpers, run against a stubbed ps so nothing real is touched."""

    @staticmethod
    def function(name):
        source = (ROOT / "setup.sh").read_text()
        body = source.split(name + "() {", 1)[1].split("\n}\n", 1)[0]
        return name + "() {" + body + "\n}\n"

    def run_zsh(self, script):
        return subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True, timeout=10)

    def test_game_leftovers_can_be_narrowed_to_one_game(self):
        # --play-log must not refuse to start because Aurora15Connector is
        # listening, which is its normal state after a FIFA 15 session.
        harness = r"""
set -u
ps() { print -r -- '111 C:\x\fifa15.exe'; print -r -- '222 C:\x\FIFA17.exe'
       print -r -- '333 C:\x\Aurora17Connector.exe'; print -r -- '444 C:\x\Aurora15Client.exe'
       print -r -- '555 /bin/zsh ./setup.sh --play-log'; }
wine_owned_pid() { return 0; }
""" + self.function("game_leftovers") + r"""
print -r -- "all: $(game_leftovers | tr '
' ' ')"
print -r -- "17: $(game_leftovers fifa17 | tr '
' ' ')"
print -r -- "15: $(game_leftovers fifa15 | tr '
' ' ')"
"""
        result = self.run_zsh(harness)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("all: 111 222 333 444 ", result.stdout)
        self.assertIn("17: 222 333 ", result.stdout)
        self.assertIn("15: 111 444 ", result.stdout)

    def test_gui_quit_is_sent_to_each_copy_by_path(self):
        # Two copies share the name "CrossOver"; quitting by name reached one.
        with tempfile.TemporaryDirectory(prefix="fifa-quit-") as directory:
            log = Path(directory) / "osascript.log"
            calls = Path(directory) / "calls"
            # Counted in a file: the function runs inside $(...), where a
            # shell variable would not survive. Both copies stay "open" for
            # the two calls before the quits are sent, then they are gone.
            harness = f"""
set -u
crossovers_running() {{
    print -r -- x >> {shlex_quote(str(calls))}
    [ "$(wc -l < {shlex_quote(str(calls))})" -le 2 ] || return 0
    print -r -- '/Applications/CrossOver.app'
    print -r -- '/Applications/CrossOver-FIFA.app'
}}
osascript() {{ print -r -- "$2" >> {shlex_quote(str(log))}; }}
""" + self.function("quit_crossovers_gui") + """
quit_crossovers_gui; print -r -- "rc=$?"
wait
"""
            result = self.run_zsh(harness)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("rc=0", result.stdout)
            sent = sorted(log.read_text().splitlines())
            self.assertEqual(sent, [
                'tell application "/Applications/CrossOver-FIFA.app" to quit',
                'tell application "/Applications/CrossOver.app" to quit',
            ])

    def test_install_path_guards_and_ends_its_session(self):
        source = (ROOT / "setup.sh").read_text()
        preflight, rest = source.split("# From here on things change on disk.", 1)
        install = rest.split("# ------------------------------------------------------------- the receipt", 1)[0]
        self.assertIn("require_bottle_free\n", preflight.split("say \"1. Checking\"", 1)[1])
        self.assertIn("take_setup_lock", preflight.split("say \"1. Checking\"", 1)[1])
        after_bottle = install.split('configure_bottle "$APP"', 1)[1]
        self.assertIn("end_own_wine_session", after_bottle)


class CrtOverrideTests(unittest.TestCase):
    """Wine's own Visual C++ runtimes do their floating point differently from
    Microsoft's, and an online match -- a lockstep simulation -- desyncs at
    kick-off. setup.sh points each bottle at the native pair its game was built
    against: FIFA 17 msvcr120/msvcp120 (VS2013), FIFA 15 msvcr110/msvcp110
    (VS2012). FIFA 17 ships Microsoft's copies in its game folder; FIFA 15 does
    not, so setup.sh has to put a pair where it will be found."""

    SECTION = r'[Software\\Wine\\DllOverrides]'
    REG = ('WINE REGISTRY Version 2\n'
           ';; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n'
           '\n'
           r'[Software\\Wine\\DllOverrides] 1758000000' + '\n'
           '#time=1dc0000000000000\n'
           '"*d3dcompiler_47"="native"\n'
           '"version"="native,builtin"\n'
           '\n'
           r'[Software\\Wine\\X11 Driver] 1758000000' + '\n'
           '"Decorated"="Y"\n')
    # What the two greps look for: Wine stamps its builtins in the clear, and a
    # Microsoft DLL says so in a UTF-16 version resource.
    MICROSOFT = b'MZ\x90\x00' + 'Microsoft Corporation'.encode('utf-16-le') + b'\x00\x00'
    WINE = b'MZ\x90\x00Wine builtin DLL\x00' + 'Microsoft Corporation'.encode('utf-16-le')
    PAIRS = {"fifa17": ("msvcr120", "msvcp120"), "fifa15": ("msvcr110", "msvcp110")}

    @staticmethod
    def function(name):
        source = (ROOT / "setup.sh").read_text()
        body = source.split(name + "() {", 1)[1].split("\n}\n", 1)[0]
        return name + "() {" + body + "\n}\n"

    @staticmethod
    def source():
        return (ROOT / "setup.sh").read_text()

    @classmethod
    def array_line(cls):
        return [line for line in cls.source().splitlines()
                if line.startswith('if [ "$GAME" = fifa15 ]; then CRT_OVERRIDE_DLLS=')][0] + "\n"

    @classmethod
    def exes_line(cls):
        return [line for line in cls.source().splitlines()
                if line.startswith('if [ "$GAME" = fifa15 ]; then OVERRIDE_EXES=')][0] + "\n"

    @classmethod
    def block(cls, head):
        """One indented if-block out of setup.sh, ending at its own `fi`."""
        return head + cls.source().split(head, 1)[1].split("\n    fi\n", 1)[0] + "\n    fi\n"

    STUBS = ('problems=0\n'
             'ok() { print -r -- "OK $*"; }\n'
             'bad() { print -r -- "BAD $*"; }\n'
             'note() { print -r -- "NOTE $*"; }\n'
             'say() { print -r -- "SAY $*"; }\n')

    def harness(self, game, reg):
        return ("set -u\n"
                f"GAME={game}\nBOTTLE=Aurora17\n"
                f"OVERRIDE_SECTION='{self.SECTION}'\n"
                "bottle_user_reg() { print -r -- " + shlex_quote(str(reg)) + "; }\n"
                + self.array_line()
                + self.exes_line()
                + self.function("reg_line_is_set")
                + self.function("set_reg_line")
                + "appdefaults_section() {" + self.source().split("appdefaults_section() {", 1)[1].split("\n", 1)[0] + "\n"
                + self.function("dll_override_is_set")
                + self.function("set_dll_override")
                + self.function("crt_override_is_set")
                + self.function("set_crt_override"))

    def files_harness(self, game, bottle_dir, bottle="Aurora15"):
        return ("set -u\n"
                f"GAME={game}\nBOTTLE={bottle}\n"
                "BOTTLE_DIR=" + shlex_quote(str(bottle_dir)) + "\n"
                + self.array_line()
                + self.function("crt_dll_is_microsoft")
                + self.function("crt_dlls_are_microsoft_in")
                + self.function("f15_game_dir")
                + self.function("f15_crt_native_dir")
                + self.function("f15_crt_donor_dir")
                # Where each game is, with the folder gate's path mapping
                # (unix_path_to_win's too: one copy).
                + resolver_source()
                + self.function("unix_path_to_win")
                + self.function("f15_ensure_crt_dlls"))

    def run_zsh(self, script, env=None):
        return subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True,
                              timeout=30, env=env)

    def fixture(self, directory):
        reg = Path(directory) / "user.reg"
        reg.write_text(self.REG)
        return reg

    def lines_in_section(self, reg, section=None):
        section = section or self.SECTION
        found, out = False, []
        for line in reg.read_text().splitlines():
            if line.startswith("["):
                found = line.startswith(section)
                continue
            if found and line.startswith('"'):
                out.append(line)
        return out

    def game_env(self, work, **extra):
        """A home of our own: these helpers search ~/Downloads and friends, and
        a test must never find (or write into) the real game folders."""
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("AURORA_", "FIFA15_", "FIFA17_", "CX_"))}
        env.update(HOME=str(work), CX_VOLUMES_DIR=str(work / "Volumes"), **extra)
        return env

    def plant_pair(self, directory, game, content):
        Path(directory).mkdir(parents=True, exist_ok=True)
        for dll in self.PAIRS[game]:
            (Path(directory) / f"{dll}.dll").write_bytes(content)

    # ---------------------------------------------------------- the pair itself

    def test_each_game_gets_the_runtime_it_was_built_against(self):
        for game, expected in [("fifa17", "msvcr120 msvcp120"), ("fifa15", "msvcr110 msvcp110")]:
            with self.subTest(game=game):
                script = ("set -u\n" f"GAME={game}\n" + self.array_line()
                          + 'print -r -- "[$CRT_OVERRIDE_DLLS]"\n')
                result = self.run_zsh(script)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), f"[{expected}]")
        # The other runtimes belong to everything else in the bottle; forcing
        # those native breaks them, so they must stay out of the list.
        for banned in ("vcruntime140", "ucrtbase", "msvcp140", "msvcr100"):
            self.assertNotIn(banned, self.array_line())

    # --------------------------------------------------------- the registry side

    @staticmethod
    def app_section(exe):
        return r'[Software\\Wine\\AppDefaults' + '\\\\' + exe + r'\\DllOverrides]'

    def test_it_writes_both_lines_for_the_games_own_programs_only(self):
        # Per program, not bottle-wide: a bottle-wide msvcr110 would put FIFA 16
        # on Microsoft's runtime in a bottle the two share.
        for game, exes, expected in [
            ("fifa17", ["FIFA17.exe", "_fifa17.exe"],
             ['"msvcp120"="native,builtin"', '"msvcr120"="native,builtin"']),
            ("fifa15", ["fifa15.exe"],
             ['"msvcp110"="native,builtin"', '"msvcr110"="native,builtin"']),
        ]:
            with self.subTest(game=game):
                with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
                    reg = self.fixture(directory)
                    result = self.run_zsh(self.harness(game, reg)
                                          + 'crt_override_is_set && print -r -- BEFORE-SET\n'
                                            'set_crt_override || print -r -- WRITE-FAILED\n'
                                            'crt_override_is_set && print -r -- AFTER-SET\n')
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn("BEFORE-SET", result.stdout)
                    self.assertNotIn("WRITE-FAILED", result.stdout)
                    self.assertIn("AFTER-SET", result.stdout)
                    for exe in exes:
                        self.assertEqual(sorted(self.lines_in_section(reg, self.app_section(exe))),
                                         expected, exe)
                    # The bottle-wide section, and the one after it, are as they were.
                    self.assertEqual(sorted(self.lines_in_section(reg)),
                                     ['"*d3dcompiler_47"="native"', '"version"="native,builtin"'])
                    self.assertIn('"Decorated"="Y"', reg.read_text())

    def test_a_bottle_wide_override_from_an_earlier_setup_still_counts(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            reg = self.fixture(directory)
            reg.write_text(self.REG.replace('"version"="native,builtin"\n',
                                            '"version"="native,builtin"\n'
                                            '"msvcr120"="native,builtin"\n'
                                            '"msvcp120"="native,builtin"\n'))
            before = reg.read_text()
            result = self.run_zsh(self.harness("fifa17", reg)
                                  + 'crt_override_is_set && print -r -- SET\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SET", result.stdout)
            self.assertEqual(reg.read_text(), before)

    def version_harness(self, game, reg):
        source = self.source()
        line = [l for l in source.splitlines()
                if l.startswith('if [ "$GAME" = fifa15 ]; then OVERRIDE_DLL=')][0]
        return (self.harness(game, reg) + line + "\n"
                + self.function("dll_override_is_global")
                + self.function("version_override_is_set")
                + [l for l in source.splitlines() if l.startswith("set_version_override()")][0]
                + "\n")

    def test_version_stays_bottle_wide_and_only_bottle_wide_counts(self):
        # The launchers' proxy version.dll files sit beside other programs
        # (Impulsum17Launcher.exe, FIFA 13/16/21 for Aurora.exe), so a
        # per-program override for FIFA17.exe would not reach them.
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            reg = self.fixture(directory)
            reg.write_text(self.REG.replace('"version"="native,builtin"\n', '')
                           + '\n[Software\\\\Wine\\\\AppDefaults\\\\FIFA17.exe\\\\DllOverrides] 0\n'
                           '"version"="native,builtin"\n')
            result = self.run_zsh(self.version_harness("fifa17", reg)
                                  + 'version_override_is_set && print -r -- EARLY\n'
                                  'set_version_override && version_override_is_set && print -r -- SET\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("EARLY", result.stdout)
            self.assertIn("SET", result.stdout)
            self.assertIn('"version"="native,builtin"', self.lines_in_section(reg))
        # FIFA 15's dinput8 stays per program.
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            reg = self.fixture(directory)
            result = self.run_zsh(self.version_harness("fifa15", reg)
                                  + 'set_version_override && version_override_is_set && print -r -- SET\n')
            self.assertIn("SET", result.stdout)
            self.assertNotIn('"dinput8"="native,builtin"', self.lines_in_section(reg))
            self.assertEqual(self.lines_in_section(reg, self.app_section("fifa15.exe")),
                             ['"dinput8"="native,builtin"'])

    def test_an_existing_section_in_another_case_is_reused(self):
        # wineserver compares key names without case and keeps the first
        # spelling; a second [..fifa17.exe..] section would be a duplicate key.
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            reg = self.fixture(directory)
            reg.write_text(self.REG + '\n[Software\\\\Wine\\\\AppDefaults\\\\fifa17.exe\\\\DllOverrides] 0\n'
                           '"MSVCR120"="builtin"\n'
                           '\n[Software\\\\Wine\\\\AppDefaults\\\\_FIFA17.EXE\\\\DllOverrides] 0\n'
                           '"msvcp120"="native,builtin"\n"msvcr120"="native,builtin"\n')
            result = self.run_zsh(self.harness("fifa17", reg)
                                  + 'set_crt_override && crt_override_is_set && print -r -- SET\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SET", result.stdout)
            text = reg.read_text()
            self.assertEqual(text.lower().count("appdefaults\\\\fifa17.exe\\\\dlloverrides]"), 1, text)
            self.assertEqual(text.lower().count("appdefaults\\\\_fifa17.exe\\\\dlloverrides]"), 1, text)
            # The old value under the other spelling of its name is replaced.
            self.assertEqual(sorted(self.lines_in_section(reg, self.app_section("fifa17.exe"))),
                             ['"msvcp120"="native,builtin"', '"msvcr120"="native,builtin"'])

    def test_setting_it_twice_changes_nothing_the_second_time(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            reg = self.fixture(directory)
            harness = self.harness("fifa17", reg)
            self.assertEqual(self.run_zsh(harness + "set_crt_override\n").returncode, 0)
            once = reg.read_text()
            result = self.run_zsh(harness + 'set_crt_override && crt_override_is_set\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(reg.read_text(), once, "a second run rewrote the registry")

    # ------------------------------------------------------ whose DLL is this

    def test_it_can_tell_a_microsoft_dll_from_wines_own(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            (work / "real.dll").write_bytes(self.MICROSOFT)
            # Wine's builtin names Microsoft too; the builtin marker settles it.
            (work / "wine.dll").write_bytes(self.WINE)
            (work / "junk.dll").write_bytes(b"\x00\x01\x02nothing to see here")
            script = ("set -u\n" + self.function("crt_dll_is_microsoft")
                      + "for f in real wine junk missing; do\n"
                        '  crt_dll_is_microsoft ' + shlex_quote(str(work)) + '/$f.dll '
                        '&& print -r -- "$f YES" || print -r -- "$f no"\n'
                        "done\n")
            result = self.run_zsh(script)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.split(),
                             ["real", "YES", "wine", "no", "junk", "no", "missing", "no"])

    def test_a_directory_counts_only_when_both_dlls_are_microsofts(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            self.plant_pair(work / "both", "fifa15", self.MICROSOFT)
            self.plant_pair(work / "wine", "fifa15", self.WINE)
            self.plant_pair(work / "half", "fifa15", self.MICROSOFT)
            (work / "half" / "msvcp110.dll").write_bytes(self.WINE)
            script = (self.files_harness("fifa15", work / "bottles")
                      + "for d in both wine half missing; do\n"
                        '  crt_dlls_are_microsoft_in ' + shlex_quote(str(work)) + '/$d '
                        '&& print -r -- "$d YES" || print -r -- "$d no"\n'
                        "done\n")
            result = self.run_zsh(script, env=self.game_env(work))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.split(),
                             ["both", "YES", "wine", "no", "half", "no", "missing", "no"])

    # ------------------------------------------- putting a pair where FIFA 15 looks

    def bottle_tree(self, work):
        bottles = work / "bottles"
        (bottles / "Aurora15" / "drive_c" / "windows" / "system32").mkdir(parents=True)
        (bottles / "Aurora15" / "dosdevices").mkdir(parents=True)
        # Resolved, as CrossOver writes it: the temporary folder is under
        # /var, which is /private/var, and a game folder is resolved too.
        (bottles / "Aurora15" / "dosdevices" / "y:").symlink_to(work.resolve(), target_is_directory=True)
        return bottles

    def test_it_copies_the_pair_out_of_a_fifa_17_folder(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            self.bottle_tree(work)
            game = work / "FIFA 15"
            game.mkdir()
            (game / "fifa15.exe").write_bytes(b"MZ")
            donor = work / "Downloads" / "FIFA 17"
            self.plant_pair(donor, "fifa15", self.MICROSOFT)
            (donor / "FIFA17.exe").write_bytes(b"MZ")
            script = self.files_harness("fifa15", work / "bottles") + self.STUBS \
                + 'f15_ensure_crt_dlls ' + shlex_quote(str(work / "app")) + '\n'
            env = self.game_env(work, FIFA15_DIR=str(game))
            result = self.run_zsh(script, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("OK msvcr110 + msvcp110", result.stdout)
            for dll in ("msvcr110.dll", "msvcp110.dll"):
                self.assertEqual((game / dll).read_bytes(), self.MICROSOFT)
            # Nothing of the game's own is touched, and a second run says so
            # rather than copying again.
            again = self.run_zsh(script, env=env)
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
            self.assertIn("already beside fifa15.exe", again.stdout)
            self.assertEqual((game / "fifa15.exe").read_bytes(), b"MZ")

    def test_a_fifa_17_on_an_external_drive_is_a_donor_too(self):
        # Only the home folders used to be asked, so a FIFA 17 on a drive was
        # never found and the redistributable ran in the bottle instead.
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            self.bottle_tree(work)
            game = work / "FIFA 15"
            (game / "_Redist").mkdir(parents=True)
            (game / "fifa15.exe").write_bytes(b"MZ")
            (game / "_Redist" / "vcredist_x64_2012_x64.exe").write_bytes(b"MZ")
            donor = work / "Volumes" / "Untitled" / "FIFA 17"
            self.plant_pair(donor, "fifa15", self.MICROSOFT)
            (donor / "FIFA17.exe").write_bytes(b"MZ")
            wine = work / "app" / "Contents" / "SharedSupport" / "CrossOver" / "bin" / "wine"
            wine.parent.mkdir(parents=True)
            wine.write_text("#!/bin/zsh\nprint -r -- \"$@\" >> " + shlex_quote(str(work / "wine.log")) + "\n")
            wine.chmod(0o755)
            script = self.files_harness("fifa15", work / "bottles") + self.STUBS \
                + 'f15_ensure_crt_dlls ' + shlex_quote(str(work / "app")) + '\n'
            result = self.run_zsh(script, env=self.game_env(work, FIFA15_DIR=str(game)))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("copied Microsoft's own beside fifa15.exe", result.stdout)
            self.assertIn(f"from {donor.resolve()}", result.stdout)
            for dll in ("msvcr110.dll", "msvcp110.dll"):
                self.assertEqual((game / dll).read_bytes(), self.MICROSOFT)
            self.assertFalse((work / "wine.log").exists(), "the redistributable was run")

    def test_it_falls_back_to_the_games_own_redistributable(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            system32 = bottles / "Aurora15" / "drive_c" / "windows" / "system32"
            self.plant_pair(system32, "fifa15", self.WINE)
            game = work / "FIFA 15"
            (game / "_Redist").mkdir(parents=True)
            (game / "fifa15.exe").write_bytes(b"MZ")
            (game / "_Redist" / "vcredist_x64_2012_x64.exe").write_bytes(b"MZ")
            # A stand-in for CrossOver's wine that does what the redistributable
            # does: writes Microsoft's copies into the bottle's system32.
            wine = work / "app" / "Contents" / "SharedSupport" / "CrossOver" / "bin" / "wine"
            wine.parent.mkdir(parents=True)
            wine.write_text("#!/bin/zsh\nprint -r -- \"$@\" >> " + shlex_quote(str(work / "wine.log"))
                            + "\nfor d in msvcr110 msvcp110; do\n"
                              "  printf 'MZ' > " + shlex_quote(str(system32)) + "/$d.dll\n"
                              "  printf 'M\\0i\\0c\\0r\\0o\\0s\\0o\\0f\\0t\\0 \\0C\\0o\\0r\\0p\\0'"
                              " >> " + shlex_quote(str(system32)) + "/$d.dll\ndone\n")
            wine.chmod(0o755)
            script = self.files_harness("fifa15", bottles) + self.STUBS \
                + 'f15_ensure_crt_dlls ' + shlex_quote(str(work / "app")) + '\n'
            result = self.run_zsh(script, env=self.game_env(work, FIFA15_DIR=str(game)))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("OK msvcr110 + msvcp110", result.stdout)
            self.assertIn("system32", result.stdout)
            called = (work / "wine.log").read_text()
            self.assertIn("--bottle Aurora15", called)
            self.assertIn(r"--cx-app Y:\FIFA 15\_Redist\vcredist_x64_2012_x64.exe", called)
            self.assertIn("/install /quiet /norestart", called)
            # The game folder is left alone when the bottle route worked.
            self.assertFalse((game / "msvcr110.dll").exists())

    def test_with_no_source_at_all_it_says_so_and_stops_short_of_failing(self):
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            self.bottle_tree(work)
            game = work / "FIFA 15"
            game.mkdir()
            (game / "fifa15.exe").write_bytes(b"MZ")
            script = self.files_harness("fifa15", work / "bottles") + self.STUBS \
                + 'f15_ensure_crt_dlls ' + shlex_quote(str(work / "app")) + '\nprint -r -- "rc=$?"\n'
            result = self.run_zsh(script, env=self.game_env(work, FIFA15_DIR=str(game)))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("NOTE no Microsoft copy", result.stdout)
            self.assertIn("rc=1", result.stdout)
            self.assertEqual(sorted(p.name for p in game.iterdir()), ["fifa15.exe"])

    # ------------------------------------------------------------- the doctor

    def test_the_doctor_says_which_way_the_bottle_is_set(self):
        block = self.block('    if [ ${#CRT_OVERRIDE_DLLS} -gt 0 ] && [ -f "$(bottle_user_reg)" ]; then')
        report = '\nprint -r -- "problems=$problems"\n'
        for game, pair in [("fifa17", "msvcr120 + msvcp120"), ("fifa15", "msvcr110 + msvcp110")]:
            with self.subTest(game=game):
                with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
                    reg = self.fixture(directory)
                    unset = self.run_zsh(self.harness(game, reg) + self.STUBS + block + report)
                    self.assertEqual(unset.returncode, 0, unset.stdout + unset.stderr)
                    self.assertIn("BAD", unset.stdout)
                    self.assertIn("desync", unset.stdout)
                    self.assertIn("problems=1", unset.stdout)

                    set_up = self.run_zsh(self.harness(game, reg) + self.STUBS
                                          + "set_crt_override\n" + block + report)
                    self.assertEqual(set_up.returncode, 0, set_up.stdout + set_up.stderr)
                    self.assertIn(f"OK {pair} = native,builtin in the Aurora17 bottle",
                                  set_up.stdout)
                    self.assertIn("problems=0", set_up.stdout)

    def test_the_doctor_also_asks_whether_fifa_15_has_a_microsoft_copy(self):
        block = self.block('    if [ "$GAME" = fifa15 ]; then\n        local crt_dir')
        report = '\nprint -r -- "problems=$problems"\n'
        with tempfile.TemporaryDirectory(prefix="fifa-crt-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            system32 = bottles / "Aurora15" / "drive_c" / "windows" / "system32"
            game = work / "FIFA 15"
            game.mkdir()
            (game / "fifa15.exe").write_bytes(b"MZ")
            script = self.files_harness("fifa15", bottles) + self.STUBS + block + report
            env = self.game_env(work, FIFA15_DIR=str(game))

            none = self.run_zsh(script, env=env)
            self.assertEqual(none.returncode, 0, none.stdout + none.stderr)
            self.assertIn("BAD", none.stdout)
            self.assertIn("problems=1", none.stdout)

            # Wine's own copies in system32 are what it starts with: still bad.
            self.plant_pair(system32, "fifa15", self.WINE)
            still = self.run_zsh(script, env=env)
            self.assertIn("problems=1", still.stdout)

            self.plant_pair(system32, "fifa15", self.MICROSOFT)
            in_bottle = self.run_zsh(script, env=env)
            self.assertIn(f"OK msvcr110 + msvcp110 — Microsoft's own, in {system32}",
                          in_bottle.stdout)
            self.assertIn("problems=0", in_bottle.stdout)

            # Beside the game wins: that is where the loader looks first.
            self.plant_pair(game, "fifa15", self.MICROSOFT)
            beside = self.run_zsh(script, env=env)
            self.assertIn(f"OK msvcr110 + msvcp110 — Microsoft's own, in {game.resolve()}",
                          beside.stdout)
            self.assertIn("problems=0", beside.stdout)

        # FIFA 17 skips this check entirely: its game folder ships the pair.
        source = self.source()
        self.assertIn('if [ "$GAME" = fifa15 ]; then\n            f15_ensure_crt_dlls "$APP"',
                      source)


class WebView2RuntimeTests(unittest.TestCase):
    """The RebornFUT launcher is a WebView2 app from 3.1.45 on, and every
    WebView2 runtime from version 100 presents its frames through a
    DirectComposition path Wine cannot drive: the window opened and stayed
    blank. setup.sh puts Microsoft's fixed-version runtime 99.0.1150.52 in the
    bottle -- runtime 99 still draws through plain GDI -- and points the
    launcher at it with one bottle setting."""

    VERSION = "99.0.1150.52"
    CAB_NAME = "Microsoft.WebView2.FixedVersionRuntime.99.0.1150.52.x64"
    URL = ("https://github.com/westinyang/WebView2RuntimeArchive/releases/download/"
           "99.0.1150.52/Microsoft.WebView2.FixedVersionRuntime.99.0.1150.52.x64.cab")
    SHA256 = "b43a87ae6a039daaf96a8a3766a11c317a90c1ffe973bb19087374528d611544"
    SETTING = "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"
    WIN_DIR = r"C:\webview2-fixed\99.0.1150.52"

    STUBS = ('problems=0\nE_PAYLOAD=4\n'
             'ok() { print -r -- "OK $*"; }\n'
             'bad() { print -r -- "BAD $*"; }\n'
             'note() { print -r -- "NOTE $*"; }\n'
             'say() { print -r -- "SAY $*"; }\n'
             'die() { local code="$1"; shift; print -r -- "DIE $code $*"; exit "$code"; }\n')

    @staticmethod
    def source(script="setup.sh"):
        return (ROOT / script).read_text()

    @classmethod
    def function(cls, name):
        body = cls.source().split(name + "() {", 1)[1].split("\n}\n", 1)[0]
        return name + "() {" + body + "\n}\n"

    @classmethod
    def add_setting(cls):
        """The writer itself, which configure_bottle calls."""
        return "SOFT_SETTINGS=()\n" + cls.function("add_setting")

    @classmethod
    def block(cls, head, script="setup.sh"):
        """One indented if-block, ending at its own `fi`."""
        return head + cls.source(script).split(head, 1)[1].split("\n    fi\n", 1)[0] + "\n    fi\n"

    def run_zsh(self, script, env=None):
        return subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True,
                              timeout=30, env=env)

    # ---------------------------------------------------------- what it fetches

    def test_the_download_is_one_named_file_checked_against_one_hash(self):
        source = self.source()
        self.assertIn(self.URL.rsplit("/", 2)[0], source)
        self.assertIn("WEBVIEW2_SHA256=" + self.SHA256, source)
        self.assertIn('WEBVIEW2_CAB_NAME="Microsoft.WebView2.FixedVersionRuntime.'
                      '$WEBVIEW2_VERSION.x64"', source)
        self.assertIn("WEBVIEW2_VERSION=" + self.VERSION, source)
        # The URL is assembled from the version, so it can never name one
        # version and check another's hash.
        self.assertIn("releases/download/$WEBVIEW2_VERSION/$WEBVIEW2_CAB_NAME.cab", source)
        installer = self.function("install_webview2_runtime")
        self.assertIn('curl -fL --retry 2 -o "$cab" "$WEBVIEW2_URL"', installer)
        self.assertIn('shasum -a 256 "$cab"', installer)
        # A cabinet that is not the published one is deleted, never unpacked.
        before = installer.split('got="$(shasum', 1)[0]
        self.assertNotIn("cabarc", before)
        self.assertIn('rm -f "$cab"\n        die $E_PAYLOAD', installer)

    def test_it_unpacks_with_wines_own_cabarc_in_the_shape_the_wrapper_survives(self):
        installer = self.function("install_webview2_runtime")
        self.assertIn("--cx-app cabarc.exe", installer)
        self.assertIn(r"-p X 'C:\webview2-fixed\download.cab' 'C:\webview2-fixed\'", installer)
        # -F:* is the argument the CrossOver wine wrapper mangles.
        self.assertNotIn("-F:", installer)
        # No Homebrew tool is needed, and none is reached for.
        for tool in ("cabextract", "7z", "brew"):
            self.assertNotIn(tool, installer)

    # ------------------------------------------------------- the bottle setting

    def test_the_setting_is_fifa_17s_and_skip_leaves_both_of_them_out(self):
        source = self.source().split(
            "# --------------------------------------------------------- safety guards", 1)[0]
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            probe = Path(directory) / "profile.sh"
            probe.write_text(source + '\nprint -rl -- $BOTTLE_SETTINGS\n')
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("AURORA_", "FIFA15_", "FIFA17_", "CX_", "WEBVIEW2_"))}
            env["CX_BOTTLE_PATH"] = str(Path(directory) / "bottles")

            on = self.run_zsh(f"/bin/zsh {shlex_quote(str(probe))} --verify", env=env)
            self.assertEqual(on.returncode, 0, on.stdout + on.stderr)
            self.assertIn(f"{self.SETTING}={self.WIN_DIR}", on.stdout.splitlines())

            off = self.run_zsh(f"/bin/zsh {shlex_quote(str(probe))} --verify",
                               env={**env, "WEBVIEW2_RUNTIME": "skip"})
            self.assertEqual(off.returncode, 0, off.stdout + off.stderr)
            self.assertFalse(any(line.startswith("WEBVIEW2_") for line in off.stdout.splitlines()))

    def test_the_setting_is_written_with_the_backslashes_the_bottle_needs(self):
        """The value is a Windows path. Written as a regexp, "\\9" in it is a
        back-reference to a group that does not exist, and the check for "already
        set" then failed every time -- appending the line again on every run."""
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            conf = Path(directory) / "cxbottle.conf"
            conf.write_text("[EnvironmentVariables]\n")
            harness = ("set -eu\nCONF=" + shlex_quote(str(conf)) + "\n" + self.STUBS
                       + self.add_setting()
                       + f"\nadd_setting {self.SETTING} '{self.WIN_DIR}'\n"
                       + f"add_setting {self.SETTING} '{self.WIN_DIR}'\n")
            result = self.run_zsh(harness)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(conf.read_text(),
                             "[EnvironmentVariables]\n"
                             f'"{self.SETTING}" = "{self.WIN_DIR}"\n')
            self.assertIn("already set", result.stdout)

    # ------------------------------------------------------ installing it

    def bottle_tree(self, work):
        bottles = work / "bottles"
        (bottles / "Aurora17" / "drive_c").mkdir(parents=True, exist_ok=True)
        return bottles

    def fake_wine(self, work, root):
        """A wine that does what cabarc does, and records what it was given."""
        wine = work / "CrossOver-FIFA.app/Contents/SharedSupport/CrossOver/bin/wine"
        wine.parent.mkdir(parents=True, exist_ok=True)
        out = root / self.CAB_NAME
        wine.write_text("#!/bin/zsh\n"
                        f"print -rl -- \"$@\" > {shlex_quote(str(work / 'wine-args'))}\n"
                        f"mkdir -p {shlex_quote(str(out))}\n"
                        f"print -r -- MZ > {shlex_quote(str(out / 'msedgewebview2.exe'))}\n"
                        f"print -r -- v > {shlex_quote(str(out / (self.VERSION + '.manifest')))}\n")
        wine.chmod(0o755)
        return work / "CrossOver-FIFA.app"

    def installer_harness(self, bottles, sha, extra=""):
        return ("set -eu\n"
                "BOTTLE_DIR=" + shlex_quote(str(bottles)) + "\nBOTTLE=Aurora17\n"
                f"WEBVIEW2_VERSION={self.VERSION}\n"
                f"WEBVIEW2_CAB_NAME={self.CAB_NAME}\n"
                "WEBVIEW2_URL=https://127.0.0.1:9/never-reached\n"
                f"WEBVIEW2_SHA256={sha}\n"
                + extra + self.STUBS + self.function("install_webview2_runtime"))

    def test_it_unpacks_the_cabinet_and_leaves_the_folder_named_by_its_version(self):
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            root = bottles / "Aurora17" / "drive_c" / "webview2-fixed"
            app = self.fake_wine(work, root)
            cab = work / "runtime.cab"
            cab.write_bytes(b"MSCF not really a cabinet")
            sha = hashlib.sha256(cab.read_bytes()).hexdigest()
            result = self.run_zsh(self.installer_harness(bottles, sha)
                                  + f"install_webview2_runtime {shlex_quote(str(app))}\n",
                                  env={**os.environ, "WEBVIEW2_CAB": str(cab)})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"OK WebView2 {self.VERSION} unpacked", result.stdout)
            self.assertTrue((root / self.VERSION / "msedgewebview2.exe").is_file())
            self.assertTrue((root / self.VERSION / f"{self.VERSION}.manifest").is_file())
            # The cabinet and the name it unpacked under are both gone.
            self.assertEqual(sorted(p.name for p in root.iterdir()), [self.VERSION])
            self.assertTrue(cab.is_file(), "the copy named by WEBVIEW2_CAB was moved, not copied")
            args = (work / "wine-args").read_text().splitlines()
            self.assertEqual(args, ["--bottle", "Aurora17", "--cx-app", "cabarc.exe", "-p", "X",
                                    r"C:\webview2-fixed\download.cab", "C:" + "\\webview2-fixed" + "\\"])

    def test_a_cabinet_that_is_not_the_published_one_is_deleted_and_stops_the_install(self):
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            root = bottles / "Aurora17" / "drive_c" / "webview2-fixed"
            app = self.fake_wine(work, root)
            cab = work / "runtime.cab"
            cab.write_bytes(b"somebody else's file")
            result = self.run_zsh(self.installer_harness(bottles, self.SHA256)
                                  + f"install_webview2_runtime {shlex_quote(str(app))}\n",
                                  env={**os.environ, "WEBVIEW2_CAB": str(cab)})
            self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
            self.assertIn("DIE 4", result.stdout)
            self.assertIn(self.SHA256, result.stdout)
            self.assertFalse((root / "download.cab").exists())
            self.assertFalse((work / "wine-args").exists(), "it unpacked a cabinet it had rejected")
            self.assertFalse((root / self.VERSION).exists())

    def test_a_runtime_already_there_is_left_alone_and_nothing_is_downloaded(self):
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            root = bottles / "Aurora17" / "drive_c" / "webview2-fixed"
            app = self.fake_wine(work, root)
            (root / self.VERSION).mkdir(parents=True)
            (root / self.VERSION / "msedgewebview2.exe").write_bytes(b"MZ")
            loud = 'curl() { print -r -- "DOWNLOADED"; return 1; }\n'
            result = self.run_zsh(self.installer_harness(bottles, self.SHA256, extra=loud)
                                  + f"install_webview2_runtime {shlex_quote(str(app))}\n")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("already in the Aurora17 bottle", result.stdout)
            self.assertNotIn("DOWNLOADED", result.stdout)
            self.assertFalse((work / "wine-args").exists())

    def test_skip_does_nothing_at_all_and_says_what_it_costs(self):
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            root = bottles / "Aurora17" / "drive_c" / "webview2-fixed"
            app = self.fake_wine(work, root)
            result = self.run_zsh(self.installer_harness(bottles, self.SHA256)
                                  + f"install_webview2_runtime {shlex_quote(str(app))}\n",
                                  env={**os.environ, "WEBVIEW2_RUNTIME": "skip"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("NOTE skipped", result.stdout)
            self.assertIn("blank", result.stdout)
            self.assertFalse(root.exists())

    # ------------------------------------------------------------- the doctor

    def test_the_doctor_checks_the_folder_as_well_as_the_setting(self):
        block = self.block('    if [ "$GAME" = fifa17 ] && [ "${WEBVIEW2_RUNTIME:-}" != skip ]; then')
        report = '\nprint -r -- "problems=$problems"\n'
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            runtime = bottles / "Aurora17" / "drive_c" / "webview2-fixed" / self.VERSION
            harness = ("set -u\nGAME=fifa17\nBOTTLE=Aurora17\n"
                       f"WEBVIEW2_VERSION={self.VERSION}\n"
                       "BOTTLE_DIR=" + shlex_quote(str(bottles)) + "\n" + self.STUBS)

            missing = self.run_zsh(harness + block + report)
            self.assertEqual(missing.returncode, 0, missing.stdout + missing.stderr)
            self.assertIn("BAD the WebView2 99.0.1150.52 runtime is not in the Aurora17 bottle",
                          missing.stdout)
            self.assertIn("blank", missing.stdout)
            self.assertIn("problems=1", missing.stdout)

            # The executable alone is not enough: an unpacking that stopped
            # half way leaves one without the other.
            runtime.mkdir(parents=True)
            (runtime / "msedgewebview2.exe").write_bytes(b"MZ")
            half = self.run_zsh(harness + block + report)
            self.assertIn("problems=1", half.stdout)

            (runtime / f"{self.VERSION}.manifest").write_text("99.0.1150.52")
            whole = self.run_zsh(harness + block + report)
            self.assertIn("OK WebView2 99.0.1150.52 in the Aurora17 bottle", whole.stdout)
            self.assertIn("problems=0", whole.stdout)

            # FIFA 15 and 16 have no RebornFUT, and skip means it was never installed.
            for skipped in ("GAME=fifa15\n", "GAME=fifa16\n", "WEBVIEW2_RUNTIME=skip\n"):
                quiet = self.run_zsh(harness + skipped + block + report)
                self.assertIn("problems=0", quiet.stdout)
                self.assertNotIn("WebView2", quiet.stdout)

    def test_the_doctor_does_not_call_the_setting_a_stranger(self):
        source = self.source()
        allowed = [line for line in source.splitlines()
                   if "WINE_COREAUDIO_EXCLUDE|" in line and "PROMPT)" in line][0]
        self.assertIn(self.SETTING, allowed)

    # --------------------------------------------------------------- undoing it

    def test_uninstall_takes_the_setting_and_the_folder_out_and_nothing_else(self):
        source = self.source("uninstall.sh")
        block = source.split("# ------------------------------------ the launcher's browser runtime",
                             1)[1].split("\n# ---", 1)[0]
        with tempfile.TemporaryDirectory(prefix="fifa-wv2-") as directory:
            work = Path(directory)
            bottles = self.bottle_tree(work)
            conf = bottles / "Aurora17" / "cxbottle.conf"
            kept = ('[EnvironmentVariables]\n'
                    '"CX_GRAPHICS_BACKEND" = "d3dmetal"\n'
                    '"CX_DR_TRAP" = "2"\n'
                    '"WINE_SIMULATE_WRITECOPY" = "1"\n')
            conf.write_text(kept + f'"{self.SETTING}" = "{self.WIN_DIR}"\n')
            runtime = bottles / "Aurora17" / "drive_c" / "webview2-fixed" / self.VERSION
            runtime.mkdir(parents=True)
            (runtime / "msedgewebview2.exe").write_bytes(b"MZ")
            other = bottles / "Aurora17" / "drive_c" / "windows"
            other.mkdir(parents=True)

            harness = ("set -eu\nundone=0\n"
                       "BOTTLE_DIR=" + shlex_quote(str(bottles)) + "\nBOTTLE=Aurora17\n"
                       + self.STUBS + block + '\nprint -r -- "undone=$undone"\n')
            result = self.run_zsh(harness)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(self.SETTING, result.stdout)
            self.assertEqual(conf.read_text(), kept)
            self.assertFalse((bottles / "Aurora17" / "drive_c" / "webview2-fixed").exists())
            self.assertTrue(other.is_dir(), "it deleted more of drive_c than its own folder")
            self.assertIn("undone=2", result.stdout)
            self.assertFalse(list((bottles / "Aurora17").glob("*.tmp-aurora17")))

            # A bottle that never had either is left exactly as it is.
            again = self.run_zsh(harness)
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
            self.assertEqual(conf.read_text(), kept)
            self.assertIn("undone=0", again.stdout)



GATE_SCRIPT = ROOT / "fixes/x86_64-unix/cx-fifa17-gate"


def fake_pe(stamp):
    """The few bytes of FIFA17.exe the gate reads: e_lfanew and the PE timestamp."""
    head = bytearray(b"MZ" + b"\0" * 0x3a) + (0x40).to_bytes(4, "little")
    head += b"PE\0\0" + b"\x4c\x01\x01\x00" + stamp.to_bytes(4, "little") + b"\0" * 64
    return bytes(head)


class FolderGateTests(unittest.TestCase):
    """The FIFA 17 folder gate (fixes/x86_64-unix/cx-fifa17-gate): which
    launcher started the game, and the folder put the way that launcher needs
    it. Every folder, bottle and app here is a small fake under a temporary
    directory; the table of the game's own files is the test's, through the
    gate's test hooks, so nothing needs 75 MB."""

    STAMP = 0x1234ABCD
    DATA = "Update/Patch/Data"
    # path as the table spells it, the game's own bytes, CAS's bytes
    FILES = {
        "Update/Patch/Data/layout.toc": (b"vanilla layout.toc", b"cas-mod layout.toc"),  # same size
        "Update/Patch/Data/Win32/chunks0.toc": (b"vanilla chunks", b"cas chunks, longer than that"),
        "Update/Patch/Data/Win32/storysba.sb": (b"vanilla story", b"cas story data"),
    }
    ADDED = "Update/Patch/Data/Win32/superbundlelayout/fifa_installpackage_00/cas_03.cas"
    # How CAS's own manifest spells them: Win32 and win32 both.
    CAS_SPELLING = {
        "Update/Patch/Data/layout.toc": "Update/Patch/Data/layout.toc",
        "Update/Patch/Data/Win32/chunks0.toc": "Update/Patch/Data/Win32/chunks0.toc",
        "Update/Patch/Data/Win32/storysba.sb": "Update/Patch/Data/win32/storysba.sb",
    }
    CAS_DLL = b"MZ\0\0cas-fifa-redirect.dll\0CASBRDG1\0"
    IMPULSUM_DLL = b"MZ\0\0IMPULSUM_AUTH_TOKEN\0IMPULSUM_SERVER_HOST\0v1"
    AURORA_DLL = b"MZ\0\0FUT17_GAME_CODE\0FUT17_LSX_PORT\0"
    OLD = 1497019336

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fifa-gate-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.game = self.work / "Games/FIFA 17"
        self.prefix = self.work / "bottles/Aurora17"
        self.local = self.prefix / "drive_c/users/crossover/AppData/Local"
        self.stash = self.game / ".crossover-fifa"
        self.log = self.prefix / "cxfifa-gate.log"
        exe = fake_pe(self.STAMP)
        self.game.mkdir(parents=True)
        (self.game / "FIFA17.exe").write_bytes(exe)
        for rel, (vanilla, _) in self.FILES.items():
            self.put(self.game / rel, vanilla, self.OLD)
        (self.prefix / "dosdevices").mkdir(parents=True)
        (self.prefix / "dosdevices/z:").symlink_to("/", target_is_directory=True)
        (self.prefix / "dosdevices/c:").symlink_to("../drive_c", target_is_directory=True)
        self.table = self.work / "table"
        self.table.write_text("".join(
            f"{rel}  {len(v)}  {hashlib.sha256(v).hexdigest()}\n" for rel, (v, _) in self.FILES.items()))
        self.builds = self.work / "builds"
        self.builds.write_text(f"{len(exe)}  {self.STAMP:08X}\n")
        self.ps = self.work / "ps.txt"
        self.ps.write_text("")

    # ------------------------------------------------------------ the world
    @staticmethod
    def put(path, data, mtime=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if mtime:
            os.utime(path, (mtime, mtime))

    def win(self, path):
        return "Z:" + str(path).replace("/", "\\")

    def install_cas(self):
        """CAS in the bottle: cas.exe, its manifest, its copies of the originals."""
        (self.local / "CAS").mkdir(parents=True, exist_ok=True)
        (self.local / "CAS/cas.exe").write_bytes(b"MZ")
        content = self.local / "CAS/content/FIFA17-test"
        files = [{"path": self.CAS_SPELLING[rel], "bytes": len(c), "replaces": True}
                 for rel, (_, c) in self.FILES.items()]
        files.insert(0, {"path": self.ADDED, "bytes": 9, "replaces": False})
        self.put(content / "installed.json", json.dumps(
            {"game": "fifa17", "mods": [{"name": "CAS Custom Players", "version": "123"}],
             "files": files}, indent=2).encode())
        for rel, (vanilla, _) in self.FILES.items():
            self.put(content / "original" / self.CAS_SPELLING[rel], vanilla, 1700000000)
        return content

    def cas_plays(self):
        """What a CAS PLAY leaves: its data, cas_03.cas and its DLL."""
        content = self.local / "CAS/content/FIFA17-test"
        for rel, (_, cas) in self.FILES.items():
            self.put(self.game / rel, cas)
        self.put(self.game / self.ADDED, b"cas-added")
        (self.game / "version.dll").write_bytes(self.CAS_DLL)
        if (content / "installed.json").exists():
            # CAS rewrites its manifest on every PLAY; each play here is a
            # little later than the last.
            self.plays = getattr(self, "plays", 0) + 1
            stamp = 1800000000 + self.plays
            os.utime(content / "installed.json", (stamp, stamp))

    def is_vanilla(self):
        return all((self.game / rel).read_bytes() == v for rel, (v, _) in self.FILES.items())

    def is_cas(self):
        return (all((self.game / rel).read_bytes() == c for rel, (_, c) in self.FILES.items())
                and (self.game / self.ADDED).exists())

    def env(self, **extra):
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.work), "LANG": "C",
               "CX_FIFA_GATE_TEST_TABLE": str(self.table),
               "CX_FIFA_GATE_TEST_BUILDS": str(self.builds),
               "CX_FIFA_GATE_TEST_PS": str(self.ps),
               # The chores a start leaves for after it, run before the
               # gate exits, so a test sees what they did.
               "CX_FIFA_GATE_TEST_CHORES": "wait",
               "CX_FIFA_GATE_TEST_DIALOG": str(self.work / "dialogs")}
        env.update(extra)
        return env

    def argv(self, exe, parent, envnames):
        return ["/bin/zsh", "-f", str(GATE_SCRIPT), "--exe", exe,
                "--image", self.win(self.game / exe), "--parent", parent,
                "--envnames", envnames, "--prefix", str(self.prefix), "--winpid", "42"]

    def gate(self, exe="FIFA17.exe", parent="-", envnames="PATH,TEMP", **extra):
        result = subprocess.run(self.argv(exe, parent, envnames), env=self.env(**extra),
                                capture_output=True, text=True, timeout=60, cwd="/")
        self.assertEqual(result.stderr, "", result.stderr)
        return result.returncode, self.last_log()

    def last_log(self):
        """The start's own line (the chores after it log as "after <exe>")."""
        if not self.log.exists():
            return None
        lines = [l.split("\t") for l in self.log.read_text().splitlines()]
        lines = [l for l in lines if not l[1].startswith("after ")]
        return lines[-1] if lines else None

    def chores_log(self):
        if not self.log.exists():
            return []
        return [l.split("\t") for l in self.log.read_text().splitlines()
                if l.split("\t")[1].startswith("after ")]

    def lock_holder(self):
        """A process that looks like a gate run to `ps`, alive for the test."""
        proc = subprocess.Popen(["/bin/zsh", "-f", "-c", "sleep 30; :", "cx-fifa17-gate"])
        self.addCleanup(lambda: (proc.kill(), proc.wait()))
        return proc

    def dialogs(self):
        path = self.work / "dialogs"
        return path.read_text() if path.exists() else ""

    def source(self, body):
        script = "source " + shlex_quote(str(GATE_SCRIPT)) + "\n" + body
        return subprocess.run(["/bin/zsh", "-f", "-c", script], env=self.env(),
                              capture_output=True, text=True, timeout=30)

    # ------------------------------------------------------- who started it
    def test_identification_follows_the_table_first_match_wins(self):
        cases = [
            # exe, parent, env names, live dll, CasBridge running -> launcher
            ("FIFA17.exe", "FIFA17.exe", "FUT17_GAME_CODE", "aurora", "0", "skip"),
            ("FIFA17.exe", "Aurora15Connector.exe", "PATH,FUT17_GAME_CODE", "cas", "1", "aurora"),
            ("FIFA17.exe", "cas.exe", "IMPULSUM_SERVER_HOST,PATH", "cas", "0", "impulsum"),
            ("FIFA17.exe", "-", "CAS_DEBUG", "aurora", "0", "cas"),
            ("FIFA17.exe", "Aurora.exe", "PATH", "cas", "1", "aurora"),
            ("FIFA17.exe", "AURORA15CLIENT.EXE", "PATH", "cas", "1", "aurora"),
            ("FIFA17.exe", "Impulsum17Launcher.exe", "PATH", "cas", "1", "impulsum"),
            ("FIFA17.exe", "cas.exe", "PATH", "aurora", "0", "cas"),
            ("FIFA17.exe", "CasBridge.exe", "PATH", "impulsum", "0", "cas"),
            ("FIFA17.exe", "_fifa17.exe", "PATH", "cas", "1", "cas"),
            ("FIFA17.exe", "RebornFUT.exe", "PATH", "reborn", "0", "reborn"),
            ("FIFA17.exe", "_fifa17.exe", "PATH", "aurora", "0", "direct"),
            ("FIFA17.exe", "winewrapper.exe", "PATH", "cas", "0", "direct"),
            ("FIFA17.exe", "start.exe", "PATH", "impulsum", "0", "direct"),
            ("FIFA17.exe", "explorer.exe", "PATH", "missing", "0", "direct"),
            ("FIFA17.exe", "cmd.exe", "PATH", "unknown", "0", "direct"),
            ("FIFA17.exe", "-", "PATH", "aurora", "0", "direct"),
            ("FIFA17.exe", "launcher.exe", "PATH", "aurora", "0", "other"),
            # The safety rule: CAS's DLL live and no known parent -> CAS.
            ("FIFA17.exe", "-", "PATH", "cas", "0", "cas"),
            ("FIFA17.exe", "launcher.exe", "PATH", "cas", "0", "cas"),
        ]
        body = "".join(
            f"cxg_identify {' '.join(shlex_quote(x) for x in c[:5])}; print -r -- '|'\n"
            for c in cases)
        result = self.source(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        answers = [a.strip() for a in result.stdout.split("|")[:-1]]
        for case, answer in zip(cases, answers):
            with self.subTest(case=case):
                self.assertEqual(answer.split("\t")[0], case[5], answer)
                self.assertNotIn("\n", answer)

    def test_a_dll_is_known_by_its_content_never_by_its_name(self):
        for name, data, kind in [("version.dll.cas-backup", self.AURORA_DLL, "aurora"),
                                 ("version.dll.before-impulsum", self.CAS_DLL, "cas"),
                                 ("version.dll.aurora17", self.IMPULSUM_DLL, "impulsum"),
                                 ("x.dll", b"MZ crumpet.ini", "reborn"),
                                 ("y.dll", b"MZ Aurora17RedirectShim.dll", "aurora17"),
                                 ("verorig.dll", (ROOT / "fixes/x86_64-windows/version.dll").read_bytes(), "wine"),
                                 ("z.dll", b"MZ nothing", "unknown")]:
            (self.game / name).write_bytes(data)
            result = self.source(f"cxg_dll_kind {shlex_quote(str(self.game / name))}")
            self.assertEqual(result.stdout.strip(), kind, name)

    # --------------------------------------------- the game's own files back
    def test_a_launch_that_is_not_cas_after_cas_gets_the_games_own_files(self):
        for launcher, parent, envnames, dll in [
                ("aurora", "-", "PATH,FUT17_GAME_CODE,FUT17_LSX_PORT", self.AURORA_DLL),
                ("impulsum", "Impulsum17Launcher.exe", "PATH", self.IMPULSUM_DLL),
                ("direct", "_fifa17.exe", "PATH", self.CAS_DLL)]:
            with self.subTest(launcher=launcher):
                self.install_cas()
                self.cas_plays()
                (self.game / "version.dll").write_bytes(dll)
                rc, line = self.gate(parent=parent, envnames=envnames)
                self.assertEqual(rc, 0)
                self.assertTrue(self.is_vanilla(), line)
                self.assertFalse((self.game / self.ADDED).exists())
                self.assertEqual((self.stash / "parked" / self.ADDED).read_bytes(), b"cas-added")
                self.assertTrue(line[3].startswith(launcher + "("), line)
                self.assertIn("3 file(s) restored", line[4])
                self.assertIn("cas_03.cas parked", line[4])
                self.assertEqual(line[5], "ok")
                self.assertEqual(line[2], str(self.game))
                # The version.dll is left as that launcher put it.
                self.assertEqual((self.game / "version.dll").read_bytes(), dll)
                # Kept once, from CAS's copies (the live files were CAS's).
                for rel, (vanilla, _) in self.FILES.items():
                    self.assertEqual((self.stash / "vanilla" / rel).read_bytes(), vanilla)
                self.assertEqual(list(self.game.rglob("*.cxtmp")), [])
                self.assertFalse((self.stash / "journal").exists())
                self.assertFalse((self.stash / "lock").exists())

    def test_a_cas_launch_keeps_its_data(self):
        self.install_cas()
        self.cas_plays()
        for parent, reason in [("cas.exe", "parent cas.exe"),
                               ("-", "CAS's version.dll live")]:
            rc, line = self.gate(parent=parent)
            self.assertEqual(rc, 0)
            self.assertTrue(self.is_cas(), line)
            self.assertTrue(line[3].startswith("cas(" + reason), line)
        # Its originals are kept all the same, from CAS's own copies, but
        # after the start (see test_a_cas_start_never_hashes_or_waits).
        self.assertIn("after FIFA17.exe", self.log.read_text())
        self.assertIn("kept 3 original file(s)", self.log.read_text())

    def test_the_fast_path_changes_nothing_when_the_files_are_the_games_own(self):
        self.install_cas()
        self.cas_plays()
        self.gate(envnames="FUT17_GAME_CODE")
        self.assertTrue(self.is_vanilla())
        before = {p: (p.stat().st_mtime_ns, p.stat().st_ino) for p in self.game.rglob("*")
                  if p.is_file() and ".crossover-fifa" not in p.parts}
        kept = {p: p.stat().st_mtime_ns for p in (self.stash / "vanilla").rglob("*") if p.is_file()}
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)
        self.assertEqual(line[4], "nothing to do")
        after = {p: (p.stat().st_mtime_ns, p.stat().st_ino) for p in self.game.rglob("*")
                 if p.is_file() and ".crossover-fifa" not in p.parts}
        self.assertEqual(after, before)
        self.assertEqual({p: p.stat().st_mtime_ns for p in (self.stash / "vanilla").rglob("*")
                          if p.is_file()}, kept)

    def test_without_cas_nothing_is_kept_or_hashed(self):
        rc, line = self.gate(parent="Aurora.exe")
        self.assertEqual(rc, 0)
        self.assertEqual(line[4], "nothing to do")
        self.assertFalse((self.stash / "vanilla").exists())

    def test_a_cas_file_with_the_games_size_is_still_put_back_after_a_cas_play(self):
        # layout.toc is the same size in both; only the time and the manifest tell.
        self.install_cas()
        self.gate(envnames="FUT17_GAME_CODE")          # keeps the originals
        rel = "Update/Patch/Data/layout.toc"
        self.cas_plays()
        os.utime(self.game / rel, (self.OLD, self.OLD))   # as if CAS kept the time
        self.gate(envnames="FUT17_GAME_CODE")
        self.assertTrue(self.is_vanilla())

    def test_a_file_outside_the_table_comes_back_only_when_cas_recorded_its_hash(self):
        # A newer CAS pack replaces files the built-in table does not know.
        # CAS's own original/ copy is trusted only when CAS's base-hashes.json
        # gives the same size and sha256 for it.
        content = self.install_cas()
        vouched = ("Update/Patch/Data/win32/globals.sb", b"vanilla globals", b"cas globals!")
        unvouched = ("Update/Patch/Data/win32/ui.sb", b"vanilla ui", b"cas ui data")
        wrong = ("Update/Patch/Data/win32/chants_full.sb", b"vanilla chants", b"cas chants")
        manifest = json.loads((content / "installed.json").read_text())
        entries = {}
        for rel, vanilla, _ in (vouched, unvouched, wrong):
            self.put(self.game / rel, vanilla, self.OLD)
            self.put(content / "original" / rel, vanilla, 1700000000)
            manifest["files"].append({"path": rel, "bytes": len(vanilla), "replaces": True})
        for rel, vanilla, _ in (vouched, wrong):
            sha = hashlib.sha256(vanilla if rel == vouched[0] else b"something else").hexdigest()
            entries["Z:\\Games\\FIFA 17\\" + rel] = {"bytes": len(vanilla), "modified": 1,
                                                       "sha256": sha}
        self.put(content / "installed.json", json.dumps(manifest).encode())
        self.put(content / "base-hashes.json", json.dumps({"entries": entries}).encode())
        self.cas_plays()
        for rel, _, cas in (vouched, unvouched, wrong):
            self.put(self.game / rel, cas)
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)
        self.assertTrue(self.is_vanilla(), line)
        self.assertEqual((self.game / vouched[0]).read_bytes(), vouched[1], line)
        self.assertEqual((self.stash / "vanilla" / vouched[0]).read_bytes(), vouched[1])
        for rel, _, cas in (unvouched, wrong):
            self.assertEqual((self.game / rel).read_bytes(), cas, line)
            self.assertFalse((self.stash / "vanilla" / rel).exists())
        self.assertIn("4 file(s) restored", line[4])
        self.assertIn("ui.sb", line[4])
        self.assertIn("chants_full.sb", line[4])

    # ---------------------------------------------------------- Impulsum17
    def test_impulsums_dll_is_kept_and_put_back_by_content(self):
        (self.game / "Impulsum17Launcher.exe").write_bytes(b"MZ")
        (self.game / "version.dll").write_bytes(self.IMPULSUM_DLL)
        rc, line = self.gate(exe="Impulsum17Launcher.exe", parent="explorer.exe")
        self.assertEqual(rc, 0)
        self.assertIn("kept Impulsum17's version.dll", line[4])
        self.assertEqual((self.stash / "impulsum/version.dll").read_bytes(), self.IMPULSUM_DLL)
        # Aurora plays and puts its own in.
        (self.game / "version.dll").write_bytes(self.AURORA_DLL)
        # Impulsum17's launcher starts: its own DLL goes back before it loads one.
        rc, line = self.gate(exe="Impulsum17Launcher.exe", parent="explorer.exe")
        self.assertEqual(rc, 0)
        self.assertEqual((self.game / "version.dll").read_bytes(), self.IMPULSUM_DLL)
        self.assertIn("it was Aurora.exe's shim", line[4])
        # And at game start too, when another launcher played in between.
        (self.game / "version.dll").write_bytes(self.CAS_DLL)
        rc, line = self.gate(parent="Impulsum17Launcher.exe", envnames="IMPULSUM_AUTH_TOKEN")
        self.assertEqual(rc, 0)
        self.assertEqual((self.game / "version.dll").read_bytes(), self.IMPULSUM_DLL)
        self.assertTrue(line[3].startswith("impulsum(env"), line)

    def test_a_new_impulsum_dll_replaces_the_kept_one_which_is_kept_once(self):
        self.put(self.stash / "impulsum/version.dll", self.IMPULSUM_DLL)
        newer = self.IMPULSUM_DLL + b" v2"
        (self.game / "version.dll").write_bytes(newer)
        self.gate(exe="Impulsum17Launcher.exe")
        self.assertEqual((self.stash / "impulsum/version.dll").read_bytes(), newer)
        self.assertEqual((self.stash / "impulsum/version.dll.prev").read_bytes(), self.IMPULSUM_DLL)

    def test_an_impulsum_dll_kept_only_as_a_backup_is_found_by_its_content(self):
        (self.game / "version.dll").write_bytes(self.CAS_DLL)
        (self.game / "version.dll.cas-backup").write_bytes(self.IMPULSUM_DLL)
        (self.game / "version.dll.before-impulsum").write_bytes(self.AURORA_DLL)
        rc, _ = self.gate(envnames="IMPULSUM_SERVER_HOST")
        self.assertEqual(rc, 0)
        self.assertEqual((self.game / "version.dll").read_bytes(), self.IMPULSUM_DLL)

    def test_impulsum_is_refused_when_its_dll_is_gone_and_none_is_kept(self):
        self.install_cas()
        self.cas_plays()
        rc, line = self.gate(parent="Impulsum17Launcher.exe")
        self.assertEqual(rc, 10)
        self.assertEqual(line[5], "refused")
        # Nothing was changed for a launch that does not happen.
        self.assertTrue(self.is_cas())
        self.assertEqual((self.game / "version.dll").read_bytes(), self.CAS_DLL)
        # The launcher itself is never stopped.
        rc, line = self.gate(exe="Impulsum17Launcher.exe", parent="explorer.exe")
        self.assertEqual(rc, 0)
        self.assertIn("no Impulsum17 version.dll kept", line[4])

    # ------------------------------------------------- crashes and the lock
    def test_an_interrupted_run_is_finished_by_the_next(self):
        self.install_cas()
        self.gate(envnames="FUT17_GAME_CODE")   # originals kept
        self.cas_plays()
        proc = subprocess.Popen(self.argv("FIFA17.exe", "-", "FUT17_GAME_CODE"),
                                env=self.env(CX_FIFA_GATE_TEST_PAUSE="3"),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        first = self.game / "Update/Patch/Data/layout.toc"
        try:
            for _ in range(200):
                if first.read_bytes() == self.FILES["Update/Patch/Data/layout.toc"][0]:
                    break
                subprocess.run(["/bin/sleep", "0.05"])
        finally:
            proc.kill()
            proc.wait()
        self.assertTrue((self.stash / "journal").exists())
        self.assertFalse(self.is_vanilla())
        # A copy that was half made when it was killed.
        second = self.game / "Update/Patch/Data/Win32/chunks0.toc"
        (second.parent / (second.name + ".cxtmp")).write_bytes(b"half")
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)
        self.assertTrue(self.is_vanilla())
        self.assertIn("cleaned up after an interrupted run", line[4])
        self.assertEqual(list(self.game.rglob("*.cxtmp")), [])
        self.assertFalse((self.stash / "journal").exists())

    def test_a_held_lock_is_waited_for_then_the_launch_goes_on_unchanged(self):
        self.install_cas()
        self.cas_plays()
        (self.stash / "lock").mkdir(parents=True)
        holder = self.lock_holder()
        (self.stash / "lock/pid").write_text(f"{holder.pid} 0\n")
        rc, line = self.gate(envnames="FUT17_GAME_CODE", CX_FIFA_GATE_TEST_LOCK_WAIT="1")
        self.assertEqual(rc, 0)
        self.assertIn("lock", line[5])
        self.assertTrue(self.is_cas())
        # A lock whose owner is gone is stale, and taken over.
        (self.stash / "lock/pid").write_text("999999 0\n")
        rc, line = self.gate(envnames="FUT17_GAME_CODE", CX_FIFA_GATE_TEST_LOCK_WAIT="1")
        self.assertEqual(line[5], "ok")
        self.assertTrue(self.is_vanilla())

    def test_nothing_is_touched_while_another_fifa17_runs(self):
        self.install_cas()
        self.cas_plays()
        # The gated game itself, and this script's own command line, do not count.
        self.ps.write_text(
            f"  {os.getpid()}     1 Z:\\Games\\FIFA 17\\FIFA17.exe\n"
            "  998   500 /bin/zsh -f /x/cx-fifa17-gate --exe FIFA17.exe --image Z:\\a\\FIFA17.exe\n"
            "  997   500 tail -f /tmp/FIFA17.exe.log\n")
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(line[5], "ok")
        self.assertTrue(self.is_vanilla())
        self.cas_plays()
        self.ps.write_text(self.ps.read_text() + "  999     1 Z:\\Volumes\\x\\FIFA 17\\FIFA17.exe /dbrv=1\n")
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)
        self.assertEqual(line[5], "skipped: FIFA 17 already running")
        self.assertTrue(self.is_cas())

    def test_the_games_own_relaunch_is_left_alone(self):
        self.install_cas()
        self.cas_plays()
        rc, line = self.gate(parent="FIFA17.exe", envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)
        self.assertEqual(line[3], "skip(parent FIFA17.exe)")
        self.assertEqual(line[5], "skipped")
        self.assertTrue(self.is_cas())
        self.assertFalse(self.stash.exists())

    def test_an_unknown_build_is_left_alone_and_said_so(self):
        self.install_cas()
        self.cas_plays()
        (self.game / "FIFA17.exe").write_bytes(fake_pe(0x0BADF00D))
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)
        self.assertIn("unknown FIFA 17 build", line[4])
        self.assertTrue(self.is_cas())
        self.assertFalse((self.stash / "vanilla").exists())

    def test_the_log_never_holds_a_value_and_is_kept_short(self):
        self.put(self.log, b"".join(b"2026-01-01 00:00:00\tFIFA17.exe\t-\t?\tx\tok\t1 " + b"y" * 300 + b"\n"
                                    for _ in range(600)))
        self.gate(envnames="IMPULSUM_AUTH_TOKEN,PATH")
        text = self.log.read_text()
        self.assertLessEqual(len(text.splitlines()), 501)
        self.assertNotIn("IMPULSUM_AUTH_TOKEN", text)

    def test_the_gate_is_shipped_and_installed_beside_ntdll(self):
        subprocess.run(["/bin/zsh", "-n", str(GATE_SCRIPT)], check=True)
        sums = (ROOT / "fixes/SHA256SUMS").read_text()
        self.assertIn(hashlib.sha256(GATE_SCRIPT.read_bytes()).hexdigest()
                      + "  x86_64-unix/cx-fifa17-gate", sums)
        setup = (ROOT / "setup.sh").read_text()
        self.assertIn("GATE=x86_64-unix/cx-fifa17-gate", setup)
        for name in ("refresh_fixes",):
            self.assertIn('cmp -s "$HERE/fixes/$GATE" "$wine/$GATE"', function_source(name))
        # One copy of the path mapping: setup.sh's are the gate's.
        self.assertIn("cxg_win_to_unix", function_source("win_path_to_unix"))
        self.assertIn("cxg_unix_to_win", function_source("unix_path_to_win"))

    # ------------------------------------------- setup.sh: finding the folder
    def reg_path(self, path, trailing=""):
        return "Z:" + str(path).replace("/", "\\\\") + trailing

    def detection_harness(self):
        names = ["reg_value", "bottle_appdata", "aurora_launcher_dir", "aurora_ini_dir",
                 "connector_game_dir", "win_path_to_unix", "fifa17_dir_candidates", "game_dir_find"]
        source = (ROOT / "setup.sh").read_text()
        key = [l for l in source.splitlines() if l.startswith("IMPULSUM_UNINSTALL_KEY=")][0]
        return ("set -eu\n"
                "BOTTLE_DIR=" + shlex_quote(str(self.prefix.parent)) + "\nBOTTLE=Aurora17\n"
                + key + "\n"
                'bottle_user_reg() { print -r -- "$BOTTLE_DIR/$BOTTLE/user.reg"; }\n'
                'bottle_system_reg() { print -r -- "$BOTTLE_DIR/$BOTTLE/system.reg"; }\n'
                "source " + shlex_quote(str(GATE_SCRIPT)) + "\n"
                + "".join(function_source(n) for n in names))

    def test_the_folder_launchers_use_comes_before_a_guess(self):
        folders = {}
        for name in ("given", "gatelog", "cas", "impulsum", "ini", "connector", "ea"):
            d = self.work / name / "FIFA 17"
            d.mkdir(parents=True)
            (d / "FIFA17.exe").write_bytes(b"MZ")
            folders[name] = d
        guess = self.work / "Downloads/FIFA 17"
        guess.mkdir(parents=True)
        (guess / "FIFA17.exe").write_bytes(b"MZ")
        (guess / "_fifa17.exe").write_bytes(b"MZ")
        (folders["impulsum"] / "_fifa17.exe").write_bytes(b"MZ")
        self.log.write_text(f"2026-10-12 11:16:20\tFIFA17.exe\t{folders['gatelog']}\tcas(parent cas.exe)\tnothing to do\tok\t40\n"
                            f"2026-10-12 11:17:20\tImpulsum17Launcher.exe\t{folders['ea']}\timpulsum(launcher)\tnothing to do\tok\t40\n")
        (self.prefix / "user.reg").write_text(
            "WINE REGISTRY Version 2\n\n[Software\\\\CAS\\\\Launcher] 1791794587\n"
            f'"FifaExe"="FIFA17.exe"\n"FifaFolder"="{self.reg_path(folders["cas"])}"\n')
        (self.prefix / "system.reg").write_text(
            "WINE REGISTRY Version 2\n\n"
            "[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\"
            "{8F3C5E0A-1C34-4D8E-9E1B-7C2A5D9F1707}_is1] 1791798238\n"
            f'"InstallLocation"="{self.reg_path(folders["impulsum"], chr(92) * 2)}"\n\n'
            "[Software\\\\Wow6432Node\\\\EA Sports\\\\FIFA 17] 1\n"
            f'"Install Dir"="{self.reg_path(folders["ea"], chr(92) * 2)}"\n')
        aurora = self.local / "Aurora15Connector"
        aurora.mkdir(parents=True)
        (aurora / "Aurora15Connector.exe").write_bytes(b"MZ")
        (aurora / "Aurora15Connector.ini").write_text(
            "FifaPath=\r\nFifa17Path=Z:" + str(folders["ini"]).replace("/", "\\") + "\r\n")
        conn = self.local / "Aurora17/Connector"
        conn.mkdir(parents=True)
        (conn / "connector.json").write_text(json.dumps({"gameDirectory": "Z:" + str(folders["connector"]).replace("/", "\\")}))
        run = lambda env: subprocess.run(
            ["/bin/zsh", "-f", "-c", self.detection_harness()
             + 'fifa17_dir_candidates\nprint -r -- "find=$(game_dir_find)"\n'],
            env={**self.env(), **env}, capture_output=True, text=True, timeout=30)
        result = run({"AURORA_GAME_DIR": str(folders["given"])})
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:-1], [
            f"AURORA_GAME_DIR\t{folders['given']}", f"gate log\t{folders['gatelog']}",
            f"CAS\t{folders['cas']}", f"Impulsum17\t{folders['impulsum']}",
            f"Aurora.exe\t{folders['ini']}", f"Aurora17\t{folders['connector']}",
            f"EA registry\t{folders['ea']}", f"guess\t{guess}", f"guess\t{self.game}"])
        # The loader's folder: the first that has _fifa17.exe, not the guess.
        self.assertEqual(lines[-1], f"find={folders['impulsum']}")
        # One folder named by several launchers is one line.
        (self.prefix / "user.reg").write_text((self.prefix / "user.reg").read_text().replace(
            self.reg_path(folders["cas"]), self.reg_path(folders["impulsum"])))
        lines = run({}).stdout.splitlines()
        self.assertIn(f"CAS, Impulsum17\t{folders['impulsum']}", lines)
        self.assertEqual(lines[0], f"gate log\t{folders['gatelog']}")

    # ----------------------------------------------- setup.sh: --verify and --fix-folder
    def shared_bottle(self, gate_on=True):
        """A bottle with all three launchers pointing at the game folder, CAS's
        data live in it, and a stray guess in ~/Downloads."""
        app = self.work / "CrossOver-FIFA.app"
        unix = app / "Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix"
        unix.mkdir(parents=True)
        (unix / "ntdll.so").write_bytes(b"ntdll CX_GAME_PROFILES" + (b" CX_FOLDER_GATE_V1" if gate_on else b""))
        shutil.copy2(GATE_SCRIPT, unix / "cx-fifa17-gate")
        (self.prefix / "cxbottle.conf").write_text(
            '[EnvironmentVariables]\n"CX_GRAPHICS_BACKEND" = "d3dmetal"\n"CX_DR_TRAP" = "2"\n'
            '"WEBVIEW2_BROWSER_EXECUTABLE_FOLDER" = "C:\\\\webview2-fixed\\\\99.0.1150.52"\n')
        wv = self.prefix / "drive_c/webview2-fixed/99.0.1150.52"
        wv.mkdir(parents=True)
        (wv / "msedgewebview2.exe").write_bytes(b"MZ")
        self.install_cas()
        self.cas_plays()
        (self.game / "Impulsum17Launcher.exe").write_bytes(b"MZ")
        (self.game / "version.dll.cas-backup").write_bytes(self.AURORA_DLL)
        aurora = self.local / "Aurora15Connector"
        aurora.mkdir(parents=True)
        (aurora / "Aurora15Connector.exe").write_bytes(b"MZ")
        (self.prefix / "user.reg").write_text(
            "WINE REGISTRY Version 2\n\n[Software\\\\CAS\\\\Launcher] 1791794587\n"
            f'"FifaFolder"="{self.reg_path(self.game)}"\n\n'
            '[Software\\\\Wine\\\\DllOverrides] 0\n"version"="native,builtin"\n'
            '"msvcr120"="native,builtin"\n"msvcp120"="native,builtin"\n')
        (self.prefix / "system.reg").write_text(
            "WINE REGISTRY Version 2\n\n"
            "[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\"
            "{8F3C5E0A-1C34-4D8E-9E1B-7C2A5D9F1707}_is1] 1\n"
            f'"InstallLocation"="{self.reg_path(self.game, chr(92) * 2)}"\n')
        guess = self.work / "Downloads/FIFA 17"
        guess.mkdir(parents=True)
        (guess / "FIFA17.exe").write_bytes(b"MZ")
        return app, guess

    def setup_sh(self, mode, app, **extra):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("AURORA_", "FIFA1", "FIFA2", "CX_", "WEBVIEW2_", "REBORN_"))}
        env.update(self.env(), CX_BOTTLE_PATH=str(self.prefix.parent), HOME=str(self.work),
                   AURORA_RECEIPT_DIR=str(self.work / "receipts"), NO_COLOR="1",
                   CX_VOLUMES_DIR=str(self.work / "Volumes"),
                   AURORA_BOTTLE="Aurora17", AURORA_TARGET=str(app), **extra)
        return subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), mode], env=env,
                              capture_output=True, text=True, timeout=120)

    @staticmethod
    def block(stdout):
        return stdout.split("FIFA 17 game folder\n", 1)[1].split("\n\n", 1)[0]

    def tree(self):
        return {p: p.read_bytes() for root in (self.game, self.prefix)
                for p in root.rglob("*") if p.is_file()}

    def test_verify_shows_the_folder_and_changes_nothing(self):
        app, guess = self.shared_bottle()
        (self.log).write_text(f"2026-01-02 11:16:20\tFIFA17.exe\t{self.game}\tcas(parent cas.exe)\tnothing to do\tok\t40\n")
        before = self.tree()
        result = self.setup_sh("--verify", app)
        self.assertIn(result.returncode, (0, 5), result.stdout + result.stderr)
        self.assertEqual(self.tree(), before, "--verify changed something")
        block = self.block(result.stdout)
        self.assertIn("  ~/Games/FIFA 17              FIFA 17 last ran here 01-02 11:16 (cas); CAS and Impulsum17 point here", block)
        self.assertIn("data files      CAS mod data (CAS Custom Players v123, 4 files)", block)
        self.assertIn("the next launch that is not CAS's puts the game's own back", block)
        self.assertIn("version.dll     CAS's redirect (", block)
        self.assertIn("originals       0/3 in .crossover-fifa; CAS keeps copies in its original/ folder", block)
        self.assertIn("Impulsum DLL    not on this Mac: Impulsum17's PLAY will stop and say so.", block)
        self.assertIn("note  Impulsum17's version.dll is gone from ~/Games/FIFA 17", block)
        self.assertIn("gate            on (ntdll.so has CX_FOLDER_GATE_V1, script is the shipped one)", block)
        self.assertIn("last launches   01-02 11:16 cas: nothing to do", block)
        self.assertIn("other files     version.dll.cas-backup is Aurora.exe's shim", block)
        self.assertIn("~/Downloads/FIFA 17          only a guess: no launcher points here", block)
        self.assertNotIn("BAD", block)
        # The launcher table's Impulsum17 row says what its PLAY would stop at.
        rows, launchers = SharedBottleTests.tables(result.stdout)
        self.assertEqual(launchers[("Impulsum17", "FIFA 17")], "missing Impulsum DLL")
        self.assertEqual(rows["FIFA 17"][1], "found (gate log)")
        self.assertIn(f"  FIFA 17: {self.game}  (where it last started)", result.stdout)

    def test_verify_calls_the_gate_off_bad_with_several_launchers(self):
        app, _ = self.shared_bottle()
        with (self.prefix / "cxbottle.conf").open("a") as conf:
            conf.write('"CX_FIFA_GATE" = "0"\n')
        result = self.setup_sh("--verify", app)
        self.assertEqual(result.returncode, 5)
        block = self.block(result.stdout)
        self.assertIn('gate            off in this bottle ("CX_FIFA_GATE" = "0"', block)
        self.assertIn("BAD   the folder gate is off, and the Aurora17 bottle has 3 FIFA 17 launchers", block)

    def test_fix_folder_keeps_copies_and_never_touches_the_game(self):
        app, guess = self.shared_bottle()
        game_files = {p: p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
        result = self.setup_sh("--fix-folder", app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("kept 3 original file(s)", result.stdout)
        self.assertIn("Impulsum17's version.dll is not on this Mac", result.stdout)
        self.assertEqual({p: p.read_bytes() for p in self.game.rglob("*")
                          if p.is_file() and ".crossover-fifa" not in p.parts}, game_files)
        for rel, (vanilla, _) in self.FILES.items():
            self.assertEqual((self.stash / "vanilla" / rel).read_bytes(), vanilla)
        self.assertFalse((guess / ".crossover-fifa").exists())
        # The next launch that is not CAS's puts the game's own back, and
        # --verify then says so.
        (self.game / "version.dll").write_bytes(self.AURORA_DLL)
        rc, _ = self.gate(parent="Aurora15Connector.exe")
        self.assertEqual(rc, 0)
        block = self.block(self.setup_sh("--verify", app).stdout)
        self.assertIn("data files      the game's own (3 of 3)", block)
        self.assertIn("originals       3/3 in .crossover-fifa, match FIFA 17's final update", block)
        self.assertIn("aurora: 3 file(s) restored, cas_03.cas parked", block)


    # ------------------------------------- starting states (2026-10-12 review)
    def hash_log(self):
        """A shasum on PATH that notes each file it hashes and whether the
        gate run that asked was the after-start chores."""
        bin_dir = self.work / "bin"
        bin_dir.mkdir(exist_ok=True)
        calls = self.work / "hashed.txt"
        wrapper = bin_dir / "shasum"
        wrapper.write_text(
            "#!/bin/zsh -f\n"
            "c=\"$(/bin/ps -o command= -p $PPID)\"\n"
            f"print -r -- \"${{c[(w)4]}} ${{@[-1]}}\" >> {shlex_quote(str(calls))}\n"
            "exec /usr/bin/shasum \"$@\"\n")
        wrapper.chmod(0o755)
        return f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin", calls

    @staticmethod
    def hashed(calls):
        return calls.read_text().splitlines() if calls.exists() else []

    def test_a_cas_start_never_hashes_or_waits(self):
        # CAS's debugger hung its FIFA 17 when the gate took a second. The
        # first start after CAS wrote its data used to hash and copy 75 MB
        # (CAS's copies, and the live files of the game's size) right there.
        self.install_cas()
        self.cas_plays()
        path, calls = self.hash_log()
        rc, line = self.gate(parent="cas.exe", PATH=path)
        self.assertEqual(rc, 0)
        self.assertEqual(line[4], "nothing to do", line)
        self.assertTrue(self.is_cas())
        self.assertEqual([c for c in self.hashed(calls) if not c.startswith("--chores")], [])
        # The copies are kept all the same, by the chores after the start,
        # from CAS's copies only (not the live files, which are CAS's).
        self.assertTrue(all(c.startswith("--chores") and "/original/" in c for c in self.hashed(calls)),
                        self.hashed(calls))
        self.assertIn("kept 3 original file(s)", self.chores_log()[-1][4])
        for rel, (vanilla, _) in self.FILES.items():
            self.assertEqual((self.stash / "vanilla" / rel).read_bytes(), vanilla)
        # A CAS start never waits for the lock either.
        (self.stash / "lock").mkdir()
        (self.stash / "lock/pid").write_text(f"{self.lock_holder().pid} 0\n")
        import time
        t0 = time.monotonic()
        rc, line = self.gate(parent="cas.exe", CX_FIFA_GATE_TEST_LOCK_WAIT="5")
        self.assertLess(time.monotonic() - t0, 3)
        self.assertEqual((rc, line[5]), (0, "ok"))
        self.assertIn("folder busy", line[4])

    def test_the_chores_run_after_the_gate_has_let_the_game_go(self):
        self.install_cas()
        self.cas_plays()
        rc, line = self.gate(parent="cas.exe", CX_FIFA_GATE_TEST_CHORES="")
        self.assertEqual(rc, 0)
        import time
        for _ in range(100):
            if self.chores_log():
                break
            time.sleep(0.05)
        self.assertIn("kept 3 original file(s)", self.chores_log()[-1][4])
        self.assertTrue((self.stash / "snapshot").exists())
        self.assertFalse((self.stash / "lock").exists())

    def test_a_copy_found_not_to_be_the_games_is_not_hashed_again(self):
        # CAS gone with its original/ folder, its data still in the game:
        # no copy of the originals anywhere. Every start used to hash the
        # live files of the game's size again.
        content = self.install_cas()
        self.cas_plays()
        shutil.rmtree(content / "original")
        path, calls = self.hash_log()
        rc, line = self.gate(envnames="FUT17_GAME_CODE", PATH=path)
        self.assertEqual((rc, line[5]), (0, "incomplete"))
        first = self.hashed(calls)
        self.assertTrue(any(c.endswith("layout.toc") for c in first), first)
        rc, line = self.gate(envnames="FUT17_GAME_CODE", PATH=path)
        self.assertEqual(self.hashed(calls), first)
        # CAS's set is left whole, cas_03.cas with it: half of it put back
        # and cas_03.cas parked would be neither CAS's game nor the game's.
        self.assertTrue(self.is_cas())
        self.assertIn("no original of", line[4])

    def test_a_start_that_cannot_be_saved_says_so(self):
        content = self.install_cas()
        self.cas_plays()
        shutil.rmtree(content / "original")
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(rc, 0)          # it still starts: nothing is refused
        self.assertIn("likely to close", self.dialogs())
        self.assertIn("layout.toc", self.dialogs())
        # CAS's own start is fine with its data.
        (self.work / "dialogs").unlink()
        self.gate(parent="cas.exe")
        self.assertEqual(self.dialogs(), "")

    def test_a_partly_kept_stash_is_completed_once_cas_is_gone(self):
        # Two of three kept while CAS was around; CAS gone, the game's own
        # files back in place. The third used to stay "no original" for good.
        rel = "Update/Patch/Data/layout.toc"
        self.put(self.stash / "vanilla" / rel, self.FILES[rel][0], self.OLD)
        rc, line = self.gate(parent="Aurora.exe")
        self.assertEqual((rc, line[5]), (0, "ok"), line)
        for rel, (vanilla, _) in self.FILES.items():
            self.assertEqual((self.stash / "vanilla" / rel).read_bytes(), vanilla)

    def test_a_cracked_exe_over_the_final_updates_data_counts_as_that_build(self):
        initfs = b"the final update's initfs"
        self.put(self.game / "Update/Patch/Data/initfs_Win32", initfs, self.OLD)
        self.builds.write_text(self.builds.read_text() + "Update/Patch/Data/initfs_Win32  "
                               f"{len(initfs)}  {hashlib.sha256(initfs).hexdigest()}\n")
        (self.game / "FIFA17.exe").write_bytes(fake_pe(0x0BADF00D))
        self.install_cas()
        self.cas_plays()
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual((rc, line[5]), (0, "ok"), line)
        self.assertTrue(self.is_vanilla())
        # Other data is another build: left alone.
        self.cas_plays()
        self.put(self.game / "Update/Patch/Data/initfs_Win32", b"another build's initfs!!", self.OLD)
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertIn("unknown FIFA 17 build", line[4])
        self.assertTrue(self.is_cas())

    def test_a_folder_wine_reaches_by_any_path(self):
        # \\?\unix\... is how Wine names a folder no drive letter reaches.
        self.install_cas()
        for image in ["\\\\?\\unix" + str(self.game / "FIFA17.exe").replace("/", "\\"),
                      "\\??\\unix" + str(self.game / "FIFA17.exe").replace("/", "\\")]:
            with self.subTest(image=image):
                self.cas_plays()
                argv = self.argv("FIFA17.exe", "-", "FUT17_GAME_CODE")
                argv[argv.index("--image") + 1] = image
                subprocess.run(argv, env=self.env(), capture_output=True, timeout=60)
                self.assertEqual(self.last_log()[2], str(self.game))
                self.assertTrue(self.is_vanilla())

    def test_odd_folder_names_and_other_drive_letters_work(self):
        # Not a fix: the starting states with a D: drive, a folder in
        # drive_c, and a name with an apostrophe, accents and spaces.
        odd = self.work / "Mokhtar's Spiele/FIFA 17 – Édition"
        shutil.move(str(self.game), str(odd))
        self.game, self.stash = odd, odd / ".crossover-fifa"
        (self.prefix / "dosdevices/d:").symlink_to(odd.parent, target_is_directory=True)
        self.install_cas()
        for image in ["D:\\" + odd.name + "\\FIFA17.exe", self.win(odd / "FIFA17.exe")]:
            with self.subTest(image=image):
                self.cas_plays()
                argv = self.argv("FIFA17.exe", "-", "FUT17_GAME_CODE")
                argv[argv.index("--image") + 1] = image
                subprocess.run(argv, env=self.env(), capture_output=True, timeout=60)
                self.assertEqual(self.last_log()[5], "ok", self.last_log())
                self.assertTrue(self.is_vanilla())
        inside = self.prefix / "drive_c/Games/FIFA 17"
        shutil.move(str(odd), str(inside))
        self.game, self.stash = inside, inside / ".crossover-fifa"
        self.cas_plays()
        argv = self.argv("FIFA17.exe", "-", "FUT17_GAME_CODE")
        argv[argv.index("--image") + 1] = "C:\\Games\\FIFA 17\\FIFA17.exe"
        subprocess.run(argv, env=self.env(), capture_output=True, timeout=60)
        self.assertEqual(self.last_log()[2], str(inside))
        self.assertTrue(self.is_vanilla())

    def test_no_appledouble_file_is_left_beside_a_restored_file(self):
        # On exFAT every file a process writes gets a ._<name> beside it
        # (com.apple.provenance); the real game folder had seven of them in
        # Update/Patch/Data after the first restore.
        self.install_cas()
        self.cas_plays()
        rel = Path("Update/Patch/Data/layout.toc")
        (self.game / rel.parent / ("._" + rel.name)).write_bytes(b"\0\5\26\7 xattrs")
        self.gate(envnames="FUT17_GAME_CODE")
        self.assertTrue(self.is_vanilla())
        self.assertEqual([p.name for p in self.game.rglob("._*")], [])

    def test_a_half_made_copy_with_no_journal_is_removed(self):
        self.install_cas()
        self.cas_plays()
        self.gate(envnames="FUT17_GAME_CODE")
        left = self.game / "Update/Patch/Data/Win32/chunks0.toc.cxtmp"
        left.write_bytes(b"half")
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertEqual(line[4], "nothing to do")
        self.assertFalse(left.exists())

    def test_a_lock_whose_pid_now_belongs_to_another_program_is_stale(self):
        # A run killed with its lock held; after a restart its pid is some
        # other program's. That used to hold every start up for 15 s, for
        # ten minutes.
        self.install_cas()
        self.cas_plays()
        (self.stash / "lock").mkdir(parents=True)
        (self.stash / "lock/pid").write_text(f"{os.getpid()} 0\n")
        rc, line = self.gate(envnames="FUT17_GAME_CODE", CX_FIFA_GATE_TEST_LOCK_WAIT="1")
        self.assertEqual((rc, line[5]), (0, "ok"), line)
        self.assertTrue(self.is_vanilla())

    def cas_folder_name(self, folder):
        win = ("z:" + str(folder).replace("/", "\\")).lower()
        return "FIFA17-" + hashlib.sha256(win.encode()).hexdigest()[:12]

    def test_only_this_folders_cas_content_is_used(self):
        # CAS keeps one content folder per game folder. Another folder's
        # (here a different build, whose ui.sb differs) must not be put
        # into this one.
        content = self.install_cas()
        mine = content.parent / self.cas_folder_name(self.game)
        content.rename(mine)
        other = content.parent / "FIFA17-0123456789ab"
        rel = "Update/Patch/Data/win32/ui.sb"
        theirs = b"the other build's ui"
        self.put(other / "original" / rel, theirs, 1700000000)
        self.put(other / "installed.json", json.dumps(
            {"mods": [], "files": [{"path": rel, "bytes": 3, "replaces": True}]}).encode())
        self.put(other / "base-hashes.json", json.dumps({"entries": {
            "Z:\\Other\\FIFA 17\\" + rel: {"bytes": len(theirs), "sha256": hashlib.sha256(theirs).hexdigest()}}}).encode())
        os.utime(other, (1900000000, 1900000000))     # the newest, so first
        self.put(self.game / rel, b"this folder's own ui", self.OLD)
        self.cas_plays()
        rc, line = self.gate(envnames="FUT17_GAME_CODE")
        self.assertTrue(self.is_vanilla(), line)
        self.assertEqual((self.game / rel).read_bytes(), b"this folder's own ui")
        self.assertFalse((self.stash / "vanilla" / rel).exists())

    def test_a_second_bottle_on_the_same_folder_does_not_copy_it_all_again(self):
        self.install_cas()
        self.cas_plays()
        self.gate(envnames="FUT17_GAME_CODE")
        self.assertTrue(self.is_vanilla())
        other = self.work / "bottles/FIFA17"
        (other / "dosdevices").mkdir(parents=True)
        (other / "dosdevices/z:").symlink_to("/", target_is_directory=True)
        def gate_in(prefix):
            argv = self.argv("FIFA17.exe", "-", "FUT17_GAME_CODE")
            argv[argv.index("--prefix") + 1] = str(prefix)
            subprocess.run(argv, env=self.env(), capture_output=True, timeout=60)
            return (prefix / "cxfifa-gate.log").read_text().splitlines()[-1].split("\t")
        gate_in(other)                  # its first look may copy once
        self.assertEqual(gate_in(self.prefix)[4], "nothing to do")
        self.assertEqual(gate_in(other)[4], "nothing to do")
        self.assertEqual(gate_in(self.prefix)[4], "nothing to do")
        # CAS played from the first bottle: the second still puts it right.
        self.cas_plays()
        line = gate_in(other)
        self.assertIn("3 file(s) restored", line[4])
        self.assertTrue(self.is_vanilla())

    def test_a_read_only_game_folder_is_skipped_not_failed(self):
        self.game.chmod(0o555)
        self.addCleanup(self.game.chmod, 0o755)
        rc, line = self.gate(parent="Aurora.exe")
        self.assertEqual(rc, 0)
        self.assertEqual(line[5], "skipped: the game folder is read-only")

    def test_verify_reads_a_cracked_exes_build_and_writes_nothing(self):
        app, _ = self.shared_bottle()
        initfs = b"the final update's initfs"
        self.put(self.game / "Update/Patch/Data/initfs_Win32", initfs, self.OLD)
        self.builds.write_text(self.builds.read_text() + "Update/Patch/Data/initfs_Win32  "
                               f"{len(initfs)}  {hashlib.sha256(initfs).hexdigest()}\n")
        (self.game / "FIFA17.exe").write_bytes(fake_pe(0x0BADF00D))
        self.stash.mkdir()
        before = self.tree()
        block = self.block(self.setup_sh("--verify", app).stdout)
        self.assertEqual(self.tree(), before, "--verify changed something")
        self.assertNotIn("unknown FIFA 17 build", block)
        self.assertIn("CAS mod data", block)

    def test_fix_folder_takes_lost_originals_from_another_copy(self):
        app, guess = self.shared_bottle()
        shutil.rmtree(self.local / "CAS/content/FIFA17-test/original")
        block = self.block(self.setup_sh("--verify", app).stdout)
        self.assertIn("BAD", block)
        self.assertIn("--fix-folder takes the files from it", block)
        self.assertIn("and nothing to put the game's own back from", block)
        self.assertNotIn("puts the game's own back", block)
        # The stray copy in ~/Downloads is the same build, with the game's
        # own files.
        shutil.copy2(self.game / "FIFA17.exe", guess / "FIFA17.exe")
        for rel, (vanilla, _) in self.FILES.items():
            self.put(guess / rel, vanilla, self.OLD)
        result = self.setup_sh("--fix-folder", app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("kept 3 original file(s) from", result.stdout)
        self.assertNotIn("no original", result.stdout)
        for rel, (vanilla, _) in self.FILES.items():
            self.assertEqual((self.stash / "vanilla" / rel).read_bytes(), vanilla)
        self.assertTrue(self.is_cas())
        rc, _ = self.gate(parent="Aurora15Connector.exe")
        self.assertTrue(self.is_vanilla())

if __name__ == "__main__":
    unittest.main()
