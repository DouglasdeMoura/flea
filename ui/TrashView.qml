import QtQuick
import qs.Commons
import "." as Flea
import "js/Format.js" as Format
import "js/Icons.js" as Icons
import "js/TrashDates.js" as Trash

// Trash keeps the normal integer ListView model, holding metadata only for its current window.
FocusScope {
    id: root
    property bool opened: false
    property int total: 0
    property real totalBytes: 0
    property bool bytesReady: false
    property bool bytesPartial: false
    property int first: 0
    property var rows: []
    property var selected: ({})
    property int cursor: 0
    property int requestId: 0
    property int minimumId: 0
    property bool busy: false
    property string errorText: ""
    property bool confirmingAll: false
    property var confirmingUris: []
    readonly property bool confirmationOpen: confirmation.opened
    readonly property var confirmationItem: confirmation
    readonly property int windowRows: 100
    signal requested(var message)
    signal backRequested()
    signal contextRequested(real x, real y, bool hasSelection)
    signal statusReported(string message, bool error)
    signal countChanged(int count)
    anchors.fill: parent
    visible: opened

    function send(op, fields) {
        var message = fields || {}
        message.c = "trashbrowse"
        message.op = op
        message.id = ++requestId
        requested(message)
    }
    function open() { minimumId = requestId + 1; opened = true; selected = ({}); cursor = 0; refresh(); forceActiveFocus() }
    function close() { opened = false; confirmation.close(); send("cancel"); backRequested() }
    function refresh() { if (!busy) { busy = true; send("list", {start: first, count: windowRows}) } }
    function rowAt(index) { return rows[index - first] || null }
    function selectedUris() { return Object.keys(selected).filter(function(uri) { return selected[uri] }) }
    function choose(index, extend) {
        cursor = Math.max(0, Math.min(total - 1, index))
        var item = rowAt(cursor)
        if (!item) return
        var next = extend ? Object.assign({}, selected) : ({})
        next[item.uri] = extend ? !next[item.uri] : true
        selected = next
        listing.positionViewAtIndex(cursor, ListView.Contain)
        forceActiveFocus()
    }
    function restore(all) { busy = true; send("restore", {all: all, uris: selectedUris()}) }
    function prepare(all) {
        confirmingAll = all
        confirmingUris = selectedUris()
        busy = true
        send("prepare", {all: all, uris: confirmingUris})
    }
    function receive(message) {
        if (!opened || message.id > requestId || message.id < minimumId) return
        busy = false
        if (!message.ok) {
            errorText = message.error || "Trash operation failed."
            statusReported(errorText, true)
            return
        }
        if (message.op === "list" || message.op === "window") {
            total = message.total
            countChanged(total)
            first = message.start
            rows = message.rows || []
            cursor = Math.max(0, Math.min(cursor, total - 1))
            if (message.op === "list") { busy = true; send("summary") }
        } else if (message.op === "summary") {
            totalBytes = message.bytes
            bytesPartial = message.partial
            bytesReady = true
        } else if (message.op === "prepare") confirmation.open(message)
        else if (message.op === "check" && !message.valid) {
            confirmation.close()
            send("prepare", {all: confirmingAll, uris: confirmingUris})
        } else if (message.op === "restore" || message.op === "delete") {
            var failed = message.failed || 0
            var next = ({})
            var failures = message.failures || []
            for (var i = 0; i < failures.length; i++) next[failures[i].uri] = true
            selected = next
            var text = (message.op === "restore" ? "Restored " : "Deleted ") + message.done + " of " + (message.done + failed)
            if (failed) text += " · " + failed + " failed: " + failures.map(function(item) { return item.error }).join("; ")
            statusReported(text, failed > 0)
            refresh()
        }
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) root.close()
        else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) root.choose(root.cursor + 1, false)
        else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) root.choose(root.cursor - 1, false)
        else if (event.key === Qt.Key_Space) root.choose(root.cursor, true)
        else if (event.key === Qt.Key_Delete && root.selectedUris().length) root.prepare(false)
        else if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) root.contextRequested(root.width / 2, Theme.rowHeight, root.selectedUris().length > 0)
        else return
        event.accepted = true
    }
    Rectangle { anchors.fill: parent; color: Theme.color.background }
    Column {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            width: parent.width
            height: Theme.rowHeight
            color: Theme.color.surface
            Row {
                anchors.fill: parent
                anchors.leftMargin: Theme.spacing.rowPaddingX
                anchors.rightMargin: Theme.spacing.rowPaddingX
                spacing: Theme.spacing.gap
                Flea.Glyph { width: Theme.markSize; height: parent.height; name: "arrow-left"; color: Theme.color.muted; TapHandler { onTapped: root.close() } }
                Flea.Glyph { width: Theme.markSize; height: parent.height; name: "arrow-up"; color: Theme.color.muted; opacity: 0.45 }
                Text { width: parent.width - 2 * Theme.markSize - countLabel.width - 3 * parent.spacing; anchors.verticalCenter: parent.verticalCenter; text: "Trash"; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                Text { id: countLabel; anchors.verticalCenter: parent.verticalCenter; text: root.total + " items" + (root.bytesReady ? " · " + (root.bytesPartial ? "≥ " : "") + Format.size(root.totalBytes) : ""); color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
            }
        }
        Row {
            width: parent.width
            height: Theme.rowHeight
            leftPadding: Theme.spacing.rowPaddingX
            rightPadding: Theme.spacing.rowPaddingX
            spacing: Theme.spacing.gap
            Item { width: Theme.markSize; height: 1 }
            Text { width: Math.max(0, parent.width - Theme.markSize - locationTitle.width - deletedTitle.width - 3 * parent.spacing - parent.leftPadding - parent.rightPadding); text: "Name"; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
            Text { id: locationTitle; width: Math.min(Theme.space(210), root.width * 0.35); horizontalAlignment: Text.AlignRight; text: "Original location"; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
            Text { id: deletedTitle; width: Math.min(Theme.space(110), root.width * 0.2); horizontalAlignment: Text.AlignRight; text: "Deleted"; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.caption } }
        }
        ListView {
            id: listing
            width: parent.width
            height: parent.height - 2 * Theme.rowHeight
            model: root.total
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onContentYChanged: {
                var top = Math.max(0, Math.floor(contentY / Theme.rowHeight))
                if (!root.busy && (top < root.first || top + Math.ceil(height / Theme.rowHeight) >= root.first + root.rows.length)) {
                    root.busy = true
                    root.send("window", {start: top, count: root.windowRows})
                }
            }
            Flea.FastScrollHandler { flickable: listing }
            delegate: Rectangle {
                id: itemRow
                required property int index
                readonly property var item: root.rowAt(index)
                readonly property bool selected: item && root.selected[item.uri] === true
                width: listing.width
                height: Theme.rowHeight
                color: selected ? Qt.alpha(Theme.color.accent, 0.14) : "transparent"
                Rectangle { width: Theme.spacing.hairline * 2; height: parent.height; visible: itemRow.selected; color: Theme.color.accent }
                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacing.rowPaddingX
                    anchors.rightMargin: Theme.spacing.rowPaddingX
                    spacing: Theme.spacing.gap
                    Flea.Glyph { width: Theme.markSize; height: parent.height; name: itemRow.item ? (itemRow.item.directory ? "folder" : Icons.glyphFor(itemRow.item.icon)) : "file"; color: Theme.color.foreground }
                    Text { width: Math.max(0, parent.width - Theme.markSize - original.width - deleted.width - 3 * parent.spacing); anchors.verticalCenter: parent.verticalCenter; text: itemRow.item ? itemRow.item.original.split("/").pop() : ""; textFormat: Text.PlainText; elide: Text.ElideRight; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                    Text { id: original; width: locationTitle.width; anchors.verticalCenter: parent.verticalCenter; text: itemRow.item ? itemRow.item.original.slice(0, itemRow.item.original.lastIndexOf("/")) : ""; textFormat: Text.PlainText; elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                    Text { id: deleted; width: deletedTitle.width; anchors.verticalCenter: parent.verticalCenter; text: itemRow.item ? Trash.deleted(itemRow.item.deleted, Date.now()) : ""; textFormat: Text.PlainText; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight; color: Theme.color.foreground; font { family: Theme.font.family; pixelSize: Theme.font.body } }
                }
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton; onClicked: function(mouse) { root.choose(itemRow.index, mouse.modifiers & Qt.ControlModifier) } }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: { if (!itemRow.selected) root.choose(itemRow.index, false); root.contextRequested(itemRow.x, itemRow.y - listing.contentY + 2 * Theme.rowHeight, true) } }
            }
        }
    }
    Text { anchors.centerIn: parent; visible: root.total === 0; text: root.errorText || (root.busy ? "Reading Trash…" : "Trash is empty"); textFormat: Text.PlainText; color: root.errorText ? Theme.color.error : Theme.color.muted; font { family: Theme.font.family; pixelSize: Theme.font.body } }
    Timer { interval: 2500; repeat: true; running: root.opened && !root.busy; onTriggered: { if (confirmation.opened) { root.busy = true; root.send("check", {token: confirmation.snapshot.token}) } else root.refresh() } }
    Flea.TrashConfirm {
        id: confirmation
        z: 3
        onConfirmed: function(token) { root.busy = true; root.send("delete", {token: token}); root.forceActiveFocus() }
        onCancelled: { root.send("cancel"); root.forceActiveFocus() }
    }
}
