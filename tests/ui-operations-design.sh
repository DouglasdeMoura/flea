#!/usr/bin/env bash
# Sourced after ui-menus.sh and ui-permissions.sh; their guards and native input helpers are shared.
# shellcheck disable=SC2034,SC2154 # ui.sh supplies state; sourced helpers consume dynamically scoped locals.
operations_copy_to() {
    local destination="$1"
    menus_guard "$destination"
    key m >/dev/null
    menus_expect menuState '.opened and .snapshotReady' "Operations menu snapshots the native selection"
    menus_choose copyTo
    menus_expect menuDialogState '.opened and .action == "copyTo"' "Copy to opens its actual destination field"
    key -M ctrl -k a -m ctrl "$destination" -k Return >/dev/null
    menus_expect menuDialogState '.opened | not' "Copy to submits through the destination field"
}

operations_status_control() {
    local name="$1" centre
    centre=$(ipc statusActivityState | jq -er --arg name "$name" '.[$name] | select(.visible) | .centre') \
        || fail "operations: status control $name is not visible"
    menus_point "$centre"
}

operations_secondary() {
    cardsize_expect statusSecondary "$1"
    menus_equal "$2" "$1" "$(ipc statusSecondary)"
}

operations_idle_footer() {
    local total="$1" selected="$2" label="$3" items="$1 items"
    [[ "$total" == 1 ]] && items="1 item"
    menus_expect statusFooterState ".total == $total and .selected == $selected and .countsLeft and .filesystem != \"\" and .left.text == \"$items\" and .right.text == .filesystem and .right.width > 0 and .right.color == .left.color and .right.fontSize == .left.fontSize" "$label"
    if [[ "$selected" == 0 ]]; then
        menus_expect statusFooterState '(.selection.visible | not) and .right.x >= .left.x + .left.width' "$label has no selection label"
    else
        menus_expect statusFooterState ".selection.visible and .selection.text == \"$selected selected\" and .selection.x == .left.x + .left.width + .countGap and .right.x >= .selection.x + .selection.width" "$label has separate nonoverlapping counts"
    fi
    menus_equal "$label foreground" "$(ipc themeForeground)" "$(ipc statusColor)"
}

operations_path_footer() {
    menus_expect statusFooterState '(.countsLeft | not) and .left.text == .path and (.selection.visible | not) and .right.text != .filesystem' "$1 retains the path beside activity"
}

operations_missing_footer() {
    local missing="$menu_box/missing"
    menus_guard "$missing"
    [[ ! -e "$missing" && ! -L "$missing" ]] || fail "operations: missing-path fixture already exists"
    launch "$missing"
    menus_expect statusFooterState '.listingState == "error" and .filesystem == ""' "missing directory has no filesystem information"
    menus_acknowledge
    menus_expect statusFooterState '(.countsLeft | not) and .left.text == .path and .right.text == "unavailable" and (.selection.visible | not)' "missing filesystem retains path-left and unavailable fallback-right"
    menus_equal "missing filesystem fallback foreground" "$(ipc themeForeground)" "$(ipc statusColor)"
    shot operations-no-filesystem
    kill_flea
}

operations_loading_footer() (
    local permissions_listing="$1" total="$2" destination="$3" operations_stopped="" pid end state
    local -a pids
    menus_guard "$permissions_listing"
    menus_guard "$destination"
    mapfile -t pids < <(backend_pids)
    [[ "${#pids[@]}" == 1 ]] || fail "operations: loading proof requires one owned backend"
    pid="${pids[0]}"
    permissions_backend_owned "$pid" || fail "operations: loading backend candidate, fixture or session differs"
    operations_stopped="$pid"
    trap 'permissions_resume_stopped "$operations_stopped"' EXIT
    kill -STOP "$pid" || fail "operations: could not pause the owned listing backend"
    end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        # Sample process state: Tsl; its leading T proves the owned backend stopped.
        state=$(ps -o stat= -p "$pid") || fail "operations: paused listing backend disappeared"
        [[ "$state" == T* ]] && break
        sleep 0.05
    done
    [[ "$state" == T* ]] || fail "operations: listing backend did not stop"
    key -M ctrl -k l -m ctrl "$destination" -k Return >/dev/null
    menus_expect statusFooterState '.listingState == "loading" and .filesystem != "" and (.countsLeft | not) and .left.visible and .left.width > 0 and .left.text == .path and (.selection.visible | not)' "native refresh preserves its path while the backend cannot reply"
    shot operations-loading-footer
    permissions_resume_stopped "$operations_stopped" || fail "operations: listing backend could not resume"
    operations_stopped=""
    wait_listing 1
    key -M ctrl -k l -m ctrl "$permissions_listing" -k Return >/dev/null
    wait_listing "$total"
    operations_idle_footer "$total" 0 "resumed listing restores idle counts and filesystem"
)

