#!/usr/bin/env bash
# The org.freedesktop.FileManager1 contract, driven the way Chromium drives it: one ShowItems call
# carrying a file:// URI, answered by one Flea window on the item's parent with the item selected.
#
# Everything here runs on a PRIVATE session bus this suite starts and kills, whose only service
# directory is inside its own fixture. Nothing is written to ~/.local/share/dbus-1/services: a
# user-level service file outranks /usr/share/dbus-1/services and silently shadows it, which shipped
# a development portal backend to the operator as a bug.
#
# The negative control is the first case and stays in the suite: on a bus that has never heard of
# the name, the same call fails with ServiceUnknown.
set -u
set -o pipefail
# Hard rule 9's guard, which owns FIXTURE_ROOT and every create and delete this suite makes.
. "$(dirname "$0")/../tools/flea-sandbox-guard"

root=$(cd "$(dirname "$0")/.." && pwd)
service_file="$root/packaging/com.thisisgm.flea.FileManager1.service"
fixture="$FIXTURE_ROOT/flea-filemanager1-$$"
install_path=/usr/lib/flea/flea-filemanager1
bus_pid=0
failed=0

note() { printf '  %s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failed=$((failed + 1)); }

for tool in dbus-daemon python3; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL %s is not installed, so nothing below was run\n' "$tool"; exit 1; }
done

stop_bus() {
    if [[ "$bus_pid" != 0 ]] && kill -0 "$bus_pid" 2>/dev/null; then
        kill "$bus_pid" 2>/dev/null
        wait "$bus_pid" 2>/dev/null
    fi
    bus_pid=0
}

cleanup() {
    stop_bus
    sandbox_remove "$fixture"
}
trap cleanup EXIT

# A bus of this suite's own, listening inside the fixture and reading service files from the one
# directory it is given. FLEA_BIN is set in the daemon's environment because an activated service
# inherits the daemon's, which is the only way the stub reaches a child D-Bus starts.
start_bus() {
    local services="$1"
    cat > "$fixture/bus.conf" <<CONF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$fixture/bus</listen>
  <servicedir>$services</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <!-- The receive half, copied from /usr/share/dbus-1/session.conf: without it every method
         call is delivered and every reply is denied, so the caller times out instead. -->
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
    rm -f "$fixture/bus"
    FLEA_BIN="$fixture/flea-stub" \
        dbus-daemon --config-file="$fixture/bus.conf" --fork --print-pid=3 3>"$fixture/bus.pid" \
        || { fail "the private bus would not start"; return 1; }
    bus_pid=$(cat "$fixture/bus.pid")
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$fixture/bus"
    return 0
}

make_fixture() {
    sandbox_make "$fixture"
    mkdir -p "$fixture/services" "$fixture/empty" "$fixture/docs/inner"
    printf 'alpha\n' > "$fixture/docs/alpha.txt"
    printf 'beta\n' > "$fixture/docs/beta.txt"
    printf 'spaced\n' > "$fixture/docs/two words.txt"
    # A name carrying a real newline, so the URI holding %0A names a file that is there. Without it
    # the existence check refuses that URI first and the control-character rule is never reached:
    # deleting the rule left the whole suite green until this file was added.
    printf 'newline\n' > "$fixture/docs/$(printf 'al\npha.txt')"
    # The stub stands in for the window: one line per invocation, its arguments separated by a bar,
    # so a path carrying a space is still one unambiguous field.
    cat > "$fixture/flea-stub" <<STUB
#!/usr/bin/env bash
printf '%s|' "\$@" >> "$fixture/argv.log"
printf '\n' >> "$fixture/argv.log"
STUB
    chmod +x "$fixture/flea-stub"
    : > "$fixture/argv.log"
    # The shipped registration with only its Exec repointed at this checkout, so the Name= under
    # test is the packaged file's own: a broken Name in packaging/ reddens here.
    sed "s#^Exec=.*#Exec=$root/tools/flea-filemanager1#" "$service_file" \
        > "$fixture/services/com.thisisgm.flea.FileManager1.service"
}

# One real D-Bus call. Prints "ok", or "error <name>" carrying the remote error name the caller sees.
ask() {
    python3 - "$@" <<'ASK'
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

method, uris = sys.argv[1], sys.argv[2:]
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
try:
    bus.call_sync("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                  "org.freedesktop.FileManager1", method,
                  GLib.Variant("(ass)", (uris, "")), None, Gio.DBusCallFlags.NONE, 10000, None)
except GLib.Error as error:
    print("error %s" % (Gio.DBusError.get_remote_error(error) or error.message))
else:
    print("ok")
ASK
}

lines() { wc -l < "$fixture/argv.log" | tr -d ' '; }

# The reply is sent once the child is spawned, so the stub's own write can still be in flight.
wait_for_lines() {
    local want="$1" step
    for step in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ "$(lines)" -ge "$want" ]] && return 0
        sleep 0.25
    done
    return 1
}

