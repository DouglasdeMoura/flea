import QtQuick
import "js/Drag.js" as DragOps

// A directory as a drop target, named by path: the listing's floor in ui/PaneWire.qml and each tab in
// ui/TabBar.qml. The rows keep their own DropAreas above the floor, so only what a row refuses lands
// here; ui/js/Drag.js dropInto decides the verb and sends the one transfer.
DropArea {
    id: root

    property var pane: null
    property string dest: ""
    // The destination's filesystem when it is known, 0 when it is not, which makes the drop a copy.
    property int destDev: 0

    keys: [DragOps.ROWS_MIME, "text/uri-list"]

    onEntered: function (drag) {
        if (!DragOps.canDropInto(drag.getDataAsString(DragOps.ROWS_MIME), drag.urls, root.dest))
            drag.accepted = false
    }
    onDropped: function (drop) {
        if (DragOps.dropInto(root.pane, drop.getDataAsString(DragOps.ROWS_MIME), drop.urls, root.dest, root.destDev))
            drop.accept(Qt.CopyAction)
    }
}
