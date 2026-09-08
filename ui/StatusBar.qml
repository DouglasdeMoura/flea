import QtQuick
import qs.Commons
import "js/Format.js" as Format
import "js/Ops.js" as Ops
import "js/Status.js" as Status

Item {
    id: root

    property string path: ""
    property int total: 0
    property int cursorIndex: 0
    property string listingState: "loading"
    property int selectionCount: 0
    property string fsName: ""
    property real fsFree: 0
    property string notice: ""
    property var errors: []
    readonly property string transient_: root.errors.length ? root.errors[0].text : root.notice
    readonly property string errorDetail: root.errors.length ? root.errors[0].detail : ""
    readonly property bool transientIsError: root.errors.length > 0
    property string sticky: ""
    property var transfer: Ops.emptyTransfer()
    property int cancellingId: 0
    readonly property bool stickyHere: root.sticky.length > 0
    property string searchLine: ""
    property string searchKeys: ""
    property bool searchRunning: false
    readonly property bool searching: root.searchLine.length > 0
    readonly property int spiralSize: Style.font.body
    readonly property int messageMs: 4000
    readonly property bool hasUndo: !root.transientIsError && !root.stickyHere && !root.searching
                                    && root.notice.indexOf(Ops.UNDO_HINT) >= 0
    readonly property string secondaryText: root.transientIsError || root.stickyHere
        ? [root.transientIsError && root.stickyHere ? root.sticky : "", root.searching ? "search " + root.searchLine : ""].filter(function (s) { return s.length > 0 }).join(" · ")
        : ""
    signal transferCancelRequested(int id)
    signal undoRequested()
    implicitHeight: Theme.chromeHeight + detailView.height

    // Completion messages cannot acknowledge a failure; each error requires its own dismissal.
    function say(text, isError, detail) {
        if (!text) { root.dismiss(); return }
        if (isError) {
            root.errors = root.errors.concat([{text: text, detail: detail || ""}])
            return
        }
        root.notice = text
        if (text.indexOf(Ops.UNDO_HINT) >= 0) clear.stop()
        else clear.restart()
    }

    function dismiss() {
        if (root.errors.length) root.errors = root.errors.slice(1)
        else root.notice = ""
    }

    function settle(text, isError) {
        root.sticky = ""
        root.say(text, isError)
    }

    function countText() {
        if (root.listingState === "empty") return "empty"
        if (root.listingState === "error" || root.listingState === "locked") return "unavailable"
        if (root.listingState !== "ready") return ""
        var base = root.total + (root.total === 1 ? " item" : " items")
        return root.selectionCount > 0 ? base + " · " + root.selectionCount + " selected" : base
    }

    function fsText() {
        return root.fsName.length ? root.fsName + " · " + Format.size(root.fsFree) + " free" : ""
    }

    function slot() {
        return { transient: root.transient_, transientIsError: root.transientIsError,
                 searching: root.searching, searchKeys: "Search: " + root.searchLine + " · " + root.searchKeys,
                 stickyHere: root.stickyHere, sticky: root.sticky, fsText: root.fsText() }
    }

    function rightText() {
        var text = Status.rightText(root.slot())
        return root.hasUndo ? text.replace(Ops.UNDO_HINT, "") : text
    }
    function rightColor() { return Theme.color[Status.rightRole(root.slot())] }

    Timer { id: clear; interval: root.messageMs; onTriggered: root.notice = "" }

    Item { id: strip; width: parent.width; height: Theme.chromeHeight }

    Rectangle {
        width: parent.width
        height: Theme.chromeHeight
        color: Theme.color.surface
        border.width: Theme.spacing.hairline
        border.color: root.transientIsError ? Theme.color.error : Theme.color.muted
    }

    Text {
        id: location
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: strip.verticalCenter
        width: Math.min(implicitWidth, root.width / 4)
        text: root.path
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        elide: Text.ElideMiddle
        textFormat: Text.PlainText
    }

    Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: strip.verticalCenter
        spacing: Theme.spacing.gap

        StatusAction {
            visible: root.transfer.running
            label: root.cancellingId === root.transfer.id ? "Cancelling" : root.transfer.moving ? "Cancel move" : "Cancel copy"
            available: root.cancellingId !== root.transfer.id
            onActivated: {
                root.cancellingId = root.transfer.id
                root.transferCancelRequested(root.transfer.id)
            }
        }
        StatusAction { visible: root.hasUndo; label: "Undo · z"; onActivated: root.undoRequested() }
        StatusAction { visible: root.transientIsError; label: "Dismiss error"; onActivated: root.dismiss() }
    }

    Text {
        id: secondary
        anchors.right: actions.left
        anchors.rightMargin: actions.width ? Theme.spacing.gap : 0
        anchors.verticalCenter: strip.verticalCenter
        width: root.secondaryText.length ? Math.min(implicitWidth, root.width / 4) : 0
        text: root.secondaryText
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
    }

    Text {
        id: primary
        anchors.right: secondary.left
        anchors.rightMargin: secondary.width ? Theme.spacing.gap : 0
        anchors.verticalCenter: strip.verticalCenter
        width: Math.max(0, Math.min(implicitWidth, secondary.x - location.x - location.width - 3 * Theme.spacing.gap - root.spiralSize))
        text: root.rightText() || root.countText()
        color: root.rightColor()
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        elide: Text.ElideMiddle
        textFormat: Text.PlainText
    }

    Spinner {
        visible: !root.transientIsError && (root.stickyHere || root.searchRunning)
        anchors.right: primary.left
        anchors.rightMargin: Theme.spacing.gap
        anchors.verticalCenter: strip.verticalCenter
        width: root.spiralSize
        height: root.spiralSize
        color: Theme.color.muted
    }

    Rectangle {
        x: detailView.x; y: detailView.y
        width: detailView.width; height: detailView.height
        visible: detailView.visible
        color: Theme.color.surface
        border.color: Theme.color.error
        border.width: Theme.spacing.hairline
    }
    Flickable {
        id: detailView
        y: Theme.chromeHeight
        width: parent.width
        visible: root.errorDetail.length > 0
        height: visible ? Math.min(contentHeight, root.parent ? root.parent.height / 3 : contentHeight) : 0
        contentWidth: width
        contentHeight: detailText.implicitHeight + 2 * Theme.spacing.rowPaddingY
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onVisibleChanged: contentY = 0
        Text {
            id: detailText
            x: Theme.spacing.rowPaddingX
            y: Theme.spacing.rowPaddingY
            width: parent.width - 2 * Theme.spacing.rowPaddingX
            text: root.errorDetail
            color: Theme.color.error
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
    }
}
