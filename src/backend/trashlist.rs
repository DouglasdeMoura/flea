// Enumerates the freedesktop trash the way gio sees it: the home trash plus one
// top-directory trash per mount. Each trash is a files/ dir of entries beside an info/ dir of
// .trashinfo files, so the enumeration walks files/ and reads the info beside each entry, never
// the other way round: an info file with no entry is metadata about nothing and is dropped.
use crate::backend::fsinfo::dev_of;
use crate::backend::listing::Listing;
use crate::backend::mountinfo;
use crate::backend::responses::listed_line;
use crate::backend::run::{forget_rows, write_window};
use crate::backend::searchreq::finish_search;
use crate::backend::sort::sort_by_name;
use crate::backend::state::{State, Tables};
use crate::backend::thumbs::Pool;
use crate::backend::trashinfo;
use crate::error::FleaError;
use std::collections::HashMap;
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

pub struct Entry {
    // The absolute files/ path: the row's own identity on the wire, which is what every per-row
    // facility stats, thumbnails and opens with no special case.
    pub path: PathBuf,
    // Empty when no info file vouches for one. The row still lists; it just restores to nowhere.
    pub original: PathBuf,
    // The raw DeletionDate, or empty. See trashinfo.rs for why the backend never converts it.
    pub deleted: String,
}

// What a trash row carries beside its file stat. Keyed by the arena name rather than the row
// index, so a later sort reorders nothing here: the map is order-free and the rows line looks
// each row up by the same name it draws.
pub struct Extra {
    pub original: String,
    pub deleted: String,
}

// thp.rs idiom: std already links the system libc, so one extern names the call without a crate.
// Always safe to call: geteuid takes no arguments and cannot fail.
unsafe extern "C" {
    fn geteuid() -> u32;
}

pub fn euid() -> u32 {
    unsafe { geteuid() }
}

// The home trash gio writes when the trashed file lives on the home device: $XDG_DATA_HOME/Trash,
// ~/.local/share/Trash when the session set no data home. None when no HOME names one at all,
// and then there is simply no home trash to show.
pub fn home_trash() -> Option<PathBuf> {
    crate::userfile::data_home().ok().map(|h| h.join("Trash"))
}

// Where a search rooted at the token walks: the home trash's files, because a path set across
// trash roots is not a directory and cannot be walked as one. A search from a trash with no home
// behind it is refused rather than walked nowhere.
pub fn search_scope(path: &str) -> Result<String, FleaError> {
    if path != TRASH_TOKEN {
        return Ok(path.to_string());
    }
    home_trash()
        .map(|h| h.join("files").to_string_lossy().into_owned())
        .ok_or_else(|| FleaError {
            where_: "search".to_string(),
            path: TRASH_TOKEN.to_string(),
            msg: "the trash has no home directory to search".to_string(),
        })
}

// One candidate per mount, in mountinfo order; list() skips whatever is not a readable dir, so
// /proc, /sys and every unmounted name on the list cost one failed read_dir each and nothing else.
pub fn top_trashes(mounts: &[PathBuf], uid: u32) -> Vec<PathBuf> {
    mounts.iter().map(|m| m.join(format!(".Trash-{uid}"))).collect()
}

// The $topdir a relative Path= in this trash is resolved against. Home trash has none.
pub fn topdir_of(trash: &Path) -> Option<PathBuf> {
    let name = trash.file_name()?.to_str()?;
    if name.starts_with(".Trash-") {
        return trash.parent().map(Path::to_path_buf);
    }
    let parent = trash.parent()?;
    if parent.file_name()?.to_str() == Some(".Trash") {
        return parent.parent().map(Path::to_path_buf);
    }
    None
}

// The one line that reads /proc/self/mountinfo lives with the caller that needs it, the same rule
// renamecompat.rs follows: the parser owns the body, never the file.
pub fn mount_points() -> Vec<PathBuf> {
    match std::fs::read_to_string("/proc/self/mountinfo") {
        Ok(body) => mountinfo::mount_points_in(&body),
        Err(_) => Vec::new(),
    }
}