operations_absent() {
    local path="$1" end=$((SECONDS + 15))
    menus_guard "$path"
    while (( SECONDS < end )); do
        [[ ! -e "$path" && ! -L "$path" ]] && return
        sleep 0.05
    done
    fail "operations: an owned operation retained $path"
}

operations_mixed() {
    local source="$menu_box/mixed" destination="$menu_box/mixed-out" name selected
    for name in "$source" "$destination"; do menus_guard "$name"; mkdir "$name"; done
    for name in a.txt b.txt c.txt d.txt e.txt; do
        menus_guard "$source/$name"
        printf 'original %s\n' "$name" > "$source/$name"
    done
    menus_guard "$destination/c.txt"
    printf 'existing collision\n' > "$destination/c.txt"
    launch "$source"
    wait_listing 5
    permissions_viewport 920 600
    operations_secondary "" "no retry claim exists before an attributed failure"
    operations_idle_footer 5 0 "idle footer shows all five items and actual filesystem"
    operations_loading_footer "$source" 5 "$destination" || fail "operations: paused navigation proof failed"
    key v >/dev/null
    operations_idle_footer 5 1 "native selection adds the separate one-selected label"
    shot operations-idle-selected
    key v >/dev/null
    operations_idle_footer 5 0 "native deselection removes the selection label"
    hotkey --global ctrl a flea >/dev/null
    menus_expect selectionCount '. == 5' "native Select All captures all five sources"
    operations_idle_footer 5 5 "native Select All updates the separate selection label"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 1 and (.notice | contains("Copied 4 of 5") and contains("1 failed"))' "mixed completion retains all counts behind its named error"
    menus_error 'Copy failed: c.txt' 'collision names the failed source'
    operations_path_footer "persistent error"
    menus_expect selectionCount '. == 1' "failed original is selected for retry"
    selected=$(ipc selectedIndices)
    [[ "$selected" == "$(row_index_of c.txt)" ]] || fail "operations: retry selected a different source"
    operations_secondary "c.txt selected for retry" "only the identity-verified selected original receives retry secondary text"
    for name in a.txt b.txt d.txt e.txt; do menus_same_file "committed copy $name" "$source/$name" "$destination/$name"; done
    [[ "$(cat "$destination/c.txt")" == 'existing collision' ]] || fail "operations: collision was overwritten"
    shot operations-mixed-error
    sleep "$transient_clear_s"
    menus_expect statusActivityState '.errors == 1 and (.notice | contains("Copied 4 of 5"))' "error and hidden outcome survive the notice timeout"
    operations_status_control dismiss
    menus_message 'Copied 4 of 5' 'acknowledgement reveals the complete outcome'
    menus_expect statusActivityState '.undo.visible and .undo.enabled and .errors == 0' "successful items retain their native Undo control"
    operations_path_footer "acknowledged completion"
    operations_secondary "c.txt selected for retry" "acknowledged completion retains its selected-retry secondary"
    shot operations-mixed-acknowledged
    key -k Escape >/dev/null
    menus_expect selectionCount '. == 0' "native Escape clears the retry selection"
    operations_secondary "" "changing selection removes the previous retry claim"
    seek_row_named c.txt
    key v >/dev/null
    menus_expect selectionCount '. == 1' "native re-selection names one source for the explicit retry"
    operations_secondary "" "manual re-selection cannot revive an earlier identity proof"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 1' "a repeated collision records its own completed failure"
    operations_secondary "c.txt selected for retry" "a new verified locate reply establishes fresh retry text"
    menus_guard "$source/c.txt"
    touch "$source/c.txt"
    operations_secondary "" "external metadata change invalidates displayed retry proof"
    menus_expect selectionCount '. == 1' "watch invalidation does not change the user's selected source"
    menus_acknowledge

    menus_guard "$destination/c.txt"
    menus_guard "$menu_box/collision-kept.txt"
    mv -- "$destination/c.txt" "$menu_box/collision-kept.txt"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 0 and (.notice | contains("Copied 1 item"))' "retry copies only the retained original selection"
    menus_same_file 'retry preserves source contents' "$source/c.txt" "$destination/c.txt"
    menus_guard "$destination/c.txt"
    operations_status_control undo
    menus_message 'Undid the copy.' 'pointer Undo reverses the retry'
    [[ ! -e "$destination/c.txt" ]] || fail "operations: retry Undo retained its created file"
    for name in a.txt b.txt d.txt e.txt; do menus_guard "$destination/$name"; done
    key z >/dev/null
    menus_message 'Undid the copy.' 'native z reverses the earlier committed items'
    for name in a.txt b.txt d.txt e.txt; do operations_absent "$destination/$name"; done
    [[ "$(cat "$menu_box/collision-kept.txt")" == 'existing collision' ]] || fail "operations: Undo touched the pre-existing collision"
    for name in a.txt b.txt c.txt d.txt e.txt; do [[ "$(cat "$source/$name")" == "original $name" ]] || fail "operations: source changed through copy or Undo"; done
    kill_flea
}

