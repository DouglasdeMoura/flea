import QtQuick
import "js/Ops.js" as Ops

Loader {
    id: root
    required property var pane
    anchors.fill: parent
    z: 2
    active: false
    source: "MenuActionDialog.qml"
    readonly property bool opened: item !== null && item.opened
    property int requestId: 0
    property string identity: ""
    property string folder: ""
    property bool ready: false
    property string pendingAction: ""

    function snapshot() {
        requestId++
        ready = false
        pendingAction = ""
        identity = pane.menuSelectionIdentity
        folder = pane.path
        pane.backend.send({c: "menuaction", op: "snapshot", id: requestId, rows: Ops.targetIndices(pane)})
    }
    function open(action) {
        if (opened) return
        if (action === "newFile") {
            requestId++
            folder = pane.path
            show(action)
            return
        }
        if (!requestId || identity !== pane.menuSelectionIdentity) snapshot()
        pendingAction = action
        if (ready) show(action)
    }
    function show(action) {
        pendingAction = ""
        active = true
        item.open(action, requestId, folder, pane.listArea)
    }
    Connections {
        target: root.pane.backend
        function onMenuResult(message) {
            if (message.id !== root.requestId) return
            if (message.op === "snapshot") {
                root.ready = message.ok === true && root.identity === root.pane.menuSelectionIdentity
                if (!root.ready) {
                    root.pendingAction = ""
                    root.identity = ""
                    root.pane.message(message.error || "Selected items changed; reopen the menu.", true)
                } else if (root.pendingAction) root.show(root.pendingAction)
                return
            }
            if (root.item) root.item.receive(message)
        }
        function onFailed(where, input, message, mode) {
            if (where !== "backend") return
            root.ready = false
            root.identity = ""
            root.pendingAction = ""
            if (root.opened) root.item.receive({id: root.requestId, ok: false, error: message})
        }
    }
    Connections {
        target: root.item
        function onRequested(message) { root.pane.backend.send(message) }
        function onApproved(message) {
            root.pane.backend.send({c: "transfer", op: message.action === "moveTo" ? "move" : "copy",
                menuId: message.id, dest: message.dest})
        }
        function onCreated(path) { root.pane.refresh(path); root.pane.message("File created.", false) }
        function onClosed() { root.ready = false; root.identity = "" }
    }
}
