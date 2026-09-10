.pragma library

.import "Ops.js" as Ops

// The trash, client-side: the dd pair's arm-and-fire policy, the trash browser's own three
// operations, and the sentences their replies draw. Ops.js keeps move-to-trash alone, because
// that one acts on ordinary listings and everything here acts on the trash location.

// The trash as a location, not a directory: no absolute path can equal this token, so it rides
// the same path field every listing carries. Parent refuses in it and Back works out of it, the
// picker's flea:recent token contract carried over to the browser. This module owns the token
// because everything trash-shaped already lives here; ui/js/Nav.js answers it through isTrash().
var TRASH_TOKEN = "flea:trash"

function isTrash(path) {
    return String(path) === TRASH_TOKEN
}

// How long the first d stays armed. Long enough to be a deliberate pair, short enough that an arm
// nobody finished cannot be completed by a d typed minutes later.
var ARM_MS = 1500

// ui/js/Focus.js clears pane.trashArmedAt for every other action, so an arm never survives the key
// after it; this reads the stamp before it writes one, which is what makes the second press the pair.
function arm(pane) {
    if (pane.trashArmedAt > 0 && Date.now() - pane.trashArmedAt < ARM_MS) {
        pane.trashArmedAt = 0
        Ops.trash(pane)
        return
    }
    pane.trashArmedAt = Date.now()
    pane.message("Press d again to trash, or Delete on its own.", false)
}

// ---- the trash browser's own operations, acting on the listing that is up right now ----

// u in the trash: the cursor row, or the selection when one stands, goes back to where its info
// file says it came from.
function restore(pane) {
    var idx = Ops.targetIndices(pane)
    if (idx.length === 0) {
        return
    }
    pane.backend.trashRestore(idx)
}

// Delete in the trash removes the entry for good, with the info beside it. No journal, no undo:
// the backend answers counts and the refresh afterwards shows the result.
function deletePermanent(pane) {
    var idx = Ops.targetIndices(pane)
    if (idx.length === 0) {
        return
    }
    pane.backend.trashDelete(idx)
}

function emptyTrash(pane) {
    pane.backend.trashEmpty()
}

// A restore puts each entry back where its info file says it came from. No undo hint: the
// journal records nothing for it, so z has nothing to put back; see src/backend/opsreq.rs.
function restored(ok, failed) {
    if (ok === 0) {
        return failed === 1 ? "That item could not be restored; it stays in the trash."
                            : Ops.items(failed) + " could not be restored; they stay in the trash."
    }
    var line = "Restored " + Ops.items(ok)
    if (failed > 0) {
        line += ", " + failed + " failed"
    }
    return line
}

function trashDeleted(ok, failed) {
    if (ok === 0) {
        return failed === 1 ? "That item could not be deleted." : Ops.items(failed) + " could not be deleted."
    }
    var line = "Deleted " + Ops.items(ok) + " permanently"
    if (failed > 0) {
        line += ", " + failed + " failed"
    }
    return line
}

function trashEmptied(ok, failed) {
    if (ok === 0 && failed === 0) {
        return "The trash is already empty."
    }
    if (ok === 0) {
        return failed === 1 ? "That item could not be deleted." : Ops.items(failed) + " could not be deleted."
    }
    var line = "Emptied " + Ops.items(ok) + " from the trash"
    if (failed > 0) {
        line += ", " + failed + " failed"
    }
    return line
}

// d in the trash, where there is nothing left to trash: the pair deletes permanently instead, and
// Delete goes on one press the way it trashes on one press elsewhere. No journal, no undo, so the
// pair is the only safety; see src/backend/opsreq.rs run_trash_delete.
function deleteArm(pane) {
    if (pane.deleteArmedAt > 0 && Date.now() - pane.deleteArmedAt < ARM_MS) {
        pane.deleteArmedAt = 0
        deletePermanent(pane)
        return
    }
    pane.deleteArmedAt = Date.now()
    pane.message("Press d again to delete permanently. This cannot be undone.", false)
}

// Emptying the trash, armed the same way for the same reason: it destroys every entry at once and
// nothing puts them back. The menu row and this share one route, ui/js/Focus.js "emptyTrash".
function emptyArm(pane) {
    if (pane.emptyArmedAt > 0 && Date.now() - pane.emptyArmedAt < ARM_MS) {
        pane.emptyArmedAt = 0
        emptyTrash(pane)
        return
    }
    pane.emptyArmedAt = Date.now()
    pane.message("Press again to empty the trash. This cannot be undone.", false)
}
