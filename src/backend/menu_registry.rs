// Application discovery uses the same GIO registry that launches the selected desktop entry.
use super::trashmanifest::Cancellation;
use std::ffi::OsStr;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};

// Registry output is metadata; an oversized response is refused instead of allocating without a bound.
const MAX_REGISTRY_BYTES: u64 = 1024 * 1024;
const SIGKILL: i32 = 9;
const ESRCH: i32 = 3;
const EINTR: i32 = 4;
const POLLIN: i16 = 1;
#[repr(C)]
struct PollFd { fd: i32, events: i16, revents: i16 }
extern "C" {
    fn pidfd_open(pid: i32, flags: u32) -> i32;
    fn kill(pid: i32, signal: i32) -> i32;
    fn poll(fds: *mut PollFd, count: usize, timeout: i32) -> i32;
}
struct Running { pid: i32, pidfd: OwnedFd, group: bool }

#[derive(Clone, Default)]
pub(crate) struct Registry { running: Arc<Mutex<Option<Running>>> }

impl Registry {
    pub fn cancel(&self) -> Result<(), String> {
        let running = self.running.lock().map_err(|_| "The application query service stopped.")?;
        if let Some(child) = running.as_ref() {
            // Reaping also holds this lock, so cancellation cannot target a reused PID or process group.
            terminate(child.pid, child.group)?;
        }
        Ok(())
    }

    fn query(&self, args: &[&OsStr], cancel: &Cancellation) -> Result<String, String> {
        let mut command = Command::new("gio");
        command.args(args).env("LC_ALL", "C");
        self.capture(&mut command, cancel)
    }

    fn capture(&self, command: &mut Command, cancel: &Cancellation) -> Result<String, String> {
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut owned = OwnedChild::start(command, self, cancel, true)?;
        let child = owned.child.as_mut().unwrap();
        let output = reader(child.stdout.take().unwrap(), self.clone())?;
        let errors = match reader(child.stderr.take().unwrap(), self.clone()) {
            Ok(reader) => reader,
            Err(error) => { drop(owned); let _ = output.join(); return Err(error); }
        };
        let output = match output.join() {
            Ok(result) => result,
            Err(_) => { drop(owned); let _ = errors.join(); return Err("GIO output reader stopped.".into()); }
        };
        let errors = errors.join().map_err(|_| "GIO error reader stopped.".to_string())?;
        let status = owned.wait()?;
        cancelled(cancel)?;
        let stdout = output?;
        let stderr = errors?;
        if !status.success() {
            let detail = String::from_utf8_lossy(&stderr);
            return Err(format!("GIO application query failed: {}.", detail.lines().last().unwrap_or("no diagnostic")));
        }
        String::from_utf8(stdout).map_err(|_| "GIO returned invalid application registry text.".into())
    }

    pub fn launch(&self, desktop: &Path, path: &Path, cancel: &Cancellation) -> Result<(), String> {
        const PR_SET_THP_DISABLE: i32 = 41;
        extern "C" { fn prctl(option: i32, arg2: u64, arg3: u64, arg4: u64, arg5: u64) -> i32; }
        let mut command = Command::new("gio");
        command.arg("launch").arg(desktop).arg(path);
        // Foreign applications retain the released THP policy; this child hook cannot allocate.
        unsafe { command.pre_exec(|| if prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0) == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }); }
        self.launch_command(&mut command, cancel)
            .map_err(|error| format!("Could not open {} with {}: {}", path.display(), desktop.display(), error))
    }

    fn launch_command(&self, command: &mut Command, cancel: &Cancellation) -> Result<(), String> {
        // Applications can inherit launcher descriptors and its group, so neither pipes nor group cancellation are appropriate here.
        command.stdout(Stdio::null()).stderr(Stdio::null());
        let status = OwnedChild::start(command, self, cancel, false)?.wait()?;
        cancelled(cancel)?;
        if status.success() { Ok(()) } else { Err(format!("GIO application launcher exited with {}.", status)) }
    }
}

struct OwnedChild { child: Option<Child>, registry: Registry }

