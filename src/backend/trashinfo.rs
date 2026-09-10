// Reads one freedesktop .trashinfo file: the [Trash Info] group naming where a trashed
// entry came from and when it was deleted. These files are shared state every GTK application
// writes, so they are parsed defensively: only the one group is read, and every field stands on
// its own, so a file with a good Path and a bad DeletionDate still restores.
use std::path::{Component, Path, PathBuf};

// Only this group is read. Keys before the first group and keys in any other group are skipped,
// the same boundary thumbspec.rs draws around [Thumbnailer Entry]: a group is what names the
// program a key belongs to, and a key outside one names nothing.
const GROUP: &str = "[Trash Info]";

pub struct Info {
    // Empty when the file is missing, carries no Path, or the Path is not an absolute path
    // without control characters. The entry is still listed; it just restores to nowhere.
    pub original: Option<PathBuf>,
    // The file's own "YYYY-MM-DDThh:mm:ss" local time, verbatim. Empty when the file carries
    // none it can vouch for. The backend stays timezone-free on purpose: the client formats it
    // with new Date(), which reads a timezone-less stamp as local time, exactly what the spec means.
    pub deleted: String,
}

pub fn parse(text: &str) -> Info {
    parse_at(text, None)
}

// top is the $topdir a top-directory trash lives on: a relative Path= is resolved against it.
// Home trash passes None, so a relative Path is still not an original.
pub fn parse_at(text: &str, top: Option<&Path>) -> Info {
    let mut info = Info { original: None, deleted: String::new() };
    let mut in_group = false;
    let mut saw_path = false;
    let mut saw_date = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') {
            in_group = line == GROUP;
            continue;
        }
        if !in_group {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        // First wins: the trash spec names one value per key and says to keep the first when
        // either is repeated, so a later Path cannot change where restore puts the entry.
        match key.trim() {
            "Path" if !saw_path => {
                saw_path = true;
                info.original = decode_path(value, top);
            }
            "DeletionDate" if !saw_date => {
                saw_date = true;
                info.deleted = valid_date(value);
            }
            _ => {}
        }
    }
    info
}

// Sample input: /home/gm/my%20file.txt
// The spec escapes Path= as a URI path, so %XX decodes one UTF-8 byte at a time and a bare %
// or a non-hex pair refuses the whole value rather than guessing. A + stays a +, which is what
// distinguishes a URI escape from a form encoding.
fn decode_path(value: &str, top: Option<&Path>) -> Option<PathBuf> {
    if value.is_empty() {
        return None;
    }
    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = value.get(i + 1..i + 3)?;
            let byte = u8::from_str_radix(hex, 16).ok()?;
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    let decoded = String::from_utf8(out).ok()?;
    // A control character smuggled past the percent form (%0A decodes without complaint) is
    // refused the way the D-Bus service refuses one.
    if decoded.chars().any(|c| c.is_control()) {
        return None;
    }
    if decoded.starts_with('/') {
        return Some(PathBuf::from(decoded));
    }
    // Top-directory trash may store Path relative to $topdir. Home trash has no $topdir, and
    // a relative path with .. would climb out of it, so both are refused.
    let top = top?;
    let rel = Path::new(&decoded);
    if rel.components().any(|c| matches!(c, Component::ParentDir | Component::Prefix(_) | Component::RootDir)) {
        return None;
    }
    Some(top.join(rel))
}

