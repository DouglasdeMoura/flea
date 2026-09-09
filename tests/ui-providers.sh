#!/usr/bin/env bash
# Sourced by ui.sh; provider doubles record calls, and all application changes enter through native input.
# shellcheck disable=SC2154 # ui.sh supplies the candidate paths and fixture root.
providers_write() {
    menus_guard "$menu_box/$1"
    printf '%s' "$2" > "$menu_box/$1" || fail "providers: cannot write $1"
}

providers_expect() {
    local expression="$1" label="$2" observed deadline=$((SECONDS + 25))
    while (( SECONDS < deadline )); do
        observed=$(ipc providerState) || fail "providers: state observer failed"
        if jq -e "$expression" <<< "$observed" >/dev/null; then
            menus_checks=$((menus_checks + 1))
            printf 'PROVIDERS_CHECK %s %s state=%s\n' "$menus_checks" "$label" "$observed"
            return
        fi
        sleep 0.05
    done
    fail "providers: $label: $observed"
}

providers_seek() {
    local action="$1" state cursor target step index
    local -a events=()
    state=$(ipc menuState) || fail "providers: menu observer failed"
    target=$(jq -er --arg action "$action" '.entries | to_entries[] | select(.value.action == $action and (.value.disabled | not)) | .key' <<< "$state") \
        || fail "providers: unavailable action $action: $state"
    cursor=$(jq -r .cursor <<< "$state")
    if (( target > cursor )); then step=1; else step=-1; fi
    for ((index = cursor + step; index != target + step; index += step)); do
        if jq -e --argjson index "$index" '.entries[$index] | (.separator | not) and (.disabled | not)' <<< "$state" >/dev/null; then
            if (( step > 0 )); then events+=(-k Down); else events+=(-k Up); fi
        fi
    done
    if (( ${#events[@]} )); then key "${events[@]}" >/dev/null || fail "providers: menu keys failed"; fi
    menus_expect menuState ".entries[.cursor].action == \"$action\"" "keyboard reaches $action"
}

providers_calls() {
    jq -s --arg helper "$1" '[.[] | select(.helper == $helper)] | length' "$menu_box/calls.jsonl"
}

providers_call() {
    local helper="$1" expected="$2" before="$3" seen deadline=$((SECONDS + 15))
    while (( SECONDS < deadline )); do
        seen=$(jq -sc --arg helper "$helper" '[.[] | select(.helper == $helper)]' "$menu_box/calls.jsonl") \
            || fail "providers: invalid invocation record"
        if jq -e --argjson before "$before" --argjson expected "$expected" \
            'length == ($before + 1) and .[-1].args == $expected' <<< "$seen" >/dev/null; then
            menus_checks=$((menus_checks + 1))
            printf 'PROVIDERS_CALL %s %s\n' "$helper" "$seen"
            return
        fi
        sleep 0.05
    done
    fail "providers: expected one $helper call with $expected after $before calls: $seen"
}

providers_install() {
    local name="$1" installed="$2" source destination
    if [[ "$installed" == yes ]]; then source="$menu_box/absent/$name"; destination="$menu_box/bin/$name"
    else source="$menu_box/bin/$name"; destination="$menu_box/absent/$name"; fi
    if [[ -e "$destination" ]]; then return; fi
    menus_guard "$source"
    menus_guard "$destination"
    [[ -e "$source" ]] || fail "providers: missing owned helper $source"
    mv -- "$source" "$destination" || fail "providers: cannot change fixture installation $name"
}

providers_mode() {
    providers_write "$1-mode" "$2"
    providers_write "$1-output" "$3"
    providers_write "$1-error" "${4:-}"
    providers_write "$1-exit" "${5:-0}"
}

providers_release() {
    local provider="$1"
    menus_guard "$menu_box/$provider-release"
    [[ -p "$menu_box/$provider-release" && ! -L "$menu_box/$provider-release" ]] || fail "providers: release is not an owned FIFO"
    if [[ "$provider" == tailscale ]]; then printf 'release\n' >&"$taildrop_fd" || fail 'providers: Tailscale gate write failed'
    elif [[ "$provider" == dropbox-cli ]]; then printf 'release\n' >&"$dropbox_fd" || fail 'providers: Dropbox gate write failed'
    else fail "providers: unknown release $provider"; fi
}

providers_close() {
    key -k Escape >/dev/null || fail "providers: menu Escape failed"
    menus_expect menuState '(.opened | not) and (.submenu | not)' 'Escape closes provider menu'
    providers_expect '.listFocus' 'provider menu restores listing focus'
}

providers_ready() {
    providers_mode tailscale ready "$provider_ready"
    providers_mode dropbox-cli ready 'Up to date'
    providers_write home/.dropbox/info.json "$(jq -cn --arg path "$menu_box/Dropbox" '{personal:{path:$path}}')"
}

providers_open() {
    menus_file_menu "${1:-b-cursor.txt}" "${2:-key}"
    providers_expect '(.refreshing | not) and (.taildrop.checking | not) and (.dropbox.checking | not)' 'provider entry refresh finishes'
}

providers_disabled() {
    local action="$1" reason="$2" state target before
    menus_expect menuState "any(.entries[]; .action == \"$action\" and .disabled and (.hint | contains(\"$reason\")))" "$action names $reason"
    state=$(ipc menuState)
    target=$(jq -er --arg action "$action" '.entries | to_entries[] | select(.value.action == $action) | .key' <<< "$state")
    before=$(providers_calls omarchy-tailscale-send)
    providers_seek copy
    menus_point "$(ipc contextMenuRowCentre "$target")"
    menus_expect menuState '.opened and .entries[.cursor].action == "copy"' 'disabled provider pointer activation preserves the current action'
    menus_equal 'disabled row sends nothing' "$before" "$(providers_calls omarchy-tailscale-send)"
}

providers_geometry() {
    local state x y width height area_x area_y area_width area_height
    state=$(ipc menuState)
    read -r x y width height <<< "$(jq -r .frame <<< "$state")"
    read -r area_x area_y area_width area_height <<< "$(jq -r '.workArea | [.x,.y,.width,.height] | join(" ")' <<< "$state")"
    jq -en --argjson x "$x" --argjson y "$y" --argjson width "$width" --argjson height "$height" \
        --argjson ax "$area_x" --argjson ay "$area_y" --argjson aw "$area_width" --argjson ah "$area_height" \
        '$width > 0 and $height > 0 and $x >= $ax and $y >= $ay and ($x+$width) <= ($ax+$aw) and ($y+$height) <= ($ay+$ah)' >/dev/null \
        || fail "providers: refreshed menu escaped work area: $state"
    providers_expect '.menuFocus' 'provider refresh retains menu keyboard focus'
    printf 'PROVIDERS_GEOMETRY %s\n' "$state"
}

providers_fixture() {
    local part file name target
    local -a parts
    sandbox_scratch "$menu_box"
    : > "$menu_box/.flea-test-sandbox" || fail 'providers: sandbox marker write failed'
    for target in list Dropbox retired bin absent doubles state config cache data; do
        menus_guard "$menu_box/$target"
        mkdir -p "$menu_box/$target" || fail "providers: fixture directory $target failed"
    done
    fixture_home_make "$menu_box/home"
    menus_guard "$menu_box/home/.dropbox"
    mkdir "$menu_box/home/.dropbox" || fail 'providers: private account directory failed'
    for target in list/a-marked.txt list/b-cursor.txt Dropbox/a-marked.txt Dropbox/b-cursor.txt; do
        providers_write "$target" "$target original"
    done
    providers_write calls.jsonl ''
    for name in tailscale dropbox-cli; do
        menus_guard "$menu_box/$name-release"
        mkfifo "$menu_box/$name-release" || fail "providers: cannot make $name gate"
    done
    exec {taildrop_fd}<>"$menu_box/tailscale-release" || fail 'providers: cannot open Tailscale gate'
    exec {dropbox_fd}<>"$menu_box/dropbox-cli-release" || fail 'providers: cannot open Dropbox gate'
    # Excluding every real provider prevents removal of a double from falling through to GM's account.
    IFS=: read -r -a parts <<< "$PATH"
    for part in "${parts[@]}"; do
        [[ -d "$part" ]] || continue
        for file in "$part"/*; do
            [[ -f "$file" && -x "$file" ]] || continue
            name=${file##*/}
            case "$name" in tailscale|omarchy-tailscale-send|dropbox-cli|wl-copy) continue ;; esac
            [[ ! -e "$menu_box/bin/$name" ]] || continue
            menus_guard "$menu_box/bin/$name"
            ln -s -- "$file" "$menu_box/bin/$name" || fail "providers: cannot retain required command $name"
        done
    done
    menus_guard "$menu_box/doubles/provider"
    cat > "$menu_box/doubles/provider" <<'SH'
#!/usr/bin/env bash
set -eu
box=${FLEA_PROVIDERS_BOX:?}
[[ "$box" == /* && -f "$box/.flea-test-sandbox" ]] || exit 90
guard() {
    [[ -n "$1" && "$1" == /* ]] || exit 91
    local resolved
    resolved=$(realpath -m -- "$1") || exit 91
    [[ "$resolved" == "$box/"* && "$resolved" != "$box" ]] || exit 91
}
name=${0##*/}
guard "$box/calls.jsonl"
case "$name:$#:${1:-}:${2:-}" in
    tailscale:2:status:--json|dropbox-cli:1:status:)
        jq -cn --arg helper "$name" --args '{helper:$helper,args:$ARGS.positional}' -- "$@" >> "$box/calls.jsonl"
        guard "$box/$name-mode"
        if [[ "$(cat "$box/$name-mode")" == gate ]]; then
            guard "$box/$name-release"
            [[ -p "$box/$name-release" && ! -L "$box/$name-release" ]] || exit 92
            read -r release < "$box/$name-release"
            [[ "$release" == release ]] || exit 93
        fi
        for field in output error exit; do guard "$box/$name-$field"; done
        cat "$box/$name-output"
        cat "$box/$name-error" >&2
        exit "$(cat "$box/$name-exit")"
        ;;
    omarchy-tailscale-send:2:fixture.invalid:*)
        guard "$2"
        [[ -f "$2" && ! -L "$2" ]] || exit 94
        ;;
    dropbox-cli:2:sharelink:*)
        guard "$2"
        [[ -f "$2" && ! -L "$2" ]] || exit 94
        printf 'https://fixture.invalid/share\n'
        ;;
    wl-copy:1:https://fixture.invalid/share:) ;;
    *) printf 'REFUSED: provider fixture received unexpected arguments: %s\n' "$name" >&2; exit 95 ;;
