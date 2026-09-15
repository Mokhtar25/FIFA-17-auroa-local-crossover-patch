"""Run with python3 -m unittest discover -s tests -v.

Installer entry points are exercised only with arguments that must exit before
side effects. Diagnostics run with stubbed reporting in a temporary directory.
"""
import hashlib
import os
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
            ("setup.sh", ["--verify", "--offline"], 2),
            ("setup.sh", ["one.app", "two.app"], 2),
            ("setup.sh", ["--fifa15", "--unknown"], 2),
            ("setup.sh", ["--fifa15", "one.app", "two.app"], 2),
            ("setup.sh", ["--repair", "--offline"], 2),
            ("setup.sh", ["--fifa15", "--repair"], 2),
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
                self.assertEqual(calls[0][:2], ["fifa17", "Aurora17"])
                if args == ["--verify"]:
                    self.assertEqual(calls[1], ["fifa15", "Aurora15", ["--fifa15", "--verify"]])
                if args == [] and rc17 == "5":
                    self.assertIn("FIFA 15 needs only the copy", result.stdout)

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
                self.assertIn("x86_64-windows/ole32.dll", lines)
                self.assertIn("x86_64-unix/win32u.so", lines)
                # The WebView2 pin is FIFA 17's: FIFA 15 has no RebornFUT.
                pin = r"WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=C:\webview2-fixed\99.0.1150.52"
                if game == "fifa17":
                    self.assertIn(pin, lines)
                else:
                    self.assertFalse(any(line.startswith("WEBVIEW2_") for line in lines))

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
        for action in ("--offline", "--play-offline", "--play-log", "--reseed-licence", "--bundle",
                       "--repair"):
            with self.subTest(action=action):
                result = subprocess.run(["/bin/zsh", str(ROOT / "setup.sh"), action],
                                        env={**self.env, "AURORA_GAME": "fifa15"},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("FIFA 17", result.stdout)


def function_source(name):
    """One shell function out of setup.sh, for running against stubs."""
    source = (ROOT / "setup.sh").read_text()
    body = source.split(name + "() {", 1)[1].split("\n}\n", 1)[0]
    return name + "() {" + body + "\n}\n"


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
            (wine / "x86_64-unix/ws2_32.so").write_bytes(b"ws2_32")
            harness = r"""
set -eu
HERE="$PWD"
FILES=( x86_64-windows/version.dll x86_64-unix/ntdll.so )
RESOLVER=x86_64-unix/a17hosts.dylib
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
                + self.function("reg_line_is_set")
                + self.function("set_reg_line")
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
                + self.function("unix_path_to_win")
                + self.function("f15_ensure_crt_dlls"))

    def run_zsh(self, script, env=None):
        return subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True,
                              timeout=30, env=env)

    def fixture(self, directory):
        reg = Path(directory) / "user.reg"
        reg.write_text(self.REG)
        return reg

    def lines_in_section(self, reg):
        found, out = False, []
        for line in reg.read_text().splitlines():
            if line.startswith("["):
                found = line.startswith(self.SECTION)
                continue
            if found and line.startswith('"'):
                out.append(line)
        return out

    def game_env(self, work, **extra):
        """A home of our own: these helpers search ~/Downloads and friends, and
        a test must never find (or write into) the real game folders."""
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("AURORA_", "FIFA15_", "FIFA17_", "CX_"))}
        env.update(HOME=str(work), **extra)
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

    def test_it_writes_both_lines_into_the_dll_override_section(self):
        for game, expected in [
            ("fifa17", ['"msvcp120"="native,builtin"', '"msvcr120"="native,builtin"']),
            ("fifa15", ['"msvcp110"="native,builtin"', '"msvcr110"="native,builtin"']),
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
                    # Both lines land under the DLL override section, and nothing
                    # already there -- in it or in the section after -- is lost.
                    self.assertEqual(sorted(self.lines_in_section(reg)),
                                     ['"*d3dcompiler_47"="native"', *expected,
                                      '"version"="native,builtin"'])
                    self.assertIn('"Decorated"="Y"', reg.read_text())

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
        (bottles / "Aurora15" / "dosdevices" / "y:").symlink_to(work, target_is_directory=True)
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
            self.assertIn(f"OK msvcr110 + msvcp110 — Microsoft's own, in {game}", beside.stdout)
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
        """The writer itself, lifted out of configure_bottle."""
        body = cls.source().split("        add_setting() {", 1)[1].split("\n        }\n", 1)[0]
        return "add_setting() {" + body + "\n}\n"

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
        block = self.block('    if [ "$GAME" != fifa15 ] && [ "${WEBVIEW2_RUNTIME:-}" != skip ]; then')
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

            # FIFA 15 has no RebornFUT, and skip means it was never installed.
            for skipped in ("GAME=fifa15\n", "WEBVIEW2_RUNTIME=skip\n"):
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


if __name__ == "__main__":
    unittest.main()