operations_copy_gate() {
    python3 - "$1" "$flea_bin" "$3" "$XDG_STATE_HOME" "$menu_box" "$2" "$operations_bytes" 3<&0 <<'PY'
import ctypes, json, os, select, signal, stat, struct, sys, time
from pathlib import Path

pid = int(sys.argv[1])
binary, source, state_home, root, destination = map(Path, sys.argv[2:7])
total = int(sys.argv[7])
timeout_seconds = 15

def guard(path):
    if not path.is_absolute() or not root.is_absolute() or root.resolve() != root or not (root / ".flea-test-sandbox").is_file():
        raise RuntimeError(f"operations: copy gate needs an absolute owned sandbox: {path}")
    if path.resolve() == root or not path.resolve().is_relative_to(root):
        raise RuntimeError(f"operations: copy gate path escaped its sandbox: {path}")
    return path

for path in (source, state_home, destination):
    guard(path)
partial = guard(destination / "a-large.bin")
later = guard(destination / "b-after.txt")
if os.path.lexists(partial) or os.path.lexists(later):
    raise RuntimeError("operations: copy gate destination is not empty")

process = Path("/proc", str(pid))
pidfd = os.pidfd_open(pid)
watchfd = None
stopped = False
commands = os.fdopen(3)
def interrupted(number, frame):
    raise RuntimeError(f"operations: copy gate interrupted by signal {number}")

try:
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    # Sample argv: /owned/target/release/flea NUL --backend NUL.
    argv = (process / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
    # Sample environment entry: FLEA_PATH=/tmp/owned/cancel-source NUL.
    environment = dict(item.split(b"=", 1) for item in (process / "environ").read_bytes().split(b"\0") if b"=" in item)
    expected = {b"FLEA_BIN": os.fsencode(binary), b"FLEA_PATH": os.fsencode(source), b"XDG_STATE_HOME": os.fsencode(state_home)}
    if process.stat().st_uid != os.getuid() or (process / "exe").resolve() != binary.resolve() or argv != [os.fsencode(binary), b"--backend"] or any(environment.get(key) != value for key, value in expected.items()):
        raise RuntimeError(f"operations: copy gate backend {pid} ownership differs")
    if select.select([pidfd], [], [], 0)[0]:
        raise RuntimeError(f"operations: copy gate backend {pid} already exited")
    libc = ctypes.CDLL(None, use_errno=True)
    watchfd = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
    if watchfd < 0:
        raise OSError(ctypes.get_errno(), "operations: inotify_init1 failed")
    create_mask, overflow_mask = 0x100, 0x4000
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    watched = libc.inotify_add_watch(watchfd, os.fsencode(destination), create_mask)
    if watched < 0:
        raise OSError(ctypes.get_errno(), f"operations: cannot watch {destination}")
    print(json.dumps({"state": "armed", "pid": pid, "destination": str(destination)}), flush=True)
    deadline = time.monotonic() + timeout_seconds
    while not stopped:
        ready, _, _ = select.select([watchfd, commands, pidfd], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            raise RuntimeError("operations: real copy did not create its destination before the gate timeout")
        if commands in ready:
            if commands.readline() == "":
                raise SystemExit(0)
            raise RuntimeError("operations: copy gate received a command before the real copy began")
        if pidfd in ready:
            raise RuntimeError("operations: backend exited before the real copy began")
        # Sample inotify event: wd:i32, mask:u32, cookie:u32, name_len:u32, NUL-padded filename.
        events = os.read(watchfd, 4096)
        offset = 0
        while offset < len(events):
            watch, mask, _, length = struct.unpack_from("iIII", events, offset)
            offset += struct.calcsize("iIII")
            name = events[offset:offset + length].rstrip(b"\0")
            offset += length
            if mask & overflow_mask:
                raise RuntimeError("operations: copy gate lost inotify events")
            if watch == watched and mask & create_mask and name == os.fsencode(partial.name):
                stopped = True
                signal.pidfd_send_signal(pidfd, signal.SIGSTOP)
                break
    deadline = time.monotonic() + timeout_seconds
    while True:
        # Sample task status line: State: T (stopped); every thread must have reached the stop.
        states = [next(line.split()[1] for line in task.read_text().splitlines() if line.startswith("State:")) for task in (process / "task").glob("*/status")]
        if states and all(state == "T" for state in states):
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("operations: copy backend did not stop all threads")
        time.sleep(0.01)
    metadata = partial.lstat()
    if not stat.S_ISREG(metadata.st_mode) or not 0 <= metadata.st_size < total or os.path.lexists(later):
        raise RuntimeError(f"operations: copy completed before interruption; partial bytes={metadata.st_size}, total={total}")
    print(json.dumps({"state": "stopped", "pid": pid, "bytes": metadata.st_size, "total": total, "threads": len(states)}), flush=True)
    ready, _, _ = select.select([commands, pidfd], [], [], timeout_seconds)
    if pidfd in ready:
        raise RuntimeError("operations: interrupted backend exited before cancellation resumed it")
    if commands not in ready:
        raise RuntimeError("operations: native cancellation did not release the copy gate")
    command = commands.readline()
    if command not in ("resume\n", ""):
        raise RuntimeError(f"operations: unknown copy gate command: {command!r}")
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    if stopped:
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGCONT)
        except ProcessLookupError:
            pass
    if watchfd is not None and watchfd >= 0:
        os.close(watchfd)
    os.close(pidfd)
PY
}

operations_close_gate() {
    local result=0
    if [[ -n "$gate_input" ]]; then exec {gate_input}>&-; gate_input=""; fi
    if [[ -n "$gate_pid" ]]; then wait "$gate_pid" || result=1; gate_pid=""; fi
    if [[ -n "$gate_output" ]]; then exec {gate_output}<&-; gate_output=""; fi
    return "$result"
}

operations_cancel() (
    local source="$menu_box/cancel-source" destination="$menu_box/cancel-interrupted"
    local permissions_listing="$source" pid gate_pid="" gate_input="" gate_output="" receipt
    local -a pids
    menus_guard "$destination"
    mkdir "$destination" || fail "operations: cancellation destination could not be created"
    launch "$source"
    wait_listing 2
    permissions_viewport 920 600
    hotkey --global ctrl a flea >/dev/null
    menus_expect selectionCount '. == 2' "interrupted cancellation selects two real files"
    mapfile -t pids < <(backend_pids)
    [[ "${#pids[@]}" == 1 ]] || fail "operations: cancellation needs one owned backend"
    pid="${pids[0]}"
    permissions_backend_owned "$pid" || fail "operations: backend executable, fixture or session identity differs"
    coproc OPERATIONS_GATE { operations_copy_gate "$pid" "$destination" "$source"; }
    gate_pid="$OPERATIONS_GATE_PID" gate_input="${OPERATIONS_GATE[1]}" gate_output="${OPERATIONS_GATE[0]}"
    trap 'operations_close_gate || { printf "FAIL: operations: copy gate teardown failed\n" >&2; exit 1; }' EXIT
    read -r -t 15 -u "$gate_output" receipt || fail "operations: copy gate did not arm"
    jq -e '.state == "armed"' <<< "$receipt" >/dev/null || fail "operations: invalid copy gate readiness: $receipt"
    printf 'OPERATIONS_GATE %s\n' "$receipt"
    operations_copy_to "$destination"
    read -r -t 15 -u "$gate_output" receipt || fail "operations: real copy was not interrupted"
    jq -e '.state == "stopped" and .bytes < .total and .threads > 0' <<< "$receipt" >/dev/null || fail "operations: invalid interruption receipt: $receipt"
    printf 'OPERATIONS_GATE %s\n' "$receipt"
    menus_expect statusActivityState '.activities[0].running and .cancel.enabled' "real in-flight transfer remains cancellable while interrupted"
    operations_path_footer "interrupted transfer"
    key -k Escape >/dev/null
    menus_expect statusActivityState '.activities[0].running and (.activities[0].cancelling | not)' "Escape leaves the named transfer running"
    shot operations-transfer-paused
    menus_guard "$destination/a-large.bin"
    menus_guard "$destination/b-after.txt"
    operations_status_control cancel
    menus_expect statusActivityState '.activities[0].cancelling and .cancel.visible and (.cancel.enabled | not)' "Cancel disables immediately while the backend is interrupted"
    operations_path_footer "pending cancellation"
    operations_status_control cancel
    menus_expect statusActivityState '.activities[0].cancelling and (.cancel.enabled | not)' "repeated pointer Cancel cannot resubmit"
    shot operations-cancelling
    printf 'resume\n' >&"$gate_input" || fail "operations: copy gate could not resume the owned backend"
    operations_close_gate || fail "operations: interrupted copy gate failed"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 0 and (.notice | contains("Copied 0 of 2") and contains("2 skipped") and contains("cancelled") and (contains("failed") | not))' "interrupted cancellation reports skipped work without a false write error"
    [[ ! -e "$destination/a-large.bin" && ! -e "$destination/b-after.txt" ]] || fail "operations: cancellation retained a partial copy or started a later item"
    [[ "$(stat -c '%s' "$source/a-large.bin")" == "$operations_bytes" && "$(cat "$source/b-after.txt")" == 'after cancellation' ]] \
        || fail "operations: cancellation changed source data"
    shot operations-cancelled-interrupted
    printf 'OPERATIONS_CANCEL variant=interrupted native=ok skipped=2 failed=0 partial_cleanup=ok source_preserved=ok unpaused_live=not_run\n'
    kill_flea
)

case_operationsdesign() (
    local menu_box menus_checks=0 path
    local operations_bytes=$((1024 * 1024 * 1024))
    sandbox_require "$fixture_root"
    menu_box=$(mktemp -d "$fixture_root/operations-design.XXXXXXXX") || fail "operations: fixture creation failed"
    printf 'native Operations fixture\n' > "$menu_box/.flea-test-sandbox"
    [[ "$menu_box" == "$(realpath -e "$menu_box")" ]] || fail "operations: fixture is not canonical"
    for path in state config cache data cancel-source; do menus_guard "$menu_box/$path"; mkdir "$menu_box/$path"; done
    export XDG_STATE_HOME="$menu_box/state" XDG_CONFIG_HOME="$menu_box/config" XDG_CACHE_HOME="$menu_box/cache" XDG_DATA_HOME="$menu_box/data"
    "$flea_bin" --ui-state '{"view":"list","keys":"default","menu":{"hidden":[]}}' >/dev/null || fail "operations: fixture settings failed"
    operations_missing_footer || fail "operations: missing-filesystem proof failed"
    operations_mixed || fail "operations: mixed-outcome proof failed"
    menus_guard "$menu_box/cancel-source/a-large.bin"
    truncate -s "$operations_bytes" "$menu_box/cancel-source/a-large.bin"
    menus_guard "$menu_box/cancel-source/b-after.txt"
    printf 'after cancellation\n' > "$menu_box/cancel-source/b-after.txt"
    printf 'OPERATIONS_WORKLOAD bytes=%s source=%q\n' "$operations_bytes" "$menu_box/cancel-source/a-large.bin"
    operations_cancel || fail "operations: interrupted cancellation proof failed"
    printf 'OPERATIONS_DESIGN mixed=ok retry=ok acknowledgement=ok undo=ok interrupted_cancel=ok unpaused_live=not_run\n'
)
