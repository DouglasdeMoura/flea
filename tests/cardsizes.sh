#!/usr/bin/env bash
# Every overlay at every Hyprland tile geometry a 2560x1440 monitor with a 30 px bar, 10 px gaps and
# dwindle produces: full, half, quarter, third, sixth, plus a 560x400 float and fullscreen. At each
# size the settings card keeps one title height across its sections, the network card keeps one chip
# height across protocols and scrolls what a short window cuts (by wheel and by Tab), the keymap
# sheet, the convert popup and the context menu stay inside the window. Driven through omarchy-drive
# like tests/ui.sh; the window is resized through Hyprland's Lua dispatchers by address.
set -u
set -o pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
export FLEA_BIN="${FLEA_BIN:-$repo/target/release/flea}"
export FLEA_UI="${FLEA_UI:-$repo/ui}"
. "$repo/tools/flea-sandbox-guard"
export PATH="$HOME/.local/bin:$PATH"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1}
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR"/hypr/ | head -1)
export YDOTOOL_SOCKET=$XDG_RUNTIME_DIR/.ydotool_socket
evidence_dir="${FLEA_EVIDENCE_DIR:-/tmp/flea-cardsizes-evidence}"
mkdir -p "$evidence_dir"

SB=$FIXTURE_ROOT/flea-cardsizes-$$
pass=0
fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2], expected [$3])"; fi; }

cleanup() {
  [ -n "${FLEA_PID:-}" ] && kill -- -"$FLEA_PID" 2>/dev/null
  [ -n "${FLEA_PID:-}" ] && kill "$FLEA_PID" 2>/dev/null
  sleep 0.5
  sandbox_remove "$SB" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------- fixture: one png first, sixteen text rows
sandbox_make "$SB"
png=$(find /usr/share/icons /usr/share/pixmaps -name '*.png' 2>/dev/null | head -1)
[ -n "$png" ] || { echo "REFUSAL no png under /usr/share/icons to convert"; exit 2; }
cp "$png" "$SB/0-shot.png"
for f in a b c d e f g h i j k l m n o p; do echo "$f" > "$SB/$f.txt"; done

ipc() { omarchy-drive ipc -p "$FLEA_UI" flea "$@" 2>/dev/null | head -1; }
key() { omarchy-drive key --window flea "$@" >/dev/null 2>&1; }
# Sample output: 12 42 2536 1386 False 0 (x y width height floating fullscreen)
geom() { hyprctl -j clients | python3 -c 'import json,sys; w=[c for c in json.load(sys.stdin) if c["class"]=="com.thisisgm.flea"][0]; print(w["at"][0], w["at"][1], w["size"][0], w["size"][1], w["floating"], w["fullscreen"])'; }
click_win() { set -- $(geom) "$1" "$2" "${3:-left}"; omarchy-drive click "$(( $1 + $7 ))" "$(( $2 + $8 ))" "$9" >/dev/null 2>&1; }
# omarchy-drive scroll takes no point: warp there, nudge one pixel through uinput so Qt sees a frame, then wheel.
scroll_win() { set -- $(geom) "$1" "$2"; hyprctl dispatch "hl.dsp.cursor.move({x = $(( $1 + $7 - 1 )), y = $(( $2 + $8 ))})" >/dev/null; ydotool mousemove -x 1 -y 0 >/dev/null 2>&1; sleep 0.1; omarchy-drive scroll down 1 >/dev/null 2>&1; }
# rect_inside <label> "<x y w h>": inside the window, one pixel of rounding allowed.
rect_inside() {
  local label="$1"; set -- $(geom) $2
  [ -z "${7:-}" ] && { bad "$label has no rectangle"; return; }
  if [ "$7" -ge -1 ] && [ "$8" -ge -1 ] && [ $(( $7 + $9 )) -le $(( $3 + 1 )) ] && [ $(( $8 + ${10} )) -le $(( $4 + 1 )) ]; then ok "$label is inside the ${3}x${4} window ($7 $8 $9 ${10})"; else bad "$label at $7 $8 $9 ${10} leaves the ${3}x${4} window"; fi
}
dispatch() { hyprctl dispatch "$1" 2>&1 | grep -v "^ok" | sed 's/^/    dispatch: /'; }
rowidx() { local i total; total=$(ipc total); for i in $(seq 0 $((total - 1))); do case "$(ipc rowAt "$i")" in "$1|"*) echo "$i"; return 0;; esac; done; return 1; }

