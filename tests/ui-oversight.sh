#!/usr/bin/env bash
# Sourced by ui.sh; release and candidate use one fixture through their real launchers.
# shellcheck disable=SC2034,SC2154 # ui.sh supplies globals; sourced helpers consume case locals.

oversight_identity() {
    python3 - "$repo" "$flea_ui" "$flea_bin" "$oversight_source" "$oversight_binary_sha" \
        "$oversight_box" "$oversight_home" "${1:-0}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

repo, ui, binary, source, digest, sandbox, home, pid = sys.argv[1:]
def require(condition, message):
    if not condition:
        raise SystemExit("oversight identity: " + message)

def git(*args):
    return subprocess.check_output(["git", "-C", repo, *args])

require(Path(ui).resolve() == Path(ui), "UI path is not canonical")
require(Path(binary).resolve() == Path(binary), "binary path is not canonical")
require(git("rev-parse", source + "^{commit}").decode().strip() == source, "source is not an exact commit")
require(hashlib.sha256(Path(binary).read_bytes()).hexdigest() == digest, "binary differs from its build receipt")
if Path(ui) == Path(repo, "ui"):
    require(git("rev-parse", "HEAD").decode().strip() == source, "candidate HEAD changed")
    git("diff", "--exit-code", source, "--", "src", "ui", "Cargo.toml", "Cargo.lock", "build.rs", "keys.toml")
    require(not git("ls-files", "--others", "--exclude-standard", "--", "src", "ui"), "untracked candidate product source")
expected = {}
# git ls-tree -rz: 100644 blob <object-id>\tui/StatusBar.qml\0
for record in git("ls-tree", "-rz", source, "ui").split(b"\0"):
    if not record:
        continue
    metadata, name = record.split(b"\t", 1)
    mode, kind, object_id = metadata.decode().split()
    relative = Path(os.fsdecode(name)).relative_to("ui")
    path = Path(ui, relative)
    require(kind == "blob", "unexpected UI object: " + str(relative))
    if mode == "120000":
        require(path.is_symlink(), "missing OEM import link: " + str(relative))
        data = os.fsencode(os.readlink(path))
    else:
        require(mode in ("100644", "100755") and path.is_file() and not path.is_symlink(), "missing UI file: " + str(relative))
        data = path.read_bytes()
    actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    require(actual == object_id, "UI differs from source: " + str(relative))
    expected[str(relative)] = hashlib.sha256(data).hexdigest()
actual_files = {str(path.relative_to(ui)) for path in Path(ui).rglob("*") if path.is_file() or path.is_symlink()}
require(actual_files == set(expected), "UI file inventory differs from source")
theme_files = [".local/state/omarchy/current/theme/colors.toml", ".local/state/omarchy/current/theme/shell.toml",
               ".local/state/omarchy/current/theme.name", ".config/omarchy/shell.toml"]
theme = {name: hashlib.sha256(Path(home, name).read_bytes()).hexdigest()
         for name in theme_files if Path(home, name).is_file()}
receipt = dict(source=source, binary=binary, binarySha256=digest, ui=ui, uiFiles=expected, theme=theme,
               driverSha256=hashlib.sha256(Path(repo, "tests/ui-oversight.sh").read_bytes()).hexdigest(),
               dirty=git("status", "--porcelain").decode())
if int(pid):
    process = Path("/proc", pid)
    require(process.stat().st_uid == os.getuid(), "window process has another owner")
    environment = dict(value.split(b"=", 1) for value in (process / "environ").read_bytes().split(b"\0") if b"=" in value)
    session = {name: os.environ[name] for name in ("WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE", "QT_QPA_PLATFORMTHEME")}
    for name, value in dict(session, FLEA_BIN=binary, FLEA_UI=ui, FLEA_OVERSIGHT_ROOT=sandbox, HOME=home, QSG_RHI_BACKEND="vulkan").items():
        require(environment.get(name.encode()) == value.encode(), "window environment differs: " + name)
    for name in ("XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
        require(environment.get(name.encode()) == os.environ[name].encode(), "sandbox environment differs: " + name)
        require(Path(os.environ[name]).resolve().is_relative_to(Path(sandbox)), "state escaped sandbox: " + name)
    require((process / "exe").resolve() == Path(shutil.which("qs")).resolve(), "window is not the native Quickshell executable")
    instances = json.loads(subprocess.check_output(["qs", "list", "--all", "--json"]))
    instances = [item for item in instances if item["pid"] == int(pid) and item["config_path"] == str(Path(ui, "shell.qml"))]
    require(len(instances) == 1, "window has no exact native UI instance")
    clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"]))
    clients = [item for item in clients if item.get("class") == "com.thisisgm.flea"]
    require(len(clients) == 1 and clients[0]["pid"] == int(pid), "another Flea window owns the display")
    require(clients[0]["size"] == [880, 620] and clients[0]["floating"], "viewport is not the matched 880x620 client")
    monitors = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"]))
    monitors = [item for item in monitors if item["id"] == clients[0]["monitor"]]
    require(len(monitors) == 1, "client has no attributable monitor")
    monitor = {name: monitors[0][name] for name in ("name", "x", "y", "width", "height", "scale", "transform")}
    backends = []
    processes = subprocess.run(["pgrep", "-x", "flea"], capture_output=True, text=True)
    require(processes.returncode in (0, 1), "backend process inventory failed")
    for backend_pid in processes.stdout.split():
        backend = Path("/proc", backend_pid)
        try:
            arguments = (backend / "cmdline").read_bytes().split(b"\0")
            backend_env = (backend / "environ").read_bytes().split(b"\0")
        except FileNotFoundError:
            continue
        if b"--backend" in arguments and ("FLEA_OVERSIGHT_ROOT=" + sandbox).encode() in backend_env:
            require((backend / "exe").resolve() == Path(binary), "live backend uses another binary")
            backends.append(int(backend_pid))
    require(len(backends) == 1, "expected exactly one owned backend")
    receipt.update(pid=int(pid), instance=instances[0], window=clients[0], backends=backends, monitor=monitor, session=session)
print(json.dumps(receipt, sort_keys=True))
PY
}

oversight_stop() {
    local pid
    for pid in $(flea_pids); do
        [[ -r "/proc/$pid/environ" ]] || fail "oversight: window vanished before ownership check"
        tr '\0' '\n' < "/proc/$pid/environ" | grep -Fx "FLEA_OVERSIGHT_ROOT=$oversight_box" >/dev/null \
            || fail "oversight: refusing to stop a foreign window"
    done
    kill_flea
}

oversight_visible_row() {
    local index="$1" x y width height ax ay aw ah end=$((SECONDS + 20))
    while (( SECONDS < end )); do
        read -r x y width height <<< "$(ipc rowRect "$index")"
        read -r ax ay aw ah <<< "$(ipc listAreaRect)"
        if [[ "$x $y $width $height $ax $ay $aw $ah" =~ ^[0-9]+(\ [0-9]+){7}$ ]] \
            && (( width > 0 && height > 0 && x >= ax && y >= ay && x + width <= ax + aw && y + height <= ay + ah \
                  && x + width <= 880 && y + height <= 620 )); then
            [[ "$(ipc rowAt "$index")" == field-bench-notes.md\|file\|* ]] \
                || fail "oversight: visible row has the wrong file identity"
            return
        fi
        sleep 0.05
    done
    fail "oversight: notes row never became fully visible: $x $y $width $height in $ax $ay $aw $ah"
}

oversight_park_row() {
    local index="$1" x y wx wy width height end=$((SECONDS + 20))
    read -r x y < <(hyprctl monitors -j | jq -er '.[0] | "\(.x) \(.y)"')
    read -r wx wy width height < <(window_box) || fail "native window coordinates unavailable"
    [[ "$x $y" =~ ^-?[0-9]+\ -?[0-9]+$ ]] || fail "oversight: monitor origin unavailable"
    (( x < wx || y < wy || x >= wx + width || y >= wy + height )) || fail "oversight: monitor origin is inside the client"
    omarchy-drive move "$x" "$y" >/dev/null || fail "oversight: pointer could not leave the window"
    # Relative uinput supplies the native pointer frame that a compositor cursor warp omits.
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool mousemove -x 1 -y 0 >/dev/null 2>&1 \
        || fail "oversight: native pointer motion did not complete"
    while (( SECONDS < end )); do
        [[ "$(ipc rowHovered "$index")" == false ]] && return
        sleep 0.05
    done
    fail "oversight: notes row stayed hovered after the pointer left"
}

oversight_capture() {
    local label="$1" index="${2:--1}" prefix="$evidence_dir/oversight-$oversight_arm-$1" extension identity tokens palette entries="" hints=""
    [[ "$label" =~ ^[a-z0-9-]+$ && -f "$run_root/.flea-test-sandbox" \
        && "$prefix" == /* && "$(realpath -m -- "$prefix")" == "$run_root/"* ]] \
        || fail "oversight: invalid evidence target"
    for extension in png context.png identity.json state.json; do
        [[ ! -e "$prefix.$extension" && ! -L "$prefix.$extension" ]] || fail "oversight: evidence already exists: $prefix.$extension"
    done
    identity=$(oversight_identity "$(flea_pid)") || fail "oversight: native identity changed before $label"
    [[ "$(jq -c .theme <<< "$identity")" == "$oversight_theme" ]] || fail "oversight: theme inputs changed between arms"
    [[ -n "$oversight_monitor" ]] || oversight_monitor=$(jq -c .monitor <<< "$identity")
    [[ "$(jq -c .monitor <<< "$identity")" == "$oversight_monitor" ]] || fail "oversight: monitor configuration differs between arms"
    assert_theme
    tokens=$(ipc tokens) || fail "oversight: live font tokens unavailable"
    [[ "$(grep '^family=' <<< "$tokens")" == "$oversight_font" ]] || fail "oversight: font family differs between arms"
    grep -Fx 'baseSize=14' <<< "$tokens" >/dev/null || fail "oversight: live base size is not 14"
    [[ "$(ipc bodyPx)" == 14 ]] || fail "oversight: running text is not 14px"
    grep -E 'QRhi.*backend Vulkan' "$flea_log" >/dev/null || fail "oversight: Qt did not confirm its Vulkan renderer"
    (( index < 0 )) || oversight_visible_row "$index"
    palette=$(ipc palette) || fail "oversight: live palette unavailable"
    local menu_open observed_path observed_view observed_state message transient total selected
    menu_open=$(ipc contextMenuVisible) || fail "oversight: menu visibility unavailable"
    [[ "$menu_open" == true || "$menu_open" == false ]] || fail "oversight: invalid menu visibility"
    if [[ "$menu_open" == true ]]; then
        entries=$(ipc contextMenuEntries) || fail "oversight: menu entries unavailable"
        hints=$(ipc contextMenuHints) || fail "oversight: menu hints unavailable"
    fi
    observed_path=$(ipc path) || fail "oversight: specimen path unavailable"
    observed_view=$(ipc viewMode) || fail "oversight: specimen view unavailable"
    observed_state=$(ipc state) || fail "oversight: specimen state unavailable"
    message=$(ipc stateMessage) || fail "oversight: specimen explanation unavailable"
    transient=$(ipc lastMessage) || fail "oversight: specimen transient unavailable"
    total=$(ipc total) || fail "oversight: specimen total unavailable"
    selected=$(ipc selectedIndices) || fail "oversight: specimen selection unavailable"
    printf '%s\n' "$identity" > "$prefix.identity.json" || fail "oversight: could not save native identity"
    jq -n --arg tokens "$tokens" --arg palette "$palette" --arg path "$observed_path" \
        --arg view "$observed_view" --arg state "$observed_state" --arg message "$message" \
        --arg transient "$transient" --arg total "$total" --arg selected "$selected" \
        --arg menu "$entries" --arg hints "$hints" \
        '{tokens:$tokens,palette:$palette,path:$path,view:$view,state:$state,message:$message,transient:$transient,
          total:$total,selected:$selected,menu:$menu,hints:$hints,visualInspection:"pending"}' > "$prefix.state.json" \
        || fail "oversight: could not record live specimen state"
    local address
    address=$(jq -er '.window.address' <<< "$identity") || fail "oversight: owned address unavailable"
    omarchy-drive shot "$prefix.context.png" >/dev/null || fail "oversight: full-context capture failed"
    omarchy-drive shot "$prefix.png" "$address" >/dev/null || fail "oversight: native window capture failed"
    if ! python3 - "$prefix.png" "$prefix.context.png" <<'PY'
from pathlib import Path
import struct
import sys
for index, name in enumerate(sys.argv[1:]):
    header = Path(name).read_bytes()[:24]
    assert header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR", "not a fresh PNG: " + name
    size = struct.unpack(">II", header[16:24])
    assert size == (880, 620) if index == 0 else size[0] >= 880 and size[1] >= 620, (name, size)
PY
    then fail "oversight: captured dimensions differ from the matched viewport"; fi
    printf 'OVERSIGHT_CAPTURE arm=%s state=%s source=%s binary=%s visual_inspection=pending\n' \
        "$oversight_arm" "$label" "$oversight_source" "$oversight_binary_sha"
    sha256sum "$prefix.png" "$prefix.context.png" "$prefix.identity.json" "$prefix.state.json" \
        || fail "oversight: evidence hashing failed"
}

case_oversight() {
    local candidate_ui="$flea_ui" candidate_bin="$flea_bin"
    local flea_ui="$candidate_ui" flea_bin="$candidate_bin"
    local oversight_box="$fixture_root/oversight" oversight_home="$fixture_root/oversight/home"
    local oversight_arm oversight_source oversight_binary_sha oversight_theme="" oversight_font="" oversight_monitor="" identity view chord row entries hints
    local permissions_checks=0 menus_checks=0 path end
    local -x XDG_CONFIG_HOME="$oversight_home/.config" XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    local -x FLEA_OVERSIGHT_ROOT="$oversight_box" QSG_RHI_BACKEND=vulkan QSG_INFO=1
    [[ "${FLEA_SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ && "${FLEA_BINARY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
        || fail "oversight: FLEA_SOURCE_SHA and FLEA_BINARY_SHA256 must identify the candidate build"
    [[ "$(git -C "$repo" rev-parse HEAD)" == "$FLEA_SOURCE_SHA" ]] || fail "oversight: candidate HEAD differs from the build source"
    git -C "$repo" ls-files --error-unmatch tests/ui-oversight.sh >/dev/null \
        || fail "oversight: the native instrument must be included in the candidate"
    git -C "$repo" diff --quiet "$FLEA_SOURCE_SHA" -- tests/ui.sh tests/ui-oversight.sh tests/ui-permissions.sh tests/ui-menus.sh \
        || fail "oversight: native instrument differs from the identified candidate"
    [[ "$(git -C "$repo" rev-parse 'v0.1.6^{commit}')" == 784da4692e1594dfa99cc7de841c8a3cb3b5a7e2 ]] \
        || fail "oversight: immutable release tag changed"
    sandbox_scratch "$oversight_box"
    fixture_home_make "$oversight_home"
    local listing="$oversight_home/Documents/claude"
    sandbox_require "$listing"
    mkdir -p "$listing" "$evidence_dir" || fail "oversight: could not create owned fixture/evidence directories"
    for path in flea omarchy themes; do mkdir "$listing/$path" || fail "oversight: fixture folder creation failed"; done
    for path in field-bench-notes.md README.md changelog.md notes.txt example.txt config.toml license.txt; do
        printf 'Flea native comparison fixture: %s\n' "$path" > "$listing/$path" || fail "oversight: fixture file creation failed"
    done
    trap 'oversight_stop' EXIT
    for oversight_arm in release candidate; do
        if [[ "$oversight_arm" == release ]]; then
            flea_ui=/usr/share/flea/ui; flea_bin=/usr/bin/flea
            oversight_source=784da4692e1594dfa99cc7de841c8a3cb3b5a7e2
            oversight_binary_sha=301fd049c62c8323cf4455d7d432dceae2e1c8dd3207990ecf2cc2765b39c22e
        else
            flea_ui="$candidate_ui"; flea_bin="$candidate_bin"
            oversight_source="$FLEA_SOURCE_SHA"; oversight_binary_sha="$FLEA_BINARY_SHA256"
        fi
        [[ -z "$(flea_pids)" ]] || fail "oversight: a foreign $oversight_arm UI instance is already running"
        identity=$(oversight_identity) || fail "oversight: $oversight_arm does not match its immutable source/build"
        [[ -n "$oversight_theme" ]] || oversight_theme=$(jq -c .theme <<< "$identity")
        for path in data cache; do
            sandbox_require "$oversight_box/$oversight_arm-$path"
            mkdir "$oversight_box/$oversight_arm-$path" || fail "oversight: private $path directory creation failed"
        done
        export XDG_DATA_HOME="$oversight_box/$oversight_arm-data" XDG_CACHE_HOME="$oversight_box/$oversight_arm-cache"
        seed_ui_state "$oversight_box/$oversight_arm-state" '{"keys":"default","view":"list","display":{"textSize":{"mode":14}}}'
        HOME="$oversight_home" launch "$listing"
        permissions_viewport 880 620
        wait_listing 10
        permissions_expect listInFlight false
        [[ -n "$oversight_font" ]] || oversight_font=$(ipc tokens | grep '^family=')
        [[ -n "$oversight_font" ]] || fail "oversight: no resolved font family"
        end=$((SECONDS + 20))
        until grep -E 'QRhi.*backend Vulkan' "$flea_log" >/dev/null; do
            (( SECONDS < end )) || fail "oversight: Qt did not report Vulkan readiness"
            sleep 0.05
        done
        row=$(row_index_of field-bench-notes.md)
        for view in list columns grid; do
            case "$view" in list) chord=1 ;; columns) chord=2 ;; grid) chord=3 ;; esac
            key -M ctrl -k "$chord" -m ctrl >/dev/null
            permissions_expect viewMode "$view"
            oversight_visible_row "$row"
            click_row "$row" left
            permissions_expect cursor "$row"
            permissions_expect selectionCount 0
            if [[ "$view" == columns ]]; then permissions_expect previewColumnState text; fi
            oversight_park_row "$row"
            oversight_capture "$view-idle" "$row"
            key v >/dev/null
            permissions_expect selectedIndices "$row"
            oversight_capture "$view-selected" "$row"
            key v >/dev/null
            permissions_expect selectionCount 0
        done
        key -M ctrl -k 1 -m ctrl >/dev/null
        permissions_expect viewMode list
        oversight_visible_row "$row"
        click_row "$row" right
        permissions_expect contextMenuVisible true
        if [[ "$oversight_arm" == candidate ]]; then
            menus_expect menuState '.opened and .hasRow and .snapshotReady' "default menu owns its loaded file snapshot"
        fi
        entries=$(ipc contextMenuEntries) || fail "oversight: default menu entries unavailable"
        hints=$(ipc contextMenuHints) || fail "oversight: default menu hints unavailable"
        grep -E '(^|\|)(Copy path|Open [Ww]ith|Open in terminal|Move to(\.\.\.)?|Copy to(\.\.\.)?|Properties|Permissions|Delete permanently)(\||$)' <<< "$entries" >/dev/null \
            && fail "oversight: default menu exposes a hidden action: $entries"
        [[ "$oversight_arm" != candidate || -n "${hints%%|*}" ]] || fail "oversight: default Open menu row has no key hint"
        oversight_capture defaults-menu "$row"
        key -k Escape >/dev/null
        permissions_expect contextMenuVisible false
        path="$listing/missing-directory"
        sandbox_require "$path"
        [[ ! -e "$path" && ! -L "$path" ]] || fail "oversight: missing-path fixture exists"
        key -M ctrl -k l -m ctrl "$path" -k Return >/dev/null
        permissions_expect path "$path"
        permissions_expect state error
        permissions_expect listInFlight false
        [[ -n "$(ipc stateMessage)" ]] || fail "oversight: missing path has no visible explanation"
        oversight_capture missing-error
        key -k Escape >/dev/null
        key -M ctrl -k l -m ctrl "$listing" -k Return >/dev/null
        permissions_expect path "$listing"
        wait_listing 10
        permissions_expect state ready
        oversight_visible_row "$row"
        oversight_capture recovered "$row"
        oversight_stop
    done
    trap - EXIT
    printf 'OVERSIGHT_CAPTURE_GROUP source=%s matched=880x620 base=14 arms=2 specimens_per_arm=9 visual_inspection=pending\n' "$FLEA_SOURCE_SHA"
}
