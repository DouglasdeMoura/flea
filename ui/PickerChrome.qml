import QtQuick
import "." as Flea
import "js/Format.js" as Format
import "js/Picker.js" as Picker

// The picker's two chrome strips: what was asked for and the two answers on top, where the list is
// standing and what it is narrowed to underneath. SendPicker.html draws both.
Item {
    id: root

    property var picker: null

    signal cancelRequested()
    signal acceptRequested()
    signal backRequested()
    signal upRequested()
    signal chipChosen(int index)

    readonly property var req: root.picker.req
    readonly property var chips: Picker.chips(root.req)

    implicitHeight: ask.height + where.height

    Item {
        id: ask
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Math.max(Theme.chromeHeight, titles.implicitHeight + 2 * Theme.spacing.rowPaddingY)

        Rectangle {
            anchors.fill: parent
            color: Theme.color.surface
        }

        Column {
            id: titles
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacing.rowPaddingX
            anchors.right: buttons.left
            anchors.rightMargin: Theme.spacing.gap
            anchors.verticalCenter: parent.verticalCenter

            // The caller's own words, and a filename is arbitrary text, so PlainText here too.
            Text {
                width: parent.width
                text: Picker.title(root.req)
                color: Theme.color.foreground
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySmall
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }

            // Only a portal identity is drawn, so an application the desktop cannot name gets no line.
            Text {
                width: parent.width
                visible: text.length > 0
                text: Picker.subtitle(root.req)
                color: Theme.color.muted
                font.family: Theme.font.family
                font.pixelSize: Theme.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }

        Row {
            id: buttons
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacing.gap

            Flea.DialogButton {
                label: "Cancel"
                onActivated: root.cancelRequested()
            }

            Flea.DialogButton {
                label: Picker.acceptLabel(root.req, root.picker.marks.length)
                primary: true
                onActivated: root.acceptRequested()
            }
        }
    }

    Item {
        id: where
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: ask.bottom
        height: Theme.chromeHeight

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Theme.spacing.hairline
            color: Theme.color.surface
        }

        Row {
            id: moves
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacing.gap

            Flea.ChromeButton {
                glyph: "arrow-left"
                enabled: root.picker.history.length > 0
                onActivated: root.backRequested()
            }

            Flea.ChromeButton {
                glyph: "arrow-up"
                enabled: Picker.parentOf(root.picker.path) !== root.picker.path
                onActivated: root.upRequested()
            }
        }

        Text {
            anchors.left: moves.right
            anchors.leftMargin: Theme.spacing.gap
            anchors.right: types.left
            anchors.rightMargin: Theme.spacing.gap
            anchors.verticalCenter: parent.verticalCenter
            text: Format.tilde(root.picker.path, root.picker.home)
            color: Theme.color.foreground
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            elide: Text.ElideLeft
            textFormat: Text.PlainText
        }

        // The caller's filters, and All files beside them; a request with no filters draws no chips.
        Row {
            id: types
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacing.hairline * 4

            Repeater {
                model: root.chips

                Flea.DialogButton {
                    required property var modelData
                    label: modelData.label
                    primary: modelData.index === root.picker.filterIndex
                    onActivated: root.chipChosen(modelData.index)
                }
            }
        }
    }
}
