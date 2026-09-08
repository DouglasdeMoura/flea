import QtQuick
import Quickshell
import Quickshell.Io

// Installed facts are read only when About is shown; each failed query keeps an explicit unknown.
QtObject {
    id: root
    property bool active: false
    property bool loaded: false
    property var facts: ({})
    readonly property string binary: Quickshell.env("FLEA_BIN") || "flea"

    function setFact(key, value) {
        var next = Object.assign({}, root.facts)
        next[key] = value
        root.facts = next
    }

    onActiveChanged: {
        if (!root.active || root.loaded) return
        root.loaded = true
        version.running = true
        owner.running = true
        handler.running = true
    }

    property var versionQuery: Process {
        id: version
        command: [root.binary, "--version"]
        property string answer: ""
        stdout: StdioCollector { onStreamFinished: version.answer = this.text.trim() }
        // Sample output: flea 0.1.6
        onExited: function (code) {
            if (code === 0 && version.answer.indexOf("flea ") === 0)
                root.setFact("version", version.answer.substring(5))
        }
    }
    property var ownerQuery: Process {
        id: owner
        command: ["pacman", "-Qqo", root.binary]
        property string answer: ""
        stdout: StdioCollector { onStreamFinished: owner.answer = this.text.trim() }
        // Sample output: flea
        onExited: function (code) {
            if (code !== 0 || owner.answer.length === 0) {
                root.setFact("source", "Unpackaged candidate")
                root.setFact("package", "Not owned by a package")
                return
            }
            packageVersion.command = ["pacman", "-Q", owner.answer]
            packageVersion.running = true
            repository.command = ["pacman", "-Si", owner.answer]
            repository.running = true
        }
    }
    property var packageQuery: Process {
        id: packageVersion
        property string answer: ""
        stdout: StdioCollector { onStreamFinished: packageVersion.answer = this.text.trim() }
        onExited: function (code) { if (code === 0) root.setFact("package", packageVersion.answer) }
    }
    property var repositoryQuery: Process {
        id: repository
        environment: ({ LC_ALL: "C" })
        property string answer: ""
        stdout: StdioCollector { onStreamFinished: repository.answer = this.text }
        // Sample output: Repository      : omarchy
        onExited: function (code) {
            if (code !== 0) { root.setFact("source", "Local package"); return }
            var lines = repository.answer.split("\n")
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].indexOf("Repository") !== 0) continue
                var name = lines[i].substring(lines[i].indexOf(":") + 1).trim()
                root.setFact("source", name === "omarchy" ? "Omarchy Package Repository" : name)
                return
            }
        }
    }
    property var handlerQuery: Process {
        id: handler
        command: ["xdg-mime", "query", "default", "inode/directory"]
        property string answer: ""
        stdout: StdioCollector { onStreamFinished: handler.answer = this.text.trim() }
        onExited: function (code) { if (code === 0 && handler.answer.length > 0) root.setFact("handler", handler.answer) }
    }
}
