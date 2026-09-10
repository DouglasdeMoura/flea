// The trash operations' request layer: their response lines, their runners, and the starters
// that claim the one-at-a-time slot for them. Moved out of opsreq.rs and opsdispatch.rs whole
// when the trash browser's restore, permanent delete and empty put both files over the hard cap;
// the seam is the subject, which is every wire verb that touches the freedesktop trash.
use crate::backend::listing::Listing;
use crate::backend::opsdispatch::{busy, resolve_rows, Ops};
use crate::backend::opsreq::OpMsg;
use crate::backend::trash;
use crate::backend::undo::{Entry, Step};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::thread;

pub fn trashed_line(ok: usize, failed: usize) -> String {
    format!(r#"{{"t":"trashed","ok":{},"failed":{}}}"#, ok, failed)
}

pub fn restored_line(ok: usize, failed: usize) -> String {
    format!(r#"{{"t":"restored","ok":{},"failed":{}}}"#, ok, failed)
}

pub fn trashdeleted_line(ok: usize, failed: usize) -> String {
    format!(r#"{{"t":"trashdeleted","ok":{},"failed":{}}}"#, ok, failed)
}

pub fn trashemptied_line(ok: usize, failed: usize) -> String {
    format!(r#"{{"t":"trashemptied","ok":{},"failed":{}}}"#, ok, failed)
}

// Restore, permanent delete and empty take the same slot as trash for the same reason: the status
// bar reports one operation, so a second answers an error rather than queueing invisibly behind it.
// The rows form is resolved here, at request time, so each starter owns the snapshot that outlives
// whatever the listing does next; see resolve_rows.
pub(crate) fn start_trash(out: &mut impl Write, ops: &mut Ops, paths: Vec<String>, rows: Vec<usize>, base: &Path, listing: &Listing) {
    if ops.running.is_some() {
        busy(out, "trash");
        return;
    }
    let named = resolve_rows(paths, &rows, base, listing);
    ops.claim();
    let tx = ops.tx.clone();
    thread::spawn(move || run_trash(named, tx));
}

pub(crate) fn start_trash_restore(out: &mut impl Write, ops: &mut Ops, paths: Vec<String>, rows: Vec<usize>, base: &Path, listing: &Listing) {
    if ops.running.is_some() {
        busy(out, "trashrestore");
        return;
    }
    let named = resolve_rows(paths, &rows, base, listing);
    ops.claim();
    let tx = ops.tx.clone();
    thread::spawn(move || run_trash_restore(named, tx));
}

pub(crate) fn start_trash_delete(out: &mut impl Write, ops: &mut Ops, paths: Vec<String>, rows: Vec<usize>, base: &Path, listing: &Listing) {
    if ops.running.is_some() {
        busy(out, "trashdelete");
        return;
    }
    let named = resolve_rows(paths, &rows, base, listing);
    ops.claim();
    let tx = ops.tx.clone();
    thread::spawn(move || run_trash_delete(named, tx));
}

pub(crate) fn start_trash_empty(out: &mut impl Write, ops: &mut Ops) {
    if ops.running.is_some() {
        busy(out, "trashempty");
        return;
    }
    ops.claim();
    let tx = ops.tx.clone();
    thread::spawn(move || run_trash_empty(tx));
}

pub fn run_trash(paths: Vec<String>, tx: Sender<OpMsg>) {
    let owned: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let (entries, failed) = trash::trash(&owned);
    let ok = entries.len();
    let steps = entries.into_iter().map(Step::Trashed).collect();
    let entry = Entry { op: "trash".to_string(), steps };
    let _ = tx.send(OpMsg::Trashed { ok, failed, entry });
}

// A restore moves entries out of the trash, so there is nothing for the journal to put back that
// would not orphan a .trashinfo: undoing by rename would recreate the files/ entry without its
// info, and re-trashing is a new operation rather than a reversal. Restore, permanent delete and
// empty therefore journal nothing, and the entry they would have pushed is never built.
pub fn run_trash_restore(paths: Vec<String>, tx: Sender<OpMsg>) {
    let owned: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let (ok, failed) = trash::restore_paths(&owned);
    let _ = tx.send(OpMsg::Restored { ok, failed });
}

pub fn run_trash_delete(paths: Vec<String>, tx: Sender<OpMsg>) {
    let owned: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let (ok, failed) = trash::delete_paths(&owned);
    let _ = tx.send(OpMsg::TrashDeleted { ok, failed });
}

pub fn run_trash_empty(tx: Sender<OpMsg>) {
    let (ok, failed) = trash::empty();
    let _ = tx.send(OpMsg::TrashEmptied { ok, failed });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_trash_lines_carry_counts_and_nothing_else() {
        assert_eq!(trashed_line(1, 0), r#"{"t":"trashed","ok":1,"failed":0}"#);
        assert_eq!(restored_line(1, 2), r#"{"t":"restored","ok":1,"failed":2}"#);
        assert_eq!(trashdeleted_line(0, 1), r#"{"t":"trashdeleted","ok":0,"failed":1}"#);
        assert_eq!(trashemptied_line(3, 0), r#"{"t":"trashemptied","ok":3,"failed":0}"#);
    }
}
