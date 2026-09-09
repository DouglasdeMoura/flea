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
    readonly property bool deleting: item !== null && item.deletionActive
    property int requestId: 0
    property string identity: ""
    property string folder: ""
    property bool ready: false
    property string pendingAction: ""
    property int launchingId: 0
    property var survivors: []
    property int survivorId: 0
    property string survivorFolder: ""
    property string survivorListing: ""

    function snapshot() {
        if (deleting || survivorId) return
        requestId++
        ready = false
        pendingAction = ""
        identity = pane.menuSelectionIdentity
        folder = pane.path
        pane.backend.send({c: "menuaction", op: "snapshot", id: requestId, rows: Ops.targetIndices(pane)})
    }
    function open(action) {
        if (opened) return
        if (deleting || survivorId) { pane.message("The deletion is still finishing.", false); return }
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
    function locateSurvivors() {
        if (!survivorId || pane.listInFlight) return
        if (pane.path !== survivorFolder) { survivorId = 0; survivors = []; return }
        survivorListing = pane.menuSelectionIdentity
        pane.backend.send({c: "locate", paths: survivors, id: survivorId, menuId: survivorId})
    }
    Connections {
        target: root.pane
        function onListInFlightChanged() { if (!root.pane.listInFlight) root.locateSurvivors() }
    }
    Connections {
        target: root.pane.backend
        function onChanged(path) { if (path === root.folder && root.item) root.item.sourceChanged() }
        function onLocated(message) {
            if (!root.survivorId || message.id !== root.survivorId) return
            root.survivorId = 0
            root.survivors = []
            if (message.directory !== root.pane.path || root.pane.path !== root.survivorFolder
                    || root.survivorListing !== root.pane.menuSelectionIdentity) return
            if (!message.ok) { root.pane.message(message.error, true); return }
            var matches = message.matches || []
            root.pane.selection.clear()
            for (var i = 0; i < matches.length; i++) root.pane.selection.toggle(matches[i].index)
            root.pane.selectionVersion++
            if (matches.length) root.pane.setCursor(matches[0].index)
        }
        function onMenuResult(message) {
            if (message.op === "openWith" && message.id === root.launchingId) {
                root.launchingId = 0
                if (!root.opened || message.id !== root.requestId) {
                    if (!message.ok && !message.cancelled) root.pane.message(message.error || "The application could not be opened.", true)
                    return
                }
            }
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
            root.survivorId = 0
            root.survivors = []
            root.ready = false
            root.identity = ""
            root.pendingAction = ""
            if (root.opened || root.deleting) root.item.receive({id: root.requestId, op: root.deleting ? "delete" : "", ok: false, error: message})
        }
    }
    Connections {
        target: root.item
        function onRequested(message) {
            if (message.op === "openWith") root.launchingId = message.id
            root.pane.backend.send(message)
        }
        function onApproved(message) {
            root.pane.backend.send({c: "transfer", op: message.action === "moveTo" ? "move" : "copy",
                menuId: message.id, dest: message.dest})
        }
        function onCreated(path) { root.pane.refresh(path); root.pane.message("File created.", false) }
        function onDeleted(message) {
            var text = "Deleted " + message.deleted + " of " + message.count
            if (message.failed) text += " · " + message.failed + " failed"
            if (message.cancelled) text += " · cancelled"
            root.pane.operationResult(text, message.error || "", message.failed > 0)
            if (root.pane.path !== root.folder) return
            root.survivors = message.remaining || []
            root.survivorId = root.survivors.length ? message.id : 0
            root.survivorFolder = root.folder
            root.pane.refresh()
        }
        function onClosed() { root.ready = false; root.identity = "" }
    }
}
