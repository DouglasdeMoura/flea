#!/usr/bin/env bash
# Drives the file chooser the way an application does: omarchy-file-select asks the XDG portal,
# xdg-desktop-portal routes org.freedesktop.impl.portal.FileChooser to whichever backend the
# configuration names, and this asserts what comes back AT THE CALLER. It proves nothing about Flea
# unless Flea is the backend, so it checks that first.
# Usage: ./tests/picker.sh [pick|save|cancel|withdrawn|died|fault|taildrop]; taildrop is opt-in.
# FLEA_PICKER_CONFIG names the running picker's qs config path, which is the packaged one by default.
# FLEA_PICKER_EVIDENCE names a directory the caller owns for the taildrop case's screenshot.
set -u
set -o pipefail
# Hard rule 9's guard, which owns FIXTURE_ROOT and every create and delete this suite makes.
. "$(dirname "$0")/../tools/flea-sandbox-guard"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

export PATH="$HOME/.local/bin:$PATH"
eval "$(omarchy-drive env)"
# Without the platform theme no themed icon name resolves, the same read tests/ui.sh makes.
if [[ -z "${QT_QPA_PLATFORMTHEME:-}" ]]; then
    export QT_QPA_PLATFORMTHEME="$(systemctl --user show-environment | grep '^QT_QPA_PLATFORMTHEME=' | cut -d= -f2-)"
fi
# A portal client opens its own connection to the session bus, which an ssh session does not export.
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

picker_config="${FLEA_PICKER_CONFIG:-/usr/share/flea/ui/picker.qml}"
fixture="$FIXTURE_ROOT/flea-picker-$$"
# The taildrop case takes the title the real caller gives its window, so this is not readonly.
title="Flea picker test $$"
client=0

ipc() {
    timeout 5 omarchy-drive ipc -p "$picker_config" fleapicker "$@" 2>/dev/null
}

press() {
    omarchy-drive key --window "$title" "$@" >/dev/null || fail "could not press $*"
}

# Only ever this run's own window, named by a title no other run uses, and only when one is up.
cleanup() {
    if [[ "$client" != 0 ]] && kill -0 "$client" 2>/dev/null; then
        omarchy-drive key --window "$title" -k Escape >/dev/null 2>&1
        sleep 1
        kill "$client" 2>/dev/null
    fi
    sandbox_remove "$fixture"
}
trap cleanup EXIT

backend_is_flea() {
    local owner
    owner=$(busctl --user --list --no-pager 2>/dev/null | grep -c 'org.freedesktop.impl.portal.desktop.flea')
    [[ "$owner" -gt 0 ]] || fail "org.freedesktop.impl.portal.desktop.flea is not activatable, so run flea --picker and restart xdg-desktop-portal"
}

make_fixture() {
    sandbox_make "$fixture"
    printf 'flea picker fixture\n' > "$fixture/alpha.txt"
    printf 'flea picker fixture two\n' > "$fixture/beta.txt"
    head -c 4096 /dev/urandom > "$fixture/gamma.bin"
}

# Walks from the home directory to the fixture with the keyboard alone, which is also the whole of
# the board's navigation contract: Parent climbs, the cursor steps, Enter opens a directory.
walk_to_fixture() {
    local want step
    press -k BackSpace
    for step in 1 2 3 4 5 6 7 8 9 10; do
        [[ "$(ipc path)" == "/home" ]] && break
        sleep 0.3
    done
    [[ "$(ipc path)" == "/home" ]] || fail "Backspace did not climb to /home, the picker is at $(ipc path)"
    for want in flea-sandbox "${fixture##*/}"; do
        step=0
        while [[ "$(ipc cursorName)" != "$want" ]]; do
            step=$((step + 1))
            [[ "$step" -le 200 ]] || fail "no row named $want under $(ipc path)"
            press -k Down
        done
        press -k Return
        sleep 0.5
    done
    [[ "$(ipc path)" == "$fixture" ]] || fail "the picker is at $(ipc path), not $fixture"
}

start_client() {
    omarchy-file-select --title "$title" "$@" > "$fixture/picked.txt" 2> "$fixture/client.err" &
    client=$!
    omarchy-drive wait window "$title" --timeout 25 >/dev/null || fail "no picker window named $title ever appeared"
    omarchy-drive focus "$title" >/dev/null || fail "the picker window would not take focus"
}

wait_for_client() {
    local status=0
    wait "$client" || status=$?
    client=0
    printf '%s' "$status"
}

