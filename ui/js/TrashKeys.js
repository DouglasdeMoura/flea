.pragma library

.import "Trash.js" as Trash

// What keys and menu rows mean in the trash, split out of ui/js/Focus.js at its cap the way
// Trash.js itself once was. One entry point, act(), which answers true when the trash location
// owns the action: ui/js/Focus.js calls it before its own switch, so the trash view reroutes and
// every other listing falls through untouched. Anything this returns false for reaches Focus's own
// cases, and anything no case answers ends at its "is not built yet" fallback, which is the loud
// failure a menu-only action arriving where its menu never offers it deserves.
function act(action, pane) {
    if (!Trash.isTrash(pane.path)) {
        return false
    }
    switch (action) {
    // Delete in the trash removes the entry for good: there is nothing left to trash, so the key
    // takes the permanent route instead, and d pairs the same way through Trash.deleteArm.
    case "trash":
        Trash.deletePermanent(pane)
        return true
    case "trashArm":
        Trash.deleteArm(pane)
        return true
    case "restore":
        Trash.restore(pane)
        return true
    case "deletePermanent":
        Trash.deletePermanent(pane)
        return true
    case "emptyTrash":
        Trash.emptyArm(pane)
        return true
    // Rename would orphan the entry's info file, a new folder inside the trash would list with
    // nowhere to restore to, and a duplicate would copy both defects at once: all three are
    // refused with the way back named, rather than leaving entries restore cannot reach.
    case "rename":
        pane.message("Renaming is not available in the trash. Restore the item first.", false)
        return true
    case "newFolder":
        pane.message("New folders cannot be created in the trash.", false)
        return true
    case "duplicate":
        pane.message("Duplicating is not available in the trash. Restore the item first.", false)
        return true
    // A cut out of the trash would move the entry away and orphan its info file, so it is refused
    // with the way back named; a copy leaves the entry standing and stays allowed.
    case "cut":
        pane.message("Cut is not available in the trash. Restore the item first.", false)
        return true
    // The trash is not a directory, so nothing pastes into it: the backend's absolute-path refusal
    // would answer, but its sentence names the wire's rule rather than the place.
    case "paste":
        pane.message("Nothing pastes into the trash.", false)
        return true
    // A walk out of the trash would answer rows relative to the mapped trash directory, which the
    // token path cannot join back onto; the filter narrows the trash by name instead, so nothing
    // the trash is for needs the walk.
    case "search":
        pane.message("Search is not available in the trash. Press / to filter by name.", false)
        return true
    }
    return false
}
