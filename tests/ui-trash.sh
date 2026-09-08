#!/usr/bin/env bash
# Source after tests/ui.sh helpers; case_trash owns a private D-Bus session and marked Trash fixture.
# All native actions use the candidate and read-only IPC; helper assertions do not approve pixels.

case_railorder() {
    local dir="$fixture_root/railorder" state="$fixture_root/railorder-state" config="$fixture_root/railorder-config"
    local entries trash_index home_index cx trash_y home_y end
    sandbox_scratch "$dir"
    sandbox_scratch "$state"
    sandbox_scratch "$config"
    export XDG_CONFIG_HOME="$config"
    seed_ui_state "$state" '{"view":"list","places":{"showTrash":true,"showNetwork":true,"showDevices":true}}'
    launch "$dir"
    wait_listing 0
    end=$((SECONDS + 20))
    while (( SECONDS < end )); do
        entries=$(ipc railEntries) || fail "railorder: rail entries unavailable"
        jq -e 'any(.[]; .group == "home") and any(.[]; .group == "trash")' <<< "$entries" >/dev/null && break
        sleep 0.05
    done
    jq -e '
        (map(.group) | index("trash")) as $trash |
        $trash != null and $trash > 0 and .[0].label == "Home" and
        ([.[] | select(.group == "trash")] | length) == 1 and
        .[$trash].path == "trash:///" and .[$trash - 1].group == "home" and
        all(.[:$trash][]; .group == "favourite" or .group == "home") and
        all(.[$trash + 1:][]; .group != "home" and .group != "favourite" and .group != "trash")
    ' <<< "$entries" >/dev/null || fail "railorder: Trash is not last in Places before Network/Devices: $entries"
    trash_index=$(jq -r 'map(.group) | index("trash")' <<< "$entries")
    home_index=$((trash_index - 1))
    read -r cx trash_y <<< "$(ipc railRowCentre "$trash_index")"
    read -r cx home_y <<< "$(ipc railRowCentre "$home_index")"
    [[ "$trash_y" =~ ^[0-9]+$ && "$home_y" =~ ^[0-9]+$ && "$trash_y" -gt "$home_y" ]] \
        || fail "railorder: live Trash row does not follow the Home/XDG rows"
    trash_shot trash-rail-order
    printf 'TRASH_RAIL_ORDER entries=%s home_y=%s trash_y=%s\n' "$entries" "$home_y" "$trash_y"
    kill_flea
}

