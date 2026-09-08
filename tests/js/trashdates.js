.import "../../ui/js/TrashDates.js" as Trash
function run(check) {
    var now = new Date(2026, 8, 8, 12).getTime()
    check("today", Trash.deleted("2026-09-08T01:00:00", now), "today")
    check("yesterday", Trash.deleted("2026-09-07T23:00:00", now), "yesterday")
    check("older day", Trash.deleted("2026-08-30T12:00:00", now), "Aug 30")
    check("older year", Trash.deleted("2025-08-30T12:00:00", now), "Aug 30 2025")
    check("missing date is honest", Trash.deleted("", now), "Unknown")
}
