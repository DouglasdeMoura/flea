.pragma library

// Sample input, GIO trash::deletion-date: "2026-09-08T10:00:00" in local time.
function deleted(text, nowMs) {
    var date = new Date(text)
    if (!isFinite(date.getTime())) return "Unknown"
    var now = new Date(nowMs)
    var day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    if (day === today.getTime()) return "today"
    today.setDate(today.getDate() - 1)
    if (day === today.getTime()) return "yesterday"
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return months[date.getMonth()] + " " + date.getDate() + (date.getFullYear() === now.getFullYear() ? "" : " " + date.getFullYear())
}
