//@ pragma AppId com.thisisgm.flea
//@ pragma ShellId fleapicker
//@ pragma NativeTextRendering
//@ pragma CacheDir $BASE/flea

import Quickshell
import Quickshell.Io
import QtQuick
import "." as Flea
import "js/Filter.js" as Filter
import "js/Picker.js" as Picker

// One portal request, one window: the org.freedesktop.impl.portal.FileChooser dialog every caller on
// the box gets, opened by flea --pick and answered through the reply file tools/flea-portal reads.
// The same Backend, Row, Theme and places the browser window draws with, and none of its operations:
// a chooser that can rename or delete is a file manager wearing a dialog's clothes.
ShellRoot {
    FloatingWindow {
        id: win

        readonly property var req: Picker.request(Quickshell.env("FLEA_PICKER"))
        readonly property string home: Quickshell.env("HOME")

        title: Picker.title(win.req)
        implicitWidth: Theme.space(640)
        implicitHeight: Theme.space(440)
        color: Theme.color.background

        // Where the list is standing, what it holds of the listing, and where the cursor is in it.
        property string path: ""
        property int total: 0
        property int held: 0
        property var rows: []
        // The per-response kind dictionary ui/Row.qml's Kind column indexes into.
        property var kindNames: []
        property int cursorIndex: 0
        property string listingState: "loading"
        property string message: ""

        // The checked identities, each a path and its size, so Back and Parent cannot rebind one.
        property var marks: []
        // Which chip is active: an index into the caller's filters, or -1 for All files.
        property int filterIndex: Picker.currentChip(win.req)
        readonly property var filter: win.filterIndex >= 0 ? win.req.filters[win.filterIndex] : null
        readonly property var shown: Picker.shownRows(win.rows, win.held, win.filter)
        readonly property int shownTotal: win.shown === null ? win.total : win.shown.length

        // Where Back goes, and it only ever goes back: Parent is its own button and pushes here too.
        property var history: []
        // The save mode's own name, which starts as the caller's suggestion.
        property string saveName: win.req.name

        readonly property bool saving: win.req.mode === "save"
        readonly property bool folderMode: win.req.directory || win.req.mode === "savefiles"
        readonly property int windowSize: list.visibleRows + 60

        // Exactly one answer leaves this window, whichever way it is asked for.
        property bool answered: false

        function rowFor(index) {
            var at = index - win.held
            return at >= 0 && at < win.rows.length ? win.rows[at] : null
        }

        function open(next) {
            if (next === win.path)
                return
            if (win.path.length > 0)
                win.history.push(win.path)
            win.openWithoutHistory(next)
        }

        function openWithoutHistory(next) {
            win.path = next
            win.total = 0
            win.held = 0
            win.rows = []
            win.cursorIndex = 0
            win.listingState = "loading"
            backend.list(next, win.windowSize, false)
        }

        function goBack() {
            if (win.history.length === 0)
                return
            win.openWithoutHistory(win.history.pop())
        }

        function goUp() {
            var up = Picker.parentOf(win.path)
            if (up !== win.path)
                win.open(up)
        }

        // Space. A directory is markable only when the request asked for one, and a file only when
        // it did not: the board draws no check at all on the rows the caller cannot receive.
        function toggleMark(index) {
            var row = win.rowFor(index)
            if (!row || row.d !== win.folderMode)
                return
            win.marks = Picker.toggle(win.marks, Picker.join(win.path, row.n), row.s, win.req.multiple)
        }

        // Enter. A directory is walked into, a file submits what is checked, and nothing checked is
        // nothing to submit: the board's own rule, and it is what keeps a stray Enter from sending.
        function activate(index) {
            var row = win.rowFor(index)
            if (!row)
                return
            if (row.d && !(win.folderMode && Picker.marked(win.marks, Picker.join(win.path, row.n)))) {
                win.open(Picker.join(win.path, row.n))
                return
            }
            win.accept()
        }

        function accept() {
            if (win.saving) {
                if (win.saveName.length === 0) {
                    win.say("Name the file before saving it")
                    return
                }
                win.finish(Picker.RESPONSE_OK, [Picker.join(win.path, win.saveName)])
                return
            }
            // A folder request with nothing checked takes the directory the window is standing in,
            // which is what the board's Choose folder button does with no row marked.
            if (win.marks.length === 0 && win.folderMode) {
                win.finish(Picker.RESPONSE_OK, [win.path])
                return
            }
            if (win.marks.length === 0) {
                win.say("Press Space to select a file first")
                return
            }
            win.finish(Picker.RESPONSE_OK, Picker.paths(win.marks))
        }

        function cancel() {
            win.finish(Picker.RESPONSE_CANCELLED, [])
        }

        // The one write out of this process. The window closes only once the reply file is on disk,
        // because tools/flea-portal reads it after this process exits and a lost write is a fault.
        function finish(response, list) {
            if (win.answered)
                return
            win.answered = true
            replyFile.setText(Picker.reply(response, list))
        }

        function say(text) {
            win.message = text
            messageLife.restart()
        }

        Timer {
            id: messageLife
            interval: 4000
            onTriggered: win.message = ""
        }

        FileView {
            id: replyFile
            path: Quickshell.env("FLEA_PICKER_REPLY")
            atomicWrites: true
            printErrors: true
            // Sequenced on saved(), never on setText() returning: the answer has to be readable
            // before this process ends, and Quickshell writes it on its own thread.
            onSaved: Quickshell.execDetached(["kill", String(Quickshell.processId)])
            onSaveFailed: {
                console.warn("the portal reply could not be written, so the request fails rather than reporting a refusal")
                Quickshell.execDetached(["kill", String(Quickshell.processId)])
            }
        }

        // Closing the window is a refusal, the board's own rule, and it takes the same path a
        // pressed Cancel does. A window closed after an answer is the answer's own teardown.
        Connections {
            target: Quickshell
            function onLastWindowClosed() {
                if (win.answered)
                    return
                win.finish(Picker.RESPONSE_CANCELLED, [])
            }
        }

        Flea.Backend {
            id: backend

            onListed: function (n, readMs, sortMs) {
                win.total = n
                win.listingState = n === 0 ? "empty" : "ready"
            }
            onRows: function (start, items, ms, kinds) {
                win.held = start
                win.rows = items
                win.kindNames = kinds
            }
            onFailed: function (where, input, msg, mode) {
                win.listingState = "empty"
                win.say(msg)
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.color.background
            focus: true
            // The save field takes the keyboard from the list, and Escape has to refuse from there too.
            Keys.onEscapePressed: win.cancel()

            Flea.PickerChrome {
                id: chrome
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                picker: win
                onCancelRequested: win.cancel()
                onAcceptRequested: win.accept()
                onBackRequested: win.goBack()
                onUpRequested: win.goUp()
                onChipChosen: function (index) { win.filterIndex = index }
            }

            Flea.PickerPlaces {
                id: places
                anchors.left: parent.left
                anchors.top: chrome.bottom
                anchors.bottom: save.top
                home: win.home
                current: win.path
                onChosen: function (path) { win.open(path); list.forceActiveFocus() }
            }

            Flea.PickerList {
                id: list
                anchors.left: places.right
                anchors.right: parent.right
                anchors.top: chrome.bottom
                anchors.bottom: save.top
                picker: win
                backend: backend
                clip: true
                focus: true
            }

            // The same empty hero the browser window draws, over the list area alone.
            Flea.EmptyState {
                x: list.x
                y: list.y
                width: list.width
                height: list.height
                visible: win.listingState === "empty"
            }

            Flea.PickerSave {
                id: save
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: status.top
                picker: win
                onNameEdited: function (text) { win.saveName = text }
                onAccepted: win.accept()
            }

            // The footer: what is checked on the left, the keys that act on it on the right.
            Item {
                id: status
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Theme.chromeHeight

                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: Theme.spacing.hairline
                    color: Theme.color.surface
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    text: win.message.length > 0 ? win.message : Picker.statusLine(win.marks.length, Picker.totalBytes(win.marks))
                    color: win.message.length > 0 ? Theme.color.accent : Theme.color.muted
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.caption
                    textFormat: Text.PlainText
                }

                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    text: Picker.hints(win.req)
                    color: Theme.color.muted
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.caption
                    textFormat: Text.PlainText
                }
            }
        }

        Component.onCompleted: {
            var start = win.req.folder.length > 0 ? win.req.folder : win.home
            win.openWithoutHistory(start)
        }

        // The seam tests/picker.sh drives, the same read-only shape ui/Ipc.qml has for the window.
        IpcHandler {
            target: "fleapicker"
            function ready(): bool { return true }
            function path(): string { return win.path }
            function total(): int { return win.total }
            function shownTotal(): int { return win.shownTotal }
            function cursor(): int { return win.cursorIndex }
            function marks(): string { return Picker.paths(win.marks).join(",") }
            function state(): string { return win.listingState }
            function accept(): string { return Picker.acceptLabel(win.req, win.marks.length) }
            function chip(): int { return win.filterIndex }
            function message(): string { return win.message }
        }
    }
}
