#!/usr/bin/env bash
# Standalone native TUI proof; owns flea-display.lock and preserves its marked /tmp evidence root.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

SCRIPT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
ESCAPE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
WAIT_SECONDS = 20
POLL_SECONDS = 0.05


def command(args, **options):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, **options)
    if result.returncode:
        raise RuntimeError(f"{shlex.join(map(str, args))} exited {result.returncode}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def guard(root, path):
    root, path = Path(root), Path(path)
    if not root.is_absolute() or not path.is_absolute() or not (root / ".flea-test-sandbox").is_file():
        raise RuntimeError("TUI fixture requires absolute paths and its own marker")
    path = path.resolve()
    if not path.is_relative_to(root.resolve()) or path == root.resolve():
        raise RuntimeError(f"TUI fixture path escaped its owned root: {path}")
    return path


# Native output: ESC[H starts a frame; ESC[rows;1H introduces its full-width final row, including editors.
def frame(data, rows, columns):
    raw = data.rsplit(b"\x1b[H", 1)[-1] if b"\x1b[H" in data else b""
    footer = b"\x1b[" + str(rows).encode() + b";1H"
    if footer not in raw or len(ESCAPE.sub(b"", raw.split(footer, 1)[1]).decode("utf-8", errors="replace")) < columns:
        return b"", ""
    text = re.sub(rb"\x1b\[\d+;1H", b"\n", raw)
    return raw, ESCAPE.sub(b"", text).decode("utf-8", errors="replace")


def child(case, binary):
    case, binary = Path(case), Path(binary)
    guard(case, case / "listing")
    environment = os.environ.copy()
    for name, directory in [("XDG_STATE_HOME", "state"), ("XDG_CONFIG_HOME", "config"),
                            ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")]:
        environment[name] = str(guard(case, case / directory))
    # A concrete PTY remains observable from SSH; reopening /dev/tty would select the observer's controlling terminal.
    with open(os.ttyname(sys.stdout.fileno()), "r+b", buffering=0) as terminal:
        before = command(["stty", "-g"], stdin=terminal).decode().strip()
        process = subprocess.Popen([str(binary), "--tui", str(case / "listing")],
                                   stdin=terminal, stdout=terminal, stderr=terminal, env=environment)
        (case / "product.pid").write_text(str(process.pid))
        status = process.wait()
        after = command(["stty", "-g"], stdin=terminal).decode().strip()
        (case / "exit.json").write_text(json.dumps({"status": status, "before": before, "after": after}))
    return status


class Native:
    def __init__(self, root, binary, preset):
        self.root, self.binary = root, binary
        self.case = guard(root, root / preset)
        self.case.mkdir()
        (self.case / ".flea-test-sandbox").write_text("Flea TUI native fixture\n")
        self.title = "flea-tui-" + root.name + "-" + preset
        self.address = None
        self.product_pid = None
        self.checks = 0
        self.environment = os.environ.copy()
        self.environment["FLEA_TUI_TEST_CASE"] = str(self.case)
        self.log = open(self.case / "commands.log", "xb", buffering=0)
        for directory in ["listing/amber", "listing/bronze", "state/flea", "config", "data", "cache", "evidence"]:
            guard(self.case, self.case / directory).mkdir(parents=True, exist_ok=True)
        for name in ["charlie.txt", "delta-needleproof.txt", "echo.txt", ".hidden-proof"]:
            guard(self.case, self.case / "listing" / name).write_text(name + "\n")
        (self.case / "listing/amber/nested-proof.txt").write_text("native navigation proof\n")
        (self.case / "state/flea/ui.json").write_text(json.dumps({"keys": preset, "hidden": False,
            "sort": {"key": "name", "reverse": False}, "preview": {"loadOn": "manual", "column": True}}))

    def drive(self, *args):
        invocation = ["omarchy-drive", *map(str, args)]
        self.log.write((shlex.join(invocation) + "\n").encode())
        result = subprocess.run(invocation, capture_output=True, env=self.environment)
        self.log.write(result.stdout + result.stderr + f"exit={result.returncode}\n".encode())
        if result.returncode:
            raise RuntimeError(f"native driver refused or failed ({result.returncode}): {result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def owned_process(self, pid):
        try:
            process = Path("/proc") / str(pid)
            values = (process / "environ").read_bytes().split(b"\0")
            return process.stat().st_uid == os.getuid() and ("FLEA_TUI_TEST_CASE=" + str(self.case)).encode() in values
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            return False

    def window(self):
        # hyprctl clients adds PID identity omitted by omarchy-drive's normalized window payload.
        clients = json.loads(command(["hyprctl", "clients", "-j"]))
        matches = [item for item in clients if item.get("address") == self.address] if self.address else [
            item for item in clients if item.get("title") == self.title or item.get("initialTitle") == self.title]
        if len(matches) != 1 or not self.owned_process(matches[0]["pid"]):
            raise RuntimeError("native terminal window is missing, ambiguous or not owned by this run")
        return matches[0]

    def identity(self):
        window = self.window()
        if self.product_pid is None:
            self.product_pid = int((self.case / "product.pid").read_text())
        process = Path("/proc") / str(self.product_pid)
        if not self.owned_process(self.product_pid) or (process / "exe").resolve() != self.binary:
            raise RuntimeError("TUI PID does not execute the identified candidate")
        if (process / "cmdline").read_bytes().split(b"\0")[:3] != [os.fsencode(self.binary), b"--tui", os.fsencode(self.case / "listing")]:
            raise RuntimeError("TUI command line does not match this fixture")
        return window

    def wait(self, label, predicate):
        deadline = time.monotonic() + WAIT_SECONDS
        while time.monotonic() < deadline:
            if predicate():
                self.checks += 1
                print(f"TUI_PASS {label}", flush=True)
                return
            time.sleep(POLL_SECONDS)
        raise RuntimeError(f"native TUI did not reach {label} within {WAIT_SECONDS}s")

    def terminal_size(self):
        self.identity()
        process = Path("/proc") / str(self.product_pid)
        descriptors = {str(number): os.readlink(process / "fd" / str(number)) for number in range(3)}
        # /proc/PID/stat: 2970648 (flea) R 2970620 2970620 2970620 34817 ...; tty_nr is field seven.
        tty_number = int((process / "stat").read_text().rsplit(") ", 1)[1].split()[4])
        diagnostics = {"product_pid": self.product_pid, "descriptors": descriptors, "controlling_tty": tty_number}
        if diagnostics != getattr(self, "terminal_diagnostics", None):
            self.log.write(("TUI_PTY " + json.dumps(diagnostics) + "\n").encode())
            self.terminal_diagnostics = diagnostics
        descriptor = os.open(f"/proc/{self.product_pid}/fd/1", os.O_RDONLY | os.O_NOCTTY)
        try:
            return struct.unpack("HHHH", fcntl.ioctl(descriptor, termios.TIOCGWINSZ, bytes(8)))
        finally:
            os.close(descriptor)

    def snapshot(self, label, predicate):
        def reached():
            path = self.case / "output.bin"
            self.size = self.terminal_size()
            self.raw, self.text = frame(path.read_bytes() if path.exists() else b"", *self.size[:2])
            return bool(self.raw) and predicate(self.text)
        self.wait(label, reached)
        self.identity()
        evidence = self.case / "evidence"
        (evidence / (label + ".ansi")).write_bytes(self.raw)
        (evidence / (label + ".txt")).write_text(self.text)
        (evidence / (label + ".json")).write_text(json.dumps({"window": self.window(), "pty_rows_columns_pixels": self.size}))
        shot = guard(self.case, evidence / (label + ".png"))
        if shot.exists():
            raise RuntimeError("refused stale TUI screenshot")
        self.drive("shot", shot, self.address)
        if not shot.is_file() or shot.stat().st_size == 0:
            raise RuntimeError("native screenshot command returned no new image")
        print(f"TUI_SHOT {shot} sha256={hashlib.sha256(shot.read_bytes()).hexdigest()} inspection=pending", flush=True)

    def key(self, *args):
        self.identity()
        self.drive("key", "--window", self.address, *args)

    def start(self):
        child_command = shlex.join(["bash", str(SCRIPT), "--child", str(self.case), str(self.binary)])
        invocation = ["xdg-terminal-exec", "--title=" + self.title, "--dir=" + str(self.case / "listing"), "--",
            "script", "--quiet", "--flush", "--return", "--log-in", str(self.case / "input.bin"),
            "--log-out", str(self.case / "output.bin"), "--log-timing", str(self.case / "timing.log"), "--command", child_command]
        self.log.write((shlex.join(invocation) + "\n").encode())
        self.launcher = subprocess.Popen(invocation, env=self.environment, stdout=self.log, stderr=self.log, start_new_session=True)
        self.drive("wait", "window", self.title, "--timeout", str(WAIT_SECONDS))
        window = self.window()
        self.address = window["address"]
        # The user authorized native TUI input; enable only this verified terminal's class and target its unique address.
        self.environment["OMARCHY_DRIVE_TIER_FULL"] = window["class"]
        self.wait("product-pid", lambda: (self.case / "product.pid").is_file())
        window = self.identity()
        (self.case / "identity.json").write_text(json.dumps({"window": window, "product_pid": self.product_pid,
            "command": invocation, "terminal_exe": os.readlink(f'/proc/{window["pid"]}/exe')}))

    def smoke(self):
        self.start()
        self.snapshot("listing", lambda text: "5 items" in text and "charlie.txt" in text)
        self.key("-k", "Down")
        self.key("-k", "Return")
        self.snapshot("empty-navigation", lambda text: "1 bronze" in text and "0 items" in text)
        self.key("-k", "BackSpace")
        self.snapshot("parent-navigation", lambda text: "1 listing" in text and "5 items" in text)
        self.key("-k", "Home")
        self.key("-k", "Return")
        self.snapshot("nested-navigation", lambda text: "1 amber" in text and "nested-proof.txt" in text and "1 items" in text)
        self.key("-k", "BackSpace")
        self.snapshot("listing-restored", lambda text: "1 listing" in text and "5 items" in text)
        self.key("-k", "Home")
        self.key("v")
        self.snapshot("selection-one", lambda text: " V 1 " in text)
        self.key("-k", "Down")
        self.key("v")
        self.snapshot("selection-two", lambda text: " V 2 " in text and "2 items selected" in text)
        self.key("-k", "Escape")
        self.snapshot("selection-cleared", lambda text: " V " not in text and "5 items" in text)
        self.key("-M", "ctrl", "-k", "f", "-m", "ctrl")
        self.snapshot("search-editor", lambda text: "search:" in text and "Tab changes scope" in text)
        self.key("needleproof")
        self.key("-k", "Return")
        self.snapshot("search-result", lambda text: "Search: 1 matches" in text and "delta-needleproof.txt" in text)
        self.key("-k", "Escape")
        self.snapshot("search-dismissed", lambda text: "Search:" not in text and "5 items" in text)
        before = self.window()["size"]
        before_cells = self.terminal_size()[:2]
        self.drive("window", "fullscreen", self.address)
        self.wait("native-resize", lambda: self.window()["size"] != before and self.terminal_size()[:2] != before_cells)
        self.snapshot("resized", lambda text: "5 items" in text and "1 listing" in text)
        self.key("q")
        self.wait("clean-quit", lambda: (self.case / "exit.json").is_file())
        receipt = json.loads((self.case / "exit.json").read_text())
        if receipt["status"] != 0 or receipt["before"] != receipt["after"]:
            raise RuntimeError(f"TUI exit or terminal restoration failed: {receipt}")
        self.wait("terminal-closed", lambda: not self.owned_process(self.product_pid) and self.launcher.poll() is not None)

    def cleanup(self):
        owned = lambda: [int(path.name) for path in Path("/proc").iterdir() if path.name.isdigit() and self.owned_process(int(path.name))]
        remaining = owned()
        for pid in remaining:
            if self.owned_process(pid):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 30  # The backend's drain limit is 25 seconds.
        while remaining and time.monotonic() < deadline:
            time.sleep(POLL_SECONDS)
            remaining = owned()
        for pid in remaining:
            if self.owned_process(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if hasattr(self, "launcher"):
            self.launcher.wait(timeout=5)
        self.log.close()
        if remaining:
            raise RuntimeError(f"owned TUI processes failed to drain: {remaining}")


def main():
    if ARGS == ["--self-check"]:
        assert frame(b"\x1b[Hbefore\x1b[2;1H1234567890\x1b[Hpartial", 2, 10) == (b"", "")
        assert frame(b"\x1b[Hheader\x1b[2;1Hsearch:ab", 2, 10) == (b"", "")
        assert frame(b"\x1b[Hheader\x1b[2;1H\x1b[7msearch:abc ", 2, 10)[1] == "header\nsearch:abc "
        print("TUI_OBSERVER_SELF_CHECK 3 passed; native coverage not exercised")
        return
    if len(ARGS) == 3 and ARGS[0] == "--child":
        raise SystemExit(child(ARGS[1], ARGS[2]))
    if ARGS not in ([], ["default"]):
        raise RuntimeError("usage: tests/ui-tui.sh [default|--self-check]")
    os.environ["PATH"] = str(Path.home() / ".local/bin") + os.pathsep + os.environ["PATH"]
    for helper in ["omarchy-drive", "xdg-terminal-exec", "script", "stty", "hyprctl"]:
        if not shutil.which(helper):
            raise RuntimeError(f"native TUI prerequisite missing: {helper}")
    repo = SCRIPT.parent.parent
    binary = Path(os.environ.get("FLEA_BIN", repo / "target/release/flea")).resolve(strict=True)
    head = command(["git", "-C", repo, "rev-parse", "HEAD"]).decode().strip()
    if os.environ.get("FLEA_EXPECTED_SHA") != head:
        raise RuntimeError("FLEA_EXPECTED_SHA must identify the current candidate before native testing")
    inputs = list((repo / "src").rglob("*.rs")) + [repo / name for name in ["Cargo.toml", "Cargo.lock", "keys.toml"]]
    if (repo / "build.rs").is_file():
        inputs.append(repo / "build.rs")
    if max(path.stat().st_mtime_ns for path in inputs) > binary.stat().st_mtime_ns:
        raise RuntimeError("candidate binary predates a Rust source, keymap or manifest")
    session = command(["omarchy-drive", "env"]).decode().splitlines()
    required = {"XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "YDOTOOL_SOCKET", "OMARCHY_PATH", "QT_LINUX_ACCESSIBILITY_ALWAYS_ON"}
    values = {}
    for row in session:
        match = re.fullmatch(r"export ([A-Z_]+)=([A-Za-z0-9_./-]+)", row)
        if not match or match[1] not in required or match[1] in values:
            raise RuntimeError("omarchy-drive returned an unexpected session row")
        values[match[1]] = match[2]
    if values.keys() != required or values["XDG_RUNTIME_DIR"] != f"/run/user/{os.getuid()}" or values["OMARCHY_PATH"] != "/usr/share/omarchy" \
            or values["YDOTOOL_SOCKET"] != values["XDG_RUNTIME_DIR"] + "/.ydotool_socket" \
            or values["QT_LINUX_ACCESSIBILITY_ALWAYS_ON"] != "1" or not re.fullmatch(r"wayland-[0-9]+", values["WAYLAND_DISPLAY"]):
        raise RuntimeError("native TUI session identity is incomplete or unexpected")
    os.environ.update(values)
    with open(Path(values["XDG_RUNTIME_DIR"]) / "flea-display.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        root = Path(tempfile.mkdtemp(prefix="flea-tui-native.", dir="/tmp"))
        (root / ".flea-test-sandbox").write_text("Flea TUI native evidence\n")
        print(f"TUI_NATIVE_ROOT={root}", flush=True)
        (root / "candidate.json").write_text(json.dumps({"head": head, "binary": str(binary),
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "session": values,
            "source_status": command(["git", "-C", repo, "status", "--porcelain"]).decode(),
            "harness_sha256": hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
            "keymap_sha256": hashlib.sha256((repo / "keys.toml").read_bytes()).hexdigest()}))
        native = Native(root, binary, "default")
        try:
            native.smoke()
        finally:
            native.cleanup()
        print(f"TUI_NATIVE preset=default checks={native.checks} failed=0 visual_inspection=pending", flush=True)


try:
    main()
except Exception as error:
    print(f"TUI_FAIL {error}", file=sys.stderr, flush=True)
    raise SystemExit(1)
PY
