import QtQuick
import qs.Commons
import "." as Flea
import "js/Permissions.js" as Permissions

// One item, one mode; the backend owns its reviewed descriptor for this dialog's lifetime.
FocusScope {
    id: root
    anchors.fill: parent
    visible: opened
    property bool opened: false
    property int requestId: 0
    property var facts: ({})
    property string path: ""
    property string modeText: ""
    property string errorText: ""
    property bool busy: false
    property Item focusHolder: null
    readonly property bool editable: facts.ok === true && !facts.reason && !busy
    readonly property int modeValue: Permissions.parse(modeText)
    readonly property var cardItem: card
    readonly property string scopeText: facts.directory
        ? "Scope this directory only · enclosed items unchanged · ownership unchanged"
        : "Scope this item only · ownership unchanged"
    signal requested(var message)
    signal changed()
    signal closed()

    function open(itemPath, holder) {
        requestId += 1
        path = itemPath
        focusHolder = holder
        facts = ({})
        modeText = ""
        errorText = ""
        busy = true
        opened = true
        body.contentY = 0
        cancelFocus.forceActiveFocus()
        requested({ c: "permissions", op: "inspect", id: requestId, path: path })
    }
    function receive(message) {
        if (!opened || message.id !== requestId || message.op === "close") return
        busy = false
        if (!message.ok) { errorText = message.error || "Could not change permissions."; return }
        if (message.op === "apply") { changed(); close(); return }
        facts = message
        modeText = message.mode
    }
    function close() {
        if (!opened) return
        requested({ c: "permissions", op: "close", id: requestId })
        opened = false
        closed()
        if (focusHolder) focusHolder.forceActiveFocus()
    }
    function apply() {
        if (!editable || modeValue < 0) return
        busy = true
        errorText = ""
        requested({ c: "permissions", op: "apply", id: requestId, mode: modeText })
    }
    function focusItems(item, result) {
        if (!item.visible || !item.enabled) return
        if (item.activeFocusOnTab) result.push(item)
        for (var i = 0; i < item.children.length; i++) focusItems(item.children[i], result)
    }
    function stepFocus(back) {
        var items = []
        focusItems(body, items)
        if (!items.length) return
        var current = -1
        for (var i = 0; i < items.length; i++) if (items[i].activeFocus) current = i
        var next = (current + (back ? -1 : 1) + items.length) % items.length
        items[next].forceActiveFocus()
    }
    Keys.onTabPressed: function(event) { root.stepFocus(false); event.accepted = true }
    Keys.onBacktabPressed: function(event) { root.stepFocus(true); event.accepted = true }
    Keys.onPressed: function(event) { event.accepted = true }
    Keys.onEscapePressed: function(event) { root.close(); event.accepted = true }
    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
        opacity: 0.5
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: root.close()
            onWheel: function(wheel) { wheel.accepted = true }
        }
    }
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.max(0, Math.min(Theme.space(420), root.width - 2 * Theme.spacing.gap))
        height: Math.max(0, Math.min(body.wanted + 2 * Theme.spacing.rowPaddingX, root.height - 2 * Theme.spacing.gap))
        color: Theme.color.surface
        border.color: Theme.color.muted
        border.width: Theme.spacing.hairline
        radius: Style.cornerRadius
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onWheel: function(wheel) { wheel.accepted = true }
        }
        Flea.CardScroll {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.spacing.rowPaddingX
            Column {
                width: body.width
                spacing: Theme.spacing.gap
                Row {
                    width: parent.width
                    spacing: Theme.spacing.gap
                    Flea.Glyph { width: Theme.font.bodySmall; height: title.height; name: "lock"; color: Theme.color.accent }
                    Text {
                        id: title
                        width: parent.width - 2 * Theme.font.bodySmall - 2 * parent.spacing
                        text: "Permissions"
                        color: Theme.color.foreground
                        font { family: Theme.font.family; pixelSize: Theme.font.body; bold: true }
                        textFormat: Text.PlainText
                    }
                    Flea.Glyph { width: Theme.font.bodySmall; height: title.height; name: "x"; color: Theme.color.muted
                        TapHandler { onTapped: root.close() }
                    }
                }
                Rectangle { width: parent.width; height: Theme.spacing.hairline; color: Theme.color.muted; opacity: 0.4 }
                Row {
                    width: parent.width
                    spacing: Theme.spacing.gap
                    Flea.Glyph { width: Theme.markSize; height: nameLabel.height; name: root.facts.directory ? "folder" : "file"; color: Theme.color.foreground }
                    Text { id: nameLabel; width: parent.width - Theme.markSize - kindLabel.width - 2 * parent.spacing; text: root.path.split("/").pop(); elide: Text.ElideMiddle; textFormat: Text.PlainText; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                    Text { id: kindLabel; text: root.facts.ok ? (root.facts.directory ? "directory" : "file") : ""; textFormat: Text.PlainText; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                }
                Row {
                    width: parent.width
                    Item { width: Theme.space(86); height: Theme.font.caption }
                    Repeater {
                        model: ["READ", "WRITE", root.facts.directory ? "ENTER" : "EXEC"]
                        Text { required property string modelData; width: (body.width - Theme.space(86)) / 3; horizontalAlignment: Text.AlignHCenter; text: modelData; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                    }
                }
                Repeater {
                    model: ["Owner", "Group", "Everyone"]
                    Row {
                        id: permissionRow
                        required property string modelData
                        required property int index
                        width: body.width
                        height: Theme.rowHeight
                        Text { width: Theme.space(86); anchors.verticalCenter: parent.verticalCenter; text: permissionRow.modelData; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                        Repeater {
                            model: 3
                            FocusScope {
                                id: checkbox
                                required property int index
                                readonly property int bit: 1 << (8 - permissionRow.index * 3 - index)
                                readonly property bool checked: (root.modeValue >= 0 ? root.modeValue : parseInt(root.facts.mode || "0", 8)) & bit
                                width: (body.width - Theme.space(86)) / 3
                                height: permissionRow.height
                                activeFocusOnTab: root.editable
                                opacity: root.editable ? 1 : 0.45
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: permissionRow.modelData + " " + ["read", "write", root.facts.directory ? "enter" : "execute"][index]
                                Accessible.checked: checked
                                function toggle() { if (root.editable) { root.modeText = Permissions.toggle(root.modeText, bit); forceActiveFocus() } }
                                Keys.onSpacePressed: toggle()
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: Theme.font.bodySmall
                                    height: width
                                    color: "transparent"
                                    border.width: Theme.spacing.hairline * 2
                                    border.color: checkbox.checked || checkbox.activeFocus ? Theme.color.accent : Theme.color.muted
                                    Flea.Glyph { anchors.fill: parent; name: "check"; visible: checkbox.checked; color: Theme.color.accent }
                                }
                                TapHandler { onTapped: checkbox.toggle() }
                            }
                        }
                    }
                }
                Rectangle { width: parent.width; height: Theme.spacing.hairline; color: Theme.color.muted; opacity: 0.4 }
                Row {
                    width: parent.width
                    height: Theme.rowHeight
                    Text { width: Theme.space(86); anchors.verticalCenter: parent.verticalCenter; text: "Octal"; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                    Rectangle {
                        width: body.width - Theme.space(86)
                        height: parent.height
                        color: Theme.color.background
                        border.color: octal.activeFocus ? Theme.color.accent : Theme.color.muted
                        TextInput {
                            id: octal
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.gap
                            text: root.modeText
                            readOnly: !root.editable
                            activeFocusOnTab: root.editable
                            color: root.editable ? Theme.color.foreground : Theme.color.muted
                            font { family: Theme.font.family; pixelSize: Theme.font.body }
                            clip: true
                            onTextEdited: root.modeText = text
                            onAccepted: if (root.editable && root.modeValue >= 0) applyFocus.forceActiveFocus()
                        }
                    }
                }
                Repeater {
                    model: ["Owner", "Group"]
                    Row {
                        required property string modelData
                        required property int index
                        width: body.width
                        height: Theme.rowHeight
                        Text { width: Theme.space(86); text: parent.modelData; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                        Text { width: body.width - Theme.space(86) - identity.width; text: root.facts.ok ? ((parent.index === 0 ? root.facts.owner : root.facts.group) || "Unknown") + " · read-only" : ""; textFormat: Text.PlainText; elide: Text.ElideRight; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                        Text { id: identity; text: root.facts.ok ? (parent.index === 0 ? "uid " + root.facts.uid : "gid " + root.facts.gid) : ""; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                    }
                }
                Text { width: parent.width; visible: root.facts.directory === true; text: "✓ Scope: this directory only. Enclosed files and directories keep every bit."; wrapMode: Text.Wrap; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                Text { width: parent.width; visible: text.length > 0; text: root.errorText || root.facts.reason || (root.facts.ok && root.modeValue < 0 ? "Enter three octal digits or a leading-zero four-digit mode." : root.busy ? "Reading permissions…" : ""); textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.busy ? Theme.color.muted : Theme.color.error; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                Rectangle { width: parent.width; height: Theme.spacing.hairline; color: Theme.color.muted; opacity: 0.4 }
                Text { text: "WILL CHANGE"; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                Text { width: parent.width; text: (root.editable && root.modeValue >= 0 ? "Requested mode " + Permissions.octal(root.modeValue) : "No changes available") + "\nPath " + root.path; textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere; color: root.editable ? Theme.color.accent : Theme.color.muted; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                Text { width: parent.width; text: root.scopeText; wrapMode: Text.Wrap; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
                Row {
                    anchors.right: parent.right
                    spacing: Theme.spacing.gap
                    FocusScope {
                        id: cancelFocus
                        width: cancelButton.implicitWidth; height: cancelButton.implicitHeight
                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.close()
                        Keys.onSpacePressed: root.close()
                        Flea.DialogButton { id: cancelButton; label: "Cancel"; primary: parent.activeFocus; onActivated: root.close() }
                    }
                    FocusScope {
                        id: applyFocus
                        width: applyButton.implicitWidth; height: applyButton.implicitHeight
                        activeFocusOnTab: root.editable && root.modeValue >= 0
                        Keys.onReturnPressed: root.apply()
                        Keys.onSpacePressed: root.apply()
                        Flea.DialogButton { id: applyButton; label: "Apply"; primary: parent.activeFocus; available: root.editable && root.modeValue >= 0; onActivated: root.apply() }
                    }
                }
            }
        }
    }
}