trash_guard() {
    local path="$1" canonical
    [[ -n "$path" && "$path" == /* ]] || fail "trash: empty or relative mutation path"
    [[ -f "$trash_box/.flea-test-sandbox" ]] || fail "trash: missing owned fixture marker"
    canonical=$(realpath -m -- "$path") || fail "trash: could not resolve mutation path"
    [[ "$canonical" == "$trash_box/"* && "$canonical" != "$trash_box" ]] \
        || fail "trash: mutation path is outside this case's sandbox"
}

trash_bus_id() {
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetId \
        | python3 -c 'import ast,sys; print(ast.literal_eval(sys.stdin.read())[0])'
}

trash_owned_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    trash_private_pids "$pid" | grep -Fx "$pid" >/dev/null
}

trash_private_pids() {
    python3 - "$trash_bus_address" "$XDG_DATA_HOME" "${1:-}" <<'PY'
import os, pathlib, sys
address, data = sys.argv[1].encode(), sys.argv[2].encode()
processes = [pathlib.Path("/proc", sys.argv[3])] if sys.argv[3] else pathlib.Path("/proc").iterdir()
for process in processes:
    if not process.name.isdigit() or int(process.name) in (os.getpid(), os.getppid()):
        continue
    try:
        values = dict(entry.split(b"=", 1) for entry in (process / "environ").read_bytes().split(b"\0") if b"=" in entry)
        # D-Bus activation may append the bus GUID to the same owned Unix socket address.
        bus, separator, guid = values.get(b"DBUS_SESSION_BUS_ADDRESS", b"").partition(b",guid=")
        same_bus = bus == address and (not separator or len(guid) == 32 and all(byte in b"0123456789abcdef" for byte in guid))
        if process.stat().st_uid == os.getuid() and same_bus and values.get(b"XDG_DATA_HOME") == data:
            print(process.name)
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
PY
}

trash_cleanup() {
    local result="$1" pid end
    trap - EXIT HUP INT TERM
    (kill_flea) || result=1
    for pid in $(trash_private_pids); do
        trash_owned_pid "$pid" && kill -TERM "$pid" 2>/dev/null
    done
    end=$((SECONDS + 10))
    while (( SECONDS < end )); do
        [[ -z "$(trash_private_pids)" ]] && break
        sleep 0.05
    done
    for pid in $(trash_private_pids); do
        if trash_owned_pid "$pid"; then
            printf 'FAIL: trash: private process %s did not terminate\n' "$pid" >&2
            kill -KILL "$pid" 2>/dev/null
            result=1
        fi
    done
    [[ -z "$trash_bus_pid" ]] || wait "$trash_bus_pid" 2>/dev/null || true
    if [[ "$result" -ne 0 ]]; then
        trash_guard "$trash_box/payload"
        find "$trash_box" -type d -exec chmod u+rwx -- {} + || result=1
    fi
    printf 'TRASH_NATIVE checks=%s teardown_status=%s; screenshots require separate inspection.\n' "$trash_checks" "$result"
    exit "$result"
}

trash_start_bus() {
    local end pid providers
    trash_parent_bus_id=$(trash_bus_id) || fail "trash: parent session identity unavailable"
    trash_bus_address="unix:path=$trash_box/bus"
    export DBUS_SESSION_BUS_ADDRESS="$trash_bus_address"
    dbus-daemon --session --nofork --address="$trash_bus_address" > "$trash_box/dbus.log" 2>&1 &
    trash_bus_pid=$!
    trap 'trash_cleanup $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    end=$((SECONDS + 10))
    while (( SECONDS < end )); do
        if trash_private_bus_id=$(trash_bus_id 2>/dev/null); then break; fi
        kill -0 "$trash_bus_pid" 2>/dev/null || fail "trash: private dbus-daemon exited"
        sleep 0.05
    done
    [[ -n "$trash_private_bus_id" && "$trash_private_bus_id" != "$trash_parent_bus_id" ]] \
        || fail "trash: private session did not acquire a distinct identity"
    /usr/bin/gio list trash:/// > "$trash_box/initial-list.log" \
        || fail "trash: private GIO Trash mount failed"
    providers=0
    for pid in $(trash_private_pids); do
        if [[ "$(cat "/proc/$pid/comm")" == gvfsd-trash ]]; then
            trash_provider_pid="$pid"
            providers=$((providers + 1))
        fi
    done
    [[ "$providers" == 1 ]] || fail "trash: expected one private provider, found $providers"
    printf 'TRASH_SESSION parent=%s private=%s daemon=%s provider=%s root=%s\n' \
        "$trash_parent_bus_id" "$trash_private_bus_id" "$trash_bus_pid" "$trash_provider_pid" "$trash_box"
}

trash_private() {
    local actual pid="$trash_provider_pid" candidate
    [[ -n "$trash_private_bus_id" && -n "$trash_parent_bus_id" ]] \
        || fail "trash: private and parent D-Bus identities are required"
    actual=$(trash_bus_id) || fail "trash: cannot read the current D-Bus identity"
    [[ "$actual" == "$trash_private_bus_id" && "$actual" != "$trash_parent_bus_id" ]] \
        || fail "trash: this is not the owned private D-Bus session"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/environ" ]] \
        || fail "trash: no attributable private gvfsd-trash process"
    [[ "$(cat "/proc/$pid/comm")" == gvfsd-trash ]] || fail "trash: wrong provider process"
    trash_owned_pid "$pid" || fail "trash: provider belongs to another bus, data root, or user"
    candidate=$(flea_pid)
    trash_owned_pid "$candidate" || fail "trash: candidate belongs to another bus, data root, or user"
}

trash_backing() {
    local uri="$1" info target
    info=$(/usr/bin/gio info --nofollow-symlinks --attributes=standard::target-uri "$uri") \
        || fail "trash: provider did not resolve a backing path"
    # Sample GIO line: "  standard::target-uri: file:///owned/fixture/data/Trash/files/a.txt".
    target=$(sed -n 's/^  standard::target-uri: //p' <<< "$info")
    python3 - "$target" <<'PY'
import sys
from urllib.parse import unquote, urlsplit
uri = urlsplit(sys.argv[1])
if uri.scheme != "file" or uri.netloc or uri.query or uri.fragment:
    raise SystemExit("REFUSED unsupported Trash backing URI")
print(unquote(uri.path, errors="strict"))
PY
}

trash_guard_store() {
    local expected="$1" listing uri original backing count=0
    trash_private
    trash_guard "$XDG_DATA_HOME"
    listing=$(/usr/bin/gio trash --list) || fail "trash: provider listing failed"
    if [[ -n "$listing" ]]; then
        # Sample list row: "trash:///a.txt<TAB>/owned/fixture/payload/a.txt".
        while IFS=$'\t' read -r uri original; do
            [[ "$uri" == trash:///* && -n "$original" ]] || fail "trash: malformed provider row"
            trash_guard "$original"
            backing=$(trash_backing "$uri") || fail "trash: unavailable backing path"
            trash_guard "$backing"
            [[ "$backing" == "$XDG_DATA_HOME/Trash/files/"* ]] \
                || fail "trash: provider backing is outside the private Trash store"
            count=$((count + 1))
        done <<< "$listing"
    fi
    [[ "$count" -eq "$expected" ]] || fail "trash: expected $expected private entries, found $count"
    printf 'TRASH_GUARD count=%s backing=%s/Trash/files bus=%s\n' "$count" "$XDG_DATA_HOME" "$trash_private_bus_id"
}

trash_wait() {
    local condition="$1" label="${2:-$1}" end=$((SECONDS + 20)) state
    while (( SECONDS < end )); do
        state=$(ipc trashState) || fail "trash: read-only state unavailable"
        if jq -e "$condition" <<< "$state" >/dev/null; then
            trash_checks=$((trash_checks + 1))
            printf 'TRASH_PASS %s expected=%q observed=%s\n' "$label" "$condition" "$state"
            return
        fi
        sleep 0.05
    done
    fail "trash: native state did not reach $condition; last state: $state"
}

trash_rail() {
    local index
    index=$(ipc railEntries | jq -er 'map(.label) | index("Trash")') \
        || fail "trash: no native Trash rail row"
    click_rail_row "$index" "${1:-left}"
}

trash_click() {
    local reader="$1" argument="${2:-}" button="${3:-left}" cx cy wx wy
    if [[ -n "$argument" ]]; then read -r cx cy <<< "$(ipc "$reader" "$argument")"
    else read -r cx cy <<< "$(ipc "$reader")"; fi
    [[ "$cx" =~ ^[0-9]+$ && "$cy" =~ ^[0-9]+$ ]] || fail "trash: missing native control centre"
    read -r wx wy _width _height < <(window_box)
    omarchy-drive click "$((wx + cx))" "$((wy + cy))" "$button" >/dev/null \
        || fail "trash: native pointer activation failed"
}

trash_shot() {
    local name="$1" path="$evidence_dir/$1.png" canonical
    [[ -f "$run_root/.flea-test-sandbox" ]] || fail "trash: native evidence root is not marked"
    canonical=$(realpath -m -- "$path") || fail "trash: evidence path did not resolve"
    [[ "$canonical" == "$run_root/"* && "$canonical" != "$run_root" ]] || fail "trash: evidence escaped its sandbox"
    mkdir -p "$evidence_dir" || fail "trash: evidence directory creation failed"
    [[ ! -e "$path" ]] || fail "trash: refusing to reuse an old screenshot"
    omarchy-drive shot "$path" flea >/dev/null || fail "trash: screenshot failed"
    [[ -s "$path" ]] || fail "trash: screenshot is empty"
    printf 'TRASH_SHOT path=%s viewport=%q\n' "$path" "$(window_box)"
}

trash_empty_strip() {
    trash_rail right
    menu_seek "Empty Trash"
    key -k Return >/dev/null
    trash_wait '.confirmation.opened and (.confirmation.destructiveFocus == false)'
}

case_trash() {
    local trash_box payload token row uri backing root name trash_checks=0
    local trash_parent_bus_id="" trash_private_bus_id="" trash_bus_address="" trash_bus_pid="" trash_provider_pid=""
    [[ "$(realpath -e "$(command -v gio)")" == /usr/bin/gio ]] || fail "trash: product gio resolves to a stub"
    sandbox_require "$fixture_root"
    trash_box=$(mktemp -d "$fixture_root/trash.XXXXXXXX") || fail "trash: fixture creation failed"
    printf 'native private Trash\n' > "$trash_box/.flea-test-sandbox"
    [[ "$trash_box" == "$(realpath -e -- "$trash_box")" ]] || fail "trash: fixture root is not canonical"
    export XDG_DATA_HOME="$trash_box/data" XDG_CONFIG_HOME="$trash_box/config"
    export XDG_STATE_HOME="$trash_box/state" XDG_CACHE_HOME="$trash_box/cache"
    for root in "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"; do
        trash_guard "$root"
        mkdir -p "$root" || fail "trash: writable root creation failed"
    done
    "$flea_bin" --ui-state '{"view":"list","keys":"default","preview":{"column":false},"menu":{"hidden":[]}}' >/dev/null \
        || fail "trash: initial preferences could not be stored inside the fixture"
    payload="$trash_box/payload"
    trash_guard "$payload"
    [[ ! -e "$payload" ]] || fail "trash: refusing to reuse a prior payload"
    mkdir "$payload" || fail "trash: fixture creation failed"
    trash_start_bus
    launch "$payload"
    wait_listing 0
    trash_guard_store 0
    trash_wait '.count == 0'
    trash_rail
    trash_wait '.opened and .total == 0 and (.busy == false)'
    trash_shot trash-empty-current
    trash_rail right
    ipc contextMenuModel | jq -e '[.[] | select(.action == "restoreAll" or .action == "emptyTrash")] | (map(.action) | sort) == ["emptyTrash","restoreAll"] and all(.[]; .disabled == true)' >/dev/null \
        || fail "trash: empty actions must remain present and disabled"
    key -k Escape >/dev/null
    key -k Backspace >/dev/null

    printf 'alpha\n' > "$payload/alpha.txt"
    printf 'beta\n' > "$payload/beta.txt"
    wait_listing 2
    for name in alpha.txt beta.txt; do
        click_row "$(row_index_of "$name")" left
        trash_private
        trash_guard "$payload/$name"
        key -k Delete >/dev/null
        [[ "$name" == alpha.txt ]] && wait_listing 1 || wait_listing 0
    done
    trash_wait '.count == 2'
    trash_guard_store 2
    trash_shot trash-full-not-current
    trash_rail
    trash_wait '.opened and .total == 2 and (.busy == false)'
    trash_shot trash-full-current
    row=$(ipc trashState | jq -er '.rows | map(.original | endswith("/alpha.txt")) | index(true)')
    trash_click trashRowCentre "$row" right
    menu_seek "Restore"
    trash_guard_store 2
    trash_guard "$payload/alpha.txt"
    key -k Return >/dev/null
    trash_wait '.total == 1 and (.busy == false)'
    [[ "$(cat "$payload/alpha.txt")" == alpha ]] || fail "trash: native Restore lost file contents"

    trash_empty_strip
    trash_shot trash-empty-confirm-cancel
    trash_guard_store 1
    key -k Return >/dev/null
    trash_wait '(.confirmation.opened == false) and .total == 1 and (.busy == false)'
    trash_guard_store 1
    trash_empty_strip
    token=$(ipc trashState | jq -er '.confirmation.token')
    trash_guard "$payload/arrival.txt"
    printf 'later arrival\n' > "$payload/arrival.txt"
    trash_private
    /usr/bin/gio trash -- "$payload/arrival.txt" || fail "trash: external owned arrival failed"
    trash_wait ".confirmation.opened and .confirmation.count == 2 and .confirmation.token != $token and (.confirmation.destructiveFocus == false)"
    trash_guard_store 2
    trash_shot trash-confirm-refreshed
    key l >/dev/null
    trash_guard_store 2
    key -k Return >/dev/null
    trash_wait '.total == 0 and (.busy == false)'
    trash_guard_store 0

    key -k Backspace >/dev/null
    trash_guard "$payload/good.txt"
    trash_guard "$payload/locked"
    printf 'delete this\n' > "$payload/good.txt"
    mkdir "$payload/locked"
    printf 'survive failed delete\n' > "$payload/locked/child.txt"
    chmod 0555 "$payload/locked"
    wait_listing 3
    for name in good.txt locked; do
        click_row "$(row_index_of "$name")" left
        trash_guard "$payload/$name"
        trash_private
        key -k Delete >/dev/null
        [[ "$name" == good.txt ]] && wait_listing 2 || wait_listing 1
    done
    trash_rail
    trash_wait '.total == 2 and (.busy == false)'
    hotkey ctrl+a >/dev/null
    trash_wait '.selectedCount == 2 and (.busy == false)'
    trash_guard_store 2
    key -k Delete >/dev/null
    trash_wait '.confirmation.opened and (.confirmation.all == false) and .confirmation.count == 2'
    trash_shot trash-selected-confirm
    key l >/dev/null
    trash_guard_store 2
    key -k Return >/dev/null
    trash_wait '.total == 1 and .selectedCount == 1 and (.busy == false)'
    [[ "$(ipc statusPrimary)" == 'Deleted 1 of 2 · 1 failed' && "$(ipc statusError)" == true ]] \
        || fail "trash: partial deletion did not retain the named primary failure"
    [[ "$(ipc statusDetail)" == *locked* && "$(ipc statusDetail)" == *'Permission denied'* ]] \
        || fail "trash: partial deletion has no file-specific failure detail"
    trash_guard_store 1
    trash_shot trash-partial-failure
    uri=$(/usr/bin/gio trash --list | cut -f1)
    backing=$(trash_backing "$uri") || fail "trash: missing survivor backing"
    trash_guard "$backing"
    [[ "$(cat "$backing/child.txt")" == 'survive failed delete' ]] || fail "trash: failed survivor changed"
    chmod u+w "$backing"
    key -k F5 >/dev/null
    trash_wait '.total == 1 and (.busy == false)'
    trash_click trashRowCentre 0 left
    key -k Delete >/dev/null
    trash_wait '.confirmation.opened and .confirmation.count == 1'
    key l >/dev/null
    trash_guard_store 1
    key -k Return >/dev/null
    trash_wait '.total == 0 and (.busy == false)'
    trash_guard_store 0
    [[ "$(ipc statusError)" == true ]] || fail "trash: success silently acknowledged prior failure"
    trash_click statusDismissCentre
    [[ "$(ipc statusError)" == false ]] || fail "trash: explicit acknowledgement did not dismiss failure"
    trash_shot trash-recovered-empty
    trash_cleanup 0
}
