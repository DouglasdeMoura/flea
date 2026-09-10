// The /proc/self/mountinfo parser: the filesystem type of the mount that owns a path, from a body the caller has read.
use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

// Sample: `2 1 0:9 / /home/pi/My\040Drive rw - fuse.rclone remote: rw`; longest enclosing mount wins after octal unescaping.
pub(crate) fn mount_type_in(path: &Path, body: &str) -> Option<String> {
    let mut best: Option<(usize, String)> = None;
    for line in body.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let split = match fields.iter().position(|field| *field == "-") {
            Some(value) => value,
            None => continue,
        };
        if fields.len() <= split + 1 || fields.len() < 5 {
            continue;
        }
        let mount = PathBuf::from(OsString::from_vec(unescape(fields[4])));
        if !path.starts_with(&mount) {
            continue;
        }
        let depth = mount.components().count();
        if best.as_ref().map(|(old, _)| depth >= *old).unwrap_or(true) {
            best = Some((depth, fields[split + 1].to_string()));
        }
    }
    best.map(|(_, kind)| kind)
}

// Every mount point the body names, in file order with octal escapes decoded: the caller
// that walks top-directory trashes needs the ladder, not one rung of it. Malformed lines are
// skipped the way mount_type_in skips them, so junk never becomes a trash root.
pub(crate) fn mount_points_in(body: &str) -> Vec<PathBuf> {
    body.lines().filter_map(mount_point).collect()
}

fn mount_point(line: &str) -> Option<PathBuf> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    let split = fields.iter().position(|field| *field == "-")?;
    if fields.len() <= split + 1 || fields.len() < 5 {
        return None;
    }
    Some(PathBuf::from(OsString::from_vec(unescape(fields[4]))))
}

fn unescape(field: &str) -> Vec<u8> {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match octal_byte(bytes, i) {
            Some(byte) => {
                out.push(byte);
                i += 4;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    out
}

// Sample: `\040` is a space. Summed wide and refused above 255, because `\400` overflows a u8 mid-sum.
fn octal_byte(bytes: &[u8], i: usize) -> Option<u8> {
    if bytes[i] != b'\\' || i + 3 >= bytes.len() {
        return None;
    }
    let digits = &bytes[i + 1..=i + 3];
    if !digits.iter().all(|b| (b'0'..=b'7').contains(b)) {
        return None;
    }
    u8::try_from(digits.iter().fold(0u32, |value, b| value * 8 + u32::from(b - b'0'))).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deepest_mount_identifies_rclone_and_decodes_its_path() {
        let info = "1 0 8:1 / / rw - ext4 /dev/a rw\n\
                    2 1 0:9 / /home/pi/My\\040Drive rw - fuse.rclone remote: rw\n\
                    3 2 0:10 / /home/pi/My\\040Drive/nested rw - tmpfs tmpfs rw\n";
        assert_eq!(
            mount_type_in(Path::new("/home/pi/My Drive/file"), info).as_deref(),
            Some("fuse.rclone")
        );
        assert_eq!(
            mount_type_in(Path::new("/home/pi/My Drive/nested/file"), info).as_deref(),
            Some("tmpfs")
        );
        assert_eq!(
            mount_type_in(Path::new("/elsewhere"), info).as_deref(),
            Some("ext4")
        );
    }

    #[test]
    fn malformed_mountinfo_is_ignored() {
        assert_eq!(mount_type_in(Path::new("/home/pi"), "junk\n"), None);
        assert!(mount_points_in("junk\n").is_empty());
    }

    #[test]
    fn mount_points_come_back_in_order_with_escapes_decoded() {
        let info = "1 0 8:1 / / rw - ext4 /dev/a rw\n\
                    2 1 0:9 / /home/pi/My\\040Drive rw - fuse.rclone remote: rw\n\
                    junk\n";
        assert_eq!(
            mount_points_in(info),
            vec![PathBuf::from("/"), PathBuf::from("/home/pi/My Drive")]
        );
    }

    // The kernel escapes only \040, \011, \012 and \134, but this is a parser at a trust boundary.
    #[test]
    fn an_octal_escape_above_255_is_refused_rather_than_overflowing() {
        assert_eq!(unescape("\\040"), b" ".to_vec());
        assert_eq!(unescape("\\134"), b"\\".to_vec());
        assert_eq!(unescape("\\400"), b"\\400".to_vec());
        assert_eq!(unescape("\\777"), b"\\777".to_vec());
    }
}