case_pick() {
    make_fixture
    start_client --multiple
    walk_to_fixture
    [[ "$(ipc cursorName)" == "alpha.txt" ]] || fail "the cursor landed on $(ipc cursorName), not the first row"
    press -k space
    [[ "$(ipc marks)" == "$fixture/alpha.txt" ]] || fail "space marked $(ipc marks)"
    press -k Down
    press -k space
    [[ "$(ipc marks)" == "$fixture/alpha.txt,$fixture/beta.txt" ]] || fail "the second mark left $(ipc marks)"
    press -k Return
    local status
    status=$(wait_for_client)
    [[ "$status" == 0 ]] || fail "the caller exited $status with $(cat "$fixture/client.err")"
    local want
    want=$(printf '%s\n%s' "$fixture/alpha.txt" "$fixture/beta.txt")
    [[ "$(cat "$fixture/picked.txt")" == "$want" ]] || fail "the caller received $(cat "$fixture/picked.txt")"
    printf 'pick: the caller exited 0 with both paths\n'
}

case_cancel() {
    make_fixture
    start_client --multiple
    press -k Escape
    local status
    status=$(wait_for_client)
    # 1 is the caller's "nothing picked", which is a decision; anything above it is a fault.
    [[ "$status" == 1 ]] || fail "a cancelled chooser exited $status, not 1"
    [[ ! -s "$fixture/picked.txt" ]] || fail "a cancelled chooser printed $(cat "$fixture/picked.txt")"
    printf 'cancel: the caller exited 1 with nothing picked, and nothing was sent\n'
}

# The response the portal actually answered with, which the caller collapses: 1 is the user's refusal
# and 2 is everything else, and omarchy-file-select turns both into exit 1. This is where the two can
# be told apart. Prints "<code> <uri...>", or "none" when nothing answered at all.
# Usage: portal_ask <OpenFile|SaveFile> <close|wait> [current_name]
portal_ask() {
    python3 - "$title" "$1" "$2" "${3:-}" <<'ASK'
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

title, method, withdraw, name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
seen = []

def on_response(connection, sender, path, interface, signal, params):
    code, results = params.unpack()
    seen.append(" ".join([str(code)] + list(results.get("uris", []))))
    loop.quit()

token = "fleatest"
sender = bus.get_unique_name()[1:].replace(".", "_")
path = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
                     "Response", path, None, Gio.DBusSignalFlags.NONE, on_response)
options = {"handle_token": GLib.Variant("s", token)}
if name:
    options["current_name"] = GLib.Variant("s", name)
handle = bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                       "org.freedesktop.portal.FileChooser", method,
                       GLib.Variant("(ssa{sv})", ("", title, options)),
                       None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]

def close():
    bus.call_sync("org.freedesktop.portal.Desktop", handle, "org.freedesktop.portal.Request",
                  "Close", None, None, Gio.DBusCallFlags.NONE, -1, None)
    return False

if withdraw == "close":
    GLib.timeout_add_seconds(6, close)
# A request that never answers is the defect this bounds: the caller would wait 600 s for it.
GLib.timeout_add_seconds(40, loop.quit)
loop.run()
print(seen[0] if seen else "none")
ASK
}

case_withdrawn() {
    make_fixture
    portal_ask OpenFile close > "$fixture/codes.txt"
    [[ "$(cat "$fixture/codes.txt")" == "2" ]] || fail "a withdrawn request answered $(cat "$fixture/codes.txt"), not 2"
    printf 'withdrawn: a request the caller closed answers 2, which is not the 1 a refusal answers\n'
}

# The window dying under a live request, which is the one way a chooser can leave a caller waiting.
# It must answer 2 rather than the 1 a refusal answers, and it must answer at all.
case_died() {
    make_fixture
    portal_ask OpenFile wait > "$fixture/died.txt" &
    local asker=$!
    omarchy-drive wait window "$title" --timeout 25 >/dev/null || fail "no picker window named $title appeared"
    omarchy-drive window kill "$title" >/dev/null || fail "could not kill the picker window"
    wait "$asker"
    [[ "$(cat "$fixture/died.txt")" == "2" ]] || fail "a picker that died answered $(cat "$fixture/died.txt"), not 2"
    printf 'died: a picker killed mid request answers 2, and the caller is answered rather than left waiting\n'
}

# SaveFile, the board's other mode: the name the caller suggested comes back under the directory the
# window is standing in, and the caller owns the write after that.
case_save() {
    make_fixture
    portal_ask SaveFile wait notes.md > "$fixture/saved.txt" &
    local asker=$!
    omarchy-drive wait window "$title" --timeout 25 >/dev/null || fail "SaveFile raised no picker window"
    omarchy-drive focus "$title" >/dev/null || fail "the picker window would not take focus"
    [[ "$(ipc saveName)" == "notes.md" ]] || fail "the save field holds $(ipc saveName), not the caller's name"
    walk_to_fixture
    press -k Return
    wait "$asker"
    [[ "$(cat "$fixture/saved.txt")" == "0 file://$fixture/notes.md" ]] \
        || fail "SaveFile answered $(cat "$fixture/saved.txt")"
    [[ ! -e "$fixture/notes.md" ]] || fail "the chooser wrote the file itself, which is the caller's to do"
    printf 'save: SaveFile answers 0 with the reviewed URI, and writes nothing\n'
}

