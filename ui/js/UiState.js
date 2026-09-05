.pragma library

// ui/ViewState.qml's one-writer bookkeeping, and nothing else: `saved` is the newest patch a writer
// landed, `inflight` is what the running `flea --ui-state` carries, and `pending` is the newest patch
// waiting behind it. All three are patch bytes and not the state file's, because a patch names only
// the settings that window changed. Imports no QML, so tests/js/uistate.js can redden on a mutation.

// The window's own read of ui.json. main() leaves a document it cannot read as a JSON object
// exactly as the operator wrote it, so `unreadable` is what makes the pane say the file was not used;
// no file at all is a first launch and says nothing.
function fromFile(text) {
    try {
        var found = JSON.parse(text)
        if (found && typeof found === "object" && !Array.isArray(found)) {
            return { state: found, unreadable: false }
        }
    } catch (e) {
        // A hand edit this cannot parse, which is the ordinary way in and is not an error here.
    }
    return { state: {}, unreadable: text.length > 0 }
}

// A copy of the document with one top-level key replaced, and the nested version of the same. QML
// notifies on assignment and not on a mutation, so every writer rebuilds rather than reaching in;
// the nested one merges into the group beside it, because a whole-group assignment would take the
// half a writer holds as the whole of it. ui/ViewState.qml runs both over two documents at once:
// the state it draws from, and the patch it owes the state file.
function withKey(state, key, value) {
    var out = {}
    for (var s in state)
        out[s] = state[s]
    out[key] = value
    return out
}

function withGroup(state, key, next) {
    var group = {}
    var held = state[key] || {}
    for (var h in held)
        group[h] = held[h]
    for (var n in next)
        group[n] = next[n]
    return withKey(state, key, group)
}

// The book a window starts with: nothing of its own written yet, and no writer running. Its own read
// of the file is not a patch it sent, so `saved` starts empty rather than holding what it read.
function book() {
    return { saved: "", inflight: "", pending: "" }
}

// A change asks for a write. The answer is the next book plus `start`, the patch to launch now.
function asked(b, patch) {
    // The newest patch this window has landed or has on its way, so asking for exactly those bytes
    // again sends nothing and a refused one is never short-circuited.
    if (patch === (b.pending || b.inflight || b.saved)) {
        return { saved: b.saved, inflight: b.inflight, pending: b.pending, start: "" }
    }
    // One writer at a time, and the newest patch waits rather than being dropped on the floor.
    if (b.inflight.length > 0) {
        return { saved: b.saved, inflight: b.inflight, pending: patch, start: "" }
    }
    return { saved: b.saved, inflight: patch, pending: "", start: patch }
}

// The writer exited. The answer is the next book plus `start`, and `failed` for the pane to report.
function exited(b, code) {
    // Only a zero status proves the patch reached the file: src/main.rs exits 2 on a refused patch
    // and on a state directory it could not write, and the change is on screen either way.
    return {
        saved: code === 0 ? b.inflight : b.saved,
        inflight: b.pending,
        pending: "",
        start: b.pending,
        failed: code !== 0
    }
}
