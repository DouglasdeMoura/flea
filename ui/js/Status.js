.pragma library

// Sample input: { transient: "Copy failed", transientIsError: true, searching: true, searchKeys: "esc cancels", stickyHere: true, sticky: "Copying 2 of 5", fsText: "btrfs" }
function errorHere(slot) {
    return slot.transient.length > 0 && slot.transientIsError
}

// GM's ordering: acknowledged errors leave the slot; activity cannot displace them.
function rightText(slot) {
    if (errorHere(slot))
        return slot.transient
    if (slot.stickyHere)
        return slot.sticky
    if (slot.searching)
        return slot.searchKeys
    return slot.transient.length > 0 ? slot.transient : slot.fsText
}

function rightRole(slot) {
    if (errorHere(slot))
        return "error"
    return slot.stickyHere ? "foreground" : "muted"
}
