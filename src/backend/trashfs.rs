// Restores, permanently deletes and empties the freedesktop trash at the filesystem
// level rather than through gio. gio's restore, list and empty are daemon-side: they
// cannot see a trash XDG_DATA_HOME redirects, so a gio-based verb is untestable in a
// sandbox and refuses there. The undo journal's gio trash --restore path stays in trash.rs.
use crate::error::{from_io, FleaError};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

// Restores each files/ path below to the original its info file vouches for. The semantics
// are gio's own, measured on this box rather than assumed: an existing destination refuses
// with the entry staying in the trash, and a missing parent is recreated. Nothing is
// journalled: undoing a restore by rename would recreate the files/ entry without its info,
// and re-trashing is a new operation rather than a reversal.
pub fn restore_paths(paths: &[PathBuf]) -> (usize, usize) {
    let mut ok = 0;
    let mut failed = 0;
    for p in paths {
        if restore_one(p).is_ok() {
            ok += 1;
        } else {
            failed += 1;
        }
    }
    (ok, failed)
}

fn restore_one(path: &Path) -> Result<(), FleaError> {
    let leaf = path.file_name().and_then(|n| n.to_str()).ok_or_else(|| refuse(path, "is not a trashed entry"))?;
    // <trash>/files/<leaf>, so the info beside it is <trash>/info/<leaf>.trashinfo. Anything
    // else is not a trashed entry and is refused before anything is touched.
    let files = path.parent().ok_or_else(|| refuse(path, "is not a trashed entry"))?;
    if files.file_name().and_then(|n| n.to_str()) != Some("files") {
        return Err(refuse(path, "is not a trashed entry"));
    }
    let trash = files.parent().ok_or_else(|| refuse(path, "is not a trashed entry"))?;
    let text = std::fs::read_to_string(trash.join("info").join(format!("{leaf}.trashinfo")))
        .map_err(|_| refuse(path, "has no trash entry, so where it came from is unknown"))?;
    let original = crate::backend::trashinfo::parse(&text)
        .original
        .ok_or_else(|| refuse(path, "has no original path, so it cannot be restored"))?;
    if let Some(parent) = original.parent() {
        // gio recreates parents a restore outlived, measured; a failure here refuses below.
        let _ = std::fs::create_dir_all(parent);
    }
    // Exclusive, the way every write in ops.rs is. Only EEXIST is "already there": every other
    // refusal (a parent that is a file, EXDEV, EACCES) must keep its own sentence, or a blocked
    // restore reads as a collision and the operator looks in the wrong place.
    match crate::backend::renamecompat::rename_noreplace(path, &original) {
        Ok(()) => {}
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {
            return Err(refuse(&original, "is already there, so the trashed entry was left where it is"));
        }
        Err(e) => return Err(from_io("trashrestore", &original.to_string_lossy(), &e)),
    }
    // The entry is home; an info file left behind is invisible to the listing, which walks
    // files/ and never info/, so its removal failing changes nothing the user can see.
    let _ = std::fs::remove_file(trash.join("info").join(format!("{leaf}.trashinfo")));
    Ok(())
}

fn refuse(path: &Path, msg: &str) -> FleaError {
    FleaError { where_: "trashrestore".to_string(), path: path.to_string_lossy().into_owned(), msg: msg.to_string() }
}

// Deletes each files/ entry permanently, with the info file beside it. A symlink is removed as a
// link and never followed; a directory goes whole, the way Shift+Delete on a trashed folder does.
// Gone afterwards counts as done: the end state is what the caller asked for, whatever removed it.
// The info file is removed only after the entry is gone, so a half-deleted directory still has
// somewhere to restore from rather than becoming an unrestorable leftover.
pub fn delete_paths(paths: &[PathBuf]) -> (usize, usize) {
    let mut ok = 0;
    let mut failed = 0;
    for p in paths {
        let Some(leaf) = p.file_name().and_then(|n| n.to_str()) else {
            failed += 1;
            continue;
        };
        let Some(files) = p.parent() else {
            failed += 1;
            continue;
        };
        if files.file_name().and_then(|n| n.to_str()) != Some("files") {
            failed += 1;
            continue;
        }
        let gone = match std::fs::symlink_metadata(p) {
            Err(_) => true,
            Ok(m) if m.is_dir() => std::fs::remove_dir_all(p).is_ok(),
            Ok(_) => std::fs::remove_file(p).is_ok(),
        } && std::fs::symlink_metadata(p).is_err();
        if gone {
            let info = files.parent().unwrap_or(Path::new("/")).join("info").join(format!("{leaf}.trashinfo"));
            let _ = std::fs::remove_file(&info);
            ok += 1;
        } else {
            failed += 1;
        }
    }
    (ok, failed)
}

