// One buffer plus a span each, see AGENTS.md "Why the listing is an arena".
use std::path::{Component, Path};

// Enough that a normal directory never reallocates its way up from nothing.
const NAME_RESERVE_BYTES: usize = 1 << 20;
const SPAN_RESERVE: usize = 4096;

#[derive(Clone, Copy, Debug)]
pub struct Span {
    pub off: u32,
    pub len: u32,
    pub is_dir: bool,
}

#[derive(Debug)]
pub struct Listing {
    pub names: String,
    pub spans: Vec<Span>,
}

impl Listing {
    pub fn new() -> Listing {
        let mut names = String::new();
        names.reserve(NAME_RESERVE_BYTES);
        let mut spans = Vec::new();
        spans.reserve(SPAN_RESERVE);
        Listing { names, spans }
    }

    // corner: u32 offsets cap the arena at 4 GiB of names, see AGENTS.md.
    pub fn push(&mut self, name: &str, is_dir: bool) {
        let off = self.names.len() as u32;
        self.names.push_str(name);
        self.spans.push(Span {
            off,
            len: (self.names.len() as u32) - off,
            is_dir,
        });
    }

    pub fn name(&self, i: usize) -> &str {
        let s = &self.spans[i];
        &self.names[s.off as usize..(s.off + s.len) as usize]
    }

    // The seam: callers ask the listing; spans is public only because sort borrows it.
    pub fn is_dir(&self, i: usize) -> bool {
        self.spans[i].is_dir
    }

    pub fn len(&self) -> usize {
        self.spans.len()
    }

    // Locate only names already in this listing; no filesystem access or symlink resolution.
    pub fn index_of(&self, base: &Path, path: &Path) -> Option<usize> {
        if !base.is_absolute() || !path.is_absolute() {
            return None;
        }
        let relative = path.strip_prefix(base).ok()?;
        if relative.components().any(|part| !matches!(part, Component::Normal(_))) {
            return None;
        }
        let name = relative.to_str()?;
        (0..self.len()).find(|&index| self.name(index) == name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stores_and_returns_names_in_order() {
        let mut l = Listing::new();
        l.push("alpha.txt", false);
        l.push("bin", true);
        assert_eq!(l.len(), 2);
        assert_eq!(l.name(0), "alpha.txt");
        assert_eq!(l.name(1), "bin");
        assert!(!l.is_dir(0));
        assert!(l.is_dir(1));
    }

    #[test]
    fn a_new_listing_is_empty() {
        let l = Listing::new();
        assert_eq!(l.len(), 0);
    }

    #[test]
    fn locates_existing_names_without_resolving_files() {
        let base = Path::new("/listing");
        let mut listing = Listing::new();
        listing.push("first.txt", false);
        listing.push("sub/selected.txt", false);
        assert_eq!(listing.index_of(base, Path::new("/listing/sub/selected.txt")), Some(1));
        listing.spans.reverse();
        assert_eq!(listing.index_of(base, Path::new("/listing/sub/selected.txt")), Some(0));
        for path in ["", "sub/selected.txt", "/listing", "/listing/missing", "/listing-other/first.txt", "/listing/../listing/first.txt"] {
            assert_eq!(listing.index_of(base, Path::new(path)), None, "{path}");
        }
        assert_eq!(listing.index_of(Path::new(""), Path::new("/first.txt")), None);
    }

    #[test]
    fn handles_names_with_awkward_bytes() {
        let mut l = Listing::new();
        l.push("two\nlines", false);
        l.push("quote\"inside", false);
        l.push("café", false);
        assert_eq!(l.name(0), "two\nlines");
        assert_eq!(l.name(1), "quote\"inside");
        assert_eq!(l.name(2), "café");
    }

    #[test]
    fn one_buffer_holds_every_name() {
        let mut l = Listing::new();
        for i in 0..1000 {
            l.push(&format!("file_{}.txt", i), false);
        }
        assert_eq!(l.len(), 1000);
        assert_eq!(l.name(999), "file_999.txt");
    }
}
