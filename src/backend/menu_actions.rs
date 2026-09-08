// Menu snapshots own selected identities; registry work runs only after an explicit menu action.
use crate::backend::opsreq::OpMsg;
use super::menu_registry::{self, Registry};
use super::trashmanifest::Cancellation;
use crate::json::{escape, field_str, field_usize};
use std::fs::{Metadata, OpenOptions};
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{sync_channel, Sender, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicUsize, Ordering};

pub struct MenuActions {
    requests: SyncSender<(String, Vec<String>, Cancellation)>,
    replies: Sender<OpMsg>,
    snapshot: Arc<Mutex<Snapshot>>,
    cancellation: Mutex<Cancellation>,
    registry: Registry,
    requested_id: AtomicUsize,
}
impl MenuActions {
    pub fn new(replies: Sender<OpMsg>) -> Self {
        // One pending request bounds repeated activation while an application registry query runs.
        let (requests, receiver) = sync_channel::<(String, Vec<String>, Cancellation)>(1);
        let output = replies.clone();
        let snapshot = Arc::new(Mutex::new(Snapshot::default()));
        let published = Arc::clone(&snapshot);
        let registry = Registry::default();
        let queries = registry.clone();
        std::thread::spawn(move || {
            while let Ok((line, paths, cancel)) = receiver.recv() {
                let mut state = published.lock().unwrap().clone();
                let reply = if cancel.check().is_ok() {
                    state.handle_request(&line, paths, &queries, &cancel)
                } else { response(&line, Err("Menu request cancelled.".into())) };
                if cancel.check().is_ok() && matches!(field_str(&line, "op").as_deref(), Some("snapshot" | "close")) {
                    *published.lock().unwrap() = state;
                }
                if output.send(OpMsg::Meta { line: reply }).is_err() { break; }
            }
        });
        Self { requests, replies, snapshot, cancellation: Mutex::new(Cancellation::default()), registry, requested_id: AtomicUsize::new(0) }
    }
    pub(crate) fn selection(&self, id: usize) -> Result<Vec<Selected>, String> {
        let snapshot = self.snapshot.lock().map_err(|_| "The menu service stopped; reopen this window.")?;
        if id == 0 || snapshot.id != id || snapshot.items.is_empty() {
            return Err("Menu selection expired; reopen the menu.".into());
        }
        Ok(snapshot.items.clone())
    }
    pub fn request(&self, line: String, paths: Vec<String>) {
        let op = field_str(&line, "op").unwrap_or_default();
        let mut cancellation = self.cancellation.lock().unwrap();
        if op == "snapshot" || op == "close" {
            let id = field_usize(&line, "id").unwrap_or(0);
            if op == "close" && self.requested_id.load(Ordering::Relaxed) != id {
                let _ = self.replies.send(OpMsg::Meta { line: response(&line, Ok(String::new())) });
                return;
            }
            *cancellation = cancellation.next();
            self.requested_id.store(if op == "snapshot" { id } else { 0 }, Ordering::Relaxed);
            *self.snapshot.lock().unwrap() = Snapshot::default();
            if let Err(error) = self.registry.cancel() {
                let _ = self.replies.send(OpMsg::Meta { line: response(&line, Err(error)) });
                return;
            }
            if op == "close" {
                let _ = self.replies.send(OpMsg::Meta { line: response(&line, Ok(String::new())) });
                return;
            }
        }
        if let Err(error) = self.requests.try_send((line, paths, cancellation.clone())) {
            let (request, reason) = match error {
                TrySendError::Full(request) => (request, "A menu request is still running; try again when it finishes."),
                TrySendError::Disconnected(request) => (request, "The menu service stopped; reopen this window."),
            };
            let reply = response(&request.0, Err(reason.into()));
            let _ = self.replies.send(OpMsg::Meta { line: reply });
        }
    }
}

impl Drop for MenuActions {
    fn drop(&mut self) {
        self.cancellation.lock().unwrap().next();
        if let Err(error) = self.registry.cancel() { eprintln!("flea: {}", error); }
    }
}

