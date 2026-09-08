// Application discovery uses the same GIO registry that launches the selected desktop entry.
use super::trashmanifest::Cancellation;
use std::ffi::OsStr;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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
struct Running { pid: i32, pidfd: OwnedFd }

#[derive(Clone, Default)]
pub(crate) struct Registry { running: Arc<Mutex<Option<Running>>> }

impl Registry {
    pub fn cancel(&self) -> Result<(), String> {
        let running = self.running.lock().map_err(|_| "The application query service stopped.")?;
        if let Some(child) = running.as_ref() {
            // The query never reaps this child until it holds this lock, so its process-group id cannot be reused here.
            if unsafe { kill(-child.pid, SIGKILL) } != 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() != Some(ESRCH) { return Err(format!("Could not cancel GIO application query: {}.", error)); }
            }
        }
        Ok(())
    }

    fn query(&self, args: &[&OsStr], cancel: &Cancellation) -> Result<String, String> {
        let mut command = Command::new("gio");
        command.args(args).env("LC_ALL", "C");
        self.capture(&mut command, cancel)
    }

    fn capture(&self, command: &mut Command, cancel: &Cancellation) -> Result<String, String> {
        cancelled(cancel)?;
        let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0)
            .spawn().map_err(|e| format!("Could not start GIO application query: {}.", e))?;
        let raw = unsafe { pidfd_open(child.id() as i32, 0) };
        if raw < 0 {
            let error = std::io::Error::last_os_error();
            unsafe { kill(-(child.id() as i32), SIGKILL); }
            let _ = child.wait();
            return Err(format!("Could not observe GIO application query: {}.", error));
        }
        *self.running.lock().unwrap() = Some(Running { pid: child.id() as i32, pidfd: unsafe { OwnedFd::from_raw_fd(raw) } });
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let result = (|| {
            if cancelled(cancel).is_err() { self.cancel()?; }
            let output = reader(stdout, self.clone())?;
            let errors = match reader(stderr, self.clone()) {
                Ok(reader) => reader,
                Err(error) => {
                    self.cancel()?;
                    let _ = output.join();
                    return Err(error);
                }
            };
            let output = output.join().map_err(|_| "GIO output reader stopped.".to_string())?;
            let errors = errors.join().map_err(|_| "GIO error reader stopped.".to_string())?;
            output.and_then(|bytes| errors.map(|errors| (bytes, errors)))
        })();
        if result.is_err() { self.cancel()?; }
        let descriptor = self.running.lock().unwrap().as_ref().unwrap().pidfd.as_raw_fd();
        let wait_result = wait_exit(descriptor);
        if wait_result.is_err() { self.cancel()?; }
        // poll reports exit without reaping; keep the child identity owned until cancellation can no longer use it.
        let status = {
            let mut running = self.running.lock().unwrap();
            let status = child.wait();
            running.take();
            status
        }.map_err(|e| format!("Could not reap GIO application query: {}.", e))?;
        wait_result?;
        cancelled(cancel)?;
        let (stdout, stderr) = result?;
        if !status.success() {
            let detail = String::from_utf8_lossy(&stderr);
            return Err(format!("GIO application query failed: {}.", detail.lines().last().unwrap_or("no diagnostic")));
        }
        String::from_utf8(stdout).map_err(|_| "GIO returned invalid application registry text.".into())
    }
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
        let id = line.trim();
        if !id.ends_with(".desktop") || id.contains('/') || id.contains('\0') || apps.iter().any(|a: &Application| a.id == id) { continue; }
        if let Some(path) = desktop_file(id) {
            let label = desktop_label(&path).unwrap_or_else(|| id.trim_end_matches(".desktop").into());
            apps.push(Application { id: id.into(), label, path });
        }
    }
    Ok(apps)
}

fn desktop_file(id: &str) -> Option<PathBuf> {
    let mut roots = Vec::new();
    if let Some(home) = std::env::var_os("XDG_DATA_HOME").filter(|p| !p.is_empty()) {
        roots.push(PathBuf::from(home));
    } else if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join(".local/share"));
    }
    roots.extend(std::env::split_paths(&std::env::var_os("XDG_DATA_DIRS").filter(|p| !p.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into())));
    for root in roots.into_iter().filter(|root| root.is_absolute()) {
        let apps = root.join("applications");
        let direct = apps.join(id);
        if direct.is_file() { return Some(direct); }
        let mut pending = vec![apps.clone()];
        while let Some(dir) = pending.pop() {
            let Ok(entries) = std::fs::read_dir(dir) else { continue; };
            for entry in entries.flatten() {
                let Ok(kind) = entry.file_type() else { continue; };
                let path = entry.path();
                if kind.is_dir() { pending.push(path); }
                else if path.strip_prefix(&apps).ok()?.to_string_lossy().replace('/', "-") == id && path.is_file() { return Some(path); }
            }
        }
    }
    None
}

// Sample Desktop Entry: "[Desktop Entry]\nName=Text Editor\nExec=editor %U"; GIO alone interprets Exec.
fn desktop_label(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut entry = false;
    for line in text.lines() {
        if line.starts_with('[') { entry = line == "[Desktop Entry]"; }
        if entry {
            if let Some(name) = line.strip_prefix("Name=") { return Some(name.replace("\\s", " ").replace("\\n", " ")); }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;
    use std::time::{Duration, Instant};

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
        let deadline = Instant::now() + Duration::from_secs(5);
        while registry.running.lock().unwrap().is_none() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(registry.running.lock().unwrap().is_some(), "the query must start before cancellation is exercised");
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
