.import "../../ui/js/Keymap.js" as Keymap

// SettingsKeys.html's four-value chooser, the preset suite split out of keymap.js at the 300-line
// hard cap the same way focus.js split. lookup() consults the overlay before every shared table, so
// the same call answers differently with the preset moved; every preset carries the three view
// chords, GM's ruling of 2026-09-06 over that board's dash, and every other row it governs is a
// bare shared key.
function run(check) {
    var ctrl = Qt.ControlModifier
    var shift = Qt.ShiftModifier
    check("the preset this build opens on is Default", Keymap.preset, "default")
    check("Default picks the list view on Ctrl+1, and Finder's other chords stay unbound under it",
          [Keymap.lookup(Qt.Key_1, "1", ctrl), Keymap.lookup(Qt.Key_H, "\u0008", ctrl),
           Keymap.lookup(Qt.Key_Up, "", ctrl), Keymap.lookup(Qt.Key_K, "\u000b", ctrl)].join("|"),
          "viewList|||")
    check("and the shared map is the rest of it, bare keys and chords alike",
          [Keymap.lookup(Qt.Key_J, "j", Qt.NoModifier), Keymap.lookup(Qt.Key_H, "h", Qt.NoModifier),
           Keymap.lookup(Qt.Key_C, "\u0003", ctrl)].join("|"), "cursorDown|parent|copy")

    // Every vim key is shared and preset-independent, so Vim differs from Default in nothing at all.
    Keymap.setPreset("vim")
    check("Vim answers exactly as Default does, chord and bare key alike",
          [Keymap.lookup(Qt.Key_1, "1", ctrl), Keymap.lookup(Qt.Key_H, "\u0008", ctrl),
           Keymap.lookup(Qt.Key_J, "j", Qt.NoModifier), Keymap.lookup(Qt.Key_G, "G", Qt.NoModifier)]
              .join("|"), "viewList||cursorDown|cursorLast")

    Keymap.setPreset("mac")
    check("Finder's Cmd+1 read as Ctrl+1 picks the list view under Mac",
          Keymap.lookup(Qt.Key_1, "1", ctrl), "viewList")
    check("and Explorer's Ctrl+H is not bound under it",
          Keymap.lookup(Qt.Key_H, "\u0008", ctrl), "")

    Keymap.setPreset("windows")
    check("the Windows preset binds Ctrl+H to the hidden files toggle",
          Keymap.lookup(Qt.Key_H, "\u0008", ctrl), "toggleHidden")
    check("and Explorer's own layout chords to the three views",
          [Keymap.lookup(Qt.Key_1, "", ctrl | shift), Keymap.lookup(Qt.Key_2, "", ctrl | shift),
           Keymap.lookup(Qt.Key_3, "", ctrl | shift)].join("|"), "viewList|viewColumns|viewGrid")
    check("Finder's Ctrl+1 goes quiet under it, which is what makes this a preset and not an addition",
          Keymap.lookup(Qt.Key_1, "1", ctrl), "")
    check("and so does Connect to Server", Keymap.lookup(Qt.Key_K, "\u000b", ctrl), "")
    // Everything the two platforms agree on stays in the shared tables and answers under both.
    check("the shared chords are untouched by the preset",
          [Keymap.lookup(Qt.Key_C, "\u0003", ctrl), Keymap.lookup(Qt.Key_F2, "", Qt.NoModifier),
           Keymap.lookup(Qt.Key_Backspace, "", Qt.NoModifier)].join("|"), "copy|rename|parent")

    // The three views are bound in no shared table, so a preset overlaying nothing left the keyboard
    // with no route to them at all. GM's ruling: asked of all four now, not only Mac and Windows.
    var views = function (mods) {
        return [Keymap.lookup(Qt.Key_1, "1", mods), Keymap.lookup(Qt.Key_2, "2", mods),
                Keymap.lookup(Qt.Key_3, "3", mods)].join("|")
    }
    var spelling = [["default", ctrl], ["vim", ctrl], ["mac", ctrl], ["windows", ctrl | shift]]
    var reached = []
    for (var p = 0; p < spelling.length; p++) {
        Keymap.setPreset(spelling[p][0])
        reached.push(spelling[p][0] + " " + views(spelling[p][1]))
    }
    check("every preset reaches all three views from the keyboard, each in its own spelling",
          reached.join(", "),
          "default viewList|viewColumns|viewGrid, vim viewList|viewColumns|viewGrid, "
          + "mac viewList|viewColumns|viewGrid, windows viewList|viewColumns|viewGrid")
    check("and all four were asked, so that check has a denominator", spelling.length, 4)

    // Shift+Delete is in the shared [[shift]] table and every preset row carries ctrl, which the
    // overlay requires before it can match anything, so no preset can take or shadow it: the same
    // call must answer delete under all four. mac's ctrl-delete is a different modifier state and
    // stays the trash beside it, which is Finder's own Cmd+Delete, and ctrl-shift-delete is bound
    // nowhere under either, mac's overlay row demanding no shift.
    Keymap.setPreset("mac")
    var macDelete = [Keymap.lookup(Qt.Key_Delete, "", shift), Keymap.lookup(Qt.Key_Delete, "", ctrl),
                     Keymap.lookup(Qt.Key_Delete, "", ctrl | shift)].join("|")
    Keymap.setPreset("default")
    check("shift delete is preset-proof, mac keeps ctrl delete trash beside it, and ctrl shift delete is bound nowhere",
          ["default", "vim", "mac", "windows"].map(function (n) {
              Keymap.setPreset(n)
              return Keymap.lookup(Qt.Key_Delete, "", shift)
          }).join("|") + "/" + macDelete + "/" + Keymap.lookup(Qt.Key_Delete, "", ctrl | shift),
          "delete|delete|delete|delete/delete|trash|/")
    Keymap.setPreset("default")

    // ui/ViewState.qml resolves a stored name that is not one of the four to default before it ever
    // reaches here, so an unknown name matching no overlay row is the validator's business, not this
    // module's: the shared tables still answer under it, and the overlay stays silent.
    Keymap.setPreset("marzipan")
    check("a preset name this build does not have reaches no overlay row, and no shared key with it",
          [Keymap.lookup(Qt.Key_1, "1", ctrl), Keymap.lookup(Qt.Key_H, "\u0008", ctrl),
           Keymap.lookup(Qt.Key_Backspace, "", Qt.NoModifier)].join("|"), "||parent")
    Keymap.setPreset("default")
}
