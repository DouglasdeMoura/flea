// Hard rule 9's sandbox, in code: every destructive test writes inside one of these and nowhere else.
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

// The one name that makes a directory deletable by this module; a directory without it is never touched.
const MARKER: &str = ".flea-test-sandbox";
// Every sandbox this process makes shares it, so a stray path outside the pattern is refused on the name alone.
const PREFIX: &str = "flea-test-";
// A sandbox lives under the temp root, which is at least two components deep, so a shallower path is a bug and not a root.
const MIN_COMPONENTS: usize = 3;

// Two tests in one process must not collide, and this crate takes no dependency that would generate a suffix.
static NEXT: AtomicUsize = AtomicUsize::new(0);

// Created by the test itself, removed on drop, and only ever removable while its marker is inside it.
pub struct TestDir {
    path: PathBuf,
}

impl TestDir {
    // Panics rather than returning an error: a test that cannot make its sandbox must not go on to write anywhere.
    pub fn new(tag: &str) -> TestDir {
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let name = format!("{}{}-{}-{}", PREFIX, tag, std::process::id(), n);
        let path = std::env::temp_dir().join(name);
        std::fs::create_dir(&path).expect("test sandbox could not be created");
        let mut marker = std::fs::File::create(path.join(MARKER)).expect("test sandbox marker");
        marker.write_all(b"flea test sandbox\n").expect("test sandbox marker");
        TestDir { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    // Every test that names a file inside its sandbox goes through here, so no test builds a path by hand.
    pub fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }

    pub fn file(&self, name: &str, body: &str) -> PathBuf {
        let p = self.join(name);
        std::fs::write(&p, body).expect("test sandbox file");
        p
    }

    pub fn dir(&self, name: &str) -> PathBuf {
        let p = self.join(name);
        std::fs::create_dir_all(&p).expect("test sandbox dir");
        p
    }
}

// The guard is here and not in the reviewer's head: a path that fails any clause is left on disk instead.
pub fn removable(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    if path.components().count() < MIN_COMPONENTS {
        return false;
    }
    if !path.starts_with(std::env::temp_dir()) {
        return false;
    }
    match path.file_name().and_then(|n| n.to_str()) {
        Some(n) if n.starts_with(PREFIX) => {}
        _ => return false,
    }
    path.join(MARKER).is_file()
}

impl Drop for TestDir {
    fn drop(&mut self) {
        if removable(&self.path) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sandbox_carries_its_marker_and_is_removable() {
        let d = TestDir::new("guard");
        assert!(d.path().is_dir());
        assert!(d.path().join(MARKER).is_file());
        assert!(removable(d.path()));
    }

    #[test]
    fn the_guard_refuses_every_path_that_is_not_one_of_ours() {
        // A real directory with no marker: the case the incident actually needed refused.
        let outside = TestDir::new("outside");
        let plain = outside.dir("payload");
        assert!(!removable(&plain));
        // The home directory and its parents, named explicitly because they are what was lost.
        assert!(!removable(Path::new("/home/gm")));
        assert!(!removable(Path::new("/home")));
        assert!(!removable(Path::new("/")));
        assert!(!removable(Path::new("")));
        // A relative path can be anything the caller's cwd makes it, so it never qualifies.
        assert!(!removable(Path::new("flea-test-relative")));
        // Right shape, right place, no marker.
        let bare = outside.dir(&format!("{}bare", PREFIX));
        assert!(!removable(&bare));
    }

    #[test]
    fn a_dropped_sandbox_takes_its_contents_with_it() {
        let kept;
        {
            let d = TestDir::new("drop");
            d.file("a.txt", "body");
            d.dir("sub");
            kept = d.path().to_path_buf();
            assert!(kept.is_dir());
        }
        assert!(!kept.exists());
    }
}