uri_for() { printf 'file://%s' "$1"; }

# The negative control, and the reason it is a case and not a paragraph: with no registration for
# the name, the call Chromium makes fails outright. Everything below is the same call on the same
# kind of bus with Flea's own registration present.
case_unowned() {
    start_bus "$fixture/empty" || return
    local answer
    answer=$(ask ShowItems "$(uri_for "$fixture/docs/alpha.txt")")
    if [[ "$answer" == "error org.freedesktop.DBus.Error.ServiceUnknown" ]]; then
        pass "unowned: with nothing registered for org.freedesktop.FileManager1, ShowItems fails ServiceUnknown"
    else
        fail "unowned: an unregistered ShowItems answered $answer"
    fi
    [[ "$(lines)" == 0 ]] || fail "unowned: something was launched with no service registered"
    stop_bus
}

case_shows_item() {
    local answer want
    answer=$(ask ShowItems "$(uri_for "$fixture/docs/alpha.txt")")
    [[ "$answer" == "ok" ]] || { fail "showitem: ShowItems answered $answer"; return; }
    wait_for_lines 1 || { fail "showitem: no window was launched"; return; }
    want="--select|$fixture/docs/alpha.txt|"
    if [[ "$(tail -1 "$fixture/argv.log")" == "$want" ]]; then
        pass "showitem: D-Bus activation ran the service, which opened the parent with the item selected"
    else
        fail "showitem: the window was launched as $(tail -1 "$fixture/argv.log")"
    fi
}

# The decoding is glib's own and this proves it is reached: a space arrives percent-encoded and the
# argument handed to the window is the decoded name.
case_decodes() {
    local before answer want
    before=$(lines)
    answer=$(ask ShowItems "file://$fixture/docs/two%20words.txt")
    [[ "$answer" == "ok" ]] || { fail "decode: ShowItems answered $answer"; return; }
    wait_for_lines "$(( before + 1 ))" || { fail "decode: no window was launched"; return; }
    want="--select|$fixture/docs/two words.txt|"
    if [[ "$(tail -1 "$fixture/argv.log")" == "$want" ]]; then
        pass "decode: a percent-encoded name reaches the window decoded"
    else
        fail "decode: the window was launched as $(tail -1 "$fixture/argv.log")"
    fi
}

# A window can only put the cursor on one row, so two files in one directory are one window.
case_groups_by_directory() {
    local before answer
    before=$(lines)
    answer=$(ask ShowItems "$(uri_for "$fixture/docs/alpha.txt")" "$(uri_for "$fixture/docs/beta.txt")")
    [[ "$answer" == "ok" ]] || { fail "group: ShowItems answered $answer"; return; }
    wait_for_lines "$(( before + 1 ))" || { fail "group: no window was launched"; return; }
    sleep 1
    if [[ "$(lines)" == "$(( before + 1 ))" ]]; then
        pass "group: two items in one directory opened one window"
    else
        fail "group: two items in one directory opened $(( $(lines) - before )) windows"
    fi
}

# ShowFolders opens the folder itself, so it carries no --select at all.
case_shows_folder() {
    local before answer want
    before=$(lines)
    answer=$(ask ShowFolders "$(uri_for "$fixture/docs")" "$(uri_for "$fixture/docs")")
    [[ "$answer" == "ok" ]] || { fail "showfolder: ShowFolders answered $answer"; return; }
    wait_for_lines "$(( before + 1 ))" || { fail "showfolder: no window was launched"; return; }
    sleep 1
    [[ "$(lines)" == "$(( before + 1 ))" ]] || fail "showfolder: the repeated URI opened $(( $(lines) - before )) windows"
    want="$fixture/docs|"
    if [[ "$(tail -1 "$fixture/argv.log")" == "$want" ]]; then
        pass "showfolder: ShowFolders opened the folder itself, and the repeated URI opened one window"
    else
        fail "showfolder: the window was launched as $(tail -1 "$fixture/argv.log")"
    fi
}

