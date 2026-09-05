import QtQuick
import "." as Flea
import "js/Format.js" as Format
import "js/Picker.js" as Picker

// SaveFile's own strip: the name, the URI that name resolves to, and a warning when this directory
// already holds it. The board's rule is that the caller owns the write, so nothing here refuses a
// collision; it says so and lets the request go through with the reviewed name.
Item {
    id: root

    property var picker: null

    signal nameEdited(string text)
    signal accepted()

    readonly property string outPath: Picker.join(root.picker.path, root.picker.saveName)
    // Only the rows the listing has actually sent can be compared, so a name past the held window
    // goes unwarned. The alternative is a stat this window has no request for, and the callback
    // hands the caller a URI either way.
    readonly property bool collides: {
        if (root.picker.saveName.length === 0)
            return false
        for (var i = 0; i < root.picker.rows.length; i++) {
            if (root.picker.rows[i].n === root.picker.saveName)
                return true
        }
        return false
    }

    visible: root.picker.saving
    implicitHeight: root.visible ? column.implicitHeight + 2 * Theme.spacing.rowPaddingX : 0

    Rectangle {
        anchors.fill: parent
        color: Theme.color.surface
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacing.rowPaddingX
        anchors.rightMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacing.hairline * 4

        Flea.DialogField {
            id: field
            width: parent.width
            label: "Filename"
            text: root.picker.saveName
            onTextChanged: root.nameEdited(field.text)
            onAccepted: root.accepted()
        }

        Text {
            width: parent.width
            text: "Output URI · " + Format.fileUri(root.outPath)
            color: Theme.color.muted
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
        }

        Text {
            width: parent.width
            visible: root.collides
            text: root.picker.saveName + " already exists here · review before continuing"
            color: Theme.color.error
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }
    }
}
