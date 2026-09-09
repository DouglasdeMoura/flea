#!/usr/bin/env bash
# Sourced by ui.sh; all actions enter through native pointer/key input, with read-only IPC observations.
menus_guard() {
    local target="$1" canonical
    [[ -n "$target" && "$target" == /* && -f "$menu_box/.flea-test-sandbox" ]] || fail "menus: invalid sandbox target"
    canonical=$(realpath -m -- "$target") || fail "menus: cannot resolve $target"
    [[ "$canonical" == "$menu_box/"* && "$canonical" != "$menu_box" ]] || fail "menus: target outside owned sandbox: $target"
}

menus_expect() {
    local observer="$1" expression="$2" label="$3" observed deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        observed=$(ipc "$observer") || fail "menus: observer failed: $observer"
        if jq -e "$expression" <<< "$observed" >/dev/null; then
            menus_checks=$((menus_checks + 1))
            printf 'MENUS_CHECK %s %s\n' "$menus_checks" "$label"
            return
        fi
        sleep 0.05
    done
    fail "menus: $label: $observed"
}

menus_point() {
    local centre="$1" button="${2:-left}" cx cy wx wy ww wh
    read -r cx cy <<< "$centre"
    [[ "$cx" =~ ^-?[0-9]+$ && "$cy" =~ ^-?[0-9]+$ ]] || fail "menus: no live control centre: $centre"
    read -r wx wy ww wh < <(window_box)
    (( cx >= 0 && cy >= 0 && cx < ww && cy < wh )) || fail "menus: control is clipped outside the viewport"
    assert_focus
    omarchy-drive click "$((wx + cx))" "$((wy + cy))" "$button" >/dev/null || fail "menus: pointer delivery failed"
}

menus_control() {
    local observer="$1" name="$2" state centre
    state=$(ipc "$observer") || fail "menus: cannot observe $observer"
    centre=$(jq -er --arg name "$name" '.controls[] | select(.name == $name and .visible) | .centre' <<< "$state") \
        || fail "menus: $name is not visible in $observer"
    menus_point "$centre"
}

menus_seek() {
    local action="$1" state target cursor step count
    state=$(ipc menuState)
    target=$(jq -er --arg action "$action" '.entries | to_entries[] | select(.value.action == $action and .value.disabled != true) | .key' <<< "$state") \
        || fail "menus: $action is absent or disabled: $state"
    count=$(jq -r '.entries | length' <<< "$state")
    for ((step = 0; step <= count; step++)); do
        cursor=$(ipc contextMenuCursor)
        [[ "$cursor" == "$target" ]] && return
        if (( cursor < target )); then key -k Down >/dev/null; else key -k Up >/dev/null; fi
    done
    fail "menus: keyboard could not reach $action"
}

menus_choose() {
    local action="$1" input="${2:-key}" target
    menus_seek "$action"
    if [[ "$input" == pointer ]]; then
        target=$(ipc contextMenuCursor)
        menus_point "$(ipc contextMenuRowCentre "$target")"
    else
        key -k Return >/dev/null
    fi
}

menus_file_menu() {
    local name="$1" input="${2:-pointer}" index
    index=$(row_index_of "$name")
    click_row "$index" left
    if [[ "$input" == key ]]; then key -M shift -k F10 -m shift >/dev/null
    elif [[ "$input" == menu-key ]]; then key -k Menu >/dev/null
    else click_row "$index" right; fi
    menus_expect menuState '.opened and .hasRow and (.forRail | not)' "file menu opens by $input"
}

menus_shot() {
    local name="$1" png="$evidence_dir/menus-$1-$$.png" canonical
    [[ -f "$run_root/.flea-test-sandbox" && "$png" == /* && ! -e "$png" ]] || fail "menus: screenshot must be fresh and sandboxed"
    canonical=$(realpath -m -- "$png") || fail "menus: cannot resolve screenshot path"
    [[ "$canonical" == "$run_root/"* ]] || fail "menus: screenshot escaped evidence sandbox"
    mkdir -p "$evidence_dir" || fail "menus: cannot create evidence directory"
    omarchy-drive shot "$png" flea >/dev/null || fail "menus: native capture failed"
    [[ -s "$png" ]] || fail "menus: native capture is empty"
    printf 'MENUS_SHOT_REQUIRES_INSPECTION %s\n' "$png"
}

menus_confirmation() {
    local name="$1" preset="$2" token
    menus_file_menu "$name"
    menus_choose deletePermanently
    menus_expect menuDialogState '.confirmation.opened and (.confirmation.destructiveFocus | not)' "permanent deletion opens on Cancel"
    menus_shot "$preset-confirmation"
    key -k Return >/dev/null
    menus_expect menuDialogState '.opened | not' "reflexive Enter cancels deletion"
    [[ -f "$menu_dir/$name" ]] || fail "menus: Enter on Cancel deleted the fixture"
    menus_file_menu "$name" key
    menus_choose deletePermanently
    menus_expect menuDialogState '.confirmation.opened' "deletion can reopen after cancellation"
    key -k Tab >/dev/null
    menus_expect menuDialogState '.confirmation.destructiveFocus' "Tab reaches destructive choice"
    key h >/dev/null
    menus_expect menuDialogState '.confirmation.destructiveFocus | not' "h restores Cancel"
    key l >/dev/null
    menus_expect menuDialogState '.confirmation.destructiveFocus' "l reaches destructive choice"
    key -k Left >/dev/null
    menus_expect menuDialogState '.confirmation.destructiveFocus | not' "Left restores Cancel"
    key -k Right >/dev/null
    key -k Escape >/dev/null
    menus_expect menuDialogState '.opened | not' "Escape cancels from destructive choice"
    [[ -f "$menu_dir/$name" ]] || fail "menus: Escape deleted the fixture"
}

menus_permissions() {
    local name="$1" preset="$2" actual
    menus_file_menu "$name"
    menus_choose permissions pointer
    menus_expect permissionsState '.opened and .editable and .mode == "0644"' "permissions reads actual file mode"
    menus_shot "$preset-permissions"
    menus_control permissionsState 'Owner execute'
    menus_expect permissionsState '.mode == "0744"' "permission checkbox toggles one bit"
    key -k space >/dev/null
    menus_expect permissionsState '.mode == "0644"' "Space toggles focused permission checkbox"
    menus_control permissionsState Octal
    key -M ctrl -k a -m ctrl 999 >/dev/null
    menus_expect permissionsState '.mode == "999" and any(.controls[]; .name == "Apply" and (.enabled | not))' "invalid octal disables Apply"
    key -k Escape >/dev/null
    menus_expect permissionsState '.opened | not' "permissions Escape cancels"
    [[ "$(stat -c %a "$menu_dir/$name")" == 644 ]] || fail "menus: cancelled permissions changed disk mode"
    menus_file_menu "$name" key
    menus_choose permissions
    menus_expect permissionsState '.opened and .editable' "permissions reopens"
    menus_control permissionsState Octal
    key -M ctrl -k a -m ctrl 640 -k Return >/dev/null
    menus_expect permissionsState 'any(.controls[]; .name == "Apply" and .focused)' "valid octal Enter focuses Apply"
    menus_guard "$menu_dir/$name"
    key -k space >/dev/null
    menus_expect permissionsState '.opened | not' "Space applies mode"
    actual=$(stat -c %a "$menu_dir/$name")
    [[ "$actual" == 640 ]] || fail "menus: mode is $actual after Apply, expected 640"
    menus_guard "$menu_dir/$name"
    chmod 644 "$menu_dir/$name" || fail "menus: could not restore fixture mode"
}

menus_launcher_fixture() {
    local real_gio
    real_gio=$(command -v gio) || fail "menus: GIO is required for the real application registry query"
    menus_guard "$menu_box/bin/gio"
    cat > "$menu_box/bin/gio" <<'SH'
#!/usr/bin/env bash
set -eu
box=${FLEA_MENUS_BOX:?}
[[ "$box" == /* && -f "$box/.flea-test-sandbox" ]] || exit 90
case "${1:-}" in
  info) exec "$FLEA_MENUS_GIO" "$@" ;;
  mime) [[ $# == 2 ]] || exit 91; exec "$FLEA_MENUS_GIO" "$@" ;;
  mount) [[ $# == 2 && "$2" == -l ]] || exit 92; exec "$FLEA_MENUS_GIO" "$@" ;;
  launch)
    [[ $# == 3 && "$2" == "$box/data/applications/"* && "$3" == "$box/list/"* ]] || exit 93
    [[ ! -L "$box/launcher.pid" && ! -L "$box/launcher-mode" ]] || exit 94
    printf '%s\n' "$$" > "$box/launcher.pid"
    if [[ "$(cat "$box/launcher-mode")" == block ]]; then read -r release < "$box/launcher-gate"; fi
    exit 23 ;;
esac
exit 95
SH
    chmod +x "$menu_box/bin/gio"
    printf '[Desktop Entry]\nType=Application\nName=Flea fixture viewer\nExec=/usr/bin/false %%f\nMimeType=text/plain;\n' > "$menu_box/data/applications/flea-menu-fixture.desktop"
    printf '[Default Applications]\ntext/plain=flea-menu-fixture.desktop;\n[Added Associations]\ntext/plain=flea-menu-fixture.desktop;\n' > "$menu_box/config/mimeapps.list"
    printf 'fail\n' > "$menu_box/launcher-mode"
    mkfifo "$menu_box/launcher-gate" || fail "menus: cannot create cancellation fixture gate"
    export FLEA_MENUS_BOX="$menu_box" FLEA_MENUS_GIO="$real_gio" PATH="$menu_box/bin:$PATH"
}

menus_open_with() {
    local state target cursor count step pid deadline
    menus_file_menu a.txt
    menus_choose openWith
    menus_expect menuDialogState '.opened and (.busy | not) and any(.applications[]; .id == "flea-menu-fixture.desktop")' "Open With queries the real fixture registry"
    state=$(ipc menuDialogState)
    target=$(jq -r '.applications | to_entries[] | select(.value.id == "flea-menu-fixture.desktop") | .key' <<< "$state")
    count=$(jq -r '.applications | length' <<< "$state")
    for ((step = 0; step <= count; step++)); do
        cursor=$(ipc menuDialogState | jq -r .cursor)
        [[ "$cursor" == "$target" ]] && break
        if (( cursor < target )); then key -k Down >/dev/null; else key -k Up >/dev/null; fi
    done
    [[ "$cursor" == "$target" ]] || fail "menus: cannot focus the fixture viewer"
    key -k Return >/dev/null
    menus_expect menuDialogState '.opened and (.busy | not) and (.error | contains("23"))' "launcher failure reaches live dialog"
    key -k Escape >/dev/null
    menus_guard "$menu_box/launcher.pid"
    rm -f -- "$menu_box/launcher.pid"
    printf 'block\n' > "$menu_box/launcher-mode"
    menus_file_menu a.txt
    menus_choose openWith
    menus_expect menuDialogState '.opened and (.busy | not) and .applications[0].id == "flea-menu-fixture.desktop"' "fixture viewer retains registry priority"
    key -k Return >/dev/null
    menus_expect menuDialogState '.busy and .committing and any(.controls[]; .name == "Cancel" and .enabled)' "Cancel remains available while launcher waits"
    deadline=$((SECONDS + 15))
    while [[ ! -s "$menu_box/launcher.pid" ]] && (( SECONDS < deadline )); do sleep 0.05; done
    [[ -s "$menu_box/launcher.pid" ]] || fail "menus: owned launcher never started"
    pid=$(cat "$menu_box/launcher.pid")
    menus_control menuDialogState Cancel
    menus_expect menuDialogState '.opened | not' "pointer Cancel closes launching Open With"
    deadline=$((SECONDS + 15))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.05; done
    kill -0 "$pid" 2>/dev/null && fail "menus: cancelled owned launcher remains alive"
}

case_menuscoverage() (
    local menu_box="$fixture_root/menus" menu_dir="$fixture_root/menus/list" menus_checks=0
    local preset state before target token index cx cy wx wy ww wh control
    sandbox_scratch "$menu_box"
    : > "$menu_box/.flea-test-sandbox"
    for target in list state config cache data bin data/applications; do
        menus_guard "$menu_box/$target"
        mkdir -p "$menu_box/$target" || fail "menus: cannot create $target fixture"
    done
    menus_guard "$menu_dir/a.txt"
    printf 'alpha\n' > "$menu_dir/a.txt"
    printf 'beta\n' > "$menu_dir/b.txt"
    mkdir "$menu_dir/folder"
    printf 'child\n' > "$menu_dir/folder/child.txt"
    ln -s a.txt "$menu_dir/link"
    export XDG_STATE_HOME="$menu_box/state" XDG_CONFIG_HOME="$menu_box/config" XDG_DATA_HOME="$menu_box/data" XDG_CACHE_HOME="$menu_box/cache"
    menus_launcher_fixture
    for preset in default vim mac windows; do
        "$flea_bin" --ui-state "{\"view\":\"list\",\"keys\":\"$preset\",\"menu\":{\"hidden\":[]}}" >/dev/null || fail "menus: fixture settings failed"
        launch "$menu_dir"
        wait_listing 4
        menus_file_menu a.txt menu-key
        menus_expect menuState '.entries as $entries | ["open","cut","copy","paste","duplicate","rename","trash","deletePermanently","openWith","openTerminal","moveTo","copyTo","properties","permissions","copypath","toggleHidden"] | all(.[]; . as $action | any($entries[]; .action == $action))' "full applicable plain-file inventory"
        menus_expect menuState 'any(.entries[]; .action == "paste" and .disabled)' "Paste remains visible with empty clipboard"
        before=$(ipc listContentY)
        menus_seek properties
        menus_shot "$preset-file-menu"
        menus_choose properties pointer
        menus_expect menuDialogState '.opened and .facts.ok and .facts.kind == "File"' "Properties consumes captured file identity"
        [[ "$(ipc listContentY)" == "$before" ]] || fail "menus: menu traversal scrolled the covered listing"
        key -k Tab >/dev/null
        menus_expect menuDialogState 'any(.controls[]; .name == "Cancel" and .focused)' "Properties contains Tab focus"
        key -k Escape >/dev/null
        menus_confirmation a.txt "$preset"
        menus_permissions a.txt "$preset"
        menus_file_menu link
        menus_expect menuState 'any(.entries[]; .action == "permissions" and .disabled and .hint == "Symlink target not changed")' "symlink permissions stays disabled"
        key -k Escape >/dev/null
        click_row "$(row_index_of a.txt)" left
        click_row "$(row_index_of b.txt)" left --mods ctrl
        click_row "$(row_index_of a.txt)" right
        menus_expect menuState '.entries as $entries | ["rename","duplicate","openWith","properties","permissions"] | all(.[]; . as $action | any($entries[]; .action == $action and .disabled))' "multi-selection eligibility"
        key -k Escape >/dev/null
        key -k Escape >/dev/null
        kill_flea
    done
    "$flea_bin" --ui-state '{"keys":"default","menu":{"hidden":[]}}' >/dev/null || fail "menus: default fixture preset failed"
    launch "$menu_dir"
    wait_listing 4
    menus_open_with
    menus_file_menu folder
    menus_choose deletePermanently
    menus_expect menuDialogState '.confirmation.opened and .confirmation.count == 1' "directory deletion snapshots one root"
    token=$(ipc menuDialogState | jq -r .confirmation.token)
    menus_guard "$menu_dir/folder/arrived.txt"
    printf 'arrived after confirmation\n' > "$menu_dir/folder/arrived.txt"
    menus_expect menuDialogState ".confirmation.opened and .confirmation.token != $token and (.confirmation.destructiveFocus | not)" "nested arrival replaces stale confirmation"
    menus_guard "$menu_dir/folder"
    key -k Tab -k Return >/dev/null
    menus_expect menuDialogState '(.opened | not) and (.committing | not)' "confirmed permanent deletion completes"
    [[ ! -e "$menu_dir/folder" ]] || fail "menus: freshly confirmed directory was not deleted"
    [[ "$(cat "$menu_dir/a.txt")" == alpha && "$(cat "$menu_dir/b.txt")" == beta ]] || fail "menus: deletion widened outside its confirmation"
    menus_shot deletion-completed
    printf 'MENUS_NATIVE_CHECKS=%s\n' "$menus_checks"
    printf 'MENUS_UNVERIFIED new-file/new-folder, clipboard transfers, duplicate, rename, archive/convert, provider states, hidden-row persistence, work-area/scale matrix, partial deletion failure, directory Permissions scope, concurrent-window replacement\n'
    kill_flea
)
