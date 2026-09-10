.import "../../ui/js/TrashKeys.js" as TrashKeys

// What keys and menu rows mean in the trash. These drive TrashKeys.act directly with stub panes,
// because the location is the whole of the routing and no window is needed to prove it: in the
// trash every write reroutes or refuses, and anywhere else every action falls through untouched.

// Only the members TrashKeys.act reads: the path for the location, and spies for the backends.
function pane(path) {
    var p = {
        path: path,
        cursorIndex: 3,
        said: "",
        restored: [],
        deleted: [],
        emptied: 0,
        selectedIndices: function () { return [] }
    }
    p.message = function (text, isError) { p.said = text }
    p.backend = {
        trashRestore: function (idx) { p.restored = idx },
        trashDelete: function (idx) { p.deleted = idx },
        trashEmpty: function () { p.emptied += 1 }
    }
    return p
}

function run(check) {
    var t = pane("flea:trash")
    check("trash in the trash deletes permanently", TrashKeys.act("trash", t), true)
    check("and names the rows it deletes", t.deleted.join(","), "3")
    check("the d pair arms in the trash", TrashKeys.act("trashArm", t), true)
    check("and says what the second press does", t.said,
          "Press d again to delete permanently. This cannot be undone.")
    check("u restores in the trash", TrashKeys.act("restore", t), true)
    check("and names the rows it restores", t.restored.join(","), "3")
    check("the menu's delete row deletes", TrashKeys.act("deletePermanent", t), true)
    check("the menu's empty row arms rather than firing", TrashKeys.act("emptyTrash", t), true)
    check("so choosing it once empties nothing", t.emptied, 0)
    check("and says what choosing it again does", t.said,
          "Press again to empty the trash. This cannot be undone.")
    check("rename in the trash refuses with the way back", TrashKeys.act("rename", t), true)
    check("the sentence names the refusal", t.said,
          "Renaming is not available in the trash. Restore the item first.")
    check("newFolder in the trash refuses", TrashKeys.act("newFolder", t), true)
    check("duplicate in the trash refuses", TrashKeys.act("duplicate", t), true)
    check("cut in the trash refuses", TrashKeys.act("cut", t), true)
    check("paste in the trash refuses", TrashKeys.act("paste", t), true)
    check("search in the trash refuses with the filter named", TrashKeys.act("search", t), true)
    check("the sentence names the filter", t.said,
          "Search is not available in the trash. Press / to filter by name.")

    // Movement and everything else fall through to the ordinary dispatch, in the trash as well.
    check("a cursor key is not the trash's to answer", TrashKeys.act("cursorDown", t), false)
    check("undo is not the trash's to answer either", TrashKeys.act("undo", t), false)

    // Anywhere else every action falls through untouched, including the menu-only rows, which no
    // key reaches and whose refusal would be dead code: an action arriving where its menu never
    // offers it ends at Focus's own loud fallback instead.
    var d = pane("/home/gm/Downloads")
    var actions = ["trash", "trashArm", "restore", "deletePermanent", "emptyTrash", "rename",
                   "newFolder", "duplicate", "cut", "paste", "search"]
    var handled = []
    for (var i = 0; i < actions.length; i++) {
        if (TrashKeys.act(actions[i], d)) {
            handled.push(actions[i])
        }
    }
    check("outside the trash the location owns nothing", handled.join(","), "")
    check("and says nothing either", d.said, "")
}
