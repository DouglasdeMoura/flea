import QtQuick

// The Display board's seven-stop ruler: one tick per size Omarchy offers, filled up to the effective
// one. Muted while Omarchy owns that size and the ruler is only reporting it, accent once an override
// makes it the control, which is the Blueprint's own rule for an active control against a quiet one.
Item {
    id: root

    property var stops: []
    // The last filled tick. Omarchy can be on a size that is not a stop, so the caller fills to the
    // nearest one rather than leaving the ruler blank.
    property int index: -1
    property bool active: false

    signal picked(int stop)

    readonly property int tickGap: Theme.spacing.hairline * 2
    readonly property int tickHeight: Theme.spacing.hairline * 3
    // The hairline treatment the panel already uses for a quiet edge, so an unreached stop reads as one.
    readonly property real restOpacity: 0.4
    readonly property real tickWidth: root.stops.length > 0
        ? (root.width - root.tickGap * (root.stops.length - 1)) / root.stops.length : 0

    Repeater {
        model: root.stops

        delegate: Item {
            id: tick
            required property var modelData
            required property int index

            // The whole row height is the hit box, so a stop clears the 24 px pointer target on its own.
            x: tick.index * (root.tickWidth + root.tickGap)
            width: root.tickWidth
            height: root.height

            Rectangle {
                anchors.centerIn: parent
                width: parent.width
                height: root.tickHeight
                color: root.active && tick.index <= root.index ? Theme.color.accent : Theme.color.muted
                opacity: tick.index <= root.index ? 1 : root.restOpacity
            }

            HoverHandler {
                enabled: root.active
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                enabled: root.active
                acceptedButtons: Qt.LeftButton
                onTapped: root.picked(tick.modelData)
            }
        }
    }
}
