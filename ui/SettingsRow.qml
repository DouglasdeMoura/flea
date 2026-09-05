import QtQuick
import qs.Commons
import "." as Flea

// One row of the settings panel's pane, drawn from the object ui/js/Settings.js rows() built. Every
// kind is one row height, the window's own, except a hint, which wraps and takes the height its
// wording needs; the Settings board's anatomy note is where the "no metric of its own" rule comes from.
Item {
    id: root

    // {kind, label, value?, on?, state?} from ui/js/Settings.js; kind decides what is drawn.
    property var row: ({})
    property bool current: false

    signal activated()
    // Every steppable row steps the same way, so h/l and the two chevrons fire one signal, never two.
    signal stepped(int direction)

    readonly property string kind: root.row.kind || "fact"
    readonly property bool isGroup: root.kind === "group"
    readonly property bool isHint: root.kind === "hint"
    readonly property bool isLock: root.kind === "lock"
    readonly property bool hasBox: root.kind === "check" || root.kind === "master"
    readonly property bool hasSteps: root.kind === "choice"
    // The hover lift ui/MenuRow.qml uses, so a settings row and a menu row read alike.
    readonly property real hoverOpacity: 0.08
    // The tri-state master: all six on is a check, some on is a dash, none is an empty box.
    readonly property string boxGlyph: root.kind === "master"
        ? (root.row.state === "all" ? "check" : (root.row.state === "some" ? "minus" : ""))
        : (root.row.on === true ? "check" : "")

    height: root.isHint ? hint.implicitHeight + 2 * Theme.spacing.rowPaddingY : Theme.rowHeight

    Rectangle {
        anchors.fill: parent
        visible: root.current
        color: Theme.color.foreground
        opacity: root.hoverOpacity
    }

    // A heading and a hint are the only two rows that are not a label and a control, so they draw
    // instead of the pair below rather than beside it.
    Text {
        visible: root.isGroup
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        text: root.row.label || ""
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        font.bold: true
        textFormat: Text.PlainText
    }

    Text {
        id: hint
        visible: root.isHint
        x: Theme.spacing.rowPaddingX
        y: Theme.spacing.rowPaddingY
        width: parent.width - 2 * Theme.spacing.rowPaddingX
        text: root.row.label || ""
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
    }

    Text {
        visible: !root.isGroup && !root.isHint
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.rowPaddingX
        anchors.right: trailing.left
        anchors.rightMargin: Theme.spacing.gap
        anchors.verticalCenter: parent.verticalCenter
        text: root.row.label || ""
        color: root.isLock ? Theme.color.muted : Theme.color.foreground
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySmall
        textFormat: Text.PlainText
        elide: Text.ElideRight
    }

    // Row lays its children out itself, so none of them anchors vertically: each takes the mark
    // height and centres its own content inside that, which keeps one baseline across four kinds.
    Row {
        id: trailing
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacing.gap

        Flea.Glyph {
            visible: root.hasSteps
            width: root.hasSteps ? Theme.markSize : 0
            height: Theme.markSize
            name: "chevron-left"
            color: Theme.color.muted

            TapHandler {
                enabled: root.hasSteps
                onTapped: root.stepped(-1)
            }
        }

        // The master's count, a choice's name and a fact's value are all one thing: the value the
        // row currently holds, drawn on the right the way the boards draw it.
        Text {
            visible: root.kind === "fact" || root.hasSteps || root.kind === "master"
            height: Theme.markSize
            verticalAlignment: Text.AlignVCenter
            text: root.row.value || ""
            color: root.hasSteps ? Theme.color.foreground : Theme.color.muted
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySmall
            textFormat: Text.PlainText
        }

        Flea.Glyph {
            visible: root.hasSteps
            width: root.hasSteps ? Theme.markSize : 0
            height: Theme.markSize
            name: "chevron-right"
            color: Theme.color.muted

            TapHandler {
                enabled: root.hasSteps
                onTapped: root.stepped(1)
            }
        }

        // A locked row draws the lock mark where the box would be, so the section stays a complete
        // list of what the menu can contain rather than hiding the two rows nobody can switch off.
        Flea.Glyph {
            visible: root.isLock
            width: root.isLock ? Theme.markSize : 0
            height: Theme.markSize
            name: "lock"
            color: Theme.color.muted
        }

        Rectangle {
            visible: root.hasBox
            width: root.hasBox ? Theme.markSize : 0
            height: Theme.markSize
            color: "transparent"
            border.width: Theme.spacing.hairline
            border.color: root.boxGlyph.length > 0 ? Theme.color.accent : Theme.color.muted

            Flea.Glyph {
                anchors.fill: parent
                visible: root.boxGlyph.length > 0
                name: root.boxGlyph
                color: Theme.color.accent
            }
        }
    }

    HoverHandler {
        enabled: !root.isGroup && !root.isHint
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        enabled: !root.isGroup && !root.isHint && !root.isLock && !root.hasSteps
        acceptedButtons: Qt.LeftButton
        onTapped: root.activated()
    }
}
