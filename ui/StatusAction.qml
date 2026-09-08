import QtQuick

// Compact status controls share the strip's caption and allow native keyboard activation.
Item {
    id: root
    property string label: ""
    property bool available: true
    signal activated()
    implicitWidth: text.implicitWidth + 2 * Theme.spacing.gap
    implicitHeight: text.implicitHeight + 2 * Theme.spacing.hairline
    width: implicitWidth
    height: implicitHeight
    activeFocusOnTab: visible && available
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: if (root.available) root.activated()
    Keys.onPressed: function (event) {
        if (root.available && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) {
            root.activated()
            event.accepted = true
        }
    }
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: Theme.spacing.hairline
        border.color: root.activeFocus ? Theme.color.accent : Theme.color.muted
    }
    Text {
        id: text
        anchors.centerIn: parent
        text: root.label
        color: root.available ? Theme.color.foreground : Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        textFormat: Text.PlainText
    }
    HoverHandler { cursorShape: root.available ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { onTapped: if (root.available) root.activated() }
}
