// Claim the exact reviewed payload and metadata before deletion; later arrivals keep their original names.
use crate::oflags::O_NOFOLLOW;
use std::ffi::CString;
use std::fs::{File, Metadata, OpenOptions};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

#[cfg(target_arch = "x86_64")]
const O_DIRECTORY: i32 = 0o200000;
#[cfg(target_arch = "aarch64")]
const O_DIRECTORY: i32 = 0o40000;
const RENAME_NOREPLACE: u32 = 1;
static NEXT: AtomicUsize = AtomicUsize::new(1);
extern "C" {
    fn renameat2(
        oldfd: i32,
        old: *const std::os::raw::c_char,
        newfd: i32,
        new: *const std::os::raw::c_char,
        flags: u32,
    ) -> i32;
}

#[derive(Clone, Debug, PartialEq)]
struct Identity {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: i64,
    nanos: i64,
}
impl Identity {
    fn of(meta: &Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.len(),
            mtime: meta.mtime(),
            nanos: meta.mtime_nsec(),
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Reviewed {
    path: PathBuf,
    info: PathBuf,
    payload: Identity,
    metadata: Identity,
}

fn open_dir(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_DIRECTORY)
        .open(path)
        .map_err(|e| format!("Could not open Trash directory {}: {}", path.display(), e))
}
fn fd_path(file: &File, name: &str) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}/{}", file.as_raw_fd(), name))
}
fn rename(from: &File, old: &str, to: &File, new: &str) -> Result<(), String> {
    let old = CString::new(old).map_err(|_| "Invalid Trash filename.")?;
    let new = CString::new(new).map_err(|_| "Invalid quarantine filename.")?;
    if unsafe {
        renameat2(
            from.as_raw_fd(),
            old.as_ptr(),
            to.as_raw_fd(),
            new.as_ptr(),
            RENAME_NOREPLACE,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}
fn identity(path: &Path) -> Result<Identity, String> {
    path.symlink_metadata()
        .map(|m| Identity::of(&m))
        .map_err(|e| e.to_string())
}

impl Reviewed {
    pub fn inspect(path: PathBuf, gio_identity: &str) -> Result<Self, String> {
        if !path.is_absolute()
            || path
                .parent()
                .and_then(Path::file_name)
                .and_then(|s| s.to_str())
                != Some("files")
        {
            return Err("Trash provider did not supply a supported backing path.".into());
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("Trash filename is not valid text.")?;
        let root = path
            .parent()
            .and_then(Path::parent)
            .ok_or("Trash root is missing.")?;
        let info = root.join("info").join(format!("{}.trashinfo", name));
        let payload = identity(&path)?;
        if gio_identity != format!("l{}:{}", payload.dev, payload.ino) {
            return Err("Trash identity changed while reading it.".into());
        }
        let info_meta = info.symlink_metadata().map_err(|e| e.to_string())?;
        if !info_meta.is_file() {
            return Err("Trash metadata is not a regular file.".into());
        }
        Ok(Self {
            path,
            info,
            payload,
            metadata: Identity::of(&info_meta),
        })
    }
    pub fn bytes(&self, deadline: std::time::Instant) -> crate::backend::dirsize::DirSize {
        if !self.unchanged() {
            return crate::backend::dirsize::DirSize {
                bytes: 0,
                partial: true,
            };
        }
        let mut result = match self.path.symlink_metadata() {
            Ok(meta) if meta.is_dir() => crate::backend::dirsize::walk_until(&self.path, deadline),
            Ok(meta) => crate::backend::dirsize::DirSize {
                bytes: meta.len(),
                partial: false,
            },
            Err(_) => crate::backend::dirsize::DirSize {
                bytes: 0,
                partial: true,
            },
        };
        result.partial |= !self.unchanged();
        result
    }
    pub fn unchanged(&self) -> bool {
        identity(&self.path).ok().as_ref() == Some(&self.payload)
            && identity(&self.info).ok().as_ref() == Some(&self.metadata)
    }
    pub fn delete(&self) -> Result<(), String> {
        self.delete_after(|| {})
    }
    fn delete_after(&self, before_claim: impl FnOnce()) -> Result<(), String> {
        let files = open_dir(self.path.parent().ok_or("Missing Trash parent.")?)?;
        let infos = open_dir(self.info.parent().ok_or("Missing Trash metadata parent.")?)?;
        let name = self
            .path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("Invalid Trash filename.")?;
        let info_name = self
            .info
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("Invalid Trash metadata name.")?;
        if identity(&fd_path(&files, name))? != self.payload
            || identity(&fd_path(&infos, info_name))? != self.metadata
        {
            return Err("Trash item changed; review a fresh confirmation.".into());
        }
        let quarantine_name = format!(
            ".flea-delete-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let quarantine_path = fd_path(&files, &quarantine_name);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&quarantine_path)
            .map_err(|e| format!("Could not create Trash quarantine: {}", e))?;
        let quarantine = open_dir(&quarantine_path)?;
        let recovery = self.path.parent().unwrap().join(&quarantine_name);
        before_claim();
        if let Err(error) = rename(&files, name, &quarantine, "payload") {
            let _ = std::fs::remove_dir(&quarantine_path);
            return Err(format!("Could not claim Trash item: {}", error));
        }
        let info_claim = rename(&infos, info_name, &quarantine, "metadata");
        let checked = identity(&fd_path(&quarantine, "payload")).ok().as_ref()
            == Some(&self.payload)
            && info_claim.is_ok()
            && identity(&fd_path(&quarantine, "metadata")).ok().as_ref() == Some(&self.metadata);
        if !checked {
            let payload_back = rename(&quarantine, "payload", &files, name);
            let info_back = if info_claim.is_ok() {
                rename(&quarantine, "metadata", &infos, info_name)
            } else {
                Ok(())
            };
            if payload_back.is_err() || info_back.is_err() {
                return Err(format!(
                    "Trash changed; no deletion attempted. Recover preserved items from {}.",
                    recovery.display()
                ));
            }
            let _ = std::fs::remove_dir(&quarantine_path);
            return Err(
                "Trash changed; no deletion attempted. Review a fresh confirmation.".into(),
            );
        }
        let payload_path = fd_path(&quarantine, "payload");
        let metadata = payload_path.symlink_metadata().map_err(|e| e.to_string())?;
        let removal = if metadata.is_dir() {
            std::fs::remove_dir_all(&payload_path)
        } else {
            std::fs::remove_file(&payload_path)
        };
        if let Err(error) = removal {
            let payload_back = rename(&quarantine, "payload", &files, name);
            let info_back = rename(&quarantine, "metadata", &infos, info_name);
            if payload_back.is_err() || info_back.is_err() {
                return Err(format!(
                    "Deletion failed: {}. Remaining items are preserved at {}.",
                    error,
                    recovery.display()
                ));
            }
            let _ = std::fs::remove_dir(&quarantine_path);
            return Err(format!("Deletion failed: {}. The surviving item remains in Trash; a directory may be partly deleted.", error));
        }
        std::fs::remove_file(fd_path(&quarantine, "metadata")).map_err(|e| {
            format!(
                "Payload deleted; metadata cleanup failed at {}: {}",
                recovery.display(),
                e
            )
        })?;
        std::fs::remove_dir(&quarantine_path)
            .map_err(|e| format!("Payload deleted; empty quarantine cleanup failed: {}", e))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;
    fn fixture(d: &TestDir) -> (PathBuf, Reviewed) {
        d.dir("files");
        d.dir("info");
        let path = d.file("files/item", "payload");
        d.file("info/item.trashinfo", "[Trash Info]\nPath=/original\n");
        let meta = path.symlink_metadata().unwrap();
        let reviewed =
            Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        (path, reviewed)
    }
    fn guard(d: &TestDir, path: &Path) {
        assert!(
            path.is_absolute()
                && !path.as_os_str().is_empty()
                && path.starts_with(d.path())
                && path != d.path()
        );
    }
    #[test]
    fn deletes_only_reviewed_item_and_preserves_later_arrival() {
        let d = TestDir::new("trash-delete");
        let (path, reviewed) = fixture(&d);
        let later = d.file("files/later", "keep");
        guard(&d, &path);
        reviewed.delete().unwrap();
        assert!(!path.exists());
        assert!(later.exists());
        assert!(!d.join("info/item.trashinfo").exists());
    }
    #[test]
    fn changed_identity_or_size_is_never_deleted() {
        let d = TestDir::new("trash-delete-change");
        let (path, reviewed) = fixture(&d);
        std::fs::rename(&path, d.join("files/old")).unwrap();
        std::fs::write(&path, "replacement").unwrap();
        guard(&d, &path);
        assert!(reviewed.delete().is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "replacement");
    }
    #[test]
    fn replacement_between_check_and_claim_is_restored_without_deletion() {
        let d = TestDir::new("trash-delete-race");
        let (path, reviewed) = fixture(&d);
        guard(&d, &path);
        let result = reviewed.delete_after(|| {
            std::fs::rename(&path, d.join("files/reviewed-old")).unwrap();
            std::fs::write(&path, "new arrival").unwrap();
        });
        assert!(result.is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "new arrival");
        assert_eq!(
            std::fs::read_to_string(d.join("files/reviewed-old")).unwrap(),
            "payload"
        );
        assert!(d.join("info/item.trashinfo").exists());
    }
    #[test]
    fn directory_contents_are_removed_but_symlinks_never_followed() {
        let d = TestDir::new("trash-delete-directory");
        let (path, _) = fixture(&d);
        std::fs::rename(&path, d.join("files/saved-file")).unwrap();
        std::fs::create_dir(&path).unwrap();
        let target = d.file("target", "keep");
        std::os::unix::fs::symlink(&target, path.join("link")).unwrap();
        std::fs::write(path.join("child"), "delete").unwrap();
        let meta = path.symlink_metadata().unwrap();
        let reviewed =
            Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        guard(&d, &path);
        reviewed.delete().unwrap();
        assert!(!path.exists());
        assert_eq!(std::fs::read_to_string(target).unwrap(), "keep");
    }
}
