.import "../../ui/js/UiState.js" as UiState

// ui/ViewState.qml's writer bookkeeping. The window shows the column change the instant it is made
// and the state file learns about it through a process, so the only thing that can tell the two
// apart is the writer's own exit status. A book that records the patch before the process runs
// reports a save that never happened, and then refuses the retry that would have fixed it.

var OLD = "{\"columns\":[\"name\",\"size\",\"date\"]}"
var NEW = "{\"columns\":[\"name\",\"date\"]}"
var THIRD = "{\"columns\":[\"name\"]}"

function run(check) {
    check("a fresh book holds what the file it read already has", UiState.book(OLD).saved, OLD)
    check("and nothing is in flight behind it", UiState.book(OLD).inflight, "")

    // The state file already holds this, so ui/shell.qml's scale step writes nothing.
    var same = UiState.asked(UiState.book(OLD), OLD)
    check("a patch the file already holds starts nothing", same.start, "")

    var asked = UiState.asked(UiState.book(OLD), NEW)
    check("a change starts a write", asked.start, NEW)
    check("and the change is in flight, not saved", asked.inflight, NEW)
    check("the file is still known to hold what it held", asked.saved, OLD)

    // Scenario A: ~/.local/state is unwritable, so src/main.rs prints its sentence and exits 2.
    var refused = UiState.exited(asked, 2)
    check("a refused write is not believed", refused.saved, OLD)
    check("a refused write is reported", refused.failed, true)
    check("and it leaves no writer in flight", refused.inflight, "")

    // The whole cost of believing it: the identical toggle can never even be attempted again.
    check("an identical retry is attempted after a refusal", UiState.asked(refused, NEW).start, NEW)

    var landed = UiState.exited(asked, 0)
    check("a write that exited zero is believed", landed.saved, NEW)
    check("and it is not reported", landed.failed, false)
    check("a patch the landed write already stored starts nothing", UiState.asked(landed, NEW).start, "")

    // One writer at a time, and the newest patch waits rather than being dropped on the floor.
    var queued = UiState.asked(asked, THIRD)
    check("a second change queues behind the running writer", queued.pending, THIRD)
    check("and starts nothing of its own", queued.start, "")
    check("the running writer still carries the first", queued.inflight, NEW)
    // Toggling back to what the queue already asks for must not send the same bytes twice.
    check("the queued patch is not sent twice", UiState.asked(queued, THIRD).start, "")

    // The window's own read of the file. main() leaves a ui.json it cannot read as a JSON object
    // exactly as the operator wrote it, so the window draws the defaults and has to be what says so.
    check("a document the window can read is read", UiState.fromFile(OLD).state.columns[2], "date")
    check("and nothing is said about it", UiState.fromFile(OLD).unreadable, false)
    check("a trailing comma reads as the full default shape", JSON.stringify(UiState.fromFile("{\"columns\":[\"name\"],}").state), "{}")
    check("and the pane is told to say so", UiState.fromFile("{\"columns\":[\"name\"],}").unreadable, true)
    check("a document that is not an object is the same", UiState.fromFile("[1,2]").unreadable, true)
    check("no file at all is a first launch and says nothing", UiState.fromFile("").unreadable, false)

    // The document the window holds, rebuilt rather than mutated: a var property notifies on
    // assignment and not on a reach-in, and a whole-group assignment would take one writer's half
    // of display or menu as the whole of it.
    var held = { columns: ["name"], display: { textSize: { mode: "system" } } }
    check("one key is replaced and the rest carried",
          JSON.stringify(UiState.withKey(held, "keys", "windows")),
          '{"columns":["name"],"display":{"textSize":{"mode":"system"}},"keys":"windows"}')
    check("a group merges into what is beside it rather than replacing the group",
          JSON.stringify(UiState.withGroup({ menu: { basic: true, hidden: ["paste"] } }, "menu", { hidden: [] })),
          '{"menu":{"basic":true,"hidden":[]}}')
    check("a group that is not there yet is created",
          JSON.stringify(UiState.withGroup({}, "display", { textSize: { mode: 16 } })),
          '{"display":{"textSize":{"mode":16}}}')
    check("and neither writer mutates the document it was handed",
          JSON.stringify(held), '{"columns":["name"],"display":{"textSize":{"mode":"system"}}}')

    var drained = UiState.exited(queued, 0)
    check("the queued patch starts when the writer exits", drained.start, THIRD)
    check("and the exited writer's own patch is what the file now holds", drained.saved, NEW)
    check("a refusal underneath a queue still runs the queue", UiState.exited(queued, 2).start, THIRD)
    check("and still reports the refusal", UiState.exited(queued, 2).failed, true)
}