pub fn list(home: Option<&Path>, tops: &[PathBuf]) -> Vec<Entry> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(h) = home {
        roots.push(h.to_path_buf());
    }
    roots.extend(tops.iter().cloned());
    let mut out = Vec::new();
    for root in roots {
        // A missing files/ dir is an empty trash, not an error: the common case is nothing trashed.
        let files = root.join("files");
        let info = root.join("info");
        let entries = match std::fs::read_dir(&files) {
            Ok(e) => e,
            Err(_) => continue,
        };
        // An entry the iterator itself cannot read is dropped the way scan.rs drops one: it never
        // reaches the listing rather than failing the whole of it.
        for entry in entries.flatten() {
            // Lossy the way phase 1 is lossy: the arena is a String and a name that is not UTF-8
            // reports zeroes downstream, which is scan.rs's own corner and not a second one here.
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = files.join(&name);
            let info_path = info.join(name + ".trashinfo");
            let top = topdir_of(&root);
            let parsed = std::fs::read_to_string(&info_path)
                .map(|t| trashinfo::parse_at(&t, top.as_deref()))
                .unwrap_or(trashinfo::parse(""));
            out.push(Entry {
                path,
                original: parsed.original.unwrap_or_default(),
                deleted: parsed.deleted,
            });
        }
    }
    out
}

// The base is always "/", the listpaths shape: every entry is its absolute path with the leading
// slash removed, so base.join(name) reaches the same file again in phase 2 and every per-row
// facility works with no special case anywhere. Sorted by name, because a trash the user opens
// is a listing and not a history; within one trash the shared prefix makes that the leaf order,
// across two it groups by trash first, which is what the rows have in common.
pub const BASE: &str = "/";

// The location the client names the trash by. No absolute path can equal it, so it can ride the
// same path field every listing already carries; Parent refuses in it and Back works out of it,
// the picker's flea:recent token contract carried over to the browser.
pub const TRASH_TOKEN: &str = "flea:trash";