esac
jq -cn --arg helper "$name" --args '{helper:$helper,args:$ARGS.positional}' -- "$@" >> "$box/calls.jsonl"
SH
    chmod 700 "$menu_box/doubles/provider" || fail 'providers: cannot make dispatcher executable'
    for name in tailscale omarchy-tailscale-send dropbox-cli wl-copy; do
        menus_guard "$menu_box/doubles/$name"
        cp "$menu_box/doubles/provider" "$menu_box/doubles/$name" || fail "providers: double copy failed: $name"
        menus_guard "$menu_box/absent/$name"
        ln -s "$menu_box/doubles/$name" "$menu_box/absent/$name" || fail "providers: fixture link failed: $name"
    done
    providers_install wl-copy yes
    providers_ready
}

providers_cleanup() {
    providers_release tailscale || return 1
    providers_release dropbox-cli || return 1
    kill_flea || return 1
    exec {taildrop_fd}>&-
    exec {dropbox_fd}>&-
}

providers_selection() {
    local path="$1" marked cursor
    menus_visit "$path" 2
    menus_expect listInFlight '. == false' 'provider listing settles before selection'
    marked=$(row_index_of a-marked.txt)
    cursor=$(row_index_of b-cursor.txt)
    click_row "$marked" left
    key -k Down >/dev/null || fail 'providers: cursor movement failed'
    providers_expect ".cursor == $cursor and .selected == [$marked] and .cursorPath == \"$path/b-cursor.txt\" and .selectedPaths == [\"$path/a-marked.txt\"]" 'cursor remains outside the marked selection'
    key -k Menu >/dev/null || fail 'providers: native Menu delivery failed'
    menus_expect menuState '.opened and .snapshotReady' 'native Menu captures distinct cursor and marks'
    providers_expect '(.refreshing | not) and .menuFocus' 'provider selection refresh settles'
}

