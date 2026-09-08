// Claim the exact reviewed payload and metadata before deletion; later arrivals keep their original names.
use crate::backend::trashmanifest::{Cancellation, Manifest, Records};
use crate::json::{escape, field_str, field_usize};
use crate::oflags::O_NOFOLLOW;
use std::ffi::{CString, OsStr, OsString};
use std::fs::{File, Metadata, OpenOptions};
use std::io::{BufRead, BufReader, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
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
    mode: u32,
}
impl Identity {
    fn saved(&self) -> String {
        format!("{},{},{},{},{},{}", self.dev, self.ino, self.size, self.mtime, self.nanos, self.mode)
    }
    // Sample identity: "2049,123,8,1788861600,0,33188".
    fn from_saved(text: &str) -> Result<Self, String> {
        let parts: Vec<_> = text.split(',').collect();
        if parts.len() != 6 { return Err("Invalid Trash review identity.".into()); }
        Ok(Self {
            dev: parts[0].parse().map_err(|_| "Invalid Trash device.")?,
            ino: parts[1].parse().map_err(|_| "Invalid Trash inode.")?,
            size: parts[2].parse().map_err(|_| "Invalid Trash size.")?,
            mtime: parts[3].parse().map_err(|_| "Invalid Trash mtime.")?,
            nanos: parts[4].parse().map_err(|_| "Invalid Trash nanoseconds.")?,
            mode: parts[5].parse().map_err(|_| "Invalid Trash mode.")?,
        })
    }
    fn of(meta: &Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.len(),
            mtime: meta.mtime(),
            nanos: meta.mtime_nsec(),
            mode: meta.mode(),
        }
    }
}
struct Node {
    relative: PathBuf,
    identity: Identity,
    children: u64,
}
impl Node {
    fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        for value in [self.identity.dev, self.identity.ino, self.identity.size,
            self.identity.mtime as u64, self.identity.nanos as u64, self.identity.mode as u64, self.children] {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes.extend_from_slice(self.relative.as_os_str().as_bytes());
        bytes
    }
    // Sample record: seven little-endian u64 fields followed by the raw relative filename bytes.
    fn decode(bytes: &[u8]) -> Result<Self, String> {
        const HEADER: usize = 7 * 8;
        if bytes.len() < HEADER { return Err("Truncated Trash node review.".into()); }
        let number = |index: usize| u64::from_le_bytes(bytes[index * 8..(index + 1) * 8].try_into().unwrap());
        let relative = PathBuf::from(OsString::from_vec(bytes[HEADER..].to_vec()));
        if relative.components().any(|part| !matches!(part, std::path::Component::Normal(_))) {
            return Err("Invalid relative Trash review path.".into());
        }
        Ok(Self {
            relative,
            identity: Identity { dev: number(0), ino: number(1), size: number(2),
                mtime: number(3) as i64, nanos: number(4) as i64, mode: number(5) as u32 },
            children: number(6),
        })
    }
    fn directory(&self) -> bool { self.identity.mode & 0o170000 == 0o040000 }
    fn deletion_identity_matches(&self, current: &Identity) -> bool {
        if self.directory() {
            // Deleting reviewed children changes directory size and mtime, but never its inode or mode.
            self.identity.dev == current.dev && self.identity.ino == current.ino && self.identity.mode == current.mode
        } else { self.identity == *current }
    }
    fn claim_remove(&self, parent: &File, name: &OsStr, quarantine: &File, record_offset: u64) -> Result<(), String> {
        if !self.deletion_identity_matches(&identity(&fd_path(parent, name))?) {
            return Err("Trash child changed; remaining data was preserved.".into());
        }
        let claimed = format!("entry-{}", record_offset);
        let claimed = OsStr::new(&claimed);
        rename(parent, name, quarantine, claimed)?;
        let path = fd_path(quarantine, claimed);
        let removal = (|| {
            if !self.deletion_identity_matches(&identity(&path)?) {
                return Err("Trash child changed while being claimed.".into());
            }
            if self.directory() {
                // remove_dir refuses arrivals absent from the snapshot instead of deleting them recursively.
                std::fs::remove_dir(&path).map_err(|e| format!("Trash directory has surviving items: {}", e))
            } else { std::fs::remove_file(&path).map_err(|e| e.to_string()) }
        })();
        if let Err(error) = removal {
            if rename(quarantine, claimed, parent, name).is_err() {
                return Err(format!("{}. A changed child remains in the recovery directory.", error));
            }
            return Err(error);
        }
        Ok(())
    }
}
#[derive(Clone, Debug)]
pub struct Reviewed {
    path: PathBuf,
    info: PathBuf,
    payload: Identity,
    metadata: Identity,
    tree: Option<Records>,
}

// Open one ancestor at a time; neither deep paths nor substituted symlinks need recursive traversal.
fn parent_at(base: &File, root: &OsStr, relative: &Path) -> Result<(File, OsString), String> {
    if relative.as_os_str().is_empty() {
        return Ok((base.try_clone().map_err(|e| e.to_string())?, root.to_os_string()));
    }
    let mut directory = open_dir(&fd_path(base, root))?;
    let parent = relative.parent().ok_or("Missing Trash review parent.")?;
    for component in parent.components() {
        let std::path::Component::Normal(name) = component else { return Err("Invalid Trash review parent.".into()); };
        directory = open_dir(&fd_path(&directory, name))?;
    }
    Ok((directory, relative.file_name().ok_or("Missing Trash review name.")?.to_os_string()))
}
fn matches(tree: &Records, base: &File, root: &OsStr, cancel: &Cancellation) -> Result<bool, String> {
    let mut offset = tree.start();
    while let Some(bytes) = tree.next(&mut offset)? {
        cancel.check()?;
        let node = Node::decode(&bytes)?;
        let Ok((parent, name)) = parent_at(base, root, &node.relative) else { return Ok(false); };
        let path = fd_path(&parent, &name);
        if identity(&path).ok().as_ref() != Some(&node.identity) { return Ok(false); }
        if node.directory() {
            let directory = open_dir(&path)?;
            let mut children = 0;
            for entry in std::fs::read_dir(fd_path(&directory, OsStr::new("."))).map_err(|e| e.to_string())? {
                cancel.check()?;
                entry.map_err(|e| e.to_string())?;
                children += 1;
            }
            if children != node.children || identity(&path).ok().as_ref() != Some(&node.identity) { return Ok(false); }
        }
    }
    Ok(true)
}