// The spec's own shape, "YYYY-MM-DDThh:mm:ss" in local time with no zone. Shape only, never
// semantics: the client is what turns it into a date, and a February 30th is gio's fiction to
// keep, not this parser's to judge. Anything else is not a DeletionDate at all.
fn valid_date(value: &str) -> String {
    let b = value.as_bytes();
    if b.len() != 19
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
    {
        return String::new();
    }
    for (i, c) in b.iter().enumerate() {
        if [4, 7, 10, 13, 16].contains(&i) {
            continue;
        }
        if !c.is_ascii_digit() {
            return String::new();
        }
    }
    value.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &str = "[Trash Info]\nPath=/home/gm/my%20file.txt\nDeletionDate=2025-08-26T21:38:03\n";

    #[test]
    fn a_well_formed_file_yields_both_fields() {
        let info = parse(GOOD);
        assert_eq!(info.original, Some(PathBuf::from("/home/gm/my file.txt")));
        assert_eq!(info.deleted, "2025-08-26T21:38:03");
    }

    #[test]
    fn keys_outside_the_group_are_not_read() {
        let info = parse("Path=/tmp/evil\n[Other]\nPath=/tmp/alsono\n[Trash Info]\nDeletionDate=2025-08-26T21:38:03\n");
        assert_eq!(info.original, None);
        assert_eq!(info.deleted, "2025-08-26T21:38:03");
    }

    #[test]
    fn a_repeated_key_keeps_the_first() {
        let info = parse("[Trash Info]\nPath=/tmp/first\nPath=/tmp/second\nDeletionDate=2025-08-26T21:38:03\nDeletionDate=2025-01-01T00:00:00\n");
        assert_eq!(info.original, Some(PathBuf::from("/tmp/first")));
        assert_eq!(info.deleted, "2025-08-26T21:38:03");
        let info = parse("[Trash Info]\nPath=relative/first\nPath=/tmp/second\n");
        assert_eq!(info.original, None, "the first Path is the one the spec keeps, even when it is not an original");
    }

    #[test]
    fn a_relative_path_is_not_an_original() {
        let info = parse("[Trash Info]\nPath=relative/file.txt\nDeletionDate=2025-08-26T21:38:03\n");
        assert_eq!(info.original, None);
        assert_eq!(info.deleted, "2025-08-26T21:38:03", "the date stands on its own");
    }

    #[test]
    fn a_relative_path_resolves_against_the_topdir() {
        let top = Path::new("/mnt/data");
        let info = parse_at("[Trash Info]\nPath=photos/a.jpg\nDeletionDate=2025-08-26T21:38:03\n", Some(top));
        assert_eq!(info.original, Some(PathBuf::from("/mnt/data/photos/a.jpg")));
        let info = parse_at("[Trash Info]\nPath=../escape\n", Some(top));
        assert_eq!(info.original, None, "a relative path may not climb out of the topdir");
        let info = parse_at("[Trash Info]\nPath=/abs/already\n", Some(top));
        assert_eq!(info.original, Some(PathBuf::from("/abs/already")), "an absolute Path is unchanged");
    }

    #[test]
    fn an_escaped_control_character_refuses_the_path() {
        let info = parse("[Trash Info]\nPath=/tmp/bad%0Aname\nDeletionDate=2025-08-26T21:38:03\n");
        assert_eq!(info.original, None);
    }

    #[test]
    fn a_truncated_escape_refuses_the_path() {
        assert_eq!(parse("[Trash Info]\nPath=/tmp/bad%2\n").original, None);
        assert_eq!(parse("[Trash Info]\nPath=/tmp/bad%zz\n").original, None);
        assert_eq!(parse("[Trash Info]\nPath=/tmp/bad%\n").original, None);
    }

    #[test]
    fn a_plus_is_literal_not_a_space() {
        let info = parse("[Trash Info]\nPath=/tmp/a+b\n");
        assert_eq!(info.original, Some(PathBuf::from("/tmp/a+b")));
    }

    #[test]
    fn a_malformed_date_is_empty_while_the_path_stands() {
        for bad in ["2025-08-26 21:38:03", "2025-08-26T21:38", "2025-08-26", "", "2025-08-26T21:38:03Z"] {
            let text = "[Trash Info]\nPath=/tmp/f\nDeletionDate=".to_string() + bad + "\n";
            let info = parse(&text);
            assert_eq!(info.deleted, "", "shape is the whole rule: {bad:?}");
            assert_eq!(info.original, Some(PathBuf::from("/tmp/f")));
        }
    }

    #[test]
    fn an_empty_file_answers_empty_fields_and_never_panics() {
        let info = parse("");
        assert_eq!(info.original, None);
        assert_eq!(info.deleted, "");
        let info = parse("garbage\n[Trash\nNoEqualsHere\n");
        assert_eq!(info.original, None);
    }
}
