.pragma library

.import "Ops.js" as Ops

// The dd pair, and the permanent delete beside it. A single d used to trash, and it sat in the
// middle of the letters a name is typed with, so the third keystroke of "Vid" trashed the row
// (issue 7). Delete and Ctrl+Delete are not letters and still go on one press, through Ops.trash
// directly.

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

// Shift+Delete, the severe sibling of both routes above: the same rows, straight off the disk, the
// trash never seeing them. There is no arming step, because a chord is deliberate by construction;
// the backend journals nothing, so the undo hint below does not apply to it either.
function del(pane) {
    var idx = Ops.targetIndices(pane)
    if (idx.length === 0) {
        return
    }
    pane.backend.del(idx)
}

// The deleted line's wording: trashed's shape with "permanently" where the undo hint goes, so the
// two status lines can never be confused at a glance.
function deleted(ok, failed) {
    if (ok === 0) {
        return failed === 1 ? "That item could not be deleted." : Ops.items(failed) + " could not be deleted."
    }
    var line = "Deleted " + Ops.items(ok) + " permanently"
    if (failed > 0) {
        line += ", " + failed + " failed"
    }
    return line + "."
}
