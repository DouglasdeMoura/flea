use super::{
    graphics::Protocol,
    wire::{number, text, word},
};
use crate::{
    backend::regfile,
    jsondoc::{self, Json},
    oflags::O_NOFOLLOW,
};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::{
    fd::AsRawFd,
    unix::{fs::MetadataExt, net::UnixStream},
};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

pub struct Player {
    child: Child,
    socket: UnixStream,
    events: Receiver<Json>,
    directory: PathBuf,
    _input: File,
    pub path: PathBuf,
    pub paused: bool,
    pub buffering: bool,
    pub position: f64,
    pub duration: f64,
    pub control: usize,
    pub error: String,
    pub geometry: (usize, usize, usize, usize),
    pub pixels: (usize, usize),
}
impl Player {
    pub fn start(
        path: &Path,
        protocol: Protocol,
        geometry: (usize, usize, usize, usize),
        terminal_size: (usize, usize),
        pixels: (usize, usize),
    ) -> io::Result<Self> {
        let before = fs::symlink_metadata(path)?;
        let input = regfile::open_if_regular(path, O_NOFOLLOW)?;
        let after = input.metadata()?;
        if before.dev() != after.dev() || before.ino() != after.ino() {
            return Err(io::Error::other("Selected item changed"));
        }
        let directory = temporary()?;
        let endpoint = directory.join("ipc");
        let driver = match protocol {
            Protocol::Kitty => "kitty",
            Protocol::Sixel => "sixel",
            Protocol::None => "null",
        };
        let mut command = Command::new("mpv");
        command.args([
            "--no-config",
            "--load-scripts=no",
            "--ytdl=no",
            "--pause=yes",
            "--keep-open=yes",
            "--terminal=no",
            "--input-default-bindings=no",
            "--input-vo-keyboard=no",
            "--force-window=no",
            "--osc=no",
            "--osd-level=0",
        ]);
        command
            .arg(format!("--vo={}", driver))
            .arg(format!("--input-ipc-server={}", endpoint.display()));
        if driver != "null" {
            for (option, value) in [
                ("cols", terminal_size.0),
                ("rows", terminal_size.1),
                ("width", pixels.0),
                ("height", pixels.1),
                ("left", geometry.2),
                ("top", geometry.3),
            ] {
                command.arg(format!("--vo-{}-{}={}", driver, option, value));
            }
            command.arg(format!("--vo-{}-alt-screen=no", driver));
        }
        command
            .arg("--")
            .arg(format!(
                "/proc/{}/fd/{}",
                std::process::id(),
                input.as_raw_fd()
            ))
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::null());
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                cleanup(&directory);
                return Err(error);
            }
        };
        let started = Instant::now();
        let socket = loop {
            if let Ok(socket) = UnixStream::connect(&endpoint) {
                break socket;
            }
            if child.try_wait()?.is_some() || started.elapsed() > Duration::from_secs(3) {
                let _ = child.kill();
                let _ = child.wait();
                cleanup(&directory);
                return Err(io::Error::other("mpv could not start the inline preview"));
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let reader = socket.try_clone()?;
        let (tx, events) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(reader).lines() {
                let Ok(line) = line else {
                    break;
                };
                if let Ok(value) = jsondoc::parse(&line) {
                    if tx.send(value).is_err() {
                        break;
                    }
                }
            }
        });
        let mut player = Self {
            child,
            socket,
            events,
            directory,
            _input: input,
            path: path.into(),
            paused: true,
            buffering: false,
            position: 0.0,
            duration: 0.0,
            control: 0,
            error: String::new(),
            geometry,
            pixels,
        };
        for (i, property) in ["time-pos", "duration", "pause", "paused-for-cache"]
            .iter()
            .enumerate()
        {
            player.command(vec![word("observe_property"), number(i), word(property)])?;
        }
        Ok(player)
    }
    pub fn command(&mut self, command: Vec<Json>) -> io::Result<()> {
        let value = Json::Obj(vec![("command".into(), Json::Arr(command))]);
        self.socket
            .write_all(jsondoc::render(&value).replace('\n', "").as_bytes())?;
        self.socket.write_all(b"\n")
    }
    pub fn poll(&mut self) {
        while let Ok(value) = self.events.try_recv() {
            if text(&value, "event") == "property-change" {
                let data = value.get("data").unwrap_or(&Json::Null);
                match text(&value, "name") {
                    "time-pos" => self.position = data.as_f64().unwrap_or(0.0),
                    "duration" => self.duration = data.as_f64().unwrap_or(0.0),
                    "pause" => self.paused = data.as_bool().unwrap_or(true),
                    "paused-for-cache" => self.buffering = data.as_bool().unwrap_or(false),
                    _ => {}
                }
            }
            if text(&value, "event") == "end-file" && text(&value, "reason") == "error" {
                self.error = "Could not play selected media".into();
            }
        }
    }
    pub fn toggle(&mut self) -> io::Result<()> {
        self.paused = !self.paused;
        self.command(vec![
            word("set_property"),
            word("pause"),
            Json::Bool(self.paused),
        ])
    }
    pub fn seek(&mut self, seconds: i32) -> io::Result<()> {
        self.command(vec![
            word("seek"),
            Json::Num(seconds.to_string()),
            word("relative"),
        ])
    }
    pub fn line(&self) -> String {
        format!(
            "{} {}  {} Seek  {} / {}{}",
            if self.control == 0 { "[" } else { " " },
            if self.paused { "Play]" } else { "Pause]" },
            if self.control == 1 {
                "[>]"
            } else {
                "───"
            },
            clock(self.position),
            clock(self.duration),
            if self.buffering { " · Buffering" } else { "" }
        )
    }
}
impl Drop for Player {
    fn drop(&mut self) {
        let _ = self.command(vec![word("quit")]);
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(500) {
            if self.child.try_wait().ok().flatten().is_some() {
                cleanup(&self.directory);
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        cleanup(&self.directory);
    }
}
fn clock(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as u64;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}
fn temporary() -> io::Result<PathBuf> {
    let output = Command::new("mktemp")
        .args(["-d", "/tmp/flea-tui-XXXXXX"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(
            "Could not create preview socket directory",
        ));
    }
    let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    if !path.is_absolute()
        || path.parent() != Some(Path::new("/tmp"))
        || !path
            .file_name()
            .is_some_and(|p| p.to_string_lossy().starts_with("flea-tui-"))
    {
        return Err(io::Error::other(
            "Preview socket directory is outside its sandbox",
        ));
    }
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path.join(".flea-tui-owned"))?
        .write_all(b"flea")?;
    Ok(path)
}
fn cleanup(root: &Path) {
    if !root.is_absolute()
        || root.parent() != Some(Path::new("/tmp"))
        || !root
            .file_name()
            .is_some_and(|p| p.to_string_lossy().starts_with("flea-tui-"))
        || !fs::symlink_metadata(root).is_ok_and(|m| m.file_type().is_dir())
        || fs::read(root.join(".flea-tui-owned")).ok().as_deref() != Some(b"flea")
    {
        return;
    }
    for name in ["ipc", ".flea-tui-owned"] {
        let path = root.join(name);
        if path.is_absolute() && path.starts_with(root) && path != root {
            let _ = fs::remove_file(path);
        }
    }
    let _ = fs::remove_dir(root);
}