impl OwnedChild {
    fn start(command: &mut Command, registry: &Registry, cancel: &Cancellation, group: bool) -> Result<Self, String> {
        cancelled(cancel)?;
        let mut child = command.stdin(Stdio::null()).process_group(0).spawn()
            .map_err(|e| format!("Could not start GIO application query or launcher: {}.", e))?;
        let raw = unsafe { pidfd_open(child.id() as i32, 0) };
        if raw < 0 {
            let mut error = format!("Could not observe GIO application child: {}.", std::io::Error::last_os_error());
            if let Err(cleanup) = terminate(child.id() as i32, group) { error.push_str(&format!(" {}", cleanup)); }
            if let Err(cleanup) = child.wait() { error.push_str(&format!(" Could not reap it: {}.", cleanup)); }
            return Err(error);
        }
        *registry.running.lock().unwrap() = Some(Running { pid: child.id() as i32, pidfd: unsafe { OwnedFd::from_raw_fd(raw) }, group });
        let owned = Self { child: Some(child), registry: registry.clone() };
        cancelled(cancel)?;
        Ok(owned)
    }

    fn wait(mut self) -> Result<ExitStatus, String> {
        let descriptor = self.registry.running.lock().unwrap().as_ref().unwrap().pidfd.as_raw_fd();
        wait_exit(descriptor)?;
        self.reap()
    }

    fn reap(&mut self) -> Result<ExitStatus, String> {
        let mut running = self.registry.running.lock().unwrap();
        let status = self.child.take().unwrap().wait();
        running.take();
        status.map_err(|e| format!("Could not reap GIO application child: {}.", e))
    }
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.child.is_none() { return; }
        if let Err(error) = self.registry.cancel() { eprintln!("flea: {}", error); }
        if let Err(error) = self.reap() { eprintln!("flea: {}", error); }
    }
}

fn terminate(pid: i32, group: bool) -> Result<(), String> {
    if unsafe { kill(if group { -pid } else { pid }, SIGKILL) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(ESRCH) { return Err(format!("Could not cancel owned GIO child: {}.", error)); }
    }
    Ok(())
}

fn cancelled(cancel: &Cancellation) -> Result<(), String> {
    cancel.check().map_err(|_| "Application query cancelled.".into())
}

fn reader(pipe: impl Read + Send + 'static, registry: Registry) -> Result<std::thread::JoinHandle<Result<Vec<u8>, String>>, String> {
    std::thread::Builder::new().spawn(move || {
        let mut bytes = Vec::new();
        if let Err(error) = pipe.take(MAX_REGISTRY_BYTES + 1).read_to_end(&mut bytes) {
            registry.cancel()?;
            return Err(format!("Could not read GIO application query: {}.", error));
        }
        if bytes.len() as u64 > MAX_REGISTRY_BYTES {
            registry.cancel()?;
            return Err(format!("GIO application registry response exceeds {} bytes.", MAX_REGISTRY_BYTES));
        }
        Ok(bytes)
    }).map_err(|e| format!("Could not start GIO output reader: {}.", e))
}

fn wait_exit(fd: i32) -> Result<(), String> {
    loop {
        let mut descriptor = PollFd { fd, events: POLLIN, revents: 0 };
        let result = unsafe { poll(&mut descriptor, 1, -1) };
        if result > 0 && descriptor.revents & POLLIN != 0 { return Ok(()); }
        let error = std::io::Error::last_os_error();
        if result < 0 && error.raw_os_error() == Some(EINTR) { continue; }
        return Err(format!("Could not wait for GIO application query: {}.", error));
    }
}

pub(crate) struct Application { pub id: String, pub label: String, pub path: PathBuf }

pub(crate) fn applications(registry: &Registry, path: &Path, cancel: &Cancellation) -> Result<Vec<Application>, String> {
    let info = registry.query(&["info".as_ref(), "--nofollow-symlinks".as_ref(), "--attributes=standard::content-type".as_ref(), path.as_os_str()], cancel)?;
    // Sample GIO info attribute: "  standard::content-type: text/plain".
    let mime = info.lines().find_map(|line| line.trim().strip_prefix("standard::content-type: "))
        .filter(|m| !m.is_empty()).ok_or("GIO did not report the selected item's content type.")?;
    let output = registry.query(&["mime".as_ref(), mime.as_ref()], cancel)?;
    let mut apps = Vec::new();
    // Sample GIO mime registry row: "  org.gnome.TextEditor.desktop".
    for line in output.lines().filter(|line| line.starts_with("  ")) {
        cancelled(cancel)?;
        let id = line.trim();
        if !id.ends_with(".desktop") || id.contains('/') || id.contains('\0') || apps.iter().any(|a: &Application| a.id == id) { continue; }
        if let Some(path) = desktop_file(id, cancel)? {
            let label = desktop_label(&path)?.unwrap_or_else(|| id.trim_end_matches(".desktop").into());
            apps.push(Application { id: id.into(), label, path });
        }
    }
    Ok(apps)
}

