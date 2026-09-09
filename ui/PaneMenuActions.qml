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
    property bool pendingActivation: false
    property bool activationUsed: false
    property int launchingId: 0
    property var survivors: []
    property int survivorId: 0
    property string survivorFolder: ""
    property string survivorListing: ""
    property string backgroundFolder: ""

    function snapshot() {
        if (deleting || survivorId) return
        requestId++
        ready = false
        pendingAction = ""
        pendingActivation = false
        activationUsed = false
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
        pendingActivation = false
        if (ready) show(action)
    }
    function activate(action, selected) {
        if (!selected) {
            if (action === "addFavourite") {
                if (backgroundFolder !== pane.path) { pane.message("Folder changed; reopen the menu.", true); return }
                addFavourite(backgroundFolder)
            } else pane.performMenu(action, 0, null)
            return
        }
        if (activationUsed) return
        if (deleting || survivorId) { pane.message("The deletion is still finishing.", false); return }
        if (!requestId || identity !== pane.menuSelectionIdentity) {
            pane.message("Selected items changed; reopen the menu.", true)
            return
        }
        activationUsed = true
        pendingAction = action
        pendingActivation = true
        if (ready) validateActivation()
    }
    function validateActivation() {
        var action = pendingAction
        pendingAction = ""
        pendingActivation = false
        pane.backend.send({c: "menuaction", op: "activate", id: requestId, action: action})
    }
    function show(action) {
        pendingAction = ""
        active = true
        item.open(action, requestId, folder, pane.listArea)
    }
    function addFavourite(path) {
        Favourites.add(path, path.split("/").filter(function (part) { return part.length > 0 }).pop() || "/")
    }
    function locateSurvivors() {
        if (!survivorId || pane.listInFlight) return
        if (pane.path !== survivorFolder) { survivorId = 0; survivors = []; return }
        survivorListing = pane.menuSelectionIdentity
        pane.backend.send({c: "locate", paths: survivors, id: survivorId, menuId: survivorId})
    }
    Connections {
        target: root.pane.contextMenu()
        function onOpenedChanged() {
            var menu = root.pane.contextMenu()
            if (menu.opened && !menu.hasRow && !menu.forRail && !menu.forHeader)
                root.backgroundFolder = root.pane.path
        }
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
                } else if (root.pendingAction) {
                    if (root.pendingActivation) root.validateActivation()
                    else root.show(root.pendingAction)
                }
                return
            }
            if (message.op === "activate") {
                if (!message.ok || root.identity !== root.pane.menuSelectionIdentity) {
                    root.pane.message(message.error || "Selected items changed; reopen the menu.", true)
                    return
                }
                var split = message.action.indexOf(":")
                var action = split < 0 ? message.action : message.action.substring(0, split)
                var subId = split < 0 ? "" : message.action.substring(split + 1)
                if (root.pane.contextMenu().validateChoice(action, subId)) {
                    if (action === "addFavourite") {
                        if (!message.paths || message.paths.length !== 1) { root.pane.message("The selected folder could not be read.", true); return }
                        root.addFavourite(message.paths[0])
                    } else root.pane.performMenu(message.action, message.id, message.paths)
                }
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
