import QtQuick
import qs.Commons
import "." as Flea
import "js/Keymap.js" as Keymap
import "js/Settings.js" as Settings

// The settings panel the Settings board draws: one floating surface, a fixed rail of sections and a
// pane that scrolls inside the work-area clamp. A plain overlay and not a QQC Popup, the call
// ui/ContextMenu.qml already made, because the one Controls import cost 10 ms of warm startup.
Item {
    id: root

    property bool opened: false
    property Item focusHolder: null
    // "keys", "display" or "menus"; the panel opens on Display because that is the promise it
    // carries, and the rail keeps the boards' own relative order around it.
    property string section: "display"
    property int cursor: 0
    // "rail" or "pane", which side Tab last gave the cursor to.
    property string side: "pane"

    // The interface scale goes back out to shell.qml's one applyScale, so this stepper and
    // Ctrl+Shift+Plus drive the same ui/js/Scale.js engine rather than two that can drift.
    signal scaleRequested(int direction)

    // Border-box 560 wide with a 150 rail, the board's own two numbers, in the scaled space token.
    readonly property int panelWidth: Theme.space(560)
    readonly property int railWidth: Theme.space(150)
    // The Menus board's work-area clamp: a floating surface never renders taller than its bounds
    // less this margin, and the pane scrolls inside that while the rail stays put.
    readonly property int clampMargin: 8
    readonly property real groundOpacity: 0.5

    readonly property var rows: Settings.rows(root.section, {
        scale: ViewState.uiScale,
        hidden: ViewState.menuHidden,
        preset: ViewState.keysPreset,
        baseSize: Style.font.baseSize,
        textSize: Theme.font.bodySmall,
        presetKeys: Keymap.PRESET_KEYS
    })

    // What a test reads instead of running OCR over the panel, the same idiom ui/KeymapSheet.qml's
    // rows() uses: one row per line, its kind, its wording and whatever value it currently holds.
    function rowsText() {
        var out = []
        for (var i = 0; i < root.rows.length; i++) {
            var row = root.rows[i]
            out.push(row.kind + "|" + row.label + "|" + (row.value !== undefined ? row.value : ""))
        }
        return out.join("\n")
    }

    function open(holder) {
        root.focusHolder = holder
        root.cursor = Settings.firstRow(root.rows)
        root.side = "pane"
        root.opened = true
        keys.forceActiveFocus()
    }

    function close() {
        if (!root.opened)
            return
        root.opened = false
        if (root.focusHolder)
            root.focusHolder.forceActiveFocus()
    }

    function showSection(id) {
        root.section = id
        root.cursor = Settings.firstRow(root.rows)
        flick.contentY = 0
    }

    // Enter and Space both land here. A choice steps rather than toggling, because two values need
    // no menu of their own, and the stepper's own activate is a reset to Omarchy's size.
    function activate(index) {
        var row = root.rows[index]
        if (!row || !Settings.focusable(row))
            return
        if (row.kind === "check")
            ViewState.toggleMenuAction(row.id)
        else if (row.kind === "master")
            ViewState.toggleMenuBasic()
        else if (row.kind === "stepper")
            root.scaleRequested(0)
        else
            root.stepRowValue(index, 1)
    }

    // h, l and the two chevrons. A stepper walks ui/js/Scale.js; a choice walks its own value list.
    function stepRowValue(index, direction) {
        var row = root.rows[index]
        if (!row)
            return
        if (row.kind === "stepper") {
            root.scaleRequested(direction)
            return
        }
        if (row.kind !== "choice")
            return
        var at = Settings.PRESETS.indexOf(ViewState.keysPreset)
        var next = (at + direction + Settings.PRESETS.length) % Settings.PRESETS.length
        ViewState.keysPreset = Settings.PRESETS[next]
        ViewState.save()
    }

    function moveCursor(delta) {
        if (root.side === "rail") {
            var at = Settings.SECTIONS.map(function (s) { return s.id }).indexOf(root.section)
            var to = Math.max(0, Math.min(Settings.SECTIONS.length - 1, at + delta))
            root.showSection(Settings.SECTIONS[to].id)
            return
        }
        root.cursor = Settings.stepRow(root.rows, root.cursor, delta)
        root.showCursor()
    }

    // The Column inside the Flickable holds rows of two different heights, so the visible window is
    // moved onto the row itself rather than derived from an index times a row height.
    function showCursor() {
        var item = rowItems.itemAt(root.cursor)
        if (!item)
            return
        if (item.y < flick.contentY)
            flick.contentY = item.y
        else if (item.y + item.height > flick.contentY + flick.height)
            flick.contentY = item.y + item.height - flick.height
    }

    anchors.fill: parent
    visible: root.opened
    // Above the context menu and the keymap sheet: the panel is the surface that opened last.
    z: 3

    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
        opacity: root.groundOpacity

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: root.panelWidth
        height: Math.min(Theme.chromeHeight + Math.max(rail.implicitHeight, pane.implicitHeight)
                         + 2 * Theme.spacing.rowPaddingY,
                         root.height - root.clampMargin)
        color: Theme.color.surface
        border.width: Theme.spacing.hairline
        border.color: Theme.color.muted
        // Mirrors hyprland decoration:rounding, same as ui/KeymapSheet.qml; 0 on a stock box stays square.
        radius: Style.cornerRadius
        clip: true

        Item {
            id: chrome
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Theme.chromeHeight

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: "Settings"
                color: Theme.color.foreground
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySmall
                font.bold: true
                textFormat: Text.PlainText
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: "esc"
                color: Theme.color.muted
                font.family: Theme.font.family
                font.pixelSize: Theme.font.caption
                textFormat: Text.PlainText
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Theme.spacing.hairline
                color: Theme.color.muted
                opacity: 0.4
            }
        }

        Flea.SettingsRail {
            id: rail
            anchors.left: parent.left
            anchors.top: chrome.bottom
            anchors.topMargin: Theme.spacing.rowPaddingY
            width: root.railWidth
            section: root.section
            focused: root.side === "rail"
            onChosen: function (id) {
                root.side = "rail"
                root.showSection(id)
            }
        }

        Rectangle {
            anchors.left: rail.right
            anchors.top: chrome.bottom
            anchors.bottom: parent.bottom
            width: Theme.spacing.hairline
            color: Theme.color.muted
            opacity: 0.4
        }

        Flickable {
            id: flick
            anchors.left: rail.right
            anchors.right: parent.right
            anchors.top: chrome.bottom
            anchors.bottom: parent.bottom
            anchors.topMargin: Theme.spacing.rowPaddingY
            contentWidth: width
            contentHeight: pane.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: pane
                width: flick.width

                Repeater {
                    id: rowItems
                    model: root.rows

                    delegate: Flea.SettingsRow {
                        required property var modelData
                        required property int index
                        width: pane.width
                        row: modelData
                        current: root.side === "pane" && root.cursor === index
                        onActivated: {
                            root.side = "pane"
                            root.cursor = index
                            root.activate(index)
                        }
                        onStepped: function (direction) {
                            root.side = "pane"
                            root.cursor = index
                            root.stepRowValue(index, direction)
                        }
                    }
                }
            }
        }
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onPressed: function (event) {
            event.accepted = true
            if (event.key === Qt.Key_Escape) {
                root.close()
                return
            }
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.side = root.side === "rail" ? "pane" : "rail"
                return
            }
            if (event.key === Qt.Key_Down || event.text === "j") {
                root.moveCursor(1)
                return
            }
            if (event.key === Qt.Key_Up || event.text === "k") {
                root.moveCursor(-1)
                return
            }
            // h and l step a control, which only the pane has; from the rail they do nothing rather
            // than reaching across and changing a value the cursor is not on.
            if (event.key === Qt.Key_Right || event.text === "l") {
                if (root.side === "pane")
                    root.stepRowValue(root.cursor, 1)
                return
            }
            if (event.key === Qt.Key_Left || event.text === "h") {
                if (root.side === "pane")
                    root.stepRowValue(root.cursor, -1)
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                if (root.side === "rail")
                    root.side = "pane"
                else
                    root.activate(root.cursor)
            }
            // Every other key stops here: an open panel that let one through would move the cursor
            // in the listing behind it, which is the hidden-view keyboard defect AGENTS.md records.
        }
    }
}
