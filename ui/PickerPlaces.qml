import Quickshell.Io
import QtQuick
import "." as Flea
import "js/Icons.js" as Icons
import "js/Places.js" as Places

// The picker's rail: the same favourites the browser window's sidebar draws, read from the same two
// files through the same ui/js/Places.js, and nothing else. A chooser mounts nothing and ejects
// nothing, so the Network and Devices groups the sidebar carries have no business in this window.
Item {
    id: root

    property string home: ""
    property string current: ""
    // The ink the picker draws every rule in, handed down by ui/picker.qml, which says why; the
    // window's own rule colour stands in so an unwired rail still draws a seam and never a black one.
    property color edge: Theme.color.surface

    signal chosen(string path)

    property string dirsText: ""
    property string marksText: ""
    readonly property var entries: Places.favorites(root.home, root.dirsText, root.marksText, Icons.sidebarGlyphFor)

    implicitWidth: Theme.space(150)

    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
    }

    Rectangle {
        anchors.right: parent.right
        width: Theme.spacing.hairline
        height: parent.height
        color: root.edge
    }

    ListView {
        id: rail
        anchors.fill: parent
        anchors.topMargin: Theme.spacing.rowPaddingY
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.entries

        // index and modelData are required on ui/SidebarRow.qml itself, so the view fills them;
        // redeclaring them here left the delegate uninitialised and the rail drew nothing.
        delegate: Flea.SidebarRow {
            cursor: modelData.path === root.current
            focused: false
            onActivated: function (at) { root.chosen(root.entries[at].path) }
        }
    }

    FileView {
        id: userDirsFile
        path: root.home + "/.config/user-dirs.dirs"
        printErrors: false
        onLoaded: root.dirsText = text()
    }

    FileView {
        id: bookmarksFile
        path: root.home + "/.config/gtk-3.0/bookmarks"
        printErrors: false
        onLoaded: root.marksText = text()
    }
}
