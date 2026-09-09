import QtQuick

// Legacy GTK locations remain readable, but Flea never writes the shared bookmark file.
Item {
    id: root
    property var entries: []
    property string bookmarksText: ""
    signal message(string text, bool isError)
    signal wrote()

    function rename(uri, name) {
        root.message("This legacy location is read-only. Add it to Flea Favorites to manage it there.", true)
    }
    function forget(uri) {
        root.message("This legacy location is read-only. GTK bookmarks were left unchanged.", true)
    }
}