fn desktop_file(id: &str, cancel: &Cancellation) -> Result<Option<PathBuf>, String> {
    let mut roots = Vec::new();
    if let Some(home) = std::env::var_os("XDG_DATA_HOME").filter(|p| !p.is_empty()) {
        roots.push(PathBuf::from(home));
    } else if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join(".local/share"));
    }
    roots.extend(std::env::split_paths(&std::env::var_os("XDG_DATA_DIRS").filter(|p| !p.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into())));
    for root in roots.into_iter().filter(|root| root.is_absolute()) {
        cancelled(cancel)?;
        let apps = root.join("applications");
        let direct = apps.join(id);
        if direct.is_file() { return Ok(Some(direct)); }
        let mut pending = vec![apps.clone()];
        while let Some(dir) = pending.pop() {
            cancelled(cancel)?;
            let Ok(entries) = std::fs::read_dir(dir) else { continue; };
            for entry in entries.flatten() {
                cancelled(cancel)?;
                let Ok(kind) = entry.file_type() else { continue; };
                let path = entry.path();
                if kind.is_dir() { pending.push(path); }
                else if path.strip_prefix(&apps).map(|relative| relative.to_string_lossy().replace('/', "-") == id).unwrap_or(false) && path.is_file() { return Ok(Some(path)); }
            }
        }
    }
    Ok(None)
}

