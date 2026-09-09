#!/usr/bin/env bash
# Sourced by ui.sh; pointer drags use the real relative-uinput path characterized by tests/drag.sh.
# shellcheck disable=SC2034,SC2154 # ui.sh and the case supply shared ownership and evidence state.

marquee_guard() {
    local target="$1" canonical
    [[ -n "$target" && "$target" == /* && -f "$marquee_box/.flea-test-sandbox" ]] || fail "marquee: invalid sandbox target"
    canonical=$(realpath -m -- "$target") || fail "marquee: target resolution failed"
    [[ "$canonical" == "$marquee_box/"* && "$canonical" != "$marquee_box" ]] || fail "marquee: target escaped own sandbox"
}

marquee_expect() {
    local observer="$1" expected="$2" label="$3" seen deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        seen=$(ipc "$observer") || fail "marquee: observer failed: $observer"
        if [[ "$seen" == "$expected" ]]; then
            marquee_checks=$((marquee_checks + 1))
            printf 'MARQUEE_CHECK %s %s observed=%q\n' "$marquee_checks" "$label" "$seen"
            return
        fi
        sleep 0.05
    done
    fail "marquee: $label: expected [$expected], observed [$seen]"
}

marquee_state() {
    local expression="$1" label="$2" seen deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        seen=$(ipc selectionBandState) || fail "marquee: band observation failed"
        if jq -e "$expression" <<< "$seen" >/dev/null; then
            marquee_checks=$((marquee_checks + 1))
            printf 'MARQUEE_CHECK %s %s state=%s\n' "$marquee_checks" "$label" "$seen"
            return
        fi
        sleep 0.05
    done
    fail "marquee: $label: $seen"
}

marquee_glide() {
    local tx="$1" ty="$2" cx cy dx dy step
    [[ "$tx $ty" =~ ^-?[0-9]+\ -?[0-9]+$ ]] || fail "marquee: invalid target coordinates"
    assert_focus
    # libinput accelerates relative motion; re-read the actual position after every step.
    for ((step = 0; step < 16; step++)); do
        read -r cx cy <<< "$(hyprctl cursorpos | tr -d ',')"
        [[ "$cx $cy" =~ ^-?[0-9]+\ -?[0-9]+$ ]] || fail "marquee: actual pointer coordinates unavailable"
        dx=$((tx - cx)); dy=$((ty - cy))
        if (( ${dx#-} <= 4 && ${dy#-} <= 4 )); then return; fi
        ydotool mousemove -x "$((dx / 2))" -y "$((dy / 2))" >/dev/null 2>&1 \
            || fail "marquee: relative pointer motion failed"
        sleep 0.05
    done
    fail "marquee: pointer did not reach $tx,$ty; observed $cx,$cy"
}

marquee_release() {
    if [[ "$marquee_button_down" == true ]]; then
        ydotool click 0x80 >/dev/null 2>&1 || fail "marquee: pointer release failed"
        marquee_button_down=false
    fi
    if [[ "$marquee_ctrl_down" == true ]]; then
        ydotool key 29:0 >/dev/null 2>&1 || fail "marquee: Ctrl release failed"
        marquee_ctrl_down=false
    fi
}

marquee_press() {
    local cx="$1" cy="$2" ctrl="${3:-false}" wx wy ww wh
    read -r wx wy ww wh < <(window_box) || fail "marquee: owned window is unavailable"
    (( cx >= 0 && cy >= 0 && cx < ww && cy < wh )) || fail "marquee: press is outside the owned client"
    marquee_glide "$((wx + cx))" "$((wy + cy))"
    if [[ "$ctrl" == true ]]; then
        ydotool key 29:1 >/dev/null 2>&1 || fail "marquee: Ctrl press failed"
        marquee_ctrl_down=true
    fi
    ydotool click 0x40 >/dev/null 2>&1 || fail "marquee: pointer press failed"
    marquee_button_down=true
}

marquee_to() {
    local wx wy ww wh
    read -r wx wy ww wh < <(window_box) || fail "marquee: owned window moved out of scope"
    marquee_glide "$((wx + $1))" "$((wy + $2))"
}

marquee_begin_below() {
    local last="$1" ctrl="${2:-false}" last_only="${3:-false}" ax ay aw ah rx ry rw rh cx cy
    read -r ax ay aw ah <<< "$(ipc listAreaRect)"
    read -r rx ry rw rh <<< "$(ipc rowRect "$last")"
    [[ "$ax $ay $aw $ah $rx $ry $rw $rh" =~ ^[0-9]+(\ [0-9]+){7}$ ]] || fail "marquee: listing/row geometry unavailable"
    if [[ "$(ipc viewMode)" == columns ]]; then ax=$rx; aw=$rw; fi
    (( rh > 0 && ry + rh + 8 < ay + ah )) || fail "marquee: no empty space below the last row"
    cx=$((ax + aw - 12)); cy=$(((ry + rh + ay + ah) / 2))
    [[ "$last_only" == true ]] && cx=$((rx + rw * 3 / 4))
    marquee_press "$cx" "$cy" "$ctrl"
    marquee_state '.tracking and (.active | not)' "empty-space press owns a pending band"
}

marquee_four() {
    local label="$1" cx cy
    marquee_begin_below 3
    read -r cx cy <<< "$(ipc rowCentre 0)"
    marquee_to "$cx" "$cy"
    marquee_state '.active and .tracking' "$label has a live rubber band"
    marquee_expect selectedIndices '0,1,2,3' "$label marks four intersections before release"
    local footer
    footer=$(ipc statusFooterState) || fail "marquee: footer observation failed"
    jq -e '.selected == 4 and (.counts | contains("4 selected"))' <<< "$footer" >/dev/null \
        || fail "marquee: four live marks do not reach the footer: $footer"
    shot "marquee-$label-four-held"
    printf 'MARQUEE_SHOT_REQUIRES_INSPECTION %s\n' "$label-four-held"
}

marquee_interactions() {
    local label="$1" cx cy before
    click_row 0 left
    marquee_expect selectedIndices 0 "$label plain click marks one row"
    click_row 2 left --mods ctrl
    marquee_expect selectedIndices '0,2' "$label Ctrl-click preserves another mark"
    click_row 2 left --mods ctrl
    marquee_expect selectedIndices 0 "$label Ctrl-click toggles its mark off"
    click_row 3 left --mods shift
    marquee_expect selectedIndices '2,3' "$label Shift-click extends from cursor anchor"
    click_row 1 left
    marquee_four "$label"
    key -k Escape >/dev/null || fail "marquee: Escape delivery failed"
    marquee_expect selectedIndices 1 "$label Escape restores prior marks while pressed"
    marquee_expect cursor 1 "$label Escape restores prior cursor"
    marquee_state '(.tracking | not) and (.active | not)' "$label Escape releases band ownership"
    marquee_release
    marquee_expect selectedIndices 1 "$label physical release does not recommit a cancelled band"
    marquee_four "$label-repeat"
    marquee_release
    marquee_expect selectedIndices '0,1,2,3' "$label release retains four marks"
    marquee_expect cursor 0 "$label upward release chooses last entering row"
    click_row 0 left
    marquee_begin_below 3 true true
    read -r cx cy <<< "$(ipc rowCentre 3)"
    marquee_to "$cx" "$cy"
    marquee_expect selectedIndices '0,3' "$label Ctrl at press adds the band to existing marks"
    key -k Escape >/dev/null || fail "marquee: Ctrl-band Escape delivery failed"
    marquee_expect selectedIndices 0 "$label Escape cancels while Ctrl remains held"
    marquee_release
    marquee_begin_below 3 true true
    marquee_to "$cx" "$cy"
    marquee_release
    marquee_expect selectedIndices '0,3' "$label Ctrl band retains its union on release"
    printf 'MARQUEE_INTERACTIONS %s complete\n' "$label"
}

marquee_scroll() {
    local dir="$marquee_box/scroll" i ax ay aw ah cx cy before after
    mkdir "$dir" || fail "marquee: scroll fixture creation failed"
    for i in $(seq -w 0 39); do printf 'scroll %s\n' "$i" > "$dir/file-$i.txt" || fail "marquee: scroll file creation failed"; done
    printf 'filtered out\n' > "$dir/other.txt" || fail "marquee: excluded file creation failed"
    seed_ui_state "$marquee_box/scroll-state" '{"keys":"default","view":"list","preview":{"thumbnails":"off"}}'
    HOME="$marquee_home" launch "$dir"
    wait_listing 41
    permissions_viewport 880 620
    key / file -k Return -k End >/dev/null || fail "marquee: filter/End delivery failed"
    marquee_expect drawnCount 40 "scroll fixture filter retains forty rows"
    read -r cx cy <<< "$(ipc rowCentre 39)"
    marquee_to "$cx" "$cy"
    omarchy-drive scroll down 1 >/dev/null || fail "marquee: footer could not be brought into view"
    marquee_begin_below 39
    read -r ax ay aw ah <<< "$(ipc listAreaRect)"
    marquee_to "$((ax + aw / 4))" "$((ay - 12))"
    marquee_state '.active and .contentY > 0' "top-edge drag starts from the bottom of a long filtered listing"
    before=$(ipc selectionBandState) || fail "marquee: initial autoscroll state unavailable"
    marquee_state ".active and .contentY < $(jq -r .contentY <<< "$before") and .anchor.y == $(jq -r .anchor.y <<< "$before")" \
        "top-edge autoscroll moves content without moving the band origin"
    shot marquee-autoscroll-up-held
    after=$(ipc selectionBandState) || fail "marquee: scrolled state unavailable"
    marquee_to "$((ax + aw / 4))" "$((ay + ah + 12))"
    marquee_state ".active and .contentY > $(jq -r .contentY <<< "$after") and .anchor.y == $(jq -r .anchor.y <<< "$before")" \
        "bottom-edge autoscroll reverses while retaining the band origin"
    key -k Escape >/dev/null || fail "marquee: scrolling-band Escape delivery failed"
    marquee_release
    marquee_expect selectedIndices '' "Escape restores the empty pre-scroll selection"
    marquee_expect cursor 39 "Escape restores the pre-scroll cursor"
    kill_flea
}

marquee_targets() {
    local mode dir i state deadline cx cy ax ay aw ah
    for mode in list grid; do
        dir="$marquee_box/keyboard-$mode"
        marquee_guard "$dir"
        mkdir "$dir" || fail "marquee: keyboard fixture creation failed"
        for i in 0 1 2 3; do printf 'keyboard %s\n' "$i" > "$dir/file-$i.txt" || fail "marquee: keyboard file creation failed"; done
        seed_ui_state "$marquee_box/keyboard-$mode-state" '{"keys":"default","view":"list","preview":{"thumbnails":"off"}}'
        HOME="$marquee_home" launch "$dir"
        wait_listing 4
        permissions_viewport 880 620
        click_chrome "$mode"
        marquee_expect viewMode "$mode" "keyboard target fixture enters $mode"
        if [[ "$mode" == list ]]; then
            read -r cx cy <<< "$(ipc rowCentre 0)"
            marquee_press "$cx" "$cy"
            read -r ax ay aw ah <<< "$(ipc listAreaRect)"
            marquee_to "$((ax + aw / 2))" "$((ay + ah - 12))"
            marquee_state '(.tracking | not) and (.active | not)' "a row press keeps the existing file drag and cannot start a band"
            key -k Escape >/dev/null || fail "marquee: file-drag cancellation failed"
            marquee_release
            wait_listing 4
        fi
        marquee_four "keyboard-$mode"
        marquee_release
        key y >/dev/null || fail "marquee: copy key delivery failed"
        deadline=$((SECONDS + 15))
        while (( SECONDS < deadline )); do
            state=$(ipc keyDeliveryState) || fail "marquee: clipboard observation failed"
            if jq -e --arg dir "$dir" '.clipboard.paths == [$dir + "/file-0.txt", $dir + "/file-1.txt", $dir + "/file-2.txt", $dir + "/file-3.txt"]' <<< "$state" >/dev/null; then break; fi
            sleep 0.05
        done
        jq -e --arg dir "$dir" '.clipboard.paths == [$dir + "/file-0.txt", $dir + "/file-1.txt", $dir + "/file-2.txt", $dir + "/file-3.txt"]' <<< "$state" >/dev/null \
            || fail "marquee: y did not copy the banded set: $state"
        marquee_expect selectedIndices '0,1,2,3' "$mode copying retains the shared band marks"
        marquee_guard "$(ipc path)"
        [[ "$(ipc path)" == "$dir" ]] || fail "marquee: refusing deletion outside the current owned listing"
        for i in 0 1 2 3; do marquee_guard "$dir/file-$i.txt"; done
        marquee_guard "$XDG_DATA_HOME/Trash"
        key dd >/dev/null || fail "marquee: protected trash pair delivery failed"
        wait_listing 0
        for i in 0 1 2 3; do [[ ! -e "$dir/file-$i.txt" ]] || fail "marquee: dd did not trash every banded file"; done
        key z >/dev/null || fail "marquee: undo key delivery failed"
        wait_listing 4
        for i in 0 1 2 3; do
            [[ "$(cat "$dir/file-$i.txt")" == "keyboard $i" ]] || fail "marquee: undo did not restore exact banded contents"
        done
        printf 'MARQUEE_KEYBOARD %s copy=4 trash=4 undo=4\n' "$mode"
        kill_flea
    done
}

case_marquee() (
    local marquee_checks=0 marquee_button_down=false marquee_ctrl_down=false preset mode i state other
    local marquee_box marquee_home dir
    marquee_box=$(mktemp -d "$fixture_root/marquee.XXXXXXXX") || fail "marquee: sandbox creation failed"
    printf 'native mouse-selection fixture\n' > "$marquee_box/.flea-test-sandbox"
    marquee_home="$marquee_box/home"
    fixture_home_make "$marquee_home"
    export XDG_CONFIG_HOME="$marquee_home/.config" XDG_DATA_HOME="$marquee_box/data" XDG_CACHE_HOME="$marquee_box/cache"
    export YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket"
    mkdir "$XDG_DATA_HOME" "$XDG_CACHE_HOME" || fail "marquee: private state creation failed"
    trap 'marquee_release; kill_flea' EXIT
    for preset in default vim mac windows; do
        dir="$marquee_box/$preset"
        mkdir "$dir" || fail "marquee: listing creation failed"
        for i in 0 1 2 3; do printf 'mouse selection %s\n' "$i" > "$dir/file-$i.txt" || fail "marquee: file creation failed"; done
        seed_ui_state "$marquee_box/$preset-state" "{\"keys\":\"$preset\",\"view\":\"list\",\"preview\":{\"thumbnails\":\"off\"}}"
        HOME="$marquee_home" launch "$dir"
        wait_listing 4
        permissions_viewport 880 620
        marquee_expect keymapPreset "$preset" "native preset is identified"
        for mode in list grid columns; do
            click_chrome "$mode"
            marquee_expect viewMode "$mode" "native view button selects $mode"
            marquee_interactions "$preset-$mode"
        done
        click_chrome dual
        marquee_interactions "$preset-dual-left"
        other=$(ipc dualState | jq -c '.panes[0].selected') || fail "marquee: left-pane marks unavailable"
        key -k Tab >/dev/null || fail "marquee: dual-pane Tab delivery failed"
        wait_listing 4
        marquee_interactions "$preset-dual-right"
        state=$(ipc dualState) || fail "marquee: dual-pane observation failed"
        jq -e --argjson marks "$other" '.active and .focused == 1 and .panes[0].selected == $marks and .panes[1].selected == [0,3]' <<< "$state" >/dev/null \
            || fail "marquee: mouse marks leaked between dual panes: $state"
        kill_flea
    done
    marquee_scroll
    marquee_targets
    printf 'MARQUEE_NATIVE checks=%s presets=4 views=list,grid,columns,dual-left,dual-right autoscroll=both-directions\n' "$marquee_checks"
)