# Flea has no properties dialog, so the honest answer is that it cannot, and never a browser window
# standing in for one. A window here would be the silent stub this decision exists to refuse.
case_properties_refused() {
    local before answer
    before=$(lines)
    answer=$(ask ShowItemProperties "$(uri_for "$fixture/docs/alpha.txt")")
    if [[ "$answer" == "error org.freedesktop.DBus.Error.NotSupported" ]]; then
        pass "properties: ShowItemProperties says NotSupported rather than showing something else"
    else
        fail "properties: ShowItemProperties answered $answer"
    fi
    sleep 1
    [[ "$(lines)" == "$before" ]] || fail "properties: ShowItemProperties opened a window anyway"
}

# The trust boundary: every one of these arrives from another application, and each must be refused
# on its own without taking the call down. A window launched for any of them is the failure.
case_refuses() {
    local before answer name uri entry
    local -a bad=(
        "a foreign scheme|http://example.com/x"
        "a bare path that is not a URI|/etc/passwd"
        "a foreign authority|file://evil.example$fixture/docs/alpha.txt"
        "an embedded newline, naming a file that is really there|file://$fixture/docs/al%0Apha.txt"
        "an embedded NUL|file://$fixture/docs/al%00pha.txt"
        "a path that is not there|file://$fixture/docs/gone.txt"
        "the root, which has no parent|file:///"
        "an empty URI|"
    )
    before=$(lines)
    for entry in "${bad[@]}"; do
        name=${entry%%|*}
        uri=${entry#*|}
        answer=$(ask ShowItems "$uri")
        if [[ "$answer" == "error org.freedesktop.DBus.Error.InvalidArgs" ]]; then
            note "refused $name"
        else
            fail "refuse: $name answered $answer"
        fi
    done
    # An empty call, which is the same refusal with nothing to refuse.
    answer=$(ask ShowItems)
    [[ "$answer" == "error org.freedesktop.DBus.Error.InvalidArgs" ]] || fail "refuse: a call with no URI answered $answer"
    # A good URI beside a bad one still opens, because one refusal must not take the call down.
    answer=$(ask ShowItems "http://example.com/x" "$(uri_for "$fixture/docs/beta.txt")")
    [[ "$answer" == "ok" ]] || fail "refuse: a good URI beside a bad one answered $answer"
    wait_for_lines "$(( before + 1 ))" || fail "refuse: the good URI in a mixed call opened no window"
    sleep 1
    if [[ "$(lines)" == "$(( before + 1 ))" ]]; then
        pass "refuse: eight bad URIs each answered InvalidArgs with no window, and a good one beside a bad one still opened"
    else
        fail "refuse: $(( $(lines) - before )) windows opened where one was expected"
    fi
}

# The registration only works installed, so the shipped file and the PKGBUILD lines are the case.
case_packaged() {
    local exec_line before
    before=$failed
    exec_line=$(grep '^Exec=' "$service_file")
    [[ "$exec_line" == "Exec=$install_path" ]] \
        || fail "packaged: the service file execs $exec_line, not $install_path"
    grep -Fq 'Name=org.freedesktop.FileManager1' "$service_file" \
        || fail "packaged: the service file does not claim org.freedesktop.FileManager1"
    grep -Fq "install -Dm755 tools/flea-filemanager1 \"\$pkgdir$install_path\"" "$root/PKGBUILD" \
        || fail "packaged: PKGBUILD does not install the service to $install_path"
    grep -Fq 'install -Dm644 packaging/com.thisisgm.flea.FileManager1.service -t "$pkgdir/usr/share/dbus-1/services"' "$root/PKGBUILD" \
        || fail "packaged: PKGBUILD does not install the D-Bus registration"
    # Named for Flea and not for the interface: nautilus owns the plain path on this box, and
    # dolphin, thunar and nemo each ship their own vendor-named file declaring the same Name=.
    [[ ! -e "$root/packaging/org.freedesktop.FileManager1.service" ]] \
        || fail "packaged: a file named for the interface would collide with the one nautilus owns"
    [[ "$failed" == "$before" ]] && pass "packaged: the executable and its vendor-named registration are installed"
}

make_fixture
case_unowned
start_bus "$fixture/services" || exit 1
case_shows_item
case_decodes
case_groups_by_directory
case_shows_folder
case_properties_refused
case_refuses
stop_bus
case_packaged

printf 'filemanager1: %d failure(s)\n' "$failed"
exit "$failed"