// Sample Desktop Entry: "[Desktop Entry]\nName=Text Editor\nExec=editor %U"; GIO alone interprets Exec.
fn desktop_label(path: &Path) -> Result<Option<String>, String> {
    let file = super::regfile::open_if_regular(path, 0).map_err(|e| format!("Could not read application {}: {}.", path.display(), e))?;
    let mut bytes = Vec::new();
    file.take(MAX_REGISTRY_BYTES + 1).read_to_end(&mut bytes).map_err(|e| format!("Could not read application {}: {}.", path.display(), e))?;
    if bytes.len() as u64 > MAX_REGISTRY_BYTES { return Err(format!("Application {} exceeds the {} byte metadata limit.", path.display(), MAX_REGISTRY_BYTES)); }
    let text = std::str::from_utf8(&bytes).map_err(|_| format!("Application {} is not valid UTF-8.", path.display()))?;
    let mut entry = false;
    for line in text.lines() {
        if line.starts_with('[') { entry = line == "[Desktop Entry]"; }
        if entry {
            if let Some(name) = line.strip_prefix("Name=") { return Ok(Some(name.replace("\\s", " ").replace("\\n", " "))); }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;
    use std::time::{Duration, Instant};

    fn started(registry: &Registry) -> i32 {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Some(child) = registry.running.lock().unwrap().as_ref() { return child.pid; }
            std::thread::yield_now();
        }
        panic!("the owned GIO child did not start");
    }

    struct TestApplication(Child);
    impl Drop for TestApplication {
        fn drop(&mut self) {
            if matches!(self.0.try_wait(), Ok(None)) {
                if let Err(error) = self.0.kill() { eprintln!("test application cleanup: {}", error); }
            }
            if let Err(error) = self.0.wait() { eprintln!("test application reap: {}", error); }
        }
    }

    #[test]
    fn closing_a_query_kills_its_process_group_and_releases_the_service() {
        let registry = Registry::default();
        let cancel = Cancellation::default();
        let (sent, received) = channel();
        let running = registry.clone();
        let generation = cancel.clone();
        let worker = std::thread::spawn(move || {
            let mut command = Command::new("/bin/sh");
            command.args(["-c", "sleep 600 & wait"]);
            sent.send(running.capture(&mut command, &generation)).unwrap();
        });
        started(&registry);
        cancel.next();
        registry.cancel().unwrap();
        assert!(received.recv_timeout(Duration::from_secs(5)).unwrap().unwrap_err().contains("cancelled"));
        worker.join().unwrap();
        assert!(registry.running.lock().unwrap().is_none());
        let mut next = Command::new("/usr/bin/printf");
        next.arg("ready");
        assert_eq!(registry.capture(&mut next, &Cancellation::default()).unwrap(), "ready");
    }

    #[test]
    fn cancelling_a_launcher_preserves_an_application_in_its_process_group() {
        let registry = Registry::default();
        let cancel = Cancellation::default();
        let (sent, received) = channel();
        let running = registry.clone();
        let generation = cancel.clone();
        let worker = std::thread::spawn(move || {
            let mut command = Command::new("/usr/bin/sleep");
            command.arg("600");
            sent.send(running.launch_command(&mut command, &generation)).unwrap();
        });
        let group = started(&registry);
        let mut application = TestApplication(Command::new("/usr/bin/sleep").arg("600")
            .process_group(group).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap());
        assert!(!registry.running.lock().unwrap().as_ref().unwrap().group);
        cancel.next();
        registry.cancel().unwrap();
        assert!(received.recv_timeout(Duration::from_secs(5)).unwrap().unwrap_err().contains("cancelled"));
        worker.join().unwrap();
        assert!(application.0.try_wait().unwrap().is_none(), "cancelling the chooser must not kill an application sharing the launcher's group");
        assert!(registry.running.lock().unwrap().is_none());
        assert!(registry.launch_command(&mut Command::new("/usr/bin/true"), &Cancellation::default()).is_ok());
    }

    #[test]
    fn early_failure_reaps_the_owned_query_before_the_next_request() {
        let registry = Registry::default();
        let mut command = Command::new("/usr/bin/sleep");
        command.arg("600").stdout(Stdio::null()).stderr(Stdio::null());
        let owned = OwnedChild::start(&mut command, &registry, &Cancellation::default(), true).unwrap();
        let descriptor = registry.running.lock().unwrap().as_ref().unwrap().pidfd.try_clone().unwrap();
        drop(owned);
        assert!(registry.running.lock().unwrap().is_none());
        assert!(wait_exit(descriptor.as_raw_fd()).is_ok());
        assert!(registry.launch_command(&mut Command::new("/usr/bin/true"), &Cancellation::default()).is_ok());
    }

    #[test]
    fn desktop_metadata_is_bounded_and_missing_files_are_named() {
        let d = crate::backend::testdir::TestDir::new("menu-desktop");
        let valid = d.file("valid.desktop", "[Desktop Entry]\nName=Text\\sEditor\nExec=editor %U\n");
        assert_eq!(desktop_label(&valid).unwrap().as_deref(), Some("Text Editor"));
        let link = d.join("linked.desktop");
        std::os::unix::fs::symlink(&valid, &link).unwrap();
        assert_eq!(desktop_label(&link).unwrap().as_deref(), Some("Text Editor"));
        let fifo = d.join("fifo.desktop");
        crate::backend::fifotest::mkfifo(&fifo);
        assert!(crate::backend::fifotest::within("desktop_label", move || desktop_label(&fifo)).unwrap_err().contains("not a regular file"));
        let missing = d.join("missing.desktop");
        assert!(desktop_label(&missing).unwrap_err().contains("missing.desktop"));
        let large = d.join("large.desktop");
        std::fs::write(&large, vec![b'x'; MAX_REGISTRY_BYTES as usize + 1]).unwrap();
        assert!(desktop_label(&large).unwrap_err().contains("metadata limit"));
        let cancel = Cancellation::default();
        cancel.next();
        assert!(desktop_file("valid.desktop", &cancel).unwrap_err().contains("cancelled"));
    }

    #[test]
    fn unavailable_failed_and_oversized_queries_are_named_errors() {
        let registry = Registry::default();
        let cancel = Cancellation::default();
        assert!(registry.capture(&mut Command::new("/definitely-missing-gio-test-helper"), &cancel).unwrap_err().contains("Could not start"));
        assert!(registry.capture(&mut Command::new("/usr/bin/false"), &cancel).unwrap_err().contains("query failed"));
        let mut large = Command::new("/usr/bin/head");
        large.args(["-c", &(MAX_REGISTRY_BYTES + 1).to_string(), "/dev/zero"]);
        assert!(registry.capture(&mut large, &cancel).unwrap_err().contains("exceeds"));
        assert!(registry.running.lock().unwrap().is_none());
    }
}
