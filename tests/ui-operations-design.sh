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
    hotkey --global ctrl a flea >/dev/null
    menus_expect selectionCount '. == 5' "native Select All captures all five sources"
    operations_copy_to "$destination"
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 1 and (.notice | contains("Copied 4 of 5") and contains("1 failed"))' "mixed completion retains all counts behind its named error"
    menus_error 'Copy failed: c.txt' 'collision names the failed source'
    menus_expect selectionCount '. == 1' "failed original is selected for retry"
    selected=$(ipc selectedIndices)
    [[ "$selected" == "$(row_index_of c.txt)" ]] || fail "operations: retry selected a different source"
    for name in a.txt b.txt d.txt e.txt; do menus_same_file "committed copy $name" "$source/$name" "$destination/$name"; done
    [[ "$(cat "$destination/c.txt")" == 'existing collision' ]] || fail "operations: collision was overwritten"
    shot operations-mixed-error
    sleep "$transient_clear_s"
    menus_expect statusActivityState '.errors == 1 and (.notice | contains("Copied 4 of 5"))' "error and hidden outcome survive the notice timeout"
    operations_status_control dismiss
    menus_message 'Copied 4 of 5' 'acknowledgement reveals the complete outcome'
    menus_expect statusActivityState '.undo.visible and .undo.enabled and .errors == 0' "successful items retain their native Undo control"
    shot operations-mixed-acknowledged

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

operations_cancel() (
    local variant="$1" source="$menu_box/cancel-source" destination="$menu_box/cancel-$1"
    local permissions_listing="$source" operations_stopped="" pid ui_pid state end
    local -a pids
    menus_guard "$destination"
    mkdir "$destination"
    launch "$source"
    wait_listing 2
    hotkey --global ctrl a flea >/dev/null
    menus_expect selectionCount '. == 2' "$variant cancellation selects two real files"
    operations_copy_to "$destination"
    menus_expect statusActivityState '.activities[0].running and .cancel.enabled' "$variant transfer is running through the actual copy path"
    if [[ "$variant" == paused ]]; then
        ui_pid=$(flea_pid)
        mapfile -t pids < <(pgrep -P "$ui_pid" -x flea)
        [[ "${#pids[@]}" == 1 ]] || fail "operations: paused test needs one owned backend child"
        pid="${pids[0]}"
        permissions_backend_owned "$pid" || fail "operations: backend executable, fixture or session identity differs"
        operations_stopped="$pid"
        trap 'permissions_resume_stopped "$operations_stopped"' EXIT
        kill -STOP "$pid" || fail "operations: owned backend could not pause"
        end=$((SECONDS + 15))
        while (( SECONDS < end )); do
            # Sample process state: Tsl; its leading T proves the owned backend stopped.
            state=$(ps -o stat= -p "$pid") || fail "operations: paused backend disappeared"
            [[ "$state" == T* ]] && break
            sleep 0.05
        done
        [[ "$state" == T* ]] || fail "operations: owned backend did not stop"
        menus_expect statusActivityState '.activities[0].running and .cancel.enabled' "paused transfer remains cancellable"
        key -k Escape >/dev/null
        menus_expect statusActivityState '.activities[0].running and (.activities[0].cancelling | not)' "Escape leaves the named transfer running"
        shot operations-transfer-paused
    fi
    menus_guard "$destination/a-large.bin"
    menus_guard "$destination/b-after.txt"
    operations_status_control cancel
    if [[ "$variant" == paused ]]; then
        menus_expect statusActivityState '.activities[0].cancelling and .cancel.visible and (.cancel.enabled | not)' "Cancel disables immediately while the backend is interrupted"
        operations_status_control cancel
        menus_expect statusActivityState '.activities[0].cancelling and (.cancel.enabled | not)' "repeated pointer Cancel cannot resubmit"
        shot operations-cancelling
        permissions_resume_stopped "$operations_stopped" || fail "operations: owned backend did not resume"
        operations_stopped=""
    fi
    menus_expect statusActivityState '(.activities | length) == 0 and .errors == 0 and (.notice | contains("Copied 0 of 2") and contains("2 skipped") and contains("cancelled") and (contains("failed") | not))' "$variant cancellation reports skipped work without a false write error"
    [[ ! -e "$destination/a-large.bin" && ! -e "$destination/b-after.txt" ]] || fail "operations: cancellation retained a partial copy or started a later item"
    [[ "$(stat -c '%s' "$source/a-large.bin")" == "$operations_bytes" && "$(cat "$source/b-after.txt")" == 'after cancellation' ]] \
        || fail "operations: cancellation changed source data"
    shot "operations-cancelled-$variant"
    printf 'OPERATIONS_CANCEL variant=%s native=ok skipped=2 failed=0 partial_cleanup=ok source_preserved=ok\n' "$variant"
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
    operations_mixed
    menus_guard "$menu_box/cancel-source/a-large.bin"
    truncate -s "$operations_bytes" "$menu_box/cancel-source/a-large.bin"
    menus_guard "$menu_box/cancel-source/b-after.txt"
    printf 'after cancellation\n' > "$menu_box/cancel-source/b-after.txt"
    printf 'OPERATIONS_WORKLOAD bytes=%s source=%q\n' "$operations_bytes" "$menu_box/cancel-source/a-large.bin"
    operations_cancel live
    operations_cancel paused
    printf 'OPERATIONS_DESIGN mixed=ok retry=ok acknowledgement=ok undo=ok live_cancel=ok interrupted_cancel=ok\n'
)
