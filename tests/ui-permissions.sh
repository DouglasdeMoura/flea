#!/usr/bin/env bash
# Sourced by ui.sh; Permissions changes only marked fixtures through native controls.

permissions_guard() {
    local path="$1" canonical
    [[ -n "$path" && "$path" == /* && -f "$permissions_box/.flea-test-sandbox" ]] \
        || fail "permissions: mutation needs an absolute path and owned marker"
    canonical=$(realpath -m -- "$path") || fail "permissions: mutation path did not resolve"
    [[ "$canonical" == "$permissions_box/"* && "$canonical" != "$permissions_box" ]] \
        || fail "permissions: mutation escaped the owned fixture"
}

permissions_wait() {
    local expression="$1" label="${2:-$1}" state end=$((SECONDS + 20))
    while (( SECONDS < end )); do
        state=$(ipc permissionsState) || fail "permissions: read-only state unavailable"
        if jq -e "$expression" <<< "$state" >/dev/null; then
            permissions_checks=$((permissions_checks + 1))
            printf 'PERMISSIONS_PASS %s expected=%q observed=%s\n' "$label" "$expression" "$state"
            return
        fi
        sleep 0.05
    done
    fail "permissions: $label; last native state: $state"
}

permissions_point() {
    local centre="$1" button="${2:-left}" cx cy wx wy ww wh
    read -r cx cy <<< "$centre"
    [[ "$cx" =~ ^[0-9]+$ && "$cy" =~ ^[0-9]+$ ]] || fail "permissions: native control has no centre"
    read -r wx wy ww wh < <(window_box)
    (( cx < ww && cy < wh )) || fail "permissions: control is outside the actual viewport"
    assert_focus
    omarchy-drive click "$((wx + cx))" "$((wy + cy))" "$button" >/dev/null \
        || fail "permissions: native pointer activation failed"
}

permissions_control() {
    local name="$1" centre
    centre=$(ipc permissionsState | jq -er --arg name "$name" '.controls[] | select(.name == $name and .visible) | .centre') \
        || fail "permissions: no visible $name control"
    permissions_point "$centre"
}

permissions_viewport() {
    local address result wx wy width height end=$((SECONDS + 20))
    address=$(hyprctl clients -j | jq -er --argjson pid "$(flea_pid)" '.[] | select(.pid == $pid) | .address') \
        || fail "permissions: owned window unavailable"
    [[ "$address" =~ ^0x[0-9a-fA-F]+$ ]] || fail "permissions: invalid owned window address"
    omarchy-drive window float "$address" >/dev/null || fail "permissions: owned window could not float"
    result=$(hyprctl dispatch "hl.dsp.window.resize({ x = 1100, y = 800, exact = true, window = \"address:$address\" })") \
        || fail "permissions: compositor resize failed"
    [[ "$result" == ok* ]] || fail "permissions: compositor refused resize: $result"
    omarchy-drive window center "$address" >/dev/null || fail "permissions: owned window could not center"
    while (( SECONDS < end )); do
        read -r wx wy width height < <(window_box)
        [[ "$width" == 1100 && "$height" == 800 ]] && return
        sleep 0.05
    done
    fail "permissions: viewport did not reach 1100x800"
}

permissions_setup() {
    local root
    sandbox_require "$fixture_root"
    permissions_box=$(mktemp -d "$fixture_root/permissions.XXXXXXXX") || fail "permissions: fixture creation failed"
    printf 'native Permissions fixture\n' > "$permissions_box/.flea-test-sandbox"
    [[ "$permissions_box" == "$(realpath -e "$permissions_box")" ]] || fail "permissions: fixture is not canonical"
    permissions_listing="$permissions_box/listing"
    for root in "$permissions_listing" "$permissions_box/data" "$permissions_box/config" "$permissions_box/cache"; do
        permissions_guard "$root"
        mkdir "$root" || fail "permissions: fixture directory creation failed"
    done
    export XDG_DATA_HOME="$permissions_box/data" XDG_CONFIG_HOME="$permissions_box/config" XDG_CACHE_HOME="$permissions_box/cache"
    seed_ui_state "$permissions_box/state" '{"view":"list","keys":"default","preview":{"column":false,"thumbnails":"off"},"menu":{"hidden":[]}}'
    printf 'permission fixture content\n' > "$permissions_listing/notes.md"
    printf 'other fixture content\n' > "$permissions_listing/other.txt"
    printf 'special bit fixture\n' > "$permissions_listing/special.txt"
    printf 'unreadable owned fixture\n' > "$permissions_listing/unreadable.txt"
    mkdir -p "$permissions_listing/site/nested" || fail "permissions: directory fixture failed"
    printf 'child scope canary\n' > "$permissions_listing/site/child.txt"
    printf 'nested scope canary\n' > "$permissions_listing/site/nested/leaf.txt"
    ln -s notes.md "$permissions_listing/link" || fail "permissions: symlink fixture failed"
    permissions_guard "$permissions_listing/notes.md"
    chmod 0644 "$permissions_listing/notes.md" "$permissions_listing/other.txt" "$permissions_listing/special.txt" \
        || fail "permissions: ordinary fixture modes failed"
    chmod 0000 "$permissions_listing/unreadable.txt" || fail "permissions: unreadable fixture mode failed"
    chmod 0755 "$permissions_listing/site" || fail "permissions: directory fixture mode failed"
    chmod 0711 "$permissions_listing/site/nested" || fail "permissions: nested directory fixture mode failed"
    chmod 0640 "$permissions_listing/site/child.txt" || fail "permissions: child fixture mode failed"
    chmod 0600 "$permissions_listing/site/nested/leaf.txt" || fail "permissions: nested fixture mode failed"
    launch "$permissions_listing"
    wait_listing 6
    permissions_viewport
}

permissions_open() {
    local name="$1" entry="${2:-pointer}" row target
    wait_path "$permissions_listing"
    row=$(row_index_of "$name")
    if [[ "$entry" == pointer ]]; then click_row "$row" right
    else click_row "$row" left; key m >/dev/null; fi
    ipc contextMenuModel | jq -e 'any(.[]; .action == "permissions" and .disabled != true)' >/dev/null \
        || fail "permissions: single-item menu entry is missing or disabled"
    target=$(menu_row_index Permissions) || fail "permissions: no native Permissions row"
    if [[ "$entry" == pointer ]]; then permissions_point "$(ipc contextMenuRowCentre "$target")"
    else menu_seek Permissions; key -k Return >/dev/null; fi
    permissions_wait '.opened and (.busy == false)' "native $entry Permissions entry for $name"
    target=$(jq -cn --arg path "$permissions_listing/$name" '$path')
    permissions_wait ".path == $target" 'dialog reviews the selected fixture path'
}

permissions_mode() {
    local mode="$1" value
    [[ "$mode" =~ ^0?[0-7]{3}$ ]] || fail "permissions: invalid test mode"
    value=$((8#$mode))
    permissions_wait ".mode == \"$mode\" and [.controls[] | select(.bit != null) | .bit] == [256,128,64,32,16,8,4,2,1] and all(.controls[] | select(.bit != null); .checked == ((($value / .bit | floor) % 2) == 1))" 'octal text and all nine checkboxes agree'
}

permissions_octal() {
    local text="$1" quoted
    permissions_control Octal
    permissions_wait 'any(.controls[]; .name == "Octal" and .focused and .enabled)' 'octal field owns keyboard'
    key -M ctrl -k a -m ctrl -k BackSpace >/dev/null
    [[ -z "$text" ]] || key "$text" >/dev/null
    quoted=$(jq -cn --arg text "$text" '$text')
    permissions_wait ".mode == $quoted" 'typed mode remains visible'
}

permissions_apply() {
    local path="$1" mode="$2" entry="${3:-pointer}"
    permissions_guard "$path"
    permissions_wait '.opened and .editable and (.busy == false) and any(.controls[]; .name == "Apply" and .enabled)' 'Apply is eligible on the held fixture'
    [[ "$(ipc permissionsState | jq -r '.path')" == "$path" ]] || fail "permissions: Apply targets a different item"
    if [[ "$entry" == pointer ]]; then permissions_control Apply
    else
        permissions_wait 'any(.controls[]; .name == "Apply" and .focused)' 'Apply owns keyboard'
        key -k Return >/dev/null
    fi
    permissions_wait '(.opened == false)' 'successful Apply closes Permissions'
    [[ "$(stat -c '%a' "$path")" == "$mode" ]] || fail "permissions: applied filesystem mode differs from $mode"
    [[ "$(ipc focusView)" == list ]] || fail "permissions: Apply did not restore listing focus"
}

case_permissionsbaseline() { case_permissions baseline; }
case_permissionsfile() { case_permissions file; }

case_permissions() {
    local permissions_box permissions_listing permissions_checks=0 permissions_group="${1:-file}"
    local bit name value wanted invalid before grid row_count=0
    permissions_setup
    permissions_open notes.md
    shot "permissions-$permissions_group-file-baseline"
    printf 'PERMISSIONS_SPECIMEN group=%s viewport=%q state=%s\n' "$permissions_group" "$(window_box)" "$(ipc permissionsState)"
    if [[ "$permissions_group" == baseline ]]; then
        key -k Escape >/dev/null
        permissions_wait '(.opened == false)'
        kill_flea
        return
    fi
    permissions_wait '.facts.ok and (.facts.directory == false) and .editable and .mode == "0644" and any(.controls[]; .name == "Cancel" and .focused)' 'owned file opens with Cancel focused'
    permissions_wait '.displayedSummary | contains("Requested mode 0644") and contains("Scope this item only") and contains("ownership unchanged")' 'file summary states exact effect'
    permissions_mode 0644
    before=$(stat -c '%u:%g:%a' "$permissions_listing/notes.md")
    grid=$(ipc permissionsState | jq -r '.controls[] | select(.bit != null) | [.name, .bit] | @tsv') \
        || fail "permissions: checkbox inventory unavailable"
    # Sample control row: "Owner read<TAB>256".
    while IFS=$'\t' read -r name bit; do
        permissions_control "$name"
        value=$((8#0644 ^ bit))
        printf -v wanted '%04o' "$value"
        permissions_mode "$wanted"
        key -k space >/dev/null
        permissions_mode 0644
        row_count=$((row_count + 1))
    done <<< "$grid"
    [[ "$row_count" == 9 ]] || fail "permissions: did not activate all nine checkboxes"
    [[ "$(stat -c '%u:%g:%a' "$permissions_listing/notes.md")" == "$before" ]] || fail "permissions: checkbox editing wrote before Apply"
    for invalid in '' 64 888 4755 ' 644' '0644 ' 00000 -1; do
        permissions_octal "$invalid"
        permissions_wait '.editable and all(.controls[] | select(.name == "Apply"); .enabled == false) and (.displayedError | contains("Enter three octal digits"))' 'invalid mode stays visible and Apply is disabled'
        permissions_control Apply
        permissions_wait '.opened and (.busy == false)' 'disabled Apply does not commit'
        [[ "$(stat -c '%u:%g:%a' "$permissions_listing/notes.md")" == "$before" ]] || fail "permissions: invalid mode changed the file"
    done
    permissions_octal 600
    permissions_mode 600
    key -k Return >/dev/null
    permissions_wait '.opened and any(.controls[]; .name == "Apply" and .focused)' 'Return from octal focuses Apply without committing'
    [[ "$(stat -c '%u:%g:%a' "$permissions_listing/notes.md")" == "$before" ]] || fail "permissions: first octal Return committed early"
    permissions_apply "$permissions_listing/notes.md" 600 keyboard
    [[ "$(cat "$permissions_listing/notes.md")" == 'permission fixture content' ]] || fail "permissions: mode write changed contents"
    [[ "$(stat -c '%u:%g' "$permissions_listing/notes.md")" == "${before%:*}" ]] || fail "permissions: mode write changed ownership"
    permissions_open notes.md keyboard
    permissions_mode 0600
    shot permissions-file-applied
    permissions_control Cancel
    permissions_wait '(.opened == false)'
    printf 'PERMISSIONS_NATIVE group=%s checks=%s; screenshots require inspection.\n' "$permissions_group" "$permissions_checks"
    kill_flea
}
