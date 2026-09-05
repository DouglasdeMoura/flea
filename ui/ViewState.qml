pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "js/Keymap.js" as Keymap
import "js/Settings.js" as Settings
import "js/TextSize.js" as TextSize

// The per-user view state that outlives a window: which list columns the user has hidden, and
// later whatever else a preference earns a toggle for. One JSON file under ~/.config/flea, read
// once at construction and rewritten on every change through the same FileView pattern the
// bookmarks use (ui/NetworkDialog.qml's write, ui/Sidebar.qml's watch). A write over a directory
// that does not exist yet is the one silent failure this singleton allows: the toggles keep
// working for the session and the state just does not outlive it.
QtObject {
    id: root

    // The list-column keys ("mode"/"size"/"date"/"kind") the user has hidden. Name is not here:
    // it is the one column a file manager cannot do without, see ui/js/Columns.js.
    property var hiddenCols: []

    // The Display section's text size. {"mode":"system"} follows Omarchy and is the default;
    // {"mode":"override","px":N} pins one of ui/js/TextSize.js's seven stops. ui/Theme.qml is the
    // only consumer, and the monitor scale beside it in the panel is the compositor's alone.
    property var textSize: TextSize.follow()

    // Omarchy's own size, held here so the Ctrl+Shift chords and the panel's own rows step away
    // from and back to one anchor rather than each resolving their own.
    readonly property int omarchyBase: Style.font.baseSize

    // The Display section's writers. ui/shell.qml routes keys.toml's textSizeUp, textSizeDown and
    // textSizeReset into the same three, so a chord and a control cannot hold two different sizes.
    function setTextSize(next) {
        root.textSize = TextSize.parse(next)
        root.save()
    }

    function followTextSize() {
        root.setTextSize(TextSize.follow())
    }

    function stepTextSize(direction) {
        root.setTextSize(TextSize.stepped(root.textSize, root.omarchyBase, direction))
    }

    function toggleTextFollow() {
        root.setTextSize(TextSize.following(root.textSize)
                         ? TextSize.pin(root.textSize, root.omarchyBase) : TextSize.follow())
    }

    // The context-menu actions switched off in the settings panel's Menus section, by action id.
    // ui/js/Menu.js applyHidden is the consumer and ui/ContextMenu.qml the one caller that passes
    // it in. Empty by default: the board's own default list names eight actions, seven of which
    // this release's menu cannot build at all, and the eighth ships visible today.
    property var menuHidden: []

    // "mac" or "windows", the Keys section's two-value toggle over the one generated key table.
    property string keysPreset: "mac"

    // The generated table holds the live preset, so this is the whole wire between the stored value
    // and every lookup: it fires on load and on a settings change alike, and rebinds in this process.
    onKeysPresetChanged: Keymap.setPreset(root.keysPreset)

    // The Menus section's own two writers. Both rebuild the array rather than mutating it, because
    // a var property notifies on assignment and not on a push, so a menu bound to it would not redraw.
    function toggleMenuAction(id) {
        root.menuHidden = Settings.toggleId(root.menuHidden, id)
        root.save()
    }

    function toggleMenuBasic() {
        root.menuHidden = Settings.toggleMaster(root.menuHidden)
        root.save()
    }

    // Flipped by ui/Pane.qml's onChosen, when a header-menu row answers "col:<key>".
    function toggleColumn(key) {
        var next = []
        var had = false
        for (var i = 0; i < root.hiddenCols.length; i++) {
            if (root.hiddenCols[i] === key) {
                had = true
                continue
            }
            next.push(root.hiddenCols[i])
        }
        if (!had)
            next.push(key)
        root.hiddenCols = next
        root.save()
    }

    function load() {
        try {
            var parsed = JSON.parse(store.text())
            if (parsed && parsed.hiddenCols)
                root.hiddenCols = parsed.hiddenCols
            // A stop this build does not have, or an older file's interface-scale multiplier,
            // reads as following Omarchy rather than as a size nothing on the list can draw.
            if (parsed && parsed.textSize)
                root.textSize = TextSize.parse(parsed.textSize)
            if (parsed && parsed.menuHidden)
                root.menuHidden = parsed.menuHidden
            // A file naming a preset this build does not have falls back to mac and keeps the rest,
            // the same per-key fallback the columns above take; setPreset does the same clamp again.
            if (parsed && Settings.contains(Settings.PRESETS, parsed.keysPreset))
                root.keysPreset = parsed.keysPreset
        } catch (e) {
            // A file another hand wrote is not this file's problem: the defaults stand.
        }
    }

    property var store: FileView {
        path: (Quickshell.env("XDG_CONFIG_HOME") && Quickshell.env("XDG_CONFIG_HOME").length > 0
               ? Quickshell.env("XDG_CONFIG_HOME") : Quickshell.env("HOME") + "/.config") + "/flea/view.json"
        watchChanges: false
        printErrors: false
        onLoaded: root.load()
        // No seed on a missing file: the defaults are the whole state until a toggle changes one,
        // and a first launch that never touched a column should leave nothing behind in ~/.config.
        onLoadFailed: root.hiddenCols = []
    }

    function save() {
        store.setText(JSON.stringify({ hiddenCols: root.hiddenCols, textSize: root.textSize,
                                       menuHidden: root.menuHidden, keysPreset: root.keysPreset },
                                     null, 2) + "\n")
    }
}
