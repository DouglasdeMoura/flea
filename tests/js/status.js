.import "../../ui/js/Status.js" as Status

// The status slot's precedence, which shipped with no suite of any kind. Operations.html states the
// order as an unacknowledged error, then activity, and draws a failed copy holding the slot while a
// running search keeps a secondary count beside it. These drive the precedence directly, because
// the order is the whole of the policy and none of it needs a window to be true.

function slot(over) {
    var s = {
        transient: "",
        transientIsError: false,
        searching: false,
        searchKeys: "",
        stickyHere: false,
        sticky: "",
        fsText: "btrfs · 412 GB free"
    }
    for (var k in over) {
        s[k] = over[k]
    }
    return s
}

function run(check) {
    var quiet = slot({})
    check("an idle bar says what the filesystem is", Status.rightText(quiet), "btrfs · 412 GB free")
    check("and draws it muted", Status.rightRole(quiet), "muted")

    var searching = slot({ searching: true, searchKeys: "esc cancels" })
    check("a search on its own owns the slot", Status.rightText(searching), "esc cancels")

    var working = slot({ stickyHere: true, sticky: "Compressing 2 of 5" })
    check("a running operation owns the slot", Status.rightText(working), "Compressing 2 of 5")
    check("and reads at full contrast", Status.rightRole(working), "foreground")

    var both = slot({ searching: true, searchKeys: "esc cancels", stickyHere: true, sticky: "Copying 2 of 5" })
    check("transfer precedes search", Status.rightText(both), "Copying 2 of 5")
    check("transfer retains foreground during search", Status.rightRole(both), "foreground")

    var failed = slot({ transient: "Copy failed: photo.heic · disk full", transientIsError: true })
    check("a failure owns the slot", Status.rightText(failed), "Copy failed: photo.heic · disk full")
    check("and takes the error role", Status.rightRole(failed), "error")

    // The defect this suite was written for. Operations.html's third specimen draws exactly this
    // pair: the failure holds the slot and the walk is reduced to a secondary count.
    var failedWhileSearching = slot({
        transient: "Copy failed: photo.heic · disk full",
        transientIsError: true,
        searching: true,
        searchKeys: "esc cancels"
    })
    check("a search never hides an unacknowledged error",
          Status.rightText(failedWhileSearching), "Copy failed: photo.heic · disk full")
    check("and the error keeps its role rather than painting the search keys red",
          Status.rightRole(failedWhileSearching), "error")

    // The same rule against a running operation, which the board ranks below a failure for the same
    // reason: the operation will end on its own and the error will not.
    var failedWhileWorking = slot({
        transient: "Convert failed: no encoder",
        transientIsError: true,
        stickyHere: true,
        sticky: "Converting 1 of 3"
    })
    check("a running operation never hides an unacknowledged error",
          Status.rightText(failedWhileWorking), "Convert failed: no encoder")
    check("and it is drawn as an error, not as the operation",
          Status.rightRole(failedWhileWorking), "error")

    // An ordinary result is not an error, so it stays behind activity and times out on its own.
    var noticeWhileSearching = slot({
        transient: "Moved 4 items to Trash",
        searching: true,
        searchKeys: "esc cancels"
    })
    check("a plain notice still yields to the search",
          Status.rightText(noticeWhileSearching), "esc cancels")

    check("errorHere is the one test for an unacknowledged failure",
          Status.errorHere(failed), true)
    check("and a plain notice is not one", Status.errorHere(noticeWhileSearching), false)
}