providers_choose() {
    local action="$1"
    providers_seek "$action"
    if [[ "$action" == taildrop ]]; then
        key -k Right >/dev/null || fail 'providers: submenu key failed'
        menus_expect menuState '.submenu and .submenuEntries[.submenuCursor].id == "fixture-peer"' 'Taildrop submenu retains the selected peer identity'
    fi
    key -k Return >/dev/null || fail 'providers: activation key failed'
}

case_providers() (
    local menu_box="$fixture_root/providers" menu_dir="$fixture_root/providers/list" menus_checks=0
    local taildrop_fd dropbox_fd name before action record reason path saved
    local provider_ready='{"BackendState":"Running","Self":{"UserID":"fixture-owner","Capabilities":["https://tailscale.com/cap/file-sharing"]},"Peer":{"fixture-peer":{"HostName":"Fixture","DNSName":"fixture.invalid.","Online":true,"TaildropTarget":1,"UserID":"fixture-owner"}}}'
    providers_fixture
    trap 'providers_cleanup || exit 1' EXIT
    export HOME="$menu_box/home" XDG_STATE_HOME="$menu_box/state" XDG_CONFIG_HOME="$menu_box/config"
    export XDG_CACHE_HOME="$menu_box/cache" XDG_DATA_HOME="$menu_box/data" PATH="$menu_box/bin" FLEA_PROVIDERS_BOX="$menu_box"
    "$flea_bin" --ui-state '{"view":"list","keys":"default","menu":{"hidden":[]}}' >/dev/null || fail 'providers: private settings seed failed'
    launch "$menu_dir"
    wait_listing 2
    menus_expect listInFlight '. == false' 'provider fixture initial listing settles'
    providers_open
    menus_expect menuState 'all(.entries[]; .action != "taildrop" and .action != "dropbox" and .action != "sharelink")' 'absent providers are not built'
    menus_equal 'absent providers spawn no helper' 0 "$(jq -s length "$menu_box/calls.jsonl")"
    providers_close

    for name in tailscale dropbox-cli; do
        providers_install "$name" yes
        menus_guard "$menu_box/doubles/$name"
        chmod 600 "$menu_box/doubles/$name" || fail 'providers: cannot make installed helper unusable'
    done
    providers_install omarchy-tailscale-send yes
    providers_open
    providers_disabled taildrop 'not executable'
    providers_disabled dropbox 'not executable'
    menus_equal 'unusable providers spawn no helper' 0 "$(jq -s length "$menu_box/calls.jsonl")"
    menus_shot providers-unusable
    providers_close
    for name in tailscale dropbox-cli; do menus_guard "$menu_box/doubles/$name"; chmod 700 "$menu_box/doubles/$name" || fail 'providers: executable recovery failed'; done

    while IFS='|' read -r record reason; do
        providers_mode tailscale ready "$record"
        providers_open
        providers_disabled taildrop "$reason"
        providers_close
    done <<'STATES'
{"BackendState":"NeedsLogin"}|signed out
{"BackendState":"Stopped"}|Stopped
{"BackendState":"Running","Self":{"Capabilities":["https://tailscale.com/cap/file-sharing"]},"Peer":{}}|No peers reachable
{"BackendState":"Running","Self":{},"Peer":{}}|disabled for this account
malformed|invalid status
STATES
    providers_mode tailscale ready '' 'fixture Tailscale failure' 7
    providers_open
    providers_disabled taildrop 'fixture Tailscale failure'
    providers_close
    providers_mode tailscale gate "$provider_ready"
    providers_open
    providers_disabled taildrop 'timed out'
    menus_shot providers-timeout
    providers_close
    providers_ready
    providers_install omarchy-tailscale-send no
    providers_open
    providers_disabled taildrop 'not installed'
    providers_close
    providers_install omarchy-tailscale-send yes

    for record in '{}' malformed '{"personal":{"path":"relative"}}'; do
        providers_write home/.dropbox/info.json "$record"
        providers_open
        if [[ "$record" == '{}' ]]; then reason='signed out'; else reason='invalid'; fi
        providers_disabled dropbox "$reason"
        providers_close
    done
    providers_ready
    for record in '' "Dropbox isn't running!" "Dropbox isn't responding!" 'Dropbox daemon stopped.' "Couldn't get status: fixture refusal"; do
        providers_mode dropbox-cli ready "$record"
        providers_open
        reason="$record"
        [[ -n "$reason" ]] || reason='empty status'
        providers_disabled dropbox "$reason"
        providers_close
    done
    providers_mode dropbox-cli ready '' 'fixture Dropbox failure' 7
    providers_open
    providers_disabled dropbox 'fixture Dropbox failure'
    providers_close
    providers_mode dropbox-cli gate 'Up to date'
    providers_open
    providers_disabled dropbox 'timed out'
    providers_close
    providers_ready

    providers_install tailscale no
    providers_open
    menus_expect menuState 'all(.entries[]; .action != "taildrop")' 'fresh menu removes uninstalled Tailscale'
    providers_close
    providers_install tailscale yes
    providers_mode tailscale gate "$provider_ready"
    menus_file_menu b-cursor.txt key
    providers_expect '.refreshing and .taildrop.checking' 'late installed provider refresh is in flight'
    providers_seek properties
    before=$(ipc listContentY)
    providers_release tailscale
    providers_expect '(.refreshing | not) and .menuFocus' 'late provider insertion finishes with keyboard focus'
    menus_expect menuState '.entries[.cursor].action == "properties" and any(.entries[]; .action == "taildrop" and (.disabled | not))' 'inserted provider preserves current action'
    providers_geometry
    menus_equal 'provider insertion leaves covered listing scroll unchanged' "$before" "$(ipc listContentY)"
    menus_shot providers-inserted
    providers_close
    providers_install dropbox-cli no
    menus_file_menu b-cursor.txt key
    providers_expect '.refreshing and .taildrop.checking' 'provider removal waits for the other fresh query'
    providers_seek properties
    providers_release tailscale
    providers_expect '(.refreshing | not) and .menuFocus' 'provider removal finishes with keyboard focus'
    menus_expect menuState '.entries[.cursor].action == "properties" and all(.entries[]; .action != "dropbox")' 'removed provider preserves current action'
    providers_geometry
    providers_close
    providers_install dropbox-cli yes
    providers_ready

    providers_selection "$menu_dir"
    before=$(providers_calls omarchy-tailscale-send)
    providers_choose taildrop
    providers_call omarchy-tailscale-send "$(jq -cn --arg path "$menu_dir/b-cursor.txt" '["fixture.invalid",$path]')" "$before"
    menus_message 'Sending b-cursor.txt to Fixture.' 'native Taildrop passes only the unmarked cursor to the local recorder'
    menus_equal 'Taildrop recorder preserves cursor file' 'list/b-cursor.txt original' "$(cat "$menu_dir/b-cursor.txt")"
    menus_equal 'Taildrop recorder preserves marked file' 'list/a-marked.txt original' "$(cat "$menu_dir/a-marked.txt")"

    providers_selection "$menu_dir"
    before=$(providers_calls omarchy-tailscale-send)
    providers_mode tailscale gate '{"BackendState":"Running","Self":{"Capabilities":["https://tailscale.com/cap/file-sharing"]},"Peer":{}}'
    providers_choose taildrop
    providers_expect '.refreshing and .pendingActivation and .taildrop.checking' 'chosen peer awaits fresh availability'
    providers_release tailscale
    menus_error 'That action is no longer available' 'a disappeared peer cannot inherit the queued send'
    providers_expect '(.refreshing | not) and (.pendingActivation | not)' 'peer refusal clears pending activation'
    menus_equal 'disappeared peer never reaches sender' "$before" "$(providers_calls omarchy-tailscale-send)"
    menus_acknowledge
    providers_ready

    for action in taildrop sharelink; do
        if [[ "$action" == taildrop ]]; then path="$menu_dir"; name=tailscale
        else path="$menu_box/Dropbox"; name=dropbox-cli; fi
        providers_selection "$path"
        before=$(providers_calls "$([[ "$action" == taildrop ]] && printf omarchy-tailscale-send || printf dropbox-cli)")
        providers_mode "$name" gate "$([[ "$name" == tailscale ]] && printf '%s' "$provider_ready" || printf 'Up to date')"
        providers_choose "$action"
        providers_expect '.refreshing and .pendingActivation' 'provider activation waits for a fresh status reply'
        saved="$menu_box/retired/$action-original"
        menus_guard "$path/b-cursor.txt"
        menus_guard "$saved"
        mv -- "$path/b-cursor.txt" "$saved" || fail 'providers: cannot retain cursor original'
        providers_write "${path#"$menu_box/"}/b-cursor.txt" replacement
        providers_release "$name"
        menus_error 'Selected item changed' "$action refuses an asynchronously replaced unmarked cursor"
        providers_expect '(.refreshing | not) and (.pendingActivation | not)' 'refused activation has no pending provider work'
        if [[ "$action" == taildrop ]]; then menus_equal 'stale Taildrop never reaches sender' "$before" "$(providers_calls omarchy-tailscale-send)"
        else menus_equal 'stale Share Link makes only its fresh status query' "$((before + 1))" "$(providers_calls dropbox-cli)"; fi
        menus_equal 'cursor refusal preserves replacement' replacement "$(cat "$path/b-cursor.txt")"
        menus_equal 'cursor refusal preserves original' "${path#"$menu_box/"}/b-cursor.txt original" "$(cat "$saved")"
        menus_acknowledge
        providers_ready
    done

    providers_selection "$menu_box/Dropbox"
    before=$(providers_calls dropbox-cli)
    providers_choose sharelink
    providers_expect '(.refreshing | not) and (.pendingActivation | not)' 'fresh Share Link activation settles'
    providers_call dropbox-cli "$(jq -cn --arg path "$menu_box/Dropbox/b-cursor.txt" '["sharelink",$path]')" "$((before + 1))"
    providers_call wl-copy '["https://fixture.invalid/share"]' 0
    menus_message 'Share link copied to the clipboard.' 'Share Link hands the fixture URL to the private clipboard recorder'

    providers_selection "$menu_dir"
    providers_mode dropbox-cli gate 'Up to date'
    providers_choose dropbox
    providers_expect '.refreshing and .pendingActivation and .dropbox.checking' 'Dropbox activation refresh is in flight'
    menus_guard "$menu_box/Dropbox"
    menus_guard "$menu_box/retired/Dropbox"
    mv -- "$menu_box/Dropbox" "$menu_box/retired/Dropbox" || fail 'providers: cannot retain destination original'
    menus_guard "$menu_box/Dropbox"
    mkdir "$menu_box/Dropbox" || fail 'providers: cannot replace fixture destination'
    providers_release dropbox-cli
    menus_error 'Dropbox account folder changed' 'Move to Dropbox refuses a replaced account directory'
    providers_expect '(.refreshing | not) and (.pendingActivation | not)' 'destination refusal clears pending activation'
    menus_equal 'refused destination remains empty' 0 "$(find "$menu_box/Dropbox" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    menus_equal 'destination refusal preserves marked source' 'list/a-marked.txt original' "$(cat "$menu_dir/a-marked.txt")"
    menus_equal 'destination refusal preserves cursor replacement' replacement "$(cat "$menu_dir/b-cursor.txt")"
    menus_shot providers-destination-refusal
    printf 'PROVIDERS_NATIVE_CHECKS=%s\n' "$menus_checks"
    printf 'PROVIDERS_UNVERIFIED worker-stage Dropbox retry, offline daemon wording, helper launch race, concurrent panes, all-preset provider combinations, matched-size pixels\n'
)