# A chooser that cannot open at all refuses before any window and writes no reply file, which is what
# tools/flea-portal turns into 2. Both refusals are argv-level, so neither needs the display.
case_fault() {
    make_fixture
    local flea status
    flea="$(cd "$(dirname "$0")/.." && pwd)/target/release/flea"
    [[ -x "$flea" ]] || fail "no built flea at $flea"
    status=0
    env -u FLEA_PICKER "$flea" --pick "$fixture/never.json" 2>"$fixture/pick.err" || status=$?
    [[ "$status" == 2 ]] || fail "a pick with no request exited $status, not 2"
    grep -q "needs FLEA_PICKER" "$fixture/pick.err" || fail "the refusal said $(cat "$fixture/pick.err")"
    status=0
    FLEA_PICKER='{"mode":"open"}' "$flea" --pick "" 2>>"$fixture/pick.err" || status=$?
    [[ "$status" == 2 ]] || fail "a pick with no reply file exited $status, not 2"
    [[ ! -e "$fixture/never.json" ]] || fail "a refused picker still wrote a reply file"
    printf 'fault: a picker that cannot open exits 2 before any window and writes no reply\n'
}

# Opt-in, like tests/ui.sh's networklive: this one drives the stock Tailscale panel and really sends
# a file, so it never runs unless a peer is named and it is asked for by name.
case_taildrop() {
    local peer="${FLEA_TAILDROP_PEER:-}"
    [[ -n "$peer" ]] || fail "taildrop needs FLEA_TAILDROP_PEER, so no run can send a file to a peer nobody named"
    make_fixture
    local sent="flea-picker-acceptance-$(date +%Y%m%d-%H%M%S).txt"
    printf 'Flea file picker acceptance fixture, generated %s. Safe to delete.\n' "$(date -Is)" > "$fixture/$sent"
    title="Send to $peer"
    omarchy-drive ipc omarchy.tailscale open >/dev/null || fail "the stock Tailscale panel would not open"
    sleep 1
    # The peer row has no click action of its own; the hover under the click is what moves the
    # panel's own cursor, and s is the panel's own send key. Neither is Flea's. The label is a
    # separate variable because the panel draws the peer's display name, which is not always the
    # name tailscale addresses, and because click-text reads the screen with OCR.
    omarchy-drive click-text "${FLEA_TAILDROP_LABEL:-$peer}" >/dev/null \
        || fail "no row reading ${FLEA_TAILDROP_LABEL:-$peer} in the Tailscale panel"
    # The evidence for which row the pointer actually landed on, before anything is sent. It goes
    # in the fixture unless the caller named a directory of its own to keep it in.
    omarchy-drive shot "${FLEA_PICKER_EVIDENCE:-$fixture}/tailscale-panel.png" >/dev/null
    omarchy-drive key s >/dev/null || fail "the panel refused the send key"
    omarchy-drive wait window "$title" --timeout 25 >/dev/null || fail "the Tailscale send raised no picker window"
    omarchy-drive focus "$title" >/dev/null || fail "the picker window would not take focus"
    walk_to_fixture
    local step=0
    while [[ "$(ipc cursorName)" != "$sent" ]]; do
        step=$((step + 1))
        [[ "$step" -le 50 ]] || fail "no row named $sent under $(ipc path)"
        press -k Down
    done
    press -k space
    [[ "$(ipc marks)" == "$fixture/$sent" ]] || fail "space marked $(ipc marks)"
    press -k Return
    # The caller's own report, which is the only thing downstream of the picker: it sent, or it said
    # it could not. Read off the screen, because Omarchy's shell owns its notifications.
    omarchy-drive wait ocr "" "Sent to $peer" --timeout 60 >/dev/null \
        || fail "the caller never reported a send, and the screen says: $(omarchy-drive ocr 2>&1 | tail -4)"
    printf 'taildrop: the stock plugin raised Flea, and the caller sent %s to %s\n' "$sent" "$peer"
}

backend_is_flea
[[ "$#" -gt 0 ]] || set -- pick save cancel withdrawn died fault
for name in "$@"; do
    case "$name" in
        pick) case_pick ;;
        save) case_save ;;
        cancel) case_cancel ;;
        withdrawn) case_withdrawn ;;
        died) case_died ;;
        fault) case_fault ;;
        taildrop) case_taildrop ;;
        *) fail "no case named $name" ;;
    esac
done
