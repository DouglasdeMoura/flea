import QtQuick
import qs.Commons
import "." as Flea
import "js/Format.js" as Format

// The destructive choice must be reached deliberately; a reflexive Enter activates Cancel.
FocusScope {
    id: root
    anchors.fill: parent
    visible: opened
    property bool opened: false
    property var snapshot: ({})
    property bool destructiveFocus: false
    signal confirmed(int token)
    signal cancelled()
    readonly property var cardItem: card
    function open(value) { snapshot = value; destructiveFocus = false; opened = true; forceActiveFocus() }
    function close() { opened = false }
    function cancel() { close(); cancelled() }
    function activate() {
        if (!destructiveFocus) { cancel(); return }
        var token = snapshot.token
        close()
        confirmed(token)
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) root.cancel()
        else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) root.destructiveFocus = !root.destructiveFocus
        else if (event.key === Qt.Key_L || event.key === Qt.Key_Right) root.destructiveFocus = true
        else if (event.key === Qt.Key_H || event.key === Qt.Key_Left) root.destructiveFocus = false
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) root.activate()
        event.accepted = true
    }
    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
        opacity: 0.5
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: root.cancel()
            onWheel: function(wheel) { wheel.accepted = true }
        }
    }
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.max(0, Math.min(Theme.space(340), root.width - 2 * Theme.spacing.gap))
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
                    Flea.Glyph { width: Theme.markSize; height: title.height; name: "alert"; color: Theme.color.error }
                    Text {
                        id: title
                        width: parent.width - Theme.markSize - parent.spacing
                        text: root.snapshot.all ? "Empty Trash?" : "Delete " + root.snapshot.count + " items permanently?"
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: Theme.color.foreground
                        font { family: Theme.font.family; pixelSize: Theme.font.body; bold: true }
                    }
                }
                Text {
                    width: parent.width
                    text: root.snapshot.all
                        ? root.snapshot.count + " items, " + (root.snapshot.partial ? "at least " : "") + Format.size(root.snapshot.bytes || 0) + ". This deletes them from disk. Undo cannot restore them and the undo journal does not cover it."
                        : "These Trash items are deleted from disk. This cannot be undone."
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: Theme.color.foreground
                    font { family: Theme.font.family; pixelSize: Theme.font.body }
                }
                Row {
                    anchors.right: parent.right
                    spacing: Theme.spacing.gap
                    Flea.DialogButton { label: "Cancel"; primary: !root.destructiveFocus; onActivated: root.cancel() }
                    Item {
                        width: dangerText.implicitWidth + 2 * Theme.spacing.gap
                        height: Math.max(Theme.hitMin, dangerText.implicitHeight + Theme.spacing.gap)
                        Rectangle { anchors.fill: parent; color: "transparent"; border.width: Theme.spacing.hairline; border.color: root.destructiveFocus ? Theme.color.error : Theme.color.muted }
                        Text { id: dangerText; anchors.centerIn: parent; text: root.snapshot.all ? "Empty Trash" : "Delete"; color: Theme.color.error; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                        Accessible.role: Accessible.Button
                        Accessible.name: dangerText.text
                        Accessible.onPressAction: { root.destructiveFocus = true; root.activate() }
                        TapHandler { onTapped: { root.destructiveFocus = true; root.activate() } }
                    }
                }
            }
        }
    }
}
