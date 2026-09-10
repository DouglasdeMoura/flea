import QtQuick
import qs.Commons
import "." as Flea
import "js/OpenWith.js" as OpenWith

// OpenWith.html rule 4: the Convert popup family, and the one place a default handler is written.
// The flyout beside it overrides once and writes nothing; only this card touches mimeapps.list.
Item {
    id: root

    property bool opened: false
    readonly property string action: "openWith"
    property int requestId: 0
    property string folder: ""
    property Item focusHolder: null
    property bool busy: false
    property bool committing: false
    property string errorText: ""
    property string path: ""
    property string kind: ""
    property string mime: ""
    property var handlers: []
    property var installed: []
    property bool always: false
    property int cursor: 0
    // 0 search, 1 list, 2 always box, 3 Cancel, 4 Open: rule 8's own cycle, and it wraps.
    property int focusPart: 1

    signal requested(var message)

    readonly property string name: root.path.split("/").pop()
    readonly property var rows: OpenWith.rows(root.handlers, root.installed, root.kind, field.text)
    readonly property var applications: OpenWith.applications(root.rows)
    readonly property var chosen: root.applications[root.cursor]
    readonly property bool canSubmit: !root.busy && root.chosen !== undefined
    // The shared menu-dialog probe reads these; ui/Ipc.qml openWithState adds this board's own rows.
    readonly property var facts: ({})
    readonly property bool deletionActive: false
    readonly property var confirmationItem: null
    readonly property var cardItem: card
    readonly property var closeItem: cancelButton
    readonly property var submitItem: openButton
    readonly property var fieldItem: field
    readonly property var applicationsItem: list
    readonly property var alwaysItem: alwaysBox
    readonly property var listItem: list
    function applicationItem(index) { return rowItems.itemAt(OpenWith.rowOf(root.rows, index)) }

    // Rule 5: seven rows before the list scrolls. A box with fewer applications than that leaves the
    // rest of the area empty rather than resizing the card as the search narrows it.
    readonly property int viewportRows: 7
    readonly property int listHeight: root.viewportRows * Theme.rowHeight
    readonly property int clampMargin: 8

    anchors.fill: parent
    visible: root.opened
    z: 2

    function open(operation, id, sourceFolder, holder) {
        root.requestId = id
        root.folder = sourceFolder
        root.focusHolder = holder
        root.path = ""
        root.kind = ""
        root.mime = ""
        root.handlers = []
        root.installed = []
        root.always = false
        root.cursor = 0
        root.errorText = ""
        root.committing = false
        root.busy = true
        root.focusPart = 1
        field.text = ""
        root.opened = true
        list.contentY = 0
        list.forceActiveFocus()
        root.requested({c: "menuaction", op: "applications", id: id})
    }

    function close() {
        if (!root.opened) return
        root.opened = false
        root.busy = false
        root.committing = false
        if (root.focusHolder) root.focusHolder.forceActiveFocus()
    }

    // The pane calls this when the folder is refreshed under an open dialog. Nothing to redraw here:
    // the backend rechecks the captured item on submit, so a selection that moved refuses there.
    function sourceChanged() {}

    function receive(message) {
        if (!root.opened || message.id !== root.requestId) return
        if (message.op === "applications") {
            root.busy = false
            if (!message.ok) { root.errorText = message.error || "The registry could not be read."; return }
            root.path = message.path || ""
            root.kind = message.kind || ""
            root.mime = message.mime || ""
            root.handlers = message.applications || []
            root.installed = message.installed || []
            root.cursor = 0
            return
        }
        if (message.op !== "openWith") return
        root.busy = false
        root.committing = false
        if (message.ok) { root.close(); return }
        if (!message.cancelled) root.errorText = message.error || "The application could not be opened."
    }

    function commit() {
        if (!root.canSubmit) return
        root.errorText = ""
        root.busy = true
        root.committing = true
        root.requested({c: "menuaction", op: "openWith", id: root.requestId,
                        application: root.chosen.id, always: root.always})
    }

    function moveCursor(delta) {
        var count = root.applications.length
        if (!count) return
        root.focusPart = 1
        root.cursor = Math.max(0, Math.min(count - 1, root.cursor + delta))
        list.forceActiveFocus()
        list.reveal(root.applicationItem(root.cursor))
    }

    function stepFocus(back) {
        if (root.busy) return
        var parts = [0, 1, 2, 3, 4]
        var at = parts.indexOf(root.focusPart)
        root.focusPart = parts[(at + (back ? parts.length - 1 : 1)) % parts.length]
        var item = [field, list, alwaysBox, cancelButton, openButton][root.focusPart]
        item.forceActiveFocus()
    }

    // Rule 8: typing anywhere goes to the search, so a key nothing else claimed lands in the field.
    function typeIntoSearch(text) {
        root.focusPart = 0
        field.forceActiveFocus()
        field.insert(field.length, text)
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
        opacity: 0.5

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            onClicked: root.close()
            onWheel: function (wheel) { wheel.accepted = true }
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.max(0, Math.min(Math.round(Theme.space(480) * Theme.dialogWidthRatio), root.width - 2 * root.clampMargin))
        height: Math.max(0, Math.min(body.implicitHeight + 2 * Theme.spacing.rowPaddingX, root.height - 2 * root.clampMargin))
        color: Theme.color.surface
        border.width: Theme.spacing.hairline
        border.color: Theme.color.muted
        radius: Style.cornerRadius

        // The checkbox handler takes a passive grab, so without this sink its press reaches the ground.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            onClicked: {}
            onWheel: function (wheel) { wheel.accepted = true }
        }

        Column {
            id: body
            anchors.fill: parent
            anchors.topMargin: Theme.spacing.rowPaddingX
            anchors.bottomMargin: Theme.spacing.rowPaddingX
            clip: true

            Text {
                id: title
                width: parent.width
                leftPadding: Theme.spacing.rowPaddingX
                rightPadding: Theme.spacing.rowPaddingX
                bottomPadding: Theme.spacing.gap
                text: "Open " + root.name + " with"
                color: Theme.color.foreground
                font.family: Theme.font.family
                font.pixelSize: Theme.font.body
                font.bold: true
                textFormat: Text.PlainText
                elide: Text.ElideMiddle
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Theme.spacing.hairline
                    color: Theme.color.muted
                    opacity: 0.4
                }
            }

            // Rule 4: the Network board's field, with the lens beside it and a clear mark once it holds text.
            Item {
                width: parent.width
                height: searchBox.height + Theme.spacing.gap

                Rectangle {
                    id: searchBox
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacing.rowPaddingX
                    anchors.rightMargin: Theme.spacing.rowPaddingX
                    anchors.bottom: parent.bottom
                    height: Theme.rowHeight - Theme.spacing.rowPaddingY
                    color: Theme.color.background
                    border.width: Theme.spacing.hairline
                    border.color: field.activeFocus ? Theme.color.accent : Theme.color.muted

                    Flea.Glyph {
                        id: lens
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacing.gap
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.font.body
                        height: Theme.font.body
                        name: "search"
                        color: Theme.color.muted
                    }

                    TextInput {
                        id: field
                        anchors.left: lens.right
                        anchors.right: clear.left
                        anchors.leftMargin: Theme.spacing.gap
                        anchors.rightMargin: Theme.spacing.gap
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.color.foreground
                        selectionColor: Theme.color.accent
                        selectedTextColor: Theme.color.background
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.body
                        clip: true
                        activeFocusOnTab: false
                        Keys.forwardTo: [keys]
                        onTextChanged: { root.cursor = 0; list.contentY = 0 }
                    }

                    Text {
                        anchors.left: field.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text.length === 0
                        text: "Search applications"
                        color: Theme.color.muted
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.body
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                    }

                    Item {
                        id: clear
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacing.gap
                        anchors.verticalCenter: parent.verticalCenter
                        width: field.text.length > 0 ? Theme.font.caption : 0
                        height: Theme.font.caption

                        Flea.Glyph {
                            anchors.fill: parent
                            visible: field.text.length > 0
                            name: "x"
                            color: Theme.color.muted
                        }

                        TapHandler {
                            enabled: field.text.length > 0
                            acceptedButtons: Qt.LeftButton
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: { field.text = ""; root.focusPart = 0; field.forceActiveFocus() }
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: root.listHeight

                Flickable {
                    id: list
                    anchors.fill: parent
                    clip: true
                    contentWidth: width
                    contentHeight: rowsColumn.height
                    boundsBehavior: Flickable.StopAtBounds
                    activeFocusOnTab: false
                    Keys.forwardTo: [keys]

                    function reveal(item) {
                        if (!item || list.contentHeight <= list.height) return
                        var top = item.y
                        var bottom = top + item.height
                        if (top < list.contentY) list.contentY = Math.max(0, top)
                        else if (bottom > list.contentY + list.height)
                            list.contentY = Math.min(list.contentHeight - list.height, bottom - list.height)
                    }

                    Column {
                        id: rowsColumn
                        width: list.width

                        Repeater {
                            id: rowItems
                            model: root.rows

                            delegate: Item {
                                id: row
                                required property var modelData
                                required property int index
                                readonly property bool isEyebrow: row.modelData.eyebrow !== undefined
                                // The cursor counts applications only, so an eyebrow never takes it.
                                readonly property int appIndex: row.isEyebrow ? -1 : row.modelData.at
                                width: rowsColumn.width
                                height: row.isEyebrow ? eyebrow.implicitHeight + Theme.spacing.gap : menuRow.height

                                Rectangle {
                                    anchors.top: parent.top
                                    width: parent.width
                                    height: Theme.spacing.hairline
                                    visible: row.isEyebrow && row.modelData.rule === true
                                    color: Theme.color.muted
                                    opacity: 0.4
                                }

                                Text {
                                    id: eyebrow
                                    visible: row.isEyebrow
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacing.rowPaddingX
                                    anchors.bottom: parent.bottom
                                    text: row.isEyebrow ? row.modelData.eyebrow : ""
                                    color: Theme.color.muted
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.caption
                                    font.bold: true
                                    font.capitalization: Font.AllUppercase
                                    font.letterSpacing: Theme.font.caption * 0.14
                                    textFormat: Text.PlainText
                                }

                                Flea.MenuRow {
                                    id: menuRow
                                    visible: !row.isEyebrow
                                    width: parent.width
                                    entry: row.isEyebrow ? ({}) : ({ label: row.modelData.label, action: "",
                                        icon: row.modelData.icon, glyph: "app-window",
                                        hint: row.modelData.default === true ? "default" : "" })
                                    current: !row.isEyebrow && root.cursor === row.appIndex
                                    onPointerMoved: if (!row.isEyebrow) { root.focusPart = 1; root.cursor = row.appIndex }
                                    onActivated: if (!row.isEyebrow) { root.cursor = row.appIndex; root.commit() }
                                }
                            }
                        }
                    }
                }

                // Rule 6: the area keeps its height and centres the one caption that says why it is empty.
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 4 * Theme.spacing.rowPaddingX
                    visible: !root.busy && !root.rows.length && field.text.trim().length > 0
                    text: OpenWith.noMatch(field.text)
                    color: Theme.color.muted
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.caption
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }

                // The fade that says the viewport cut the list, drawn in the card's own ground.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Theme.spacing.gap
                    visible: list.contentHeight > list.height && list.contentY < list.contentHeight - list.height - 1
                    gradient: Gradient {
                        GradientStop { position: 0; color: Qt.rgba(Theme.color.surface.r, Theme.color.surface.g, Theme.color.surface.b, 0) }
                        GradientStop { position: 1; color: Theme.color.surface }
                    }
                }
            }

            // Rule 7: the Convert board's checkbox row, drawn at this board's own 14 unit frame.
            Item {
                id: alwaysBox
                width: parent.width
                height: Theme.rowHeight
                activeFocusOnTab: true
                Keys.forwardTo: [keys]
                Accessible.role: Accessible.CheckBox
                Accessible.name: alwaysLabel.text
                Accessible.checkable: true
                Accessible.checked: root.always
                Accessible.onPressAction: root.always = !root.always

                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: Theme.spacing.hairline
                    color: Theme.color.muted
                    opacity: 0.4
                }

                Rectangle {
                    id: box
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round(14 * Theme.font.bodySmall / 13)
                    height: width
                    color: "transparent"
                    border.width: Theme.spacing.hairline * 2
                    border.color: root.always || root.focusPart === 2 ? Theme.color.accent : Theme.color.muted

                    Flea.Glyph {
                        anchors.centerIn: parent
                        width: parent.width / 2
                        height: width
                        visible: root.always
                        name: "check"
                        color: Theme.color.accent
                    }
                }

                Text {
                    id: alwaysLabel
                    anchors.left: box.right
                    anchors.leftMargin: Theme.spacing.gap
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Always use this application for " + root.kind + " files"
                    color: Theme.color.foreground
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.body
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: { root.focusPart = 2; root.always = !root.always; alwaysBox.forceActiveFocus() }
                }
            }

            Text {
                id: consequence
                width: parent.width
                leftPadding: Theme.spacing.rowPaddingX + box.width + Theme.spacing.gap
                rightPadding: Theme.spacing.rowPaddingX
                bottomPadding: Theme.spacing.gap
                text: "Writes one line to your mimeapps.list. Undo does not reverse it; change it here again."
                color: Theme.color.muted
                font.family: Theme.font.family
                font.pixelSize: Theme.font.caption
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
            }

            Text {
                width: parent.width
                leftPadding: Theme.spacing.rowPaddingX
                rightPadding: Theme.spacing.rowPaddingX
                bottomPadding: Theme.spacing.gap
                visible: root.errorText.length > 0
                text: root.errorText
                color: Theme.color.error
                font.family: Theme.font.family
                font.pixelSize: Theme.font.caption
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
            }

            Item {
                width: parent.width
                height: Math.max(cancelButton.implicitHeight, openButton.implicitHeight)

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacing.rowPaddingX
                    spacing: Theme.spacing.gap

                    Flea.DialogButton {
                        id: cancelButton
                        label: "Cancel"
                        primary: root.focusPart === 3
                        available: true
                        activeFocusOnTab: true
                        Keys.forwardTo: [keys]
                        onActivated: root.close()
                    }

                    Flea.DialogButton {
                        id: openButton
                        label: root.committing ? "Opening..." : "Open"
                        primary: root.canSubmit
                        fillColor: root.canSubmit ? "transparent" : Theme.color.background
                        available: root.canSubmit
                        activeFocusOnTab: true
                        opacity: available ? 1 : 0.55
                        Keys.forwardTo: [keys]
                        onActivated: root.commit()
                    }
                }
            }
        }
    }

    Item {
        id: keys
        anchors.fill: parent

        // Rule 8's whole map. A printable key nobody above claimed is search text, whatever holds focus.
        Keys.onPressed: function (event) {
            event.accepted = true
            if (event.key === Qt.Key_Escape) { root.close(); return }
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.stepFocus(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0)
                return
            }
            if (root.busy) return
            var quiet = field.text.length === 0
            if (event.key === Qt.Key_Down || (quiet && event.key === Qt.Key_J)) { root.moveCursor(1); return }
            if (event.key === Qt.Key_Up || (quiet && event.key === Qt.Key_K)) { root.moveCursor(-1); return }
            if (event.key === Qt.Key_PageDown) { root.moveCursor(root.viewportRows); return }
            if (event.key === Qt.Key_PageUp) { root.moveCursor(-root.viewportRows); return }
            if (event.key === Qt.Key_Space && quiet) { root.always = !root.always; return }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.focusPart === 3) root.close()
                else if (root.focusPart === 2) root.always = !root.always
                else root.commit()
                return
            }
            if (event.text.length > 0 && event.text.charCodeAt(0) >= 0x20 && !(event.modifiers & Qt.ControlModifier)) {
                if (!field.activeFocus) { root.typeIntoSearch(event.text); return }
            }
            event.accepted = false
        }
    }
}