fn open_dir(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW | O_DIRECTORY)
        .open(path)
        .map_err(|e| format!("Could not open Trash directory {}: {}", path.display(), e))
}
fn fd_path(file: &File, name: &OsStr) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd())).join(name)
}
fn rename(from: &File, old: &OsStr, to: &File, new: &OsStr) -> Result<(), String> {
    let old = CString::new(old.as_bytes()).map_err(|_| "Invalid Trash filename.")?;
    let new = CString::new(new.as_bytes()).map_err(|_| "Invalid quarantine filename.")?;
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

fn snapshot_tree(path: &Path, payload: &Identity, manifest: &mut Manifest, scratch: &Path,
    cancel: &Cancellation) -> Result<(Records, u64), String> {
        let files = open_dir(path.parent().ok_or("Missing Trash parent.")?)?;
        let name = path.file_name().ok_or("Missing Trash filename.")?;
        let mut queue = Manifest::new(scratch)?;
        queue.append(&Node { relative: PathBuf::new(), identity: payload.clone(), children: 0 }.encode())?;
        let start = manifest.len();
        let mut cursor = 0;
        let mut bytes = 0u64;
        while let Some(record) = queue.records().next(&mut cursor)? {
            cancel.check()?;
            let mut node = Node::decode(&record)?;
            let (parent, entry_name) = parent_at(&files, name, &node.relative)?;
            let path = fd_path(&parent, &entry_name);
            if identity(&path)? != node.identity { return Err("Trash changed while reviewing its contents.".into()); }
            if node.directory() {
                let directory = open_dir(&path)?;
                if Identity::of(&directory.metadata().map_err(|e| e.to_string())?) != node.identity {
                    return Err("Trash directory changed while reviewing it.".into());
                }
                for entry in std::fs::read_dir(fd_path(&directory, OsStr::new("."))).map_err(|e| e.to_string())? {
                    cancel.check()?;
                    let child_name = entry.map_err(|e| e.to_string())?.file_name();
                    let child = Node { relative: node.relative.join(&child_name),
                        identity: identity(&fd_path(&directory, &child_name))?, children: 0 };
                    queue.append(&child.encode())?;
                    node.children += 1;
                }
                if Identity::of(&directory.metadata().map_err(|e| e.to_string())?) != node.identity {
                    return Err("Trash directory changed while reviewing it.".into());
                }
            } else {
                bytes = bytes.checked_add(node.identity.size).ok_or("Trash byte total exceeds the supported range.")?;
            }
            manifest.append(&node.encode())?;
        }
        let tree = manifest.range(start, manifest.len())?;
        if identity(path).ok().as_ref() != Some(payload) || !matches(&tree, &files, name, cancel)? {
            return Err("Trash changed while reviewing its contents.".into());
        }
        Ok((tree, bytes))
}
fn remove_tree(tree: &Records, quarantine: &File, payload: &Identity) -> Result<(), String> {
    if identity(&fd_path(quarantine, OsStr::new("payload")))? != *payload {
        return Err("Trash item changed after it was claimed; remaining data was preserved.".into());
    }
    let mut offset = tree.end();
    while let Some(bytes) = tree.previous(&mut offset)? {
        let node = Node::decode(&bytes)?;
        let (parent, child_name) = parent_at(quarantine, OsStr::new("payload"), &node.relative)?;
        node.claim_remove(&parent, &child_name, quarantine, offset - tree.start())?;
    }
    Ok(())
}


// Sample .trashinfo: "[Trash Info]\nPath=/original/photo%20one.jpg\nDeletionDate=2026-09-08T10:00:00\n".
fn original_path(metadata: &File, trash_root: &Path) -> Result<PathBuf, String> {
    // Linux absolute paths passed to the restore syscall cannot exceed PATH_MAX bytes.
    const PATH_MAX: u64 = 4096;
    const MAX_ENCODED_PATH: u64 = PATH_MAX * 3;
    const PATH_PREFIX_BYTES: u64 = 5;
    let mut reader = BufReader::new(metadata);
    let mut section = false;
    let mut original = None;
    loop {
        let mut line = String::new();
        let bytes = reader.by_ref().take(MAX_ENCODED_PATH + PATH_PREFIX_BYTES + 1).read_line(&mut line)
            .map_err(|e| format!("Could not parse Trash metadata: {}", e))?;
        if bytes == 0 { break; }
        if !line.ends_with('\n') && bytes as u64 == MAX_ENCODED_PATH + PATH_PREFIX_BYTES + 1 {
            return Err("Trash metadata contains a line longer than the supported filesystem path.".into());
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.starts_with('[') { section = line == "[Trash Info]"; continue; }
        if !section { continue; }
        if let Some(value) = line.strip_prefix("Path=") {
            if original.is_some() { return Err("Trash metadata contains duplicate original paths.".into()); }
            let decoded = PathBuf::from(crate::paths::percent_decode(value));
            if decoded.as_os_str().is_empty() || decoded.components().any(|part| matches!(part, std::path::Component::ParentDir)) {
                return Err("Trash metadata contains an invalid original path.".into());
            }
            let path = if decoded.is_absolute() { decoded } else {
                let volume = if trash_root.file_name().and_then(OsStr::to_str).map(|name| name.starts_with(".Trash-")).unwrap_or(false) {
                    trash_root.parent()
                } else if trash_root.parent().and_then(Path::file_name) == Some(OsStr::new(".Trash")) {
                    trash_root.parent().and_then(Path::parent)
                } else { None }.ok_or("Relative Trash original path has no supported volume root.")?;
                volume.join(decoded)
            };
            if path.file_name().is_none() { return Err("Trash original path names a filesystem root.".into()); }
            original = Some(path);
        }
    }
    original.ok_or("Trash metadata has no original path.".into())
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
            tree: None,
        })
    }
    pub fn snapshot(&mut self, manifest: &mut Manifest, scratch: &Path, cancel: &Cancellation) -> Result<u64, String> {
        self.tree = None;
        let (tree, bytes) = snapshot_tree(&self.path, &self.payload, manifest, scratch, cancel)?;
        if !self.unchanged() { return Err("Trash changed while reviewing its contents.".into()); }
        self.tree = Some(tree);
        Ok(bytes)
    }
    pub fn saved(&self) -> Result<String, String> {
        let tree = self.tree.as_ref().ok_or("Trash contents have not been reviewed.")?;
        Ok(format!(r#"{{"path":"{}","info":"{}","payload":"{}","metadata":"{}","start":{},"end":{}}}"#,
            escape(self.path.to_str().ok_or("Trash path is not valid text.")?),
            escape(self.info.to_str().ok_or("Trash metadata path is not valid text.")?),
            self.payload.saved(), self.metadata.saved(), tree.start(), tree.end()))
    }
    pub fn from_saved(text: &str, manifest: &Manifest) -> Result<Self, String> {
        Ok(Self {
            path: PathBuf::from(field_str(text, "path").ok_or("Missing Trash review path.")?),
            info: PathBuf::from(field_str(text, "info").ok_or("Missing Trash review metadata path.")?),
            payload: Identity::from_saved(&field_str(text, "payload").ok_or("Missing Trash review identity.")?)?,
            metadata: Identity::from_saved(&field_str(text, "metadata").ok_or("Missing Trash metadata identity.")?)?,
            tree: Some(manifest.range(field_usize(text, "start").ok_or("Missing Trash review start.")? as u64,
                field_usize(text, "end").ok_or("Missing Trash review end.")? as u64)?),
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
    pub fn contents_unchanged(&self, cancel: &Cancellation) -> Result<bool, String> {
        if !self.unchanged() { return Ok(false); }
        let Some(tree) = &self.tree else { return Ok(true); };
        let files = open_dir(self.path.parent().ok_or("Missing Trash parent.")?)?;
        matches(tree, &files, self.path.file_name().ok_or("Missing Trash filename.")?, cancel)
    }
    pub fn selection_identity(&self) -> String {
        // This ephemeral value is compared within one backend session, never parsed or persisted.
        format!("{:?}|{:?}", self.payload, self.metadata)
    }
    pub fn same_item(&self, other: &Self) -> bool {
        self.path == other.path && self.info == other.info
            && self.payload.dev == other.payload.dev && self.payload.ino == other.payload.ino
            && self.payload.mode & 0o170000 == other.payload.mode & 0o170000
            && self.metadata.dev == other.metadata.dev && self.metadata.ino == other.metadata.ino
    }
    pub fn delete(&self, recovery_root: &Path) -> Result<(), String> {
        self.delete_after(recovery_root, || {})
    }
    fn delete_after(&self, recovery_root: &Path, before_claim: impl FnOnce()) -> Result<(), String> {
        self.delete_with(recovery_root, before_claim, |_| {})
    }
    fn delete_with(&self, recovery_root: &Path, before_claim: impl FnOnce(), before_remove: impl FnOnce(&Path)) -> Result<(), String> {
        let tree = self.tree.as_ref().ok_or("Trash contents have not been reviewed.")?;
        self.with_claimed("Deletion", recovery_root, None, before_claim, |quarantine| {
            if !matches(tree, quarantine, OsStr::new("payload"), &Cancellation::default())? {
                return Err("Trash contents changed; no deletion attempted.".into());
            }
            before_remove(&fd_path(quarantine, OsStr::new("payload")));
            remove_tree(tree, quarantine, &self.payload)
        })
    }
    pub fn restore(&self, original: &Path, recovery_root: &Path) -> Result<(), String> {
        self.restore_after(original, recovery_root, || {})
    }
    fn restore_after(&self, original: &Path, recovery_root: &Path, before_claim: impl FnOnce()) -> Result<(), String> {
        self.with_claimed("Restore", recovery_root, Some(original), before_claim, |quarantine| {
            let metadata = crate::backend::regfile::open_if_regular(&fd_path(quarantine, OsStr::new("metadata")), O_NOFOLLOW)
                .map_err(|e| format!("Could not read claimed Trash metadata: {}", e))?;
            if Identity::of(&metadata.metadata().map_err(|e| e.to_string())?) != self.metadata {
                return Err("Trash metadata changed after being claimed.".into());
            }
            let destination = original_path(&metadata, self.path.parent().and_then(Path::parent).ok_or("Missing Trash root.")?)?;
            if destination != original || Identity::of(&metadata.metadata().map_err(|e| e.to_string())?) != self.metadata {
                return Err("Trash original location changed; refresh the selection.".into());
            }
            let destination_parent = destination.parent().ok_or("Original parent is missing.")?.canonicalize()
                .map_err(|e| format!("Could not open original location {}: {}", destination.display(), e))?;
            let destination_directory = open_dir(&destination_parent)?;
            rename(quarantine, OsStr::new("payload"), &destination_directory,
                destination.file_name().ok_or("Original filename is missing.")?)
                .map_err(|error| format!("Could not restore {} without overwriting: {}", destination.display(), error))
        })
    }
    fn with_claimed(&self, operation: &str, recovery_root: &Path, destination: Option<&Path>, before_claim: impl FnOnce(), perform: impl FnOnce(&File) -> Result<(), String>) -> Result<(), String> {
        let files = open_dir(self.path.parent().ok_or("Missing Trash parent.")?)?;
        let infos = open_dir(self.info.parent().ok_or("Missing Trash metadata parent.")?)?;
        let name = self
            .path
            .file_name()
            .ok_or("Invalid Trash filename.")?;
        let info_name = self
            .info
            .file_name()
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
        let quarantine_path = fd_path(&files, OsStr::new(&quarantine_name));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&quarantine_path)
            .map_err(|e| format!("Could not create Trash quarantine: {}", e))?;
        let quarantine = open_dir(&quarantine_path)?;
        let recovery = self.path.parent().unwrap().join(&quarantine_name);
        let journal = match Recovery::begin(recovery_root, &self.path, &files, &self.payload,
            Some((&self.info, &self.metadata)), &recovery, &quarantine,
            if destination.is_some() { None } else { self.tree.as_ref() }, destination) {
            Ok(journal) => journal,
            Err(error) => { let _ = std::fs::remove_dir(&quarantine_path); return Err(error); }
        };
        before_claim();
        if let Err(error) = rename(&files, name, &quarantine, OsStr::new("payload")) {
            if std::fs::remove_dir(&quarantine_path).is_ok() { journal.complete()?; }
            return Err(format!("Could not claim Trash item: {}", error));
        }
        let info_claim = rename(&infos, info_name, &quarantine, OsStr::new("metadata"));
        let checked = identity(&fd_path(&quarantine, OsStr::new("payload"))).ok().as_ref() == Some(&self.payload)
            && info_claim.is_ok()
            && identity(&fd_path(&quarantine, OsStr::new("metadata"))).ok().as_ref() == Some(&self.metadata);
        if !checked {
            let payload_back = rename(&quarantine, OsStr::new("payload"), &files, name);
            let info_back = if info_claim.is_ok() {
                rename(&quarantine, OsStr::new("metadata"), &infos, info_name)
            } else {
                Ok(())
            };
            if payload_back.is_err() || info_back.is_err() {
                return Err(format!(
                    "Trash changed; no operation attempted. Recover preserved items from {}.",
                    recovery.display()
                ));
            }
            if std::fs::remove_dir(&quarantine_path).is_ok() { journal.complete()?; }
            return Err(
                "Trash changed; no operation attempted. Review a fresh confirmation.".into(),
            );
        }
        let removal = perform(&quarantine);
        if let Err(error) = removal {
            let payload_back = rename(&quarantine, OsStr::new("payload"), &files, name);
            let info_back = rename(&quarantine, OsStr::new("metadata"), &infos, info_name);
            if payload_back.is_err() || info_back.is_err() {
                return Err(format!(
                    "{} failed: {}. Remaining items are preserved at {}.",
                    operation, error,
                    recovery.display()
                ));
            }
            if std::fs::remove_dir(&quarantine_path).is_err() {
                return Err(format!("{} failed: {}. Remaining data is preserved in Trash and at {}.", operation, error, recovery.display()));
            }
            journal.complete()?;
            return Err(format!("{} failed: {}. The surviving item remains in Trash{}.", operation, error, if operation == "Deletion" { "; a directory may be partly deleted" } else { "" }));
        }
        std::fs::remove_file(fd_path(&quarantine, OsStr::new("metadata"))).map_err(|e| {
            format!(
                "{} completed; metadata cleanup failed at {}: {}",
                operation, recovery.display(),
                e
            )
        })?;
        std::fs::remove_dir(&quarantine_path)
            .map_err(|e| format!("{} completed; empty quarantine cleanup failed: {}", operation, e))?;
        journal.complete()?;
        Ok(())
    }
}

// Ordinary-path deletion shares the complete tree review; only Trash requires paired .trashinfo claims.
pub struct PathReview {
    path: PathBuf,
    payload: Identity,
    tree: Records,
}
impl PathReview {
    pub fn prepare(path: PathBuf, manifest: &mut Manifest, scratch: &Path,
        cancel: &Cancellation) -> Result<(Self, u64), String> {
        if !path.is_absolute() || path.file_name().is_none() {
            return Err("Permanent deletion requires an absolute item path; filesystem roots are refused.".into());
        }
        let payload = identity(&path)?;
        let (tree, bytes) = snapshot_tree(&path, &payload, manifest, scratch, cancel)?;
        Ok((Self { path, payload, tree }, bytes))
    }
    pub fn unchanged(&self, cancel: &Cancellation) -> Result<bool, String> {
        if identity(&self.path).ok().as_ref() != Some(&self.payload) { return Ok(false); }
        let parent = open_dir(self.path.parent().ok_or("Missing deletion parent.")?)?;
        matches(&self.tree, &parent, self.path.file_name().ok_or("Missing deletion filename.")?, cancel)
    }
    pub fn delete(&self, recovery_root: &Path) -> Result<(), String> {
        self.delete_after(recovery_root, || {})
    }
    fn delete_after(&self, recovery_root: &Path, before_claim: impl FnOnce()) -> Result<(), String> {
        let parent_path = self.path.parent().ok_or("Missing deletion parent.")?;
        let parent = open_dir(parent_path)?;
        let name = self.path.file_name().ok_or("Missing deletion filename.")?;
        if identity(&fd_path(&parent, name))? != self.payload {
            return Err("Item changed; review a fresh deletion confirmation.".into());
        }
        let quarantine_name = format!(".flea-delete-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed));
        let quarantine_path = fd_path(&parent, OsStr::new(&quarantine_name));
        std::fs::DirBuilder::new().mode(0o700).create(&quarantine_path)
            .map_err(|e| format!("Could not create deletion quarantine: {}", e))?;
        let quarantine = open_dir(&quarantine_path)?;
        let recovery = parent_path.join(&quarantine_name);
        let journal = match Recovery::begin(recovery_root, &self.path, &parent, &self.payload,
            None, &recovery, &quarantine, Some(&self.tree), None) {
            Ok(journal) => journal,
            Err(error) => { let _ = std::fs::remove_dir(&quarantine_path); return Err(error); }
        };
        before_claim();
        if let Err(error) = rename(&parent, name, &quarantine, OsStr::new("payload")) {
            if std::fs::remove_dir(&quarantine_path).is_ok() { journal.complete()?; }
            return Err(format!("Could not claim item for deletion: {}", error));
        }
        let removal = match matches(&self.tree, &quarantine, OsStr::new("payload"), &Cancellation::default()) {
            Ok(true) => remove_tree(&self.tree, &quarantine, &self.payload),
            Ok(false) => Err("Item changed after confirmation; no deletion attempted.".into()),
            Err(error) => Err(error),
        };
        if let Err(error) = removal {
            if rename(&quarantine, OsStr::new("payload"), &parent, name).is_err() {
                return Err(format!("Deletion failed: {}. Recover preserved items from {}.", error, recovery.display()));
            }
            if std::fs::remove_dir(&quarantine_path).is_err() {
                return Err(format!("Deletion failed: {}. Remaining data is preserved at the original path and {}.", error, recovery.display()));
            }
            journal.complete()?;
            return Err(format!("Deletion failed: {}. Surviving data remains at the original path; a directory may be partly deleted.", error));
        }
        std::fs::remove_dir(&quarantine_path).map_err(|e| format!("Payload deleted; empty quarantine cleanup failed: {}", e))?;
        journal.complete()?;
        Ok(())
    }
}

pub fn recovery_root() -> Result<PathBuf, String> {
    let state = match crate::userfile::env_dir("XDG_STATE_HOME") {
        Some(path) => path,
        None => crate::userfile::home()?.join(".local/state"),
    };
    Ok(state.join("flea/recovery"))
}

struct Recovery {
    path: PathBuf,
    record: Manifest,
}
impl Recovery {
    fn begin(root: &Path, source: &Path, parent: &File, payload: &Identity,
        paired: Option<(&Path, &Identity)>, quarantine_path: &Path, quarantine: &File,
        tree: Option<&Records>, destination: Option<&Path>) -> Result<Self, String> {
        if !root.is_absolute() { return Err("Recovery storage requires an absolute directory.".into()); }
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(root)
            .map_err(|e| format!("Could not create recovery directory {}: {}", root.display(), e))?;
        let directory = open_dir(root)?;
        let name = quarantine_path.file_name().ok_or("Missing quarantine name.")?.to_string_lossy();
        let path = root.join(format!("{}.review", name));
        let mut record = Manifest::create(&path)?;
        let (info, metadata) = paired.map(|(path, identity)| (path.to_string_lossy().into_owned(), identity.saved()))
            .unwrap_or_default();
        let text = format!(r#"{{"version":1,"source":"{}","parent":"{}","payload":"{}","info":"{}","metadata":"{}","quarantine":"{}","quarantineIdentity":"{}","destination":"{}"}}"#,
            escape(source.to_str().ok_or("Recovery source path is not valid text.")?),
            Identity::of(&parent.metadata().map_err(|e| e.to_string())?).saved(), payload.saved(),
            escape(&info), metadata, escape(quarantine_path.to_str().ok_or("Recovery path is not valid text.")?),
            Identity::of(&quarantine.metadata().map_err(|e| e.to_string())?).saved(),
            escape(destination.map(|path| path.to_string_lossy().into_owned()).unwrap_or_default().as_str()));
        record.append(text.as_bytes())?;
        if let Some(tree) = tree {
            let mut offset = tree.start();
            while let Some(bytes) = tree.next(&mut offset)? { record.append(&bytes)?; }
        }
        record.sync()?;
        directory.sync_all().map_err(|e| format!("Could not sync recovery directory: {}", e))?;
        Ok(Self { path, record })
    }
    fn complete(self) -> Result<(), String> {
        if identity(&self.path)? != Identity::of(&self.record.file().metadata().map_err(|e| e.to_string())?) {
            return Err("Recovery record changed; it was preserved.".into());
        }
        std::fs::remove_file(&self.path)
            .map_err(|e| format!("Could not finish recovery record {}: {}", self.path.display(), e))?;
        open_dir(self.path.parent().ok_or("Missing recovery directory.")?)?.sync_all()
            .map_err(|e| format!("Could not sync completed recovery record: {}", e))
    }
    fn replay(&self) -> Result<(), String> {
        let records = self.record.records();
        let mut tree_start = 0;
        let header = records.next(&mut tree_start)?.ok_or("Recovery record has no header.")?;
        let header = String::from_utf8(header).map_err(|_| "Recovery header is not valid text.")?;
        if field_usize(&header, "version") != Some(1) { return Err("Unsupported recovery record version.".into()); }
        let path = |key: &str| -> Result<PathBuf, String> {
            let value = PathBuf::from(field_str(&header, key).ok_or_else(|| format!("Recovery record has no {}.", key))?);
            if !value.is_absolute() || value.file_name().is_none() || value.components().any(|part| matches!(part, std::path::Component::ParentDir)) {
                return Err(format!("Recovery record has an invalid {} path.", key));
            }
            Ok(value)
        };
        let expected = |key: &str| Identity::from_saved(&field_str(&header, key).ok_or_else(|| format!("Recovery record has no {} identity.", key))?);
        let source = path("source")?;
        let quarantine_path = path("quarantine")?;
        let quarantine_name = quarantine_path.file_name().ok_or("Missing quarantine name.")?.to_string_lossy();
        let expected_name = format!("{}.review", quarantine_name);
        if !quarantine_name.starts_with(".flea-delete-") || self.path.file_name().and_then(OsStr::to_str) != Some(expected_name.as_str())
            || quarantine_path.parent() != source.parent() {
            return Err("Recovery record does not name its own quarantine.".into());
        }
        let quarantine = match open_dir(&quarantine_path) {
            Ok(directory) => directory,
            Err(error) => {
                if matches!(quarantine_path.symlink_metadata(), Err(error) if error.kind() == std::io::ErrorKind::NotFound) { return Ok(()); }
                return Err(error);
            }
        };
        if !same_node(&Identity::of(&quarantine.metadata().map_err(|e| e.to_string())?), &expected("quarantineIdentity")?) {
            return Err(format!("Recovery quarantine changed; data preserved at {}.", quarantine_path.display()));
        }
        let parent = open_dir(source.parent().ok_or("Missing recovery source parent.")?)?;
        if !same_node(&Identity::of(&parent.metadata().map_err(|e| e.to_string())?), &expected("parent")?) {
            return Err("Recovery source directory changed; no item was moved.".into());
        }
        let payload = expected("payload")?;
        let name = source.file_name().ok_or("Missing recovery source name.")?;
        for entry in std::fs::read_dir(fd_path(&quarantine, OsStr::new("."))).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let claimed_name = entry.file_name();
            let Some(offset) = claimed_name.to_str().and_then(|name| name.strip_prefix("entry-")).and_then(|value| value.parse::<u64>().ok()) else { continue; };
            let mut offset = tree_start.checked_add(offset).ok_or("Invalid recovery child offset.")?;
            let node = Node::decode(&records.next(&mut offset)?.ok_or("Recovery child has no review record.")?)?;
            if !same_node(&identity(&fd_path(&quarantine, &claimed_name))?, &node.identity) {
                return Err("Claimed recovery child changed; no item was moved.".into());
            }
            let (child_parent, child_name) = if node.relative.as_os_str().is_empty() || identity(&fd_path(&quarantine, OsStr::new("payload"))).is_ok() {
                parent_at(&quarantine, OsStr::new("payload"), &node.relative)?
            } else {
                if !same_node(&identity(&fd_path(&parent, name))?, &payload) { return Err("Recovery payload is unavailable.".into()); }
                parent_at(&parent, name, &node.relative)?
            };
            rename(&quarantine, &claimed_name, &child_parent, &child_name)
                .map_err(|e| format!("Could not return interrupted child without overwriting: {}", e))?;
        }
        let claimed_payload = fd_path(&quarantine, OsStr::new("payload"));
        let had_payload = match claimed_payload.symlink_metadata() {
            Ok(metadata) => {
                if !same_node(&Identity::of(&metadata), &payload) { return Err("Recovery payload identity changed.".into()); }
                rename(&quarantine, OsStr::new("payload"), &parent, name)
                    .map_err(|e| format!("Could not return interrupted item without overwriting: {}", e))?;
                true
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => return Err(error.to_string()),
        };
        let metadata_path = fd_path(&quarantine, OsStr::new("metadata"));
        let metadata = match metadata_path.symlink_metadata() {
            Ok(metadata) => Some(metadata),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(format!("Could not inspect interrupted Trash metadata: {}", error)),
        };
        if let Some(metadata) = metadata {
            if !same_node(&Identity::of(&metadata), &expected("metadata")?) { return Err("Recovery Trash metadata changed.".into()); }
            if had_payload || identity(&fd_path(&parent, name)).map(|current| same_node(&current, &payload)).unwrap_or(false) {
                let info = path("info")?;
                let infos = open_dir(info.parent().ok_or("Missing Trash metadata parent.")?)?;
                rename(&quarantine, OsStr::new("metadata"), &infos, info.file_name().ok_or("Missing Trash metadata name.")?)
                    .map_err(|e| format!("Could not return interrupted Trash metadata without overwriting: {}", e))?;
            } else {
                let destination = field_str(&header, "destination").unwrap_or_default();
                if !destination.is_empty() && !identity(Path::new(&destination)).map(|current| same_node(&current, &payload)).unwrap_or(false) {
                    return Err("Interrupted restore has no verified destination; metadata was preserved.".into());
                }
                std::fs::remove_file(&metadata_path).map_err(|e| format!("Could not clean completed Trash metadata: {}", e))?;
            }
        }
        std::fs::remove_dir(&quarantine_path).map_err(|e| format!("Unrecognized recovery data remains at {}: {}", quarantine_path.display(), e))?;
        Ok(())
    }
}
fn same_node(left: &Identity, right: &Identity) -> bool {
    left.dev == right.dev && left.ino == right.ino && left.mode & 0o170000 == right.mode & 0o170000
}

#[derive(Default)]
pub struct RecoveryReport {
    pub recovered: usize,
    pub failures: Vec<String>,
}
pub fn recover(root: &Path) -> Result<RecoveryReport, String> {
    if !root.is_absolute() { return Err("Recovery storage requires an absolute directory.".into()); }
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(RecoveryReport::default()),
        Err(error) => return Err(format!("Could not read recovery directory {}: {}", root.display(), error)),
    };
    let mut result = RecoveryReport::default();
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        if !name.to_str().map(|name| name.starts_with(".flea-delete-") && name.ends_with(".review")).unwrap_or(false) { continue; }
        let path = entry.path();
        let result_for_record = (|| {
            let Some(record) = Manifest::open_inactive(&path)? else { return Ok(false); };
            let recovery = Recovery { path: path.clone(), record };
            recovery.replay()?;
            recovery.complete()?;
            Ok::<bool, String>(true)
        })();
        match result_for_record {
            Ok(true) => result.recovered += 1,
            Ok(false) => {}
            Err(error) => result.failures.push(format!("{}: {}", path.display(), error)),
        }
    }
    Ok(result)
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    fn guard(d: &TestDir, path: &Path) {
        assert!(path.is_absolute() && !path.as_os_str().is_empty()
            && path.starts_with(d.path()) && path != d.path());
    }
    fn move_path(d: &TestDir, from: &Path, to: &Path) {
        guard(d, from);
        guard(d, to);
        std::fs::rename(from, to).unwrap();
    }
    fn remove_file(d: &TestDir, path: &Path) {
        guard(d, path);
        std::fs::remove_file(path).unwrap();
    }
    fn fixture(d: &TestDir, directory: bool, destination: Option<&Path>) -> (Reviewed, PathBuf, Recovery) {
        d.dir("files");
        d.dir("info");
        let source = if directory {
            let source = d.dir("files/item");
            d.file("files/item/child", "payload");
            source
        } else { d.file("files/item", "payload") };
        d.file("info/item.trashinfo", "[Trash Info]\nPath=/original\n");
        let metadata = source.symlink_metadata().unwrap();
        let mut reviewed = Reviewed::inspect(source.clone(), &format!("l{}:{}", metadata.dev(), metadata.ino())).unwrap();
        reviewed.snapshot(&mut Manifest::new(d.path()).unwrap(), d.path(), &Cancellation::default()).unwrap();
        let quarantine = d.dir("files/.flea-delete-test");
        let recovery_root = d.dir("recovery");
        for path in [&source, &reviewed.info, &quarantine, &recovery_root] { guard(d, path); }
        if let Some(destination) = destination { guard(d, destination); }
        let journal = Recovery::begin(&recovery_root, &source, &open_dir(&d.join("files")).unwrap(),
            &reviewed.payload, Some((&reviewed.info, &reviewed.metadata)), &quarantine,
            &open_dir(&quarantine).unwrap(), if destination.is_none() { reviewed.tree.as_ref() } else { None }, destination).unwrap();
        (reviewed, quarantine, journal)
    }
    fn claim(d: &TestDir, reviewed: &Reviewed, quarantine: &Path, metadata: bool) {
        move_path(d, &reviewed.path, &quarantine.join("payload"));
        if metadata { move_path(d, &reviewed.info, &quarantine.join("metadata")); }
    }
    fn claim_node(d: &TestDir, reviewed: &Reviewed, quarantine: &Path, relative: &Path) -> PathBuf {
        let tree = reviewed.tree.as_ref().unwrap();
        let mut cursor = tree.start();
        loop {
            let offset = cursor - tree.start();
            let node = Node::decode(&tree.next(&mut cursor).unwrap().expect("reviewed child")).unwrap();
            if node.relative == relative {
                let claimed = quarantine.join(format!("entry-{}", offset));
                let payload = quarantine.join("payload");
                let source = if relative.as_os_str().is_empty() { payload } else { payload.join(relative) };
                move_path(d, &source, &claimed);
                return claimed;
            }
        }
    }
    fn replay(d: &TestDir) -> RecoveryReport {
        let root = d.join("recovery");
        guard(d, &root);
        guard(d, &d.join("files"));
        guard(d, &d.join("info"));
        recover(&root).unwrap()
    }
    fn clean(d: &TestDir, quarantine: &Path, journal: &Path) {
        let report = replay(d);
        assert_eq!(report.failures, Vec::<String>::new());
        assert_eq!(report.recovered, 1);
        assert!(!quarantine.exists());
        assert!(!journal.exists());
        let repeated = replay(d);
        assert_eq!(repeated.recovered, 0);
        assert!(repeated.failures.is_empty());
    }

    #[test]
    fn recovery_skips_a_live_record_lock() {
        let d = TestDir::new("recovery-active");
        let (reviewed, quarantine, journal) = fixture(&d, false, None);
        claim(&d, &reviewed, &quarantine, true);
        let report = replay(&d);
        assert_eq!(report.recovered, 0);
        assert!(report.failures.is_empty());
        assert!(!reviewed.path.exists());
        assert!(quarantine.join("payload").exists());
        let record = journal.path.clone();
        drop(journal);
        clean(&d, &quarantine, &record);
        assert_eq!(std::fs::read_to_string(&reviewed.path).unwrap(), "payload");
        assert!(reviewed.info.exists());
    }

    #[test]
    fn recovery_returns_payload_only_and_paired_root_claims() {
        for metadata in [false, true] {
            let d = TestDir::new("recovery-roots");
            let (reviewed, quarantine, journal) = fixture(&d, false, None);
            claim(&d, &reviewed, &quarantine, metadata);
            let record = journal.path.clone();
            drop(journal);
            clean(&d, &quarantine, &record);
            assert_eq!(std::fs::read_to_string(&reviewed.path).unwrap(), "payload");
            assert_eq!(identity(&reviewed.info).unwrap(), reviewed.metadata);
        }
    }

    #[test]
    fn recovery_returns_interrupted_child_and_entry_zero_claims() {
        for relative in [Path::new("child"), Path::new("")] {
            let d = TestDir::new("recovery-child");
            let (reviewed, quarantine, journal) = fixture(&d, !relative.as_os_str().is_empty(), None);
            claim(&d, &reviewed, &quarantine, true);
            let interrupted = claim_node(&d, &reviewed, &quarantine, relative);
            let record = journal.path.clone();
            drop(journal);
            clean(&d, &quarantine, &record);
            assert!(!interrupted.exists());
            let source = if relative.as_os_str().is_empty() { reviewed.path.clone() } else { reviewed.path.join(relative) };
            assert_eq!(std::fs::read_to_string(source).unwrap(), "payload");
            assert!(reviewed.info.exists());
        }
    }

    #[test]
    fn recovery_never_overwrites_an_original_name_collision() {
        let d = TestDir::new("recovery-collision");
        let (reviewed, quarantine, journal) = fixture(&d, false, None);
        claim(&d, &reviewed, &quarantine, true);
        d.file("files/item", "later arrival");
        let record = journal.path.clone();
        drop(journal);
        let report = replay(&d);
        assert_eq!(report.recovered, 0);
        assert_eq!(report.failures.len(), 1);
        assert_eq!(std::fs::read_to_string(&reviewed.path).unwrap(), "later arrival");
        assert_eq!(std::fs::read_to_string(quarantine.join("payload")).unwrap(), "payload");
        assert!(quarantine.join("metadata").exists());
        assert!(record.exists());
    }

    #[test]
    fn recovery_never_overwrites_an_interrupted_child_collision() {
        let d = TestDir::new("recovery-child-collision");
        let (reviewed, quarantine, journal) = fixture(&d, true, None);
        claim(&d, &reviewed, &quarantine, true);
        let interrupted = claim_node(&d, &reviewed, &quarantine, Path::new("child"));
        std::fs::write(quarantine.join("payload/child"), "later arrival").unwrap();
        drop(journal);
        let report = replay(&d);
        assert_eq!(report.failures.len(), 1);
        assert_eq!(std::fs::read_to_string(interrupted).unwrap(), "payload");
        assert_eq!(std::fs::read_to_string(quarantine.join("payload/child")).unwrap(), "later arrival");
    }

    #[test]
    fn recovery_refuses_a_replaced_quarantine() {
        let d = TestDir::new("recovery-quarantine-replacement");
        let (reviewed, quarantine, journal) = fixture(&d, false, None);
        claim(&d, &reviewed, &quarantine, true);
        let saved = d.join("files/saved-quarantine");
        move_path(&d, &quarantine, &saved);
        std::fs::create_dir(&quarantine).unwrap();
        std::fs::write(quarantine.join("payload"), "replacement").unwrap();
        drop(journal);
        assert_eq!(replay(&d).failures.len(), 1);
        assert_eq!(std::fs::read_to_string(saved.join("payload")).unwrap(), "payload");
        assert_eq!(std::fs::read_to_string(quarantine.join("payload")).unwrap(), "replacement");
        assert!(!reviewed.path.exists());
    }

    #[test]
    fn recovery_validates_payload_before_returning_a_child() {
        let d = TestDir::new("recovery-payload-replacement");
        let (reviewed, quarantine, journal) = fixture(&d, true, None);
        claim(&d, &reviewed, &quarantine, true);
        let interrupted = claim_node(&d, &reviewed, &quarantine, Path::new("child"));
        move_path(&d, &quarantine.join("payload"), &d.join("files/saved-payload"));
        std::fs::create_dir(quarantine.join("payload")).unwrap();
        drop(journal);
        assert_eq!(replay(&d).failures.len(), 1);
        assert_eq!(std::fs::read_to_string(interrupted).unwrap(), "payload");
        assert!(!quarantine.join("payload/child").exists());
        assert!(!reviewed.path.exists());
    }

    #[test]
    fn recovery_cleans_a_completed_deletion_and_its_record() {
        let d = TestDir::new("recovery-completed-delete");
        let (reviewed, quarantine, journal) = fixture(&d, false, None);
        claim(&d, &reviewed, &quarantine, true);
        remove_file(&d, &quarantine.join("payload"));
        let record = journal.path.clone();
        drop(journal);
        clean(&d, &quarantine, &record);
        assert!(!reviewed.path.exists());
        assert!(!reviewed.info.exists());
    }

    #[test]
    fn recovery_cleans_restore_metadata_only_for_its_verified_destination() {
        for replace_destination in [false, true] {
            let d = TestDir::new("recovery-completed-restore");
            let destination = d.join("restored");
            let (reviewed, quarantine, journal) = fixture(&d, false, Some(&destination));
            claim(&d, &reviewed, &quarantine, true);
            move_path(&d, &quarantine.join("payload"), &destination);
            if replace_destination {
                move_path(&d, &destination, &d.join("saved-destination"));
                std::fs::write(&destination, "replacement").unwrap();
            }
            let record = journal.path.clone();
            drop(journal);
            if replace_destination {
                assert_eq!(replay(&d).failures.len(), 1);
                assert!(quarantine.join("metadata").exists());
                assert!(record.exists());
                assert_eq!(std::fs::read_to_string(destination).unwrap(), "replacement");
            } else {
                clean(&d, &quarantine, &record);
                assert_eq!(std::fs::read_to_string(destination).unwrap(), "payload");
            }
        }
    }

    #[test]
    fn recovery_keeps_malformed_and_nonregular_records() {
        let d = TestDir::new("recovery-malformed");
        d.dir("recovery");
        d.file("recovery/.flea-delete-truncated.review", "short");
        let malformed = d.join("recovery/.flea-delete-malformed.review");
        let mut record = Manifest::create(&malformed).unwrap();
        record.append(b"{}").unwrap();
        drop(record);
        d.dir("recovery/.flea-delete-directory.review");
        let target = d.file("link-target", "keep");
        std::os::unix::fs::symlink(&target, d.join("recovery/.flea-delete-link.review")).unwrap();
        assert!(std::process::Command::new("mkfifo").arg(d.join("recovery/.flea-delete-pipe.review")).status().unwrap().success());
        let report = replay(&d);
        assert_eq!(report.recovered, 0);
        assert_eq!(report.failures.len(), 5);
        assert_eq!(std::fs::read_dir(d.join("recovery")).unwrap().count(), 5);
        assert_eq!(std::fs::read_to_string(target).unwrap(), "keep");
    }

    #[test]
    fn recovery_retains_unknown_quarantine_contents() {
        let d = TestDir::new("recovery-unknown");
        let (reviewed, quarantine, journal) = fixture(&d, false, None);
        claim(&d, &reviewed, &quarantine, true);
        std::fs::write(quarantine.join("unrecognized"), "keep").unwrap();
        let record = journal.path.clone();
        drop(journal);
        assert_eq!(replay(&d).failures.len(), 1);
        assert!(record.exists());
        assert_eq!(std::fs::read_to_string(quarantine.join("unrecognized")).unwrap(), "keep");
        assert_eq!(std::fs::read_to_string(reviewed.path).unwrap(), "payload");
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
        let mut reviewed =
            Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        reviewed.snapshot(&mut Manifest::new(d.path()).unwrap(), d.path(), &Cancellation::default()).unwrap();
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
    fn restore_fixture(d: &TestDir, original: &Path) -> (PathBuf, Reviewed) {
        let (path, _) = fixture(d);
        std::fs::write(d.join("info/item.trashinfo"), format!("[Trash Info]\nPath={}\n", original.display())).unwrap();
        let meta = path.symlink_metadata().unwrap();
        let reviewed = Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        (path, reviewed)
    }
    #[test]
    fn restore_claims_both_identities_and_never_overwrites() {
        let d = TestDir::new("trash-restore-claim");
        let original = d.file("restored", "keep");
        let (path, reviewed) = restore_fixture(&d, &original);
        guard(&d, &path);
        guard(&d, &original);
        assert!(reviewed.restore(&original, d.path()).is_err());
        assert_eq!(std::fs::read_to_string(&original).unwrap(), "keep");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "payload");
        assert!(d.join("info/item.trashinfo").exists());
        std::fs::rename(&original, d.join("existing-saved")).unwrap();
        reviewed.restore(&original, d.path()).unwrap();
        assert_eq!(std::fs::read_to_string(original).unwrap(), "payload");
        assert!(!path.exists());
        assert!(!d.join("info/item.trashinfo").exists());
    }
    #[test]
    fn restore_replacement_between_check_and_claim_is_preserved() {
        let d = TestDir::new("trash-restore-race");
        let original = d.join("restored");
        let (path, reviewed) = restore_fixture(&d, &original);
        guard(&d, &path);
        guard(&d, &original);
        assert!(reviewed.restore_after(&original, d.path(), || {
            std::fs::rename(&path, d.join("files/old-reviewed")).unwrap();
            std::fs::write(&path, "replacement").unwrap();
        }).is_err());
        assert!(!original.exists());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "replacement");
        assert_eq!(std::fs::read_to_string(d.join("files/old-reviewed")).unwrap(), "payload");
        assert!(d.join("info/item.trashinfo").exists());
    }
    #[test]
    fn restore_missing_parent_and_mismatched_original_preserve_trash() {
        let d = TestDir::new("trash-restore-path");
        let original = d.join("missing/restored");
        let (path, reviewed) = restore_fixture(&d, &original);
        guard(&d, &path);
        guard(&d, &original);
        assert!(reviewed.restore(&original, d.path()).is_err());
        let wrong = d.join("wrong");
        guard(&d, &wrong);
        assert!(reviewed.restore(&wrong, d.path()).is_err());
        assert!(!wrong.exists());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "payload");
        assert!(d.join("info/item.trashinfo").exists());
    }
    #[test]
    fn original_paths_decode_escaping_and_volume_relative_metadata() {
        let d = TestDir::new("trash-restore-metadata");
        let encoded = d.file("metadata", "[Trash Info]\nPath=folder/photo%20one+two.jpg\n");
        let root = d.join(".Trash-1000");
        assert_eq!(original_path(&File::open(&encoded).unwrap(), &root).unwrap(), d.join("folder/photo one+two.jpg"));
        let root = d.join(".Trash/1000");
        assert_eq!(original_path(&File::open(&encoded).unwrap(), &root).unwrap(), d.join("folder/photo one+two.jpg"));
        std::fs::write(&encoded, "[Trash Info]\nPath=../escape\n").unwrap();
        assert!(original_path(&File::open(&encoded).unwrap(), &root).is_err());
        std::fs::write(&encoded, "[Trash Info]\nPath=/one\nPath=/two\n").unwrap();
        assert!(original_path(&File::open(&encoded).unwrap(), &root).is_err());
    }
    #[test]
    fn deletes_only_reviewed_item_and_preserves_later_arrival() {
        let d = TestDir::new("trash-delete");
        let (path, reviewed) = fixture(&d);
        let later = d.file("files/later", "keep");
        guard(&d, &path);
        reviewed.delete(d.path()).unwrap();
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
        assert!(reviewed.delete(d.path()).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "replacement");
    }
    #[test]
    fn unreviewed_contents_are_never_deleted() {
        let d = TestDir::new("trash-delete-unreviewed");
        let (path, _) = fixture(&d);
        let meta = path.symlink_metadata().unwrap();
        let unreviewed = Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        guard(&d, &path);
        assert!(unreviewed.delete(d.path()).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "payload");
    }
    #[test]
    fn changed_metadata_is_never_deleted() {
        let d = TestDir::new("trash-delete-metadata");
        let (path, reviewed) = fixture(&d);
        let info = d.join("info/item.trashinfo");
        std::fs::rename(&info, d.join("info/old.trashinfo")).unwrap();
        std::fs::write(&info, "[Trash Info]\nPath=/new-original\n").unwrap();
        guard(&d, &path);
        assert!(reviewed.delete(d.path()).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "payload");
        assert!(std::fs::read_to_string(info).unwrap().contains("/new-original"));
    }
    #[test]
    fn backing_paths_must_name_a_trash_payload() {
        assert!(Reviewed::inspect(PathBuf::from("relative/files/item"), "").is_err());
        assert!(Reviewed::inspect(PathBuf::from("/tmp/item"), "").is_err());
    }
    #[test]
    fn replacement_between_check_and_claim_is_restored_without_deletion() {
        let d = TestDir::new("trash-delete-race");
        let (path, reviewed) = fixture(&d);
        guard(&d, &path);
        let result = reviewed.delete_after(d.path(), || {
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
        let mut reviewed =
            Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        reviewed.snapshot(&mut Manifest::new(d.path()).unwrap(), d.path(), &Cancellation::default()).unwrap();
        guard(&d, &path);
        reviewed.delete(d.path()).unwrap();
        assert!(!path.exists());
        assert_eq!(std::fs::read_to_string(target).unwrap(), "keep");
    }
    #[test]
    fn directory_child_changes_invalidate_review() {
        let d = TestDir::new("trash-delete-child-change");
        d.dir("files/item");
        d.dir("info");
        d.file("info/item.trashinfo", "[Trash Info]\nPath=/original\n");
        let child = d.file("files/item/child", "reviewed");
        let path = d.join("files/item");
        let meta = path.symlink_metadata().unwrap();
        let mut reviewed = Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        assert_eq!(reviewed.snapshot(&mut Manifest::new(d.path()).unwrap(), d.path(), &Cancellation::default()).unwrap(), 8);
        std::fs::write(&child, "changed size").unwrap();
        assert!(!reviewed.contents_unchanged(&Cancellation::default()).unwrap());
        guard(&d, &path);
        assert!(reviewed.delete(d.path()).is_err());
        assert_eq!(std::fs::read_to_string(child).unwrap(), "changed size");
    }
    #[test]
    fn directory_arrival_after_claim_survives() {
        let d = TestDir::new("trash-delete-child-arrival");
        d.dir("files/item");
        d.dir("info");
        d.file("info/item.trashinfo", "[Trash Info]\nPath=/original\n");
        d.file("files/item/child", "reviewed");
        let path = d.join("files/item");
        let meta = path.symlink_metadata().unwrap();
        let mut reviewed = Reviewed::inspect(path.clone(), &format!("l{}:{}", meta.dev(), meta.ino())).unwrap();
        reviewed.snapshot(&mut Manifest::new(d.path()).unwrap(), d.path(), &Cancellation::default()).unwrap();
        guard(&d, &path);
        let result = reviewed.delete_with(d.path(), || {}, |claimed| {
            std::fs::write(claimed.join("new-arrival"), "keep").unwrap();
        });
        assert!(result.is_err());
        assert_eq!(std::fs::read_to_string(path.join("new-arrival")).unwrap(), "keep");
        assert_eq!(std::fs::read_to_string(path.join("child")).unwrap(), "reviewed");
    }
    #[test]
    fn deleting_a_reviewed_child_does_not_remove_unreviewed_siblings() {
        let d = TestDir::new("trash-delete-member-set");
        let directory = d.dir("directory");
        let path = d.file("directory/reviewed", "delete");
        let node = Node { relative: PathBuf::new(), identity: identity(&path).unwrap(), children: 0 };
        let later = d.file("directory/later", "keep");
        let quarantine = d.dir("quarantine");
        guard(&d, &path);
        node.claim_remove(&open_dir(&directory).unwrap(), OsStr::new("reviewed"), &open_dir(&quarantine).unwrap(), 0).unwrap();
        assert!(!path.exists());
        assert_eq!(std::fs::read_to_string(later).unwrap(), "keep");
    }
    #[test]
    fn cancelled_snapshot_never_leaves_an_actionable_review() {
        let d = TestDir::new("trash-review-cancel");
        let (path, mut reviewed) = fixture(&d);
        let cancellation = Cancellation::default();
        let old = cancellation.next();
        cancellation.next();
        assert!(reviewed.snapshot(&mut Manifest::new(d.path()).unwrap(), d.path(), &old).is_err());
        guard(&d, &path);
        assert!(reviewed.delete(d.path()).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "payload");
    }
    #[test]
    fn saved_reviews_keep_original_identities_and_manifest_ranges() {
        let d = TestDir::new("trash-review-record");
        let (path, mut reviewed) = fixture(&d);
        let mut manifest = Manifest::new(d.path()).unwrap();
        reviewed.snapshot(&mut manifest, d.path(), &Cancellation::default()).unwrap();
        let restored = Reviewed::from_saved(&reviewed.saved().unwrap(), &manifest).unwrap();
        assert!(restored.contents_unchanged(&Cancellation::default()).unwrap());
        std::fs::write(&path, "different").unwrap();
        assert!(!restored.contents_unchanged(&Cancellation::default()).unwrap());
        guard(&d, &path);
        assert!(restored.delete(d.path()).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "different");
    }
    #[test]
    fn ordinary_path_review_refuses_a_replacement_during_claim() {
        let d = TestDir::new("path-delete-race");
        let path = d.file("selected", "reviewed");
        let mut manifest = Manifest::new(d.path()).unwrap();
        let (reviewed, bytes) = PathReview::prepare(path.clone(), &mut manifest, d.path(), &Cancellation::default()).unwrap();
        assert_eq!(bytes, 8);
        guard(&d, &path);
        assert!(reviewed.delete_after(d.path(), || {
            std::fs::rename(&path, d.join("old-selected")).unwrap();
            std::fs::write(&path, "replacement").unwrap();
        }).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "replacement");
        assert_eq!(std::fs::read_to_string(d.join("old-selected")).unwrap(), "reviewed");
    }
    #[test]
    fn iterative_review_deletes_deep_trees_without_following_symlinks() {
        let d = TestDir::new("path-delete-deep");
        let root = d.dir("selected");
        let mut deepest = root.clone();
        for _ in 0..300 {
            deepest = deepest.join("d");
            std::fs::create_dir(&deepest).unwrap();
        }
        std::fs::write(deepest.join("payload"), "reviewed").unwrap();
        let outside = d.file("outside", "keep");
        std::os::unix::fs::symlink(&outside, deepest.join("link")).unwrap();
        let mut manifest = Manifest::new(d.path()).unwrap();
        let (reviewed, _) = PathReview::prepare(root.clone(), &mut manifest, d.path(), &Cancellation::default()).unwrap();
        assert!(reviewed.unchanged(&Cancellation::default()).unwrap());
        guard(&d, &root);
        reviewed.delete(d.path()).unwrap();
        assert!(!root.exists());
        assert_eq!(std::fs::read_to_string(outside).unwrap(), "keep");
    }
}
