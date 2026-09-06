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
        onStatusChanged: if (status !== XmlListModel.Loading) root.rebuild()
        XmlListModelRole { name: "href"; attributeName: "href" }
        XmlListModelRole { name: "visited"; attributeName: "visited" }
        XmlListModelRole { name: "modified"; attributeName: "modified" }
        XmlListModelRole { name: "added"; attributeName: "added" }
    }

    // Qt 6 gives XmlListModel no get(), so the rows are read off the model itself: data() is
    // invokable and the roles are numbered from Qt.UserRole in the order declared above.
    readonly property int hrefRole: Qt.UserRole
    readonly property int visitedRole: Qt.UserRole + 1
    readonly property int modifiedRole: Qt.UserRole + 2
    readonly property int addedRole: Qt.UserRole + 3

    // ui/js/Recent.js LIMIT bounds the read and not just the rail: an Instantiator over the whole
    // model built one QObject per bookmark, and a 50,000 bookmark history cost seconds against a
    // fraction of one here, a magnitude and not a number to cite. The bound is the file's own
    // order, which is the whole file on any history the desktop actually keeps.
    function rebuild() {
        var found = []
        var wanted = Math.min(history.count, Recent.LIMIT)
        for (var i = 0; i < wanted; i++) {
            var at = history.index(i, 0)
            // visited is when the file itself was last opened, which is what Recent means; the
            // other two stamp the bookmark and stand in for a writer that left visited out.
            var visited = String(history.data(at, root.visitedRole) || "")
            var modified = String(history.data(at, root.modifiedRole) || "")
            var added = String(history.data(at, root.addedRole) || "")
            found.push({ href: String(history.data(at, root.hrefRole) || ""),
                         stamp: visited.length > 0 ? visited : (modified.length > 0 ? modified : added) })
        }
        root.paths = Recent.paths(found)
        root.refreshed()
    }
}
