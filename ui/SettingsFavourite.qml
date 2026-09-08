import QtQuick
import "." as Flea

// Favourite records keep their exact label/path; only the drag handle initiates reordering.
Item {
    id: root
    property var row: ({})
    signal activated()
    signal actionPicked(int action)
    signal moved(int to)
    readonly property bool actions: root.row.kind === "favouriteActions"
    implicitHeight: actions ? Theme.rowHeight : Theme.railRowHeight

    Row {
        visible: root.actions
        anchors.centerIn: parent
        spacing: Theme.spacing.gap
        Repeater {
            model: ["+ Add current folder", "− Remove"]
            delegate: Rectangle {
                required property int index
                required property string modelData
                enabled: index === 0 || root.row.canRemove === true
                width: label.implicitWidth + 2 * Theme.spacing.gap
                height: Theme.hitMin
                color: "transparent"
                border.width: Theme.spacing.hairline
                border.color: index === root.row.actionIndex ? Theme.color.accent : Theme.color.muted
                Text {
                    id: label
                    anchors.centerIn: parent
                    text: modelData
                    color: !parent.enabled ? Theme.color.muted : index === root.row.actionIndex ? Theme.color.accent : Theme.color.foreground
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.caption
                    textFormat: Text.PlainText
                }
                TapHandler { onTapped: root.actionPicked(index) }
            }
        }
    }
    Flea.Glyph {
        id: icon
        visible: !root.actions
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.railIconSize
        height: width
        name: root.row.glyph || "folder"
        color: root.row.error ? Theme.color.error : Theme.color.muted
    }
    Text {
        visible: !root.actions
        anchors.left: icon.right
        anchors.leftMargin: Theme.spacing.gap
        anchors.right: path.left
        anchors.rightMargin: Theme.spacing.gap
        anchors.verticalCenter: parent.verticalCenter
        text: root.row.label || ""
        font.family: Theme.font.family
        font.pixelSize: Theme.font.body
        color: root.row.error ? Theme.color.error : Theme.color.foreground
        elide: Text.ElideRight
        textFormat: Text.PlainText
    }
    Text {
        id: path
        visible: !root.actions
        anchors.right: grip.left
        anchors.rightMargin: Theme.spacing.gap
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, root.width * 0.46)
        text: root.row.value || ""
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        color: root.row.error ? Theme.color.error : Theme.color.muted
        elide: Text.ElideMiddle
        textFormat: Text.PlainText
    }
    Flea.Glyph {
        id: grip
        visible: !root.actions
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.hitMin
        height: Theme.hitMin
        name: "list"
        color: Theme.color.muted
        DragHandler {
            id: drag
            target: null
            xAxis.enabled: false
            onActiveChanged: {
                if (active) return
                var to = Math.max(0, Math.min(Favourites.records.length - 1,
                    root.row.favouriteIndex + Math.round(translation.y / Theme.railRowHeight)))
                if (to !== root.row.favouriteIndex) root.moved(to)
            }
        }
    }
    TapHandler {
        enabled: !root.actions
        onTapped: root.activated()
    }
}
