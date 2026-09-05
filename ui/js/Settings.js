.pragma library

// The settings panel's whole model, so every row it draws is a value a test can read without a
// window: ui/SettingsPanel.qml only paints what rows() returns. The Settings, SettingsScale,
// SettingsMenus and SettingsKeys boards are what the tables below are copied from.

// Three sections, in the boards' own rail order less the four they draw beside them. View, Places,
// Preview and About have no working consumer in this release, and a rail row opening an empty pane
// is the dead entry point the release ruling keeps out of the shipped UI.
var SECTIONS = [
    { id: "keys", label: "Keys", glyph: "keyboard" },
    { id: "display", label: "Display", glyph: "sliders" },
    { id: "menus", label: "Menus", glyph: "list" }
]

// The six SettingsMenus.html puts under one master row, and the ids ui/js/Menu.js gives those rows.
var BASIC = ["cut", "copy", "paste", "duplicate", "rename", "trash"]

// Every action the listing menu can build, grouped as the board groups it. An id that this release
// cannot draw is absent rather than switched off: a toggle over a row no menu has is a mock control.
var MENU_GROUPS = [
    { label: "Basic file actions", master: true, ids: BASIC },
    { label: "Open and inspect", master: false, ids: ["copypath"] },
    { label: "Extras", master: false,
      ids: ["compress", "extract", "convert", "taildrop", "dropbox", "sharelink"] }
]

// Open and Show hidden files draw the lock mark instead of a box, and the board says why: a menu
// that cannot open the row under the cursor is not a menu, and the hidden toggle is the one
// background row with no keyboard-independent alternative.
var LOCKED = ["open", "toggleHidden"]

var LABELS = {
    cut: "Cut", copy: "Copy", paste: "Paste", duplicate: "Duplicate", rename: "Rename",
    trash: "Move to Trash", copypath: "Copy path", compress: "Compress", extract: "Extract",
    convert: "Convert", taildrop: "Send with Taildrop", dropbox: "Move to Dropbox",
    sharelink: "Copy share link", open: "Open", toggleHidden: "Show hidden files"
}

// The two values of the Keys row. SettingsKeys.html draws four; this release ships the toggle the
// public list named, Mac against Windows, over the one key table rather than a preset system.
var PRESETS = ["mac", "windows"]
var PRESET_LABELS = { mac: "Mac", windows: "Windows" }

function label(id) {
    return LABELS[id] || id
}

function contains(list, id) {
    for (var i = 0; list && i < list.length; i++) {
        if (list[i] === id)
            return true
    }
    return false
}

function isHidden(hidden, id) {
    return contains(hidden, id)
}

// GM's ruling: the count is of ENABLED actions, so "5 of 6" means one of the six is switched off.
function basicEnabled(hidden) {
    var on = 0
    for (var i = 0; i < BASIC.length; i++) {
        if (!isHidden(hidden, BASIC[i]))
            on += 1
    }
    return on
}

// The master has no stored value of its own: all, some and none are derived from the six ids alone,
// which is why removing the old menu.basic boolean took no control away with it.
function masterState(hidden) {
    var on = basicEnabled(hidden)
    if (on === BASIC.length)
        return "all"
    return on === 0 ? "none" : "some"
}

// Activating a checked master switches all six off; an unchecked or partial one switches all six on,
// so the recovering move is always the one keystroke. Unrelated hidden ids are preserved either way.
function toggleMaster(hidden) {
    var enable = masterState(hidden) !== "all"
    var next = []
    for (var i = 0; hidden && i < hidden.length; i++) {
        if (!enable || !contains(BASIC, hidden[i]))
            next.push(hidden[i])
    }
    if (!enable) {
        for (var b = 0; b < BASIC.length; b++) {
            if (!contains(next, BASIC[b]))
                next.push(BASIC[b])
        }
    }
    return next
}

