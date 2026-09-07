import QtQuick
import "js/Scroll.js" as Scroll

// Multiplies both smooth touchpad deltas and discrete wheel notches, then writes the bounded
// position directly. A MouseArea is intentional: a Flickable consumes wheel events before a child
// WheelHandler can answer them, while acceptedButtons: Qt.NoButton leaves taps and drags alone.
// The arithmetic lives in ui/js/Scroll.js and the two rates in ui/Theme.qml, so tests/js/scroll.js
// can drive the numbers without a Flickable.
MouseArea {
    id: root

    required property var flickable
    // The platform's own lines per notch, which the multiplier sits on top of.
    readonly property int wheelLines: Number(Application.styleHints.wheelScrollLines) || 3

    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    z: 1000

    function scrollDistance(pixelDeltaY, angleDeltaY) {
        return Scroll.distance(pixelDeltaY, angleDeltaY, root.wheelLines, Theme.scroll.notchPx, Theme.scroll.multiplier)
    }

    onWheel: function (wheel) {
        var distance = root.scrollDistance(wheel.pixelDelta.y, wheel.angleDelta.y)
        if (distance === 0 || !root.flickable.interactive) {
            wheel.accepted = false
            return
        }
        var previous = root.flickable.contentY
        root.flickable.cancelFlick()
        root.flickable.contentY = Scroll.bounded(previous - distance, root.flickable.originY,
                                                 root.flickable.contentHeight, root.flickable.height)
        wheel.accepted = Scroll.moved(previous, root.flickable.contentY)
    }
}
