// The wire's one-line responses: listed, the search pair, the thumbnail and dirsize replies, the
// paths reply and the error line, each a single format! call. The request side is request.rs and
// the rows serialiser is rows.rs; this file split when the delete request pushed it past the hard
// cap, the same cut rows.rs took before it.
use crate::error::FleaError;
use crate::json::escape;

pub fn listed_line(n: usize, read_ms: f64, sort_ms: f64, dev: u64) -> String {
    format!(
        r#"{{"t":"listed","n":{},"read":{:.3},"sort":{:.3},"v":{}}}"#,
        n, read_ms, sort_ms, dev
    )
}

// The streaming progress of a search: its own type rather than a listed line, because a mid-walk update is not a fresh listing and carries no read or sort timing.
pub fn searching_line(n: usize, scanned: usize, ms: f64) -> String {
    format!(r#"{{"t":"searching","n":{},"scanned":{},"ms":{:.3}}}"#, n, scanned, ms)
}

// The terminal line of a search: cancelled is true when the client stopped the walk or a new listing replaced it.
pub fn searched_line(n: usize, scanned: usize, ms: f64, cancelled: bool) -> String {
    format!(
        r#"{{"t":"searched","n":{},"scanned":{},"ms":{:.3},"cancelled":{}}}"#,
        n, scanned, ms, cancelled
    )
}

// The file is empty rather than absent on failure, so a client never waits forever for a row that will not arrive.
pub fn thumbed_line(row: usize, file: &str, ms: f64) -> String {
    format!(r#"{{"t":"thumbed","row":{},"file":"{}","ms":{:.3}}}"#, row, escape(file), ms)
}

// partial is true when the 2000 ms deadline cut the walk short, see docs/protocol.md "dirsized".
pub fn dirsized_line(row: usize, bytes: u64, partial: bool, ms: f64) -> String {
    format!(r#"{{"t":"dirsized","row":{},"bytes":{},"partial":{},"ms":{:.3}}}"#, row, bytes, partial, ms)
}

// Sample output: {"t":"paths","paths":["/home/gm/a.txt","/home/gm/b.txt"]}
pub fn paths_line(paths: &[String]) -> String {
    let mut out = String::from(r#"{"t":"paths","paths":["#);
    for (i, p) in paths.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('"');
        out.push_str(&escape(p));
        out.push('"');
    }
    out.push_str("]}");
    out
}

pub fn error_line(e: &FleaError) -> String {
    format!(
        r#"{{"t":"error","where":"{}","path":"{}","msg":"{}"}}"#,
        escape(&e.where_),
        escape(&e.path),
        escape(&e.msg)
    )
}

// A denied listing is the only failure a pane draws more than a sentence for: States.dc.html gives
// it the directory's own mode string. The field is written only when the mode is known, so every
// other error line on this wire keeps exactly the three fields it has always had.
pub fn error_line_with_mode(e: &FleaError, mode: u32) -> String {
    if mode == 0 {
        return error_line(e);
    }
    format!(
        r#"{{"t":"error","where":"{}","path":"{}","msg":"{}","mode":{}}}"#,
        escape(&e.where_),
        escape(&e.path),
        escape(&e.msg),
        mode
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_paths_line_escapes_every_element_and_survives_an_empty_list() {
        assert_eq!(paths_line(&[]), r#"{"t":"paths","paths":[]}"#);
        assert_eq!(
            paths_line(&["/home/gm/a.txt".to_string(), "/home/gm/say \"hi\".txt".to_string()]),
            r#"{"t":"paths","paths":["/home/gm/a.txt","/home/gm/say \"hi\".txt"]}"#
        );
    }

    #[test]
    fn emits_a_listed_line() {
        let s = listed_line(100000, 26.4, 2.5, 56);
        assert_eq!(s, r#"{"t":"listed","n":100000,"read":26.400,"sort":2.500,"v":56}"#);
    }

    #[test]
    fn emits_a_thumbed_line_for_a_generated_row_and_for_a_failed_one() {
        assert_eq!(
            thumbed_line(2, "/home/gm/.cache/thumbnails/large/b98fa408.png", 75.8234),
            r#"{"t":"thumbed","row":2,"file":"/home/gm/.cache/thumbnails/large/b98fa408.png","ms":75.823}"#
        );
        // The empty file is the whole failure form on this wire, so a client never waits forever.
        assert_eq!(thumbed_line(0, "", 0.0), r#"{"t":"thumbed","row":0,"file":"","ms":0.000}"#);
    }

    #[test]
    fn emits_a_dirsized_line_complete_and_partial() {
        assert_eq!(
            dirsized_line(4, 1048576, false, 12.5),
            r#"{"t":"dirsized","row":4,"bytes":1048576,"partial":false,"ms":12.500}"#
        );
        // partial:true is a floor, not a wrong exact number; the cell renders it with a leading ">".
        assert_eq!(
            dirsized_line(9, 200, true, 2000.0),
            r#"{"t":"dirsized","row":9,"bytes":200,"partial":true,"ms":2000.000}"#
        );
    }

    #[test]
    fn a_thumbed_path_is_escaped_like_every_other_string() {
        let s = thumbed_line(7, "/tmp/say \"hi\"\nand\ttab.png", 1.0);
        assert_eq!(s.lines().count(), 1);
        assert!(s.contains(r#""file":"/tmp/say \"hi\"\nand\ttab.png""#));
    }

    #[test]
    fn emits_an_error_line_naming_operation_and_path() {
        let e = FleaError {
            where_: "scan".to_string(),
            path: "/root".to_string(),
            msg: "permission denied".to_string(),
        };
        assert_eq!(
            error_line(&e),
            r#"{"t":"error","where":"scan","path":"/root","msg":"permission denied"}"#
        );
        // The mode rides on the same line, after msg, so an old reader keeps parsing what it knows.
        assert_eq!(
            error_line_with_mode(&e, 0o40750),
            r#"{"t":"error","where":"scan","path":"/root","msg":"permission denied","mode":16872}"#
        );
        // Zero is "I could not stat it either", and that draws no mode string, so it sends no field.
        assert_eq!(
            error_line_with_mode(&e, 0),
            r#"{"t":"error","where":"scan","path":"/root","msg":"permission denied"}"#
        );
    }
}