// Empties every trash the enumeration sees, home and top-directory alike, by deleting each
// entry the same way trashdelete does.
pub fn empty() -> (usize, usize) {
    let home = crate::backend::trashlist::home_trash();
    let tops = crate::backend::trashlist::top_trashes(
        &crate::backend::trashlist::mount_points(),
        crate::backend::trashlist::euid(),
    );
    empty_at(home.as_deref(), &tops)
}

// The roots as parameters, so a test names fixture trashes without touching the process
// environment: XDG_DATA_HOME is process-global and cargo runs tests on threads.
pub fn empty_at(home: Option<&Path>, tops: &[PathBuf]) -> (usize, usize) {
    let paths: Vec<PathBuf> = crate::backend::trashlist::list(home, tops)
        .into_iter()
        .map(|e| e.path)
        .collect();
    delete_paths(&paths)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn trash_home(tag: &str) -> crate::backend::testdir::TestDir {
        let t = crate::backend::testdir::TestDir::new(tag);
        t.dir("Trash/files");
        t.dir("Trash/info");
        t.dir("back");
        t
    }

    fn plant(t: &crate::backend::testdir::TestDir, leaf: &str, original: &str) {
        t.file(&format!("Trash/files/{leaf}"), "bytes");
        t.file(
            &format!("Trash/info/{leaf}.trashinfo"),
            &format!("[Trash Info]\nPath={original}\nDeletionDate=2025-08-26T21:38:03\n"),
        );
    }

    #[test]
    fn restore_puts_the_entry_back_and_drops_its_info() {
        let t = trash_home("restore-ok");
        let original = t.join("back/a.txt").to_string_lossy().into_owned();
        plant(&t, "a.txt", &original);
        let (ok, failed) = restore_paths(&[t.join("Trash/files/a.txt")]);
        assert_eq!((ok, failed), (1, 0));
        assert_eq!(std::fs::read_to_string(t.join("back/a.txt")).unwrap(), "bytes");
        assert!(t.join("Trash/files/a.txt").symlink_metadata().is_err());
        assert!(t.join("Trash/info/a.txt.trashinfo").symlink_metadata().is_err());
    }

    #[test]
    fn restore_recreates_a_parent_it_outlived() {
        let t = trash_home("restore-parent");
        let original = t.join("back/deep/down/b.txt").to_string_lossy().into_owned();
        plant(&t, "b.txt", &original);
        let (ok, failed) = restore_paths(&[t.join("Trash/files/b.txt")]);
        assert_eq!((ok, failed), (1, 0), "gio recreates the parents, measured");
        assert_eq!(std::fs::read_to_string(t.join("back/deep/down/b.txt")).unwrap(), "bytes");
    }

    #[test]
    fn restore_refuses_an_existing_destination_and_leaves_the_entry() {
        let t = trash_home("restore-clash");
        let original = t.join("back/c.txt").to_string_lossy().into_owned();
        plant(&t, "c.txt", &original);
        t.file("back/c.txt", "someone else");
        let (ok, failed) = restore_paths(&[t.join("Trash/files/c.txt")]);
        assert_eq!((ok, failed), (0, 1), "gio's own File exists answer, measured");
        let err = restore_one(&t.join("Trash/files/c.txt")).expect_err("still refused");
        assert!(err.msg.contains("already there"), "a collision names the collision: {}", err.msg);
        assert!(t.join("Trash/files/c.txt").symlink_metadata().is_ok(), "the entry stays in the trash");
        assert_eq!(std::fs::read_to_string(t.join("back/c.txt")).unwrap(), "someone else");
    }

    #[test]
    fn restore_a_parent_that_is_a_file_is_not_already_there() {
        let t = trash_home("restore-enotdir");
        t.file("back/notdir", "x");
        let original = t.join("back/notdir/c.txt").to_string_lossy().into_owned();
        plant(&t, "c.txt", &original);
        let err = restore_one(&t.join("Trash/files/c.txt")).expect_err("must refuse");
        assert!(!err.msg.contains("already there"), "a blocked parent is not a collision: {}", err.msg);
        assert_eq!(err.where_, "trashrestore");
        assert!(t.join("Trash/files/c.txt").symlink_metadata().is_ok(), "the entry stays in the trash");
    }

    #[test]
    fn restore_refuses_what_has_no_info_and_what_is_not_a_files_entry() {
        let t = trash_home("restore-refused");
        t.file("Trash/files/orphan.txt", "x");
        let (ok, failed) = restore_paths(&[t.join("Trash/files/orphan.txt")]);
        assert_eq!((ok, failed), (0, 1), "no info, no original, no restore");
        let (ok, failed) = restore_paths(&[t.join("Trash/info/orphan.txt.trashinfo")]);
        assert_eq!((ok, failed), (0, 1), "only a files/ entry is ever restored");
        let (ok, failed) = restore_paths(&[t.join("back/c.txt")]);
        assert_eq!((ok, failed), (0, 1), "a plain path is never a trashed entry");
    }

    #[test]
    fn delete_removes_the_entry_with_its_info() {
        let t = trash_home("delete-file");
        t.file("Trash/files/a.txt", "a");
        t.file("Trash/info/a.txt.trashinfo", "[Trash Info]\nPath=/home/gm/a.txt\n");
        let (ok, failed) = delete_paths(&[t.join("Trash/files/a.txt")]);
        assert_eq!((ok, failed), (1, 0));
        assert!(!t.join("Trash/files/a.txt").exists());
        assert!(!t.join("Trash/info/a.txt.trashinfo").exists());
    }

    #[test]
    fn delete_removes_a_directory_whole_and_a_symlink_as_a_link() {
        let t = trash_home("delete-dir");
        t.dir("Trash/files/tree");
        t.file("Trash/files/tree/inner.txt", "x");
        t.file("Trash/info/tree.trashinfo", "[Trash Info]\nPath=/home/gm/tree\n");
        std::os::unix::fs::symlink("a.txt", t.join("Trash/files/link.txt")).unwrap();
        t.file("Trash/info/link.txt.trashinfo", "[Trash Info]\nPath=/home/gm/link.txt\n");
        let (ok, failed) = delete_paths(&[t.join("Trash/files/tree"), t.join("Trash/files/link.txt")]);
        assert_eq!((ok, failed), (2, 0));
        assert!(!t.join("Trash/files/tree").exists());
        assert!(t.join("Trash/files/link.txt").symlink_metadata().is_err());
    }

    #[test]
    fn delete_counts_gone_as_done_and_refuses_a_non_trash_path() {
        let t = trash_home("delete-gone");
        let (ok, failed) = delete_paths(&[t.join("Trash/files/never-was.txt")]);
        assert_eq!((ok, failed), (1, 0), "the end state is what was asked for");
        let (ok, failed) = delete_paths(&[t.join("Trash/info/a.txt.trashinfo")]);
        assert_eq!((ok, failed), (0, 1), "only a files/ entry is ever deleted");
    }

    #[test]
    fn delete_keeps_the_info_when_the_entry_stays() {
        let t = trash_home("delete-keep-info");
        let dir = t.dir("Trash/files/locked");
        t.file("Trash/files/locked/inner.txt", "x");
        t.file("Trash/info/locked.trashinfo", "[Trash Info]\nPath=/nowhere/locked\n");
        let mut perms = std::fs::metadata(&dir).unwrap().permissions();
        perms.set_mode(0o555);
        std::fs::set_permissions(&dir, perms.clone()).unwrap();
        let (ok, failed) = delete_paths(&[dir.clone()]);
        assert_eq!((ok, failed), (0, 1));
        assert!(dir.is_dir(), "the half-deleted tree stays");
        assert!(t.join("Trash/info/locked.trashinfo").is_file(), "the info stays so a restore can still find it");
        perms.set_mode(0o755);
        std::fs::set_permissions(&dir, perms).unwrap();
    }

    #[test]
    fn empty_deletes_every_entry_with_its_info_and_counts_them() {
        let t = trash_home("empty-all");
        let first = t.join("back/first.txt").to_string_lossy().into_owned();
        let second = t.join("back/second.txt").to_string_lossy().into_owned();
        plant(&t, "first.txt", &first);
        plant(&t, "second.txt", &second);
        t.dir("Trash/files/tree");
        t.file("Trash/files/tree/inner.txt", "x");
        t.file("Trash/info/tree.trashinfo", "[Trash Info]\nPath=/nowhere/tree\n");
        let top = t.join("mnt/.Trash-0");
        std::fs::create_dir_all(top.join("files")).unwrap();
        std::fs::create_dir_all(top.join("info")).unwrap();
        std::fs::write(top.join("files/u.txt"), "u").unwrap();
        std::fs::write(top.join("info/u.txt.trashinfo"), "[Trash Info]\nPath=/mnt/u.txt\n").unwrap();
        let (ok, failed) = empty_at(Some(&t.join("Trash")), &[top.clone()]);
        assert_eq!((ok, failed), (4, 0));
        assert!(t.join("Trash/files/first.txt").symlink_metadata().is_err());
        assert!(t.join("Trash/info/first.txt.trashinfo").symlink_metadata().is_err());
        assert!(t.join("Trash/files/tree").symlink_metadata().is_err());
        assert!(top.join("files/u.txt").symlink_metadata().is_err(), "the top trash empties too");
    }

    #[test]
    fn empty_of_nothing_answers_zero_and_zero() {
        let t = trash_home("empty-none");
        assert_eq!(empty_at(Some(&t.join("Trash")), &[]), (0, 0));
        assert_eq!(empty_at(None, &[]), (0, 0));
    }
}