# ---------------------------------------------------------------- the app
QSG_RHI_BACKEND="${QSG_RHI_BACKEND:-vulkan}" setsid "$FLEA_BIN" --gui "$SB" >/dev/null 2>&1 </dev/null &
FLEA_PID=$!
omarchy-drive wait window flea --timeout 15 >/dev/null 2>&1 || { echo "REFUSAL no flea window"; exit 2; }
omarchy-drive focus flea >/dev/null 2>&1; sleep 0.8
addr=$(hyprctl -j clients | python3 -c 'import json,sys; print([c for c in json.load(sys.stdin) if c["class"]=="com.thisisgm.flea"][0]["address"])')
echo "== fixture $SB, window $addr at $(geom) =="

for size in tiled 1258x1386 1258x688 832x1386 832x688 560x400 fullscreen; do
  case "$size" in
    tiled) ;;
    fullscreen) dispatch "hl.dsp.window.fullscreen({ window = \"address:$addr\" })" ;;
    *) [ "$(geom | awk '{print $5}')" = True ] || dispatch "hl.dsp.window.float({ window = \"address:$addr\" })"
       dispatch "hl.dsp.window.resize({ x = ${size%x*}, y = ${size#*x}, exact = true, window = \"address:$addr\" })" ;;
  esac
  sleep 0.8; omarchy-drive focus flea >/dev/null 2>&1; sleep 0.3
  echo "=== $size: window $(geom)"

  # Settings: one title height for every section, the card inside the window.
  key ,; sleep 0.6
  check "$size settings opens" "$(ipc settingsOpen)" "true"
  display=$(ipc settingsTitleCentre)
  key -k Tab; sleep 0.2; key k; key k; sleep 0.3; keys=$(ipc settingsTitleCentre)
  key j; sleep 0.3; key j; sleep 0.3; menus=$(ipc settingsTitleCentre)
  check "$size settings title height is the same on keys, display and menus" "$keys|$menus" "$display|$display"
  rect_inside "$size settings card" "$(ipc settingsCardRect)"
  omarchy-drive shot "$evidence_dir/settings-$size.png" flea >/dev/null 2>&1
  key -k Escape; sleep 0.4
  check "$size settings closed" "$(ipc settingsOpen)" "false"

  # Network: the chips keep one centre through every protocol, the card is inside, and a short window
  # scrolls the body by wheel and by a Tab to the password field.
  key -k Tab; sleep 0.3; key a; sleep 0.7
  check "$size network dialog opens" "$(ipc dialogOpen)" "true"
  base=$(ipc networkChipCentre SMB)
  moved=""
  for p in SFTP FTPS WebDAV NFS SMB; do
    set -- $(ipc networkChipCentre "$p"); click_win "$1" "$2"; sleep 0.35
    [ "$(ipc networkProtocol)" = "$p" ] || moved="$moved $p:not-picked"
    [ "$(ipc networkChipCentre SMB)" = "$base" ] || moved="$moved $p:$(ipc networkChipCentre SMB)"
  done
  check "$size the chip row held its height through every protocol" "${moved:-still}" "still"
  rect_inside "$size network card" "$(ipc networkCardRect)"
  omarchy-drive shot "$evidence_dir/network-$size.png" flea >/dev/null 2>&1
  IFS='|' read -r sy sh svh <<<"$(ipc networkScroll)"
  if [ "${sh:-0}" -gt "${svh:-0}" ]; then
    set -- $(ipc networkCardRect); scroll_win $(( $1 + $3 / 2 )) $(( $2 + $4 / 2 )); sleep 0.4
    IFS='|' read -r sy2 _ _ <<<"$(ipc networkScroll)"
    [ "${sy2:-0}" -gt 0 ] && ok "$size a wheel notch scrolls the clamped network body ($sh > $svh, contentY $sy2)" || bad "$size the clamped network body did not scroll on a wheel notch ($sh > $svh, contentY $sy2)"
    omarchy-drive shot "$evidence_dir/network-$size-scrolled.png" flea >/dev/null 2>&1
    set -- $(ipc networkChipCentre SMB); click_win "$1" "$2"; sleep 0.3
    for i in $(seq 1 14); do key -k Tab; sleep 0.15; [ "$(ipc networkFocus)" = "Password" ] && break; done
    IFS='|' read -r sy3 _ _ <<<"$(ipc networkScroll)"
    check "$size Tab reaches the password field" "$(ipc networkFocus)" "Password"
    [ "${sy3:-0}" -gt 0 ] && ok "$size and the body scrolled it into view (contentY $sy3)" || bad "$size the password field was focused below the fold (contentY $sy3)"
  else
    ok "$size the network body fits ($sh <= $svh), nothing to scroll"
  fi
  key -k Escape; sleep 0.4
  check "$size network dialog closed" "$(ipc dialogOpen)" "false"
  key -k Escape; sleep 0.2

  # The keymap sheet, the tallest card of all.
  key '?'; sleep 0.6
  check "$size keymap sheet opens" "$(ipc keymapSheetOpen)" "true"
  rect_inside "$size keymap sheet" "$(ipc keymapCardRect)"
  omarchy-drive shot "$evidence_dir/keymap-$size.png" flea >/dev/null 2>&1
  key -k Escape; sleep 0.4
  check "$size keymap sheet closed" "$(ipc keymapSheetOpen)" "false"

  # The convert popup, from the png row's context menu; the png is row 0 so it is on screen at every size.
  idx=$(rowidx 0-shot.png) || idx=""
  set -- $(ipc rowCentre "${idx:-0}"); click_win "$1" "$2" right; sleep 0.5
  entries=$(ipc contextMenuEntries); target=-1; i=0; IFS='|'; for label in $entries; do [ "$label" = "Convert" ] && { target=$i; break; }; i=$((i+1)); done; unset IFS
  for _ in $(seq 1 14); do [ "$(ipc contextMenuCursor)" = "$target" ] && break; key -k Down; sleep 0.1; done
  # Return only on the Convert row: anything else opens the file in an editor whose window retiles Flea.
  if [ "$target" -ge 0 ] && [ "$(ipc contextMenuCursor)" = "$target" ]; then key -k Return; sleep 0.6; else key -k Escape; bad "$size the menu cursor never reached Convert (target $target, cursor $(ipc contextMenuCursor), entries $entries)"; fi
  check "$size convert popup opens" "$(ipc convertOpen)" "true"
  rect_inside "$size convert card" "$(ipc convertCardRect)"
  omarchy-drive shot "$evidence_dir/convert-$size.png" flea >/dev/null 2>&1
  key -k Escape; sleep 0.4
  check "$size convert popup closed" "$(ipc convertOpen)" "false"

  # The context menu on the last row on screen must flip to stay inside the window.
  last=$(( $(ipc visibleRows) - 1 )); total=$(ipc total); [ "$last" -ge "$total" ] && last=$((total - 1))
  set -- $(ipc rowCentre "$last"); click_win "$1" "$2" right; sleep 0.5
  rect_inside "$size context menu on the last row on screen" "$(ipc contextMenuRect)"
  omarchy-drive shot "$evidence_dir/menu-$size.png" flea >/dev/null 2>&1
  key -k Escape; sleep 0.3
  # A stray editor on a fixture file would retile the window under the next size; none is expected.
  for p in $(pgrep -f "[n]vim.*$SB"); do kill "$p" 2>/dev/null; bad "$size a fixture file was opened in an editor"; done
  [ "$size" = fullscreen ] && dispatch "hl.dsp.window.fullscreen({ window = \"address:$addr\" })"
done
echo
echo "$((pass + fail)) checks, $fail failed"
[ "$fail" = 0 ] || exit 1