#[derive(Clone, Default)]
struct Snapshot {
    id: usize,
    items: Vec<Selected>,
}
#[derive(Clone)]
pub(crate) struct Selected {
    pub path: PathBuf,
    dev: u64,
    ino: u64,
    kind: u32,
}
impl Selected {
    fn inspect(path: &str) -> Result<Self, String> {
        let path = PathBuf::from(path);
        if !path.is_absolute() || path.file_name().is_none() {
            return Err("Menu selection requires an absolute item path.".into());
        }
        let meta = path.symlink_metadata().map_err(|e| format!("Could not inspect selected item {}: {}.", path.display(), e))?;
        Ok(Self { path, dev: meta.dev(), ino: meta.ino(), kind: meta.mode() & 0o170000 })
    }
    pub(crate) fn current(&self) -> Result<Metadata, String> {
        let meta = self.path.symlink_metadata().map_err(|_| "Selected item moved or disappeared; reopen the menu.")?;
        if meta.dev() != self.dev || meta.ino() != self.ino || meta.mode() & 0o170000 != self.kind {
            return Err("Selected item changed; reopen the menu.".into());
        }
        Ok(meta)
    }
}
impl Snapshot {
    // Sample input: {"c":"menuaction","op":"snapshot","id":3}; paths are resolved from the active listing by run.rs.
    fn handle_request(&mut self, line: &str, paths: Vec<String>, registry: &Registry, cancel: &Cancellation) -> String {
        let id = field_usize(line, "id").unwrap_or(0);
        let op = field_str(line, "op").unwrap_or_default();
        let result = if op == "snapshot" {
            self.id = 0;
            self.items.clear();
            if id == 0 || paths.is_empty() {
                Err("There are no selected items to inspect.".into())
            } else {
                paths.iter().map(|path| Selected::inspect(path)).collect::<Result<Vec<_>, _>>().map(|items| {
                    self.items = items;
                    self.id = id;
                    format!(r#""count":{}"#, self.items.len())
                })
            }
        } else if op == "close" {
            if self.id == id { self.id = 0; self.items.clear(); }
            Ok(String::new())
        } else {
            self.perform(id, &op, line, registry, cancel)
        };
        response(line, result)
    }
    fn perform(&self, id: usize, op: &str, line: &str, registry: &Registry, cancel: &Cancellation) -> Result<String, String> {
        if id == 0 || id != self.id || self.items.is_empty() {
            return Err("Menu selection expired; reopen the menu.".into());
        }
        for item in &self.items { item.current()?; }
        if op == "validate" {
            let paths: Vec<String> = self.items.iter().map(|i| format!(r#""{}""#, escape(&i.path.to_string_lossy()))).collect();
            return Ok(format!(r#""action":"{}","paths":[{}],"dest":"{}""#,
                escape(&field_str(line, "action").unwrap_or_default()), paths.join(","),
                escape(&field_str(line, "dest").unwrap_or_default())));
        }
        if self.items.len() != 1 { return Err("This action requires one selected item.".into()); }
        let item = &self.items[0];
        let meta = item.current()?;
        match op {
            "properties" => {
                let kind = if meta.file_type().is_symlink() { "Symbolic link" } else if meta.is_dir() { "Directory" }
                           else if meta.is_file() { "File" } else { "Special file" };
                let target = if meta.file_type().is_symlink() {
                    std::fs::read_link(&item.path).map_err(|e| format!("Could not read symlink: {}.", e))?.to_string_lossy().to_string()
                } else { String::new() };
                Ok(format!(r#""path":"{}","kind":"{}","directory":{},"symlink":{},"target":"{}","bytes":{},"modified":{},"mode":"{:04o}","owner":"{}","uid":{},"gid":{}"#,
                    escape(&item.path.to_string_lossy()), kind, meta.is_dir(), meta.file_type().is_symlink(), escape(&target),
                    meta.len(), meta.mtime(), meta.mode() & 0o7777, escape(&super::owner::name(meta.uid())), meta.uid(), meta.gid()))
            }
            "applications" => {
                let apps = menu_registry::applications(registry, &item.path, cancel)?;
                let entries: Vec<String> = apps.iter().map(|a| format!(r#"{{"id":"{}","label":"{}"}}"#, escape(&a.id), escape(&a.label))).collect();
                Ok(format!(r#""applications":[{}]"#, entries.join(",")))
            }
            "openWith" => {
                let requested = field_str(line, "application").unwrap_or_default();
                let app = menu_registry::applications(registry, &item.path, cancel)?.into_iter().find(|a| a.id == requested)
                    .ok_or("That application is no longer registered for the selected item.")?;
                item.current()?;
                launch(&app.path, &item.path)?;
                Ok(format!(r#""path":"{}""#, escape(&item.path.to_string_lossy())))
            }
            _ => Err("Unknown menu operation.".into()),
        }
    }
    #[cfg(test)]
    fn handle(&mut self, line: &str, paths: Vec<String>) -> String {
        self.handle_request(line, paths, &Registry::default(), &Cancellation::default())
    }
}

pub(crate) fn response(line: &str, result: Result<String, String>) -> String {
    let header = format!(r#""t":"menuaction","id":{},"op":"{}""#,
        field_usize(line, "id").unwrap_or(0), escape(&field_str(line, "op").unwrap_or_default()));
    match result {
        Ok(fields) => format!("{{{},\"ok\":true{}{}}}", header, if fields.is_empty() { "" } else { "," }, fields),
        Err(error) => format!(r#"{{{},"ok":false,"error":"{}"}}"#, header, escape(&error)),
    }
}

// create_new performs collision refusal atomically, including a dangling symlink at the chosen name.
pub fn create_file(parent: &Path, name: &str) -> Result<(PathBuf, super::undo::ItemIdentity), String> {
    if !parent.is_absolute() || !super::ops::valid_name(name) {
        return Err("New File requires an absolute folder and one non-empty filename.".into());
    }
    let path = parent.join(name);
    let file = OpenOptions::new().write(true).create_new(true).open(&path)
        .map_err(|e| format!("Could not create {}: {}.", path.display(), e))?;
    let meta = file.metadata().map_err(|e| format!("Created {}, but could not record its identity: {}.", path.display(), e))?;
    Ok((path, super::undo::ItemIdentity::record(&meta)))
}

fn launch(desktop: &Path, path: &Path) -> Result<(), String> {
    // Restore foreign-child THP with an allocation-free syscall between fork and exec.
    const PR_SET_THP_DISABLE: i32 = 41;
    extern "C" { fn prctl(option: i32, arg2: u64, arg3: u64, arg4: u64, arg5: u64) -> i32; }
    let mut command = Command::new("gio");
    command.arg("launch").arg(desktop).arg(path).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
    unsafe { command.pre_exec(|| if prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0) == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }); }
    let status = command.status().map_err(|e| format!("Could not launch selected application: {}.", e))?;
    if status.success() { Ok(()) } else { Err("GIO could not open this item with the selected application.".into()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;
    use std::os::unix::fs::symlink;

    #[test]
    fn snapshot_rejects_replaced_items_and_stale_request_ids() {
        let sandbox = TestDir::new("menu-snapshot");
        let path = sandbox.file("item", "original");
        let mut snapshot = Snapshot::default();
        assert!(snapshot.handle(r#"{"op":"snapshot","id":3}"#, vec![path.to_string_lossy().into()]).contains(r#""ok":true"#));
        assert!(snapshot.handle(r#"{"op":"validate","id":2}"#, vec![]).contains("expired"));
        let moved = sandbox.join("old");
        assert!(path.is_absolute() && path.starts_with(sandbox.path()) && moved.starts_with(sandbox.path()));
        std::fs::rename(&path, moved).unwrap();
        sandbox.file("item", "replacement");
        assert!(snapshot.handle(r#"{"op":"validate","id":3}"#, vec![]).contains("Selected item changed"));
        assert_eq!(std::fs::read_to_string(path).unwrap(), "replacement");
    }
    #[test]
    fn create_file_refuses_collisions_traversal_and_symlinks() {
        let sandbox = TestDir::new("menu-newfile");
        let (path, identity) = create_file(sandbox.path(), "New File").unwrap();
        let meta = path.symlink_metadata().unwrap();
        assert_eq!(meta.len(), 0);
        assert_eq!(super::super::undo::ItemIdentity::record(&meta), identity);
        assert!(create_file(sandbox.path(), "New File").is_err());
        assert!(create_file(sandbox.path(), "../escape").is_err());
        assert!(create_file(sandbox.path(), "").is_err());
        assert!(create_file(Path::new("relative"), "file").is_err());
        symlink(sandbox.join("absent"), sandbox.join("link")).unwrap();
        assert!(create_file(sandbox.path(), "link").is_err());
        assert!(!sandbox.join("absent").exists());
    }
    #[test]
    fn properties_describe_the_link_itself_and_close_expires_selection() {
        let sandbox = TestDir::new("menu-link");
        let target = sandbox.file("target", "body");
        let link = sandbox.join("link");
        symlink(&target, &link).unwrap();
        let mut snapshot = Snapshot::default();
        snapshot.handle(r#"{"op":"snapshot","id":9}"#, vec![link.to_string_lossy().into()]);
        let line = snapshot.handle(r#"{"op":"properties","id":9}"#, vec![]);
        assert!(line.contains(r#""symlink":true"#));
        assert_eq!(field_str(&line, "target"), Some(target.to_string_lossy().into()));
        snapshot.handle(r#"{"op":"close","id":9}"#, vec![]);
        assert!(snapshot.handle(r#"{"op":"properties","id":9}"#, vec![]).contains("expired"));
    }
}
