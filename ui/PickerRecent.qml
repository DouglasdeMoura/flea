import Quickshell
import QtQuick
import QtQml.XmlListModel
import "js/Format.js" as Format
import "js/Recent.js" as Recent

// The desktop's own recent history, read and never written. Qt's XML reader does the parsing, so
// this file has no parser of its own: XmlListModel is QXmlStreamReader behind a query, and a
// history Flea hand-parsed would be a second XBEL implementation on a file it does not own.
// The read is lazy, so a picker whose user never asks for Recent never opens the file at all.
QtObject {
    id: root

    // The validated absolute paths, newest first; empty until refresh() has been asked for.
    property var paths: []
    signal refreshed()

    readonly property string file: Recent.historyPath(Quickshell.env("XDG_DATA_HOME"), Quickshell.env("HOME"))

    // Asked for when the Recent location is opened, so the file is re-read rather than remembered:
    // every other application on the box appends to it while this window is up.
    function refresh() {
        var url = Format.fileUri(root.file)
        if (history.source.toString() === url) {
            history.reload()
            return
        }
        history.source = url
    }

    property XmlListModel historyModel: XmlListModel {
        id: history
        query: "/xbel/bookmark"
        // An absent, empty or unreadable history answers Ready with no rows, and a truncated one
        // answers with the bookmarks it did read: either way the rail draws what is really there.
        onStatusChanged: if (status !== XmlListModel.Loading) settle.restart()
        XmlListModelRole { name: "href"; attributeName: "href" }
        XmlListModelRole { name: "visited"; attributeName: "visited" }
        XmlListModelRole { name: "modified"; attributeName: "modified" }
        XmlListModelRole { name: "added"; attributeName: "added" }
    }

    // The model is a model and not a list, so the rows are read off instantiated objects; there is
    // no get() on XmlListModel in Qt 6.
    property Instantiator bookmarkRows: Instantiator {
        id: bookmarks
        model: history
        delegate: QtObject {
            required property string href
            required property string visited
            required property string modified
            required property string added
        }
        onCountChanged: settle.restart()
    }

    // The delegates are created one at a time, so the rebuild waits for the batch rather than
    // running once per bookmark; a zero interval is the next event loop turn, after the last one.
    property Timer settleTimer: Timer {
        id: settle
        interval: 0
        onTriggered: root.rebuild()
    }

    function rebuild() {
        var found = []
        for (var i = 0; i < bookmarks.count; i++) {
            var row = bookmarks.objectAt(i)
            if (!row) {
                continue
            }
            // visited is when the file itself was last opened, which is what Recent means; the
            // other two stamp the bookmark and stand in for a writer that left visited out.
            var stamp = row.visited.length > 0 ? row.visited : (row.modified.length > 0 ? row.modified : row.added)
            found.push({ href: row.href, stamp: stamp })
        }
        root.paths = Recent.paths(found)
        root.refreshed()
    }
}
