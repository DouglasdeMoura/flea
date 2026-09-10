.import "../../ui/js/Trash.js" as Trash
.import "../../ui/js/Ops.js" as Ops

// The dd pair, issue 7. A single d used to trash and sat among the letters a name is typed with, so
// the third keystroke of "Vid" trashed the row. These drive Trash.arm directly, because the stamp
// and the window are the whole of the policy and neither needs a window to be true.

// What Ops.trash reaches for, plus the stamp Trash.arm reads and writes.
function pane() {
    var p = {
        trashArmedAt: 0,
        deleteArmedAt: 0,
        emptyArmedAt: 0,
        cursorIndex: 3,
        trashedIdx: [],
        restoredIdx: [],
        deletedIdx: [],
        emptied: 0,
        said: "",
        selectedIndices: function () { return [] }
    }
    p.message = function (text, isError) { p.said = text }
    p.backend = {
        trash: function (idx) { p.trashedIdx = idx },
        trashRestore: function (idx) { p.restoredIdx = idx },
        trashDelete: function (idx) { p.deletedIdx = idx },
        trashEmpty: function () { p.emptied += 1 }
    }
    return p
}

function run(check) {
    var p = pane()
    Trash.arm(p)
    check("the first d trashes nothing and says what to press", p.trashedIdx.length, 0)
    check("and the sentence names both routes", p.said,
          "Press d again to trash, or Delete on its own.")
    check("and it leaves the pair armed", p.trashArmedAt > 0, true)
    Trash.arm(p)
    check("the second d inside the window trashes the cursor row", p.trashedIdx.join(","), "3")
    check("and disarms, so a third d only arms again", p.trashArmedAt, 0)

    // A stamp older than the window is not half a pair, however long it has stood.
    var stale = pane()
    stale.trashArmedAt = Date.now() - 60000
    Trash.arm(stale)
    check("a d a minute after the first is a fresh arm, not the second of a pair",
          stale.trashedIdx.length, 0)
    check("and it re-arms rather than completing a pair nobody meant",
          stale.trashArmedAt > Date.now() - 1000, true)

    // Delete is not a letter a name is typed with, so it never armed and still goes on one press.
    var direct = pane()
    Ops.trash(direct)
    check("Delete trashes on one press, with no arming", direct.trashedIdx.join(","), "3")
    check("and it leaves no arm behind it", direct.trashArmedAt, 0)

    // The selection wins over the cursor, the rule Ops.targetIndices keeps for every write.
    var picked = pane()
    picked.selectedIndices = function () { return [1, 4] }
    picked.trashArmedAt = Date.now()
    Trash.arm(picked)
    check("the pair trashes the selection when there is one", picked.trashedIdx.join(","), "1,4")

    // The trash browser's own three: restore and permanent delete name rows, empty names none.
    var r = pane()
    Trash.restore(r)
    check("restore names the cursor row", r.restoredIdx.join(","), "3")
    var del = pane()
    Trash.deletePermanent(del)
    check("permanent delete names the cursor row", del.deletedIdx.join(","), "3")
    var e = pane()
    Trash.emptyTrash(e)
    check("empty reaches the backend", e.emptied, 1)

    // d in the trash pairs the way d pairs outside it, but fires the permanent route instead.
    var dp = pane()
    Trash.deleteArm(dp)
    check("the first d in the trash deletes nothing and arms", dp.deletedIdx.length, 0)
    check("and the sentence calls the deletion permanent", dp.said,
          "Press d again to delete permanently. This cannot be undone.")
    Trash.deleteArm(dp)
    check("the second d deletes the cursor row", dp.deletedIdx.join(","), "3")

    // Emptying arms the same way, because it destroys every entry at once and nothing puts them back.
    var ep = pane()
    Trash.emptyArm(ep)
    check("the first empty arms rather than firing", ep.emptied, 0)
    Trash.emptyArm(ep)
    check("the second empties", ep.emptied, 1)

    // The replies draw counts with no undo hint, because the journal records nothing for them.
    check("a restore says what came back", Trash.restored(2, 0), "Restored 2 items")
    check("a failed restore says what stayed", Trash.restored(0, 1),
          "That item could not be restored; it stays in the trash.")
    check("a permanent delete says so", Trash.trashDeleted(1, 0), "Deleted 1 item permanently")
    check("an empty trash says so", Trash.trashEmptied(3, 0), "Emptied 3 items from the trash")
    check("emptying an empty trash says that instead", Trash.trashEmptied(0, 0), "The trash is already empty.")
}