function toggleId(hidden, id) {
    var next = []
    var had = false
    for (var i = 0; hidden && i < hidden.length; i++) {
        if (hidden[i] === id) {
            had = true
            continue
        }
        next.push(hidden[i])
    }
    if (!had)
        next.push(id)
    return next
}

// One row per line of the panel's pane. kind decides what ui/SettingsPanel.qml draws and whether the
// row is a focus stop: group, hint, fact and lock rows are read-only and the cursor steps over them.
function focusable(row) {
    return row.kind === "check" || row.kind === "master" || row.kind === "choice" || row.kind === "stepper"
}

// state: { scale, hidden, preset, baseSize, textSize }
function rows(section, state) {
    if (section === "display")
        return displayRows(state)
    if (section === "menus")
        return menuRows(state.hidden)
    return keyRows(state)
}

// The interface scale drives ui/js/Scale.js, the one engine Ctrl+Shift+Plus already steps, so the
// row and the chord cannot disagree. Text size is a fact and not a second scale: Flea reads
// Omarchy's own base size and reports what this scale makes of it.
function displayRows(state) {
    var percent = Math.round(state.scale * 100) + "%"
    return [
        { kind: "group", label: "Text size" },
        { kind: "stepper", id: "scale", label: "Interface scale", value: percent },
        { kind: "hint", label: "Ctrl+Shift+Plus and Ctrl+Shift+Minus step it, Ctrl+Shift+0 resets." },
        { kind: "fact", label: "Text size", value: state.baseSize + "px" },
        { kind: "hint", label: "Omarchy owns the base size. Flea draws its running text at "
                               + state.textSize + "px with this scale at " + percent + "." }
    ]
}

function menuRows(hidden) {
    var out = []
    for (var g = 0; g < MENU_GROUPS.length; g++) {
        var group = MENU_GROUPS[g]
        out.push({ kind: "group", label: group.label })
        if (group.master) {
            out.push({ kind: "master", id: "basic", label: "All basic file actions",
                       state: masterState(hidden),
                       value: basicEnabled(hidden) + " of " + BASIC.length })
        }
        for (var i = 0; i < group.ids.length; i++) {
            out.push({ kind: "check", id: group.ids[i], label: label(group.ids[i]),
                       on: !isHidden(hidden, group.ids[i]) })
        }
    }
    out.push({ kind: "group", label: "Always shown" })
    for (var l = 0; l < LOCKED.length; l++)
        out.push({ kind: "lock", id: LOCKED[l], label: label(LOCKED[l]) })
    return out
}

// The chord rows come from keys.toml through the generated Keymap.PRESET_KEYS, so a preset cannot
// advertise a binding it does not have; the caller passes the table in rather than importing it,
// which keeps this file free of the generated one.
function keyRows(state) {
    var out = [
        { kind: "group", label: "Preset" },
        { kind: "choice", id: "preset", label: "Keybinding preset",
          value: PRESET_LABELS[state.preset] || state.preset },
        { kind: "hint", label: "Mac and Windows, over the one key table. Every other binding is "
                               + "shared, and the change lands in this window at once." },
        { kind: "group", label: "This preset" }
    ]
    var table = state.presetKeys || []
    for (var i = 0; i < table.length; i++) {
        if (table[i].preset === state.preset)
            out.push({ kind: "fact", label: table[i].label, value: table[i].keys })
    }
    out.push({ kind: "hint", label: "Press ? for the keyboard sheet." })
    return out
}

// A read-only row is never the cursor, so both key steps and the opening cursor skip over one; the
// same shape ui/ContextMenu.qml's stepCursor uses, because a settings row and a menu row step alike.
function stepRow(list, from, delta) {
    var i = from + delta
    while (i >= 0 && i < list.length) {
        if (focusable(list[i]))
            return i
        i += delta
    }
    return from
}

function firstRow(list) {
    return list.length > 0 && focusable(list[0]) ? 0 : stepRow(list, 0, 1)
}