pub fn answer(
    out: &mut BufWriter<io::Stdout>,
    st: &mut State,
    pool: &Pool,
    tb: &Tables,
    first: usize,
    hidden: bool,
) {
    // A new listing replaces whatever the walk was filling, so the walk ends before the build starts.
    finish_search(out, st, true);
    let t = Instant::now();
    let entries = list(home_trash().as_deref(), &top_trashes(&mount_points(), euid()));
    let mut l = Listing::new();
    let mut extra = HashMap::new();
    for e in &entries {
        let Some(name) = e.path.to_string_lossy().strip_prefix('/').map(str::to_string) else {
            continue;
        };
        // A dot-prefixed leaf is dropped before any stat when hidden is false, scan.rs's own rule.
        if !hidden && e.path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')) {
            continue;
        }
        // The link's own type, the same rule scan() reads off d_type and listpaths mirrors.
        let is_dir = std::fs::symlink_metadata(&e.path).is_ok_and(|m| m.is_dir());
        l.push(&name, is_dir);
        if !e.original.as_os_str().is_empty() || !e.deleted.is_empty() {
            extra.insert(name, Extra {
                original: e.original.to_string_lossy().into_owned(),
                deleted: e.deleted.clone(),
            });
        }
    }
    let read_ms = t.elapsed().as_secs_f64() * 1000.0;
    let sort_ms = sort_by_name(&mut l, false);
    // base and listing only move together, exactly as a list moves them.
    st.base = PathBuf::from(BASE);
    st.listing = l;
    st.trash_extra = extra;
    forget_rows(st, pool);
    writeln!(out, "{}", listed_line(st.listing.len(), read_ms, sort_ms, dev_of(&st.base))).ok();
    // Rides along unasked, the same first-paint saving a list makes.
    write_window(out, st, 0, first, tb);
    out.flush().ok();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    fn trash_fixture(tag: &str) -> TestDir {
        let t = TestDir::new(tag);
        t.dir("Trash/files/sub");
        t.file("Trash/files/a.txt", "a");
        t.dir("Trash/info");
        t.file(
            "Trash/info/a.txt.trashinfo",
            "[Trash Info]\nPath=/home/gm/a.txt\nDeletionDate=2025-08-26T21:38:03\n",
        );
        t.file(
            "Trash/info/sub.trashinfo",
            "[Trash Info]\nPath=/home/gm/sub\nDeletionDate=2025-08-26T21:38:04\n",
        );
        t
    }

    #[test]
    fn a_home_trash_lists_its_entries_with_their_info() {
        let t = trash_fixture("trashlist-home");
        let home = t.join("Trash");
        let got = list(Some(&home), &[]);
        assert_eq!(got.len(), 2);
        let a = got.iter().find(|e| e.path == home.join("files/a.txt")).expect("a.txt");
        assert_eq!(a.original, PathBuf::from("/home/gm/a.txt"));
        assert_eq!(a.deleted, "2025-08-26T21:38:03");
        let sub = got.iter().find(|e| e.path == home.join("files/sub")).expect("sub");
        assert_eq!(sub.original, PathBuf::from("/home/gm/sub"));
    }

    #[test]
    fn an_entry_with_no_info_file_still_lists_with_empty_fields() {
        let t = TestDir::new("trashlist-noinfo");
        t.dir("Trash/files");
        t.file("Trash/files/orphan.txt", "x");
        t.dir("Trash/info");
        let got = list(Some(&t.join("Trash")), &[]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].original, PathBuf::from(""));
        assert_eq!(got[0].deleted, "");
    }

    #[test]
    fn an_info_file_with_no_entry_is_dropped() {
        let t = TestDir::new("trashlist-noentry");
        t.dir("Trash/files");
        t.dir("Trash/info");
        t.file("Trash/info/ghost.txt.trashinfo", "[Trash Info]\nPath=/home/gm/ghost\n");
        let got = list(Some(&t.join("Trash")), &[]);
        assert!(got.is_empty(), "metadata about nothing lists nothing");
    }

    #[test]
    fn a_missing_trash_is_empty_not_an_error() {
        let t = TestDir::new("trashlist-missing");
        assert!(list(Some(&t.join("Nope")), &[]).is_empty());
        assert!(list(None, &[]).is_empty());
        assert!(list(None, &[t.join("Nope")]).is_empty());
    }

    #[test]
    fn a_top_trash_lists_beside_the_home_one() {
        let t = TestDir::new("trashlist-top");
        t.dir("mnt/.Trash-7/files");
        t.file("mnt/.Trash-7/files/u.txt", "u");
        t.dir("mnt/.Trash-7/info");
        t.file("mnt/.Trash-7/info/u.txt.trashinfo", "[Trash Info]\nPath=/mnt/u.txt\nDeletionDate=2025-08-26T21:38:05\n");
        let tops = top_trashes(&[t.join("mnt"), t.join("unmounted")], 7);
        assert_eq!(tops, vec![t.join("mnt/.Trash-7"), t.join("unmounted/.Trash-7")]);
        // The unreadable candidate costs nothing: it simply contributes no rows.
        let got = list(None, &tops);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].original, PathBuf::from("/mnt/u.txt"));
    }

    #[test]
    fn a_relative_path_in_a_top_trash_resolves_against_the_mount() {
        let t = TestDir::new("trashlist-rel");
        t.dir("mnt/.Trash-7/files");
        t.file("mnt/.Trash-7/files/u.txt", "u");
        t.dir("mnt/.Trash-7/info");
        t.file("mnt/.Trash-7/info/u.txt.trashinfo", "[Trash Info]\nPath=u.txt\nDeletionDate=2025-08-26T21:38:05\n");
        let got = list(None, &[t.join("mnt/.Trash-7")]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].original, t.join("mnt/u.txt"));
    }

    #[test]
    fn the_home_trash_follows_xdg_data_home() {
        // Whatever the session set is what the test sees; the rule, not the value, is asserted:
        // a set XDG_DATA_HOME wins, and an empty one falls back to ~/.local/share. HOME itself is
        // left alone, because the whole suite runs under the operator's real one.
        let data = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty());
        let expect = match data {
            Some(d) => PathBuf::from(d).join("Trash"),
            None => PathBuf::from(std::env::var("HOME").unwrap()).join(".local/share/Trash"),
        };
        assert_eq!(home_trash(), Some(expect));
    }
}
