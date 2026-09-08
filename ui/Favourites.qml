pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "js/Places.js" as Places
import "js/UiState.js" as UiState

// All callers share one operation writer; the Rust updater locks and re-reads before editing.
QtObject {
    id: root
    readonly property var records: ((ViewState.state.places || {}).favourites || [])
    readonly property bool busy: writer.running
    property var statuses: ({})
    onRecordsChanged: root.statuses = ({})
    property string lastError: ""
    signal wrote()
    signal failed(string message)

    function apply(operation) {
        if (root.busy) { root.failed("A favourites change is still being saved."); return false }
        root.lastError = ""
        writer.answer = ""
        writer.errorText = ""
        writer.command = [Quickshell.env("FLEA_BIN") || "flea", "--favourites", JSON.stringify(operation)]
        writer.pending = true
        writer.running = true
        return true
    }
    function add(path, label) {
        return root.apply({ op: "add", record: { label: label, path: path } })
    }
    function remove(index) {
        return root.apply({ op: "remove", index: index, expected: root.records })
    }
    function move(index, to) {
        return root.apply({ op: "move", index: index, to: to, expected: root.records })
    }
    function rename(index, label) {
        return root.apply({ op: "rename", index: index, label: label, expected: root.records })
    }
    function inspect(indices) {
        var pending = indices.filter(function (index) { return root.statuses[index] === undefined })
        if (pending.length === 0 || inspector.running) return
        inspector.answer = ""
        inspector.command = [Quickshell.env("FLEA_BIN") || "flea", "--favourites", JSON.stringify({ op: "inspect", indices: pending.slice(0, 128) })]
        inspector.running = true
    }
    property var inspection: Process {
        id: inspector
        property string answer: ""
        stdout: StdioCollector { onStreamFinished: inspector.answer = this.text }
        onExited: function (code) {
            if (code !== 0) return
            try {
                var rows = JSON.parse(inspector.answer).statuses
                var next = Object.assign({}, root.statuses)
                for (var i = 0; i < rows.length; i++) {
                    if (JSON.stringify(root.records[rows[i].index]) === JSON.stringify(rows[i].record))
                        next[rows[i].index] = rows[i].error
                }
                root.statuses = next
            } catch (error) { root.failed("Favourite availability could not be read.") }
        }
    }

    property var process: Process {
        id: writer
        property string answer: ""
        property string errorText: ""
        property bool pending: false
        onRunningChanged: {
            if (!running && pending) {
                pending = false
                root.lastError = "Favourites updater could not start."
                root.failed(root.lastError)
            }
        }
        stdout: StdioCollector { onStreamFinished: writer.answer = this.text }
        stderr: StdioCollector { onStreamFinished: writer.errorText = this.text.trim() }
        onExited: function (code) {
            writer.pending = false
            if (code !== 0) {
                root.lastError = writer.errorText.replace(/^flea: /, "").split("\n")[0] || "Favourites could not be saved."
                root.failed(root.lastError)
                return
            }
            try {
                var state = JSON.parse(writer.answer)
                if (!state.places || !Array.isArray(state.places.favourites)) throw new Error("missing favourites")
                ViewState.state = UiState.withGroup(ViewState.state, "places", { favourites: state.places.favourites })
                root.wrote()
            } catch (error) {
                root.lastError = "Favourites were saved, but their new state could not be read."
                root.failed(root.lastError)
            }
        }
    }
}
