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
    # The live case observes transfer progress next; an extra dialog round trip could spend that window.
    [[ "${2:-}" == live ]] && return
    menus_expect menuDialogState '.opened | not' "Copy to submits through the destination field"
}

operations_footer_click() {
    local frame x y width height body caption inset row
    frame=$(ipc statusFooterState | jq -er .frame) || fail "operations: footer frame unavailable"
    read -r x y width height <<< "$frame"
    read -r body caption inset row <<< "$(ipc metrics)"
    [[ "$frame $inset" =~ ^[0-9]+(\ [0-9]+){4}$ ]] || fail "operations: invalid footer geometry: $frame inset=$inset"
    (( width > 2 * inset && height > 0 )) || fail "operations: footer has no visible former Dismiss position"
    menus_point "$((x + width - inset - 1)) $((y + height / 2))"
}

operations_secondary() {
    cardsize_expect statusSecondary "$1"
    menus_equal "$2" "$1" "$(ipc statusSecondary)"
}

operations_footer_geometry() {
    local body caption inset row muted
    read -r body caption inset row <<< "$(ipc metrics)"
    [[ "$body $caption $inset $row" =~ ^[0-9]+(\ [0-9]+){3}$ ]] || fail "operations: live footer tokens unavailable"
    muted=$(ipc palette | cut -d' ' -f4)
    [[ -n "$muted" ]] || fail "operations: muted role unavailable"
    menus_expect statusFooterState ".borderWidth == 0 and (.frame | split(\" \") | map(tonumber) | .[2] == 880 and .[3] == 27)
        and .left.x == $inset and .left.fontSize == $caption and .right.fontSize == $caption
        and .secondary.fontSize == $caption and .secondary.color == \"$muted\"
        and (.secondary.text == \"\" or (.secondary.text | startswith(\" · \")))
        and (.secondary.text | contains(\"|\") | not)
        and .right.x >= .left.x + .left.width" "$1 matches informational footer geometry and semantic roles"
    printf 'OPERATIONS_FOOTER label=%q state=%s\n' "$1" "$(ipc statusFooterState)"
}

operations_idle_footer() {
    local total="$1" selected="$2" label="$3" items="$1 items"
    [[ "$total" == 1 ]] && items="1 item"
    [[ "$selected" == 0 ]] || items+=" · $selected selected"
    menus_expect statusFooterState ".total == $total and .selected == $selected and .filesystem != \"\" and .left.text == \"$items\" and .right.text == .filesystem and .right.width > 0 and .right.color == .left.color and .right.fontSize == .left.fontSize and .right.x >= .left.x + .left.width" "$label"
    menus_equal "$label foreground" "$(ipc themeForeground)" "$(ipc statusColor)"
    operations_footer_geometry "$label"
}

operations_counts_footer() {
    menus_expect statusFooterState '.left.text == .counts and .left.text != .path and .right.text != .filesystem and .right.x >= .left.x + .left.width' "$1 retains counts beside activity"
    operations_footer_geometry "$1"
}

operations_missing_footer() {
    local missing="$menu_box/missing"
    menus_guard "$missing"
    [[ ! -e "$missing" && ! -L "$missing" ]] || fail "operations: missing-path fixture already exists"
    launch "$missing"
    permissions_viewport 880 620
    menus_expect statusFooterState '.listingState == "error" and .filesystem == ""' "missing directory has no filesystem information"
    menus_acknowledge
    menus_expect statusFooterState '.left.text == "unavailable" and .right.text == ""' "missing filesystem reports unavailable on the left without invented capacity"
    menus_equal "missing filesystem fallback foreground" "$(ipc themeForeground)" "$(ipc statusColor)"
    shot operations-no-filesystem
    kill_flea
}

operations_pause_backend() {
    local pid end state
    local -a pids
    menus_guard "$permissions_listing"
    mapfile -t pids < <(backend_pids)
    [[ "${#pids[@]}" == 1 ]] || fail "operations: loading proof requires one owned backend"
    pid="${pids[0]}"
    permissions_backend_owned "$pid" || fail "operations: loading backend candidate, fixture or session differs"
    operations_stopped="$pid"
    kill -STOP "$pid" || fail "operations: could not pause the owned listing backend"
    end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        # Sample process state: Tsl; its leading T proves the owned backend stopped.
        state=$(ps -o stat= -p "$pid") || fail "operations: paused listing backend disappeared"
        [[ "$state" == T* ]] && break
        sleep 0.05
    done
    [[ "$state" == T* ]] || fail "operations: listing backend did not stop"
}

operations_loading_footer() (
    local permissions_listing="$1" total="$2" destination="$3" operations_stopped=""
    menus_guard "$destination"
    trap 'permissions_resume_stopped "$operations_stopped"' EXIT
    operations_pause_backend
    key -M ctrl -k l -m ctrl "$destination" -k Return >/dev/null
    menus_expect statusFooterState '.listingState == "loading" and .filesystem != "" and .left.text == "" and .left.text == .counts and .right.text == .filesystem' "native refresh clears stale counts while the backend cannot reply"
    shot operations-loading-footer
    permissions_resume_stopped "$operations_stopped" || fail "operations: listing backend could not resume"
    operations_stopped=""
    wait_listing 1
    key -M ctrl -k l -m ctrl "$permissions_listing" -k Return >/dev/null
    wait_listing "$total"
    operations_idle_footer "$total" 0 "resumed listing restores idle counts and filesystem"
)

operations_search_footer() (
    local permissions_listing="$menu_box/mixed" operations_stopped=""
    launch "$permissions_listing"
    wait_listing 5
    permissions_viewport 880 620
    trap 'permissions_resume_stopped "$operations_stopped"' EXIT
    operations_pause_backend
    key f >/dev/null
    key c.txt -k Return >/dev/null
    menus_expect keyDeliveryState '.searchMode == "results" and .searchQuery == "c.txt" and .searchRunning' "native Search submits while its owned backend is stopped"
    menus_expect statusFooterState '.listingState == "loading" and .left.text == .counts and .left.text == "" and .right.text == "Search: 0 scanned"' "submitted search displays its actual initial scanned count"
    operations_secondary " · esc cancels" "initial Search names its native cancellation key"
    operations_footer_geometry "initial search progress"
    shot operations-search-submitted
    permissions_resume_stopped "$operations_stopped" || fail "operations: search backend could not resume"
    operations_stopped=""
    menus_expect keyDeliveryState '.searchMode == "results" and .searchQuery == "c.txt" and (.searchRunning | not)' "resumed backend completes the real native search"
    wait_listing 1
    menus_expect statusFooterState '.left.text == "1 item" and (.right.text | test("^Search: 5 scanned in [0-9]+\\.[0-9] s$"))' "completed search reports one result from its five scanned fixture files"
    [[ "$(ipc rowAt 0)" == c.txt\|file\|* ]] || fail "operations: Search returned another fixture identity"
    shot operations-search-completed
    key -k Escape >/dev/null
    menus_expect keyDeliveryState '.searchMode == ""' "native Escape closes completed search"
    wait_listing 5
    operations_idle_footer 5 0 "leaving Search restores the directory footer"
    kill_flea
    printf 'OPERATIONS_SEARCH initial_submitted=ok resumed_result=ok close=ok positive_scanned_live=not_run\n'
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
    local source="$menu_box/mixed" destination="$menu_box/mixed-out" name selected notice
    for name in "$source" "$destination"; do menus_guard "$name"; mkdir "$name"; done
    for name in a.txt b.txt c.txt d.txt e.txt; do
        menus_guard "$source/$name"
        printf 'original %s\n' "$name" > "$source/$name"
    done
    menus_guard "$destination/c.txt"
    printf 'existing collision\n' > "$destination/c.txt"
    launch "$source"
    wait_listing 5
    permissions_viewport 880 620
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
    operations_counts_footer "persistent error"
    menus_expect selectionCount '. == 1' "failed original is selected for retry"
    selected=$(ipc selectedIndices)
    [[ "$selected" == "$(row_index_of c.txt)" ]] || fail "operations: retry selected a different source"
    operations_secondary " · esc dismisses · c.txt selected for retry" "error hint and identity-verified retry use separate muted secondary text"
    menus_expect statusFooterState '(.right.text | startswith("Copy failed: c.txt · ")) and (.right.text | contains("(os error") | not)' "error is a plain sentence with a named cause"
    for name in a.txt b.txt d.txt e.txt; do menus_same_file "committed copy $name" "$source/$name" "$destination/$name"; done
    [[ "$(cat "$destination/c.txt")" == 'existing collision' ]] || fail "operations: collision was overwritten"
    shot operations-mixed-error
    sleep "$transient_clear_s"
    menus_expect statusActivityState '.errors == 1 and (.notice | contains("Copied 4 of 5"))' "error and hidden outcome survive the notice timeout"
    cardsize_expect focusView list
    operations_footer_click
    # A native focus cycle flushes click delivery without changing the retry-selection identity.
    key -k Tab >/dev/null
    cardsize_expect focusView rail
    key -k Tab >/dev/null
    cardsize_expect focusView list
    menus_expect statusActivityState '.errors == 1' "pointer at the removed Dismiss control leaves the persistent error unacknowledged"
    menus_error 'Copy failed: c.txt' 'removed footer control does not dismiss the named failure'
    shot operations-error-footer-click-inert
    key -k Escape >/dev/null
    menus_message 'Copied 4 of 5' 'acknowledgement reveals the complete outcome'
    menus_expect statusActivityState '.undoAvailable and .errors == 0' "successful items remain undoable through the native key"
    operations_counts_footer "acknowledged completion"
    operations_secondary " · z undoes · c.txt selected for retry" "acknowledged completion retains Undo hint and selected-retry secondary"
    notice=$(ipc statusActivityState | jq -er .notice) || fail "operations: acknowledged Undo notice unavailable"
    sleep "$transient_clear_s"
    menus_equal 'acknowledged Undo notice survives the transient timeout unchanged' "$notice" "$(ipc statusActivityState | jq -er .notice)"
    menus_expect statusActivityState '.undoAvailable and .errors == 0' "acknowledged completion stays undoable beyond the notice timeout"
    operations_secondary " · z undoes · c.txt selected for retry" "acknowledged retry identity and Undo hint survive the notice timeout"
    shot operations-mixed-acknowledged
    key -k Escape >/dev/null
    menus_expect selectionCount '. == 0' "native Escape clears the retry selection"
    operations_secondary " · z undoes" "changing selection removes the previous retry claim while retaining Undo"
    seek_row_named c.txt
    key v >/dev/null
    menus_expect selectionCount '. == 1' "native re-selection names one source for the explicit retry"
    operations_secondary " · z undoes" "manual re-selection cannot revive an earlier identity proof"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 1' "a repeated collision records its own completed failure"
    operations_secondary " · esc dismisses · c.txt selected for retry" "a new verified locate reply establishes fresh retry text"
    menus_guard "$source/c.txt"
    touch "$source/c.txt"
    operations_secondary " · esc dismisses" "external metadata change invalidates displayed retry proof without hiding error acknowledgement"
    menus_expect selectionCount '. == 1' "watch invalidation does not change the user's selected source"
    menus_acknowledge

    menus_guard "$destination/c.txt"
    menus_guard "$menu_box/collision-kept.txt"
    mv -- "$destination/c.txt" "$menu_box/collision-kept.txt"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 0 and (.notice | contains("Copied 1 item"))' "retry copies only the retained original selection"
    menus_same_file 'retry preserves source contents' "$source/c.txt" "$destination/c.txt"
    operations_counts_footer "undoable transient"
    operations_secondary " · z undoes" "successful retry names the native Undo key"
    shot operations-transient-undo
    menus_guard "$destination/c.txt"
    cardsize_expect focusView list
    operations_footer_click
    key -k Tab >/dev/null
    cardsize_expect focusView rail
    key -k Tab >/dev/null
    cardsize_expect focusView list
    menus_expect statusActivityState '.undoAvailable and (.notice | contains("Copied 1 item"))' "clicking the informational footer cannot undo a completed copy"
    menus_same_file 'footer click preserves the completed retry' "$source/c.txt" "$destination/c.txt"
    key z >/dev/null
    menus_message 'Undid the copy.' 'native z reverses the retry'
    [[ ! -e "$destination/c.txt" ]] || fail "operations: retry Undo retained its created file"
    for name in a.txt b.txt d.txt e.txt; do menus_guard "$destination/$name"; done
    key z >/dev/null
    menus_message 'Undid the copy.' 'native z reverses the earlier committed items'
    for name in a.txt b.txt d.txt e.txt; do operations_absent "$destination/$name"; done
    [[ "$(cat "$menu_box/collision-kept.txt")" == 'existing collision' ]] || fail "operations: Undo touched the pre-existing collision"
    for name in a.txt b.txt c.txt d.txt e.txt; do [[ "$(cat "$source/$name")" == "original $name" ]] || fail "operations: source changed through copy or Undo"; done
    kill_flea
}

operations_long_error() {
    local source="$menu_box/long-name" destination="$menu_box/long-name-out" name path
    for path in "$source" "$destination"; do
        menus_guard "$path"
        mkdir "$path" || fail "operations: long-name fixture directory creation failed"
    done
    printf -v name 'long-%0230d.txt' 0
    menus_guard "$source/$name"
    menus_guard "$destination/$name"
    printf 'long-name source\n' > "$source/$name" || fail "operations: legal long-name source creation failed"
    printf 'long-name collision\n' > "$destination/$name" || fail "operations: legal long-name collision creation failed"
    launch "$source"
    wait_listing 1
    permissions_viewport 880 620
    key v >/dev/null
    menus_expect selectionCount '. == 1' "long-name collision selects its real source"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 1 and (.notice | contains("Copied 0 of 1") and contains("1 failed"))' "one long-name collision records its real failed outcome"
    menus_error "Copy failed: $name" 'long-name error retains the exact failed source identity'
    menus_equal 'long-name retry selects the original row' "$(row_index_of "$name")" "$(ipc selectedIndices)"
    operations_secondary " · esc dismisses · $name selected for retry" "long-name error retains its hint and identity-verified retry text"
    menus_expect statusFooterState '.right.visible and .right.width > 0 and .right.truncated and .right.implicitWidth > .right.width
        and .secondary.visible and .secondary.width > 0 and .secondary.truncated and .secondary.implicitWidth > .secondary.width
        and .hintWidth > 0 and .secondary.width >= ([.hintWidth, .slotWidth] | min)' \
        "long secondary content cannot erase the primary error; both captions report their actual elision"
    menus_equal 'long-name error retains its semantic role' "$(ipc palette | cut -d' ' -f6)" "$(ipc statusColor)"
    operations_footer_geometry "long-name persistent error"
    [[ "$(cat "$source/$name")" == 'long-name source' && "$(cat "$destination/$name")" == 'long-name collision' ]] \
        || fail "operations: long-name collision changed source or existing destination"
    shot operations-long-name-error
    menus_acknowledge
    menus_expect statusFooterState '(.right.text | startswith("Copied 0 of 1")) and .right.width > 0 and (.right.truncated | not) and .secondary.truncated' \
        "acknowledging the long-name error leaves its complete short outcome ahead of the elided retry"
    shot operations-long-name-acknowledged
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
    # EOF releases the stop if native proof aborts; the input checks own their deadlines.
    ready, _, _ = select.select([commands, pidfd], [], [])
    if pidfd in ready:
        raise RuntimeError("operations: interrupted backend exited before cancellation resumed it")
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
    local variant="$1" source="$menu_box/cancel-source" destination="$menu_box/cancel-$1"
    local permissions_listing="$source" pid gate_pid="" gate_input="" gate_output="" receipt cancel_centre selected cursor
    local -a pids
    menus_guard "$destination"
    mkdir "$destination" || fail "operations: cancellation destination could not be created"
    launch "$source"
    wait_listing 2
    permissions_viewport 880 620
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
    menus_expect statusActivityState '.activities[0].running and .transferCard.visible and .transferCard.cancel.visible and .transferCard.cancel.enabled' "real in-flight transfer remains cancellable in its card while interrupted"
    operations_counts_footer "interrupted transfer"
    operations_secondary " · esc cancels" "transfer footer names its native cancellation key"
    key m >/dev/null
    menus_expect menuState '.opened' "a native popup opens above the running transfer"
    key -k Escape >/dev/null
    menus_expect menuState '.opened | not' "Escape closes the popup before cancelling its transfer"
    menus_expect statusActivityState '.activities[0].running and (.activities[0].cancelling | not)' "popup Escape leaves the named transfer running"
    key / >/dev/null
    menus_expect keyDeliveryState '.filterTyping' "native filter opens above the running transfer"
    key -k Escape >/dev/null
    menus_expect keyDeliveryState '(.filterTyping | not) and .filterQuery == ""' "Escape closes the filter before cancelling its transfer"
    menus_expect statusActivityState '.activities[0].running and (.activities[0].cancelling | not)' "filter Escape leaves the named transfer running"
    key f >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing"' "native search takes focus above the running transfer"
    key -k Escape >/dev/null
    menus_expect keyDeliveryState '.searchMode == ""' "Escape closes focused search before cancelling its transfer"
    menus_expect statusActivityState '.activities[0].running and (.activities[0].cancelling | not)' "focused-search Escape leaves the named transfer running"
    shot "operations-transfer-$variant-paused"
    menus_guard "$destination/a-large.bin"
    menus_guard "$destination/b-after.txt"
    selected=$(ipc selectedIndices) || fail "operations: cancellation selection unavailable"
    cursor=$(ipc cursor) || fail "operations: cancellation cursor unavailable"
    if [[ "$variant" == pointer ]]; then
        cancel_centre=$(ipc statusActivityState | jq -er '.transferCard.cancel | select(.visible and .enabled) | .centre') \
            || fail "operations: live transfer-card Cancel is unavailable"
        menus_point "$cancel_centre"
    else
        [[ "$variant" == escape ]] || fail "operations: unknown cancellation input: $variant"
        key -k Escape >/dev/null
    fi
    menus_expect statusActivityState '.activities[0].cancelling and .transferCard.visible and .transferCard.cancelling and ((.transferCard.cancel.visible and .transferCard.cancel.enabled) | not)' "$variant cancellation becomes visibly pending while the backend is interrupted"
    operations_counts_footer "pending cancellation"
    if [[ "$variant" == pointer ]]; then menus_point "$cancel_centre"; else key -k Escape >/dev/null; fi
    key / >/dev/null
    menus_expect keyDeliveryState '.filterTyping' "a later native key is delivered before checking repeated $variant cancellation"
    key -k Escape >/dev/null
    menus_expect keyDeliveryState '.filterTyping | not' "Escape closes the pending-transfer filter without changing cancellation"
    menus_expect statusActivityState '.activities[0].cancelling and .transferCard.cancelling and ((.transferCard.cancel.visible and .transferCard.cancel.enabled) | not)' "repeated $variant cancellation remains pending"
    menus_equal "$variant cancellation does not reach the listing selection" "$selected" "$(ipc selectedIndices)"
    menus_equal "$variant cancellation does not move the listing cursor" "$cursor" "$(ipc cursor)"
    shot "operations-cancelling-$variant"
    printf 'resume\n' >&"$gate_input" || fail "operations: copy gate could not resume the owned backend"
    operations_close_gate || fail "operations: interrupted copy gate failed"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 0 and (.notice | contains("Copied 0 of 2") and contains("2 skipped") and contains("cancelled") and (contains("failed") | not))' "interrupted cancellation reports skipped work without a false write error"
    [[ ! -e "$destination/a-large.bin" && ! -e "$destination/b-after.txt" ]] || fail "operations: cancellation retained a partial copy or started a later item"
    [[ "$(stat -c '%s' "$source/a-large.bin")" == "$operations_bytes" && "$(cat "$source/b-after.txt")" == 'after cancellation' ]] \
        || fail "operations: cancellation changed source data"
    shot "operations-cancelled-$variant-interrupted"
    printf 'OPERATIONS_CANCEL variant=%s interrupted_native=ok skipped=2 failed=0 partial_cleanup=ok source_preserved=ok unpaused_live=not_run\n' "$variant"
    kill_flea
)

operations_missed_window() {
    printf 'OPERATIONS_MISSED_WINDOW phase=%q state=%s attempts=1 workload_unchanged=true\n' "$1" "$2"
    fail "operations: $1 missed the live observation/input window; no retry or workload enlargement"
}

operations_cancel_live() (
    local source="$menu_box/cancel-source" destination="$menu_box/cancel-live" permissions_listing="$menu_box/cancel-source"
    local state observed_bytes source_hash source_identity selected cursor pid deadline path
    local -a pids
    menus_guard "$destination"
    mkdir "$destination" || fail "operations: live cancellation destination creation failed"
    for path in "$source/a-large.bin" "$source/b-after.txt" "$destination/a-large.bin" "$destination/b-after.txt"; do menus_guard "$path"; done
    source_hash=$(sha256sum < "$source/a-large.bin") || fail "operations: source checksum failed"
    source_identity=$(stat -c '%d:%i:%s:%Y' "$source/a-large.bin") || fail "operations: source identity unavailable"
    launch "$source"
    trap 'kill_flea' EXIT
    wait_listing 2
    permissions_viewport 880 620
    hotkey --global ctrl a flea >/dev/null
    menus_expect selectionCount '. == 2' "live cancellation selects both real files"
    selected=$(ipc selectedIndices) || fail "operations: live selection unavailable"
    cursor=$(ipc cursor) || fail "operations: live cursor unavailable"
    mapfile -t pids < <(backend_pids)
    [[ "${#pids[@]}" == 1 ]] || fail "operations: live cancellation requires one owned backend"
    pid="${pids[0]}"
    permissions_backend_owned "$pid" || fail "operations: live backend identity differs"
    state=$(ps -o stat= -p "$pid") || fail "operations: live backend state unavailable"
    [[ "$state" != T* ]] || fail "operations: live backend is stopped before the native operation"
    operations_copy_to "$destination" live
    deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        state=$(ipc statusActivityState) || fail "operations: live transfer observer failed"
        jq -e '.errors == 0' <<< "$state" >/dev/null || fail "operations: unpaused transfer failed: $state"
        if jq -e '.activities[0].running and .activities[0].text == "Copying 1 of 2 · a-large.bin"' <<< "$state" >/dev/null; then break; fi
        if jq -e '(.activities | length) == 0 and .notice != ""' <<< "$state" >/dev/null; then operations_missed_window transfer-progress "$state"; fi
        sleep 0.05
    done
    jq -e '.activities[0].running and .activities[0].text == "Copying 1 of 2 · a-large.bin" and .transferCard.visible' <<< "$state" >/dev/null \
        || fail "operations: no filename-bearing live transfer before deadline: $state"
    observed_bytes=$(stat -c '%s' "$destination/a-large.bin") || fail "operations: live destination byte count unavailable"
    (( observed_bytes > 0 && observed_bytes < operations_bytes )) || operations_missed_window transfer-before-capture "$state"
    printf 'OPERATIONS_LIVE_TRANSFER before_capture_bytes=%s state=%s\n' "$observed_bytes" "$state"
    shot operations-transfer-unpaused-filename
    state=$(ipc statusActivityState) || fail "operations: live post-capture observer failed"
    observed_bytes=$(stat -c '%s' "$destination/a-large.bin") || fail "operations: post-capture destination byte count unavailable"
    if ! jq -e '.activities[0].running and .activities[0].text == "Copying 1 of 2 · a-large.bin"' <<< "$state" >/dev/null \
            || (( observed_bytes <= 0 || observed_bytes >= operations_bytes )); then
        operations_missed_window transfer-after-capture "$state"
    fi
    printf 'OPERATIONS_LIVE_TRANSFER after_capture_bytes=%s state=%s\n' "$observed_bytes" "$state"
    key -k Escape >/dev/null
    menus_expect statusActivityState '(.activities | length) == 0' "unpaused native Escape reaches a terminal transfer state"
    state=$(ipc statusActivityState) || fail "operations: live cancellation outcome unavailable"
    menus_equal "unpaused cancellation preserves source identity" "$source_identity" "$(stat -c '%d:%i:%s:%Y' "$source/a-large.bin")"
    menus_equal "unpaused cancellation preserves all source bytes" "$source_hash" "$(sha256sum < "$source/a-large.bin")"
    menus_equal "unpaused cancellation preserves later source" 'after cancellation' "$(cat "$source/b-after.txt")"
    jq -e '.errors == 0' <<< "$state" >/dev/null || fail "operations: live cancellation reported an error: $state"
    jq -e '.notice | contains("Copied 0 of 2") and contains("2 skipped") and contains("cancelled") and (contains("failed") | not)' <<< "$state" >/dev/null \
        || operations_missed_window transfer-cancellation "$state"
    operations_absent "$destination/a-large.bin"
    operations_absent "$destination/b-after.txt"
    menus_equal "unpaused Escape preserves listing marks" "$selected" "$(ipc selectedIndices)"
    menus_equal "unpaused Escape preserves listing cursor" "$cursor" "$(ipc cursor)"
    shot operations-cancelled-unpaused
    printf 'OPERATIONS_CANCEL variant=escape unpaused_native=ok filename_capture=ok skipped=2 failed=0 partial_cleanup=ok source_preserved=ok attempts=1\n'
)

operations_search_live() (
    local source="$menu_box/search-live" query=flea-operations-no-match state footer deadline
    local directory_count=100000
    menus_guard "$source"
    mkdir "$source" || fail "operations: nested Search fixture creation failed"
    # Reuse case_nosweep's established directory count; no larger tree or second attempt follows a miss.
    python3 - "$menu_box" "$source" "$directory_count" <<'PY' || fail "operations: nested Search fixture could not be populated"
from pathlib import Path
import sys

sandbox, root = map(Path, sys.argv[1:3])
count = int(sys.argv[3])
if not sandbox.is_absolute() or not root.is_absolute() or not (sandbox / ".flea-test-sandbox").is_file():
    raise SystemExit("operations: nested Search needs an absolute marked sandbox")
if sandbox.resolve() != sandbox or root.resolve() != root or sandbox not in root.parents or any(root.iterdir()):
    raise SystemExit("operations: nested Search root is not an empty canonical child of its sandbox")
for index in range(1, count + 1):
    child = root / f"dir_{index}"
    if not child.is_absolute() or sandbox not in child.parents:
        raise SystemExit(f"operations: nested Search path escaped its sandbox: {child}")
    child.mkdir()
PY
    printf 'OPERATIONS_SEARCH_WORKLOAD directories=%s source=%q\n' "$directory_count" "$source"
    launch "$source"
    trap 'kill_flea' EXIT
    wait_listing "$directory_count"
    permissions_viewport 880 620
    key f >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing"' "live Search opens through native input"
    key "$query" -k Return >/dev/null
    deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        state=$(ipc keyDeliveryState) || fail "operations: live Search observer failed"
        if jq -e '.searchMode == "results" and .searchRunning and .searchScanned > 0' <<< "$state" >/dev/null; then break; fi
        if jq -e '.searchMode == "results" and (.searchRunning | not)' <<< "$state" >/dev/null; then operations_missed_window search-progress "$state"; fi
        sleep 0.05
    done
    jq -e --arg query "$query" --argjson count "$directory_count" '.searchMode == "results" and .searchQuery == $query and .searchRunning and (.searchCancelled | not) and .searchScanned == $count' <<< "$state" >/dev/null \
        || fail "operations: Search did not expose the real positive scan before deadline: $state"
    footer=$(ipc statusFooterState) || fail "operations: live Search footer unavailable"
    if ! jq -e '.right.text == "Search: 100,000 scanned" and .secondary.text == " · esc cancels"' <<< "$footer" >/dev/null; then
        state=$(ipc keyDeliveryState) || fail "operations: Search state unavailable after footer mismatch"
        if jq -e '.searchMode == "results" and (.searchRunning | not)' <<< "$state" >/dev/null; then
            operations_missed_window search-footer "$state footer=$footer"
        fi
        fail "operations: running Search footer differs: state=$state footer=$footer"
    fi
    printf 'OPERATIONS_LIVE_SEARCH before_capture=%s footer=%s\n' "$state" "$footer"
    shot operations-search-positive-scanned-live
    state=$(ipc keyDeliveryState) || fail "operations: live Search post-capture observer failed"
    jq -e '.searchMode == "results" and .searchRunning and .searchScanned > 0 and (.searchCancelled | not)' <<< "$state" >/dev/null \
        || operations_missed_window search-after-capture "$state"
    printf 'OPERATIONS_LIVE_SEARCH after_capture=%s\n' "$state"
    key -k Escape >/dev/null
    menus_expect keyDeliveryState '.searchRunning | not' "native Escape reaches a terminal Search state"
    state=$(ipc keyDeliveryState) || fail "operations: live Search cancellation outcome unavailable"
    jq -e '.searchMode == "results" and .searchCancelled and .searchScanned == 100000' <<< "$state" >/dev/null \
        || operations_missed_window search-cancellation "$state"
    cardsize_expect total 0
    shot operations-search-cancelled-live
    key -k Escape >/dev/null
    menus_expect keyDeliveryState '.searchMode == ""' "second Escape closes cancelled live Search"
    wait_listing "$directory_count"
    operations_idle_footer "$directory_count" 0 "closing cancelled Search restores its real directory"
    printf 'OPERATIONS_SEARCH positive_scanned_live=ok filename_matches=0 cancelled_native=ok close=ok attempts=1 state=%s\n' "$state"
)

case_operationsdesign() (
    local menu_box menus_checks=0 path live_cancel=failed live_search=failed
    local operations_bytes=$((1024 * 1024 * 1024))
    sandbox_require "$fixture_root"
    menu_box=$(mktemp -d "$fixture_root/operations-design.XXXXXXXX") || fail "operations: fixture creation failed"
    printf 'native Operations fixture\n' > "$menu_box/.flea-test-sandbox"
    [[ "$menu_box" == "$(realpath -e "$menu_box")" ]] || fail "operations: fixture is not canonical"
    for path in state config cache data cancel-source; do menus_guard "$menu_box/$path"; mkdir "$menu_box/$path"; done
    export XDG_STATE_HOME="$menu_box/state" XDG_CONFIG_HOME="$menu_box/config" XDG_CACHE_HOME="$menu_box/cache" XDG_DATA_HOME="$menu_box/data"
    "$flea_bin" --ui-state '{"view":"list","keys":"default","display":{"textSize":{"mode":14}},"menu":{"hidden":[]}}' >/dev/null || fail "operations: fixture settings failed"
    operations_missing_footer || fail "operations: missing-filesystem proof failed"
    operations_mixed || fail "operations: mixed-outcome proof failed"
    operations_long_error || fail "operations: long-name footer proof failed"
    operations_search_footer || fail "operations: search footer proof failed"
    menus_guard "$menu_box/cancel-source/a-large.bin"
    truncate -s "$operations_bytes" "$menu_box/cancel-source/a-large.bin"
    menus_guard "$menu_box/cancel-source/b-after.txt"
    printf 'after cancellation\n' > "$menu_box/cancel-source/b-after.txt"
    printf 'OPERATIONS_WORKLOAD bytes=%s source=%q\n' "$operations_bytes" "$menu_box/cancel-source/a-large.bin"
    operations_cancel pointer || fail "operations: interrupted pointer cancellation proof failed"
    operations_cancel escape || fail "operations: interrupted Escape cancellation proof failed"
    if operations_cancel_live; then live_cancel=ok; fi
    if operations_search_live; then live_search=ok; fi
    printf 'OPERATIONS_DESIGN mixed=ok retry=ok acknowledgement=ok undo=ok informational_footer=ok long_name_elision=ok search_initial=ok interrupted_pointer_cancel=ok interrupted_escape_cancel=ok unpaused_live=%s positive_scanned_live=%s visual_inspection=pending\n' "$live_cancel" "$live_search"
    [[ "$live_cancel" == ok && "$live_search" == ok ]] || fail "operations: required unpaused proof remains incomplete"
)
