use std::io::{self, Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

static STOP: AtomicBool = AtomicBool::new(false);
const SIGINT: i32 = 2;
const SIGTERM: i32 = 15;
const SIGHUP: i32 = 1;
#[repr(C)]
struct WindowSize {
    rows: u16,
    columns: u16,
    x: u16,
    y: u16,
}
extern "C" {
    fn ioctl(fd: i32, request: usize, ...) -> i32;
    fn signal(sig: i32, handler: usize) -> usize;
}
extern "C" fn stop(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}

pub struct Terminal {
    saved: String,
    handlers: Vec<(i32, usize)>,
}
impl Terminal {
    pub fn enter() -> io::Result<Self> {
        let output = Command::new("stty")
            .arg("-g")
            .stdin(Stdio::inherit())
            .output()?;
        if !output.status.success() {
            return Err(io::Error::other("stty could not read terminal mode"));
        }
        let mut terminal = Self {
            saved: String::from_utf8_lossy(&output.stdout).trim().to_owned(),
            handlers: Vec::new(),
        };
        if terminal.saved.is_empty() {
            return Err(io::Error::other("stty returned an empty terminal mode"));
        }
        if !Command::new("stty")
            .args(["raw", "-echo", "min", "0", "time", "1"])
            .status()?
            .success()
        {
            return Err(io::Error::other("stty could not enter raw mode"));
        }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            terminal
                .handlers
                .push((sig, unsafe { signal(sig, stop as *const () as usize) }));
        }
        print!("\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[>1u\x1b[c");
        io::stdout().flush()?;
        Ok(terminal)
    }
    pub fn stopped(&self) -> bool {
        STOP.load(Ordering::Relaxed)
    }
    pub fn read(&self) -> io::Result<Vec<u8>> {
        let mut bytes = [0; 256];
        let n = io::stdin().read(&mut bytes)?;
        Ok(bytes[..n].to_vec())
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        print!("\x1b[<u\x1b[?1002l\x1b[?1006l\x1b[?2004l\x1b[0m\x1b[?25h\x1b[?1049l");
        let _ = io::stdout().flush();
        let _ = Command::new("stty").arg(&self.saved).status();
        for &(sig, handler) in &self.handlers {
            unsafe {
                signal(sig, handler);
            }
        }
    }
}
fn measured() -> Option<WindowSize> {
    #[cfg(target_os = "linux")]
    const GET_WINDOW_SIZE: usize = 0x5413;
    #[cfg(not(target_os = "linux"))]
    const GET_WINDOW_SIZE: usize = 0x40087468;
    let mut size = WindowSize {
        rows: 0,
        columns: 0,
        x: 0,
        y: 0,
    };
    if unsafe { ioctl(1, GET_WINDOW_SIZE, &mut size) } == 0 && size.columns > 0 && size.rows > 0 {
        Some(size)
    } else {
        None
    }
}

pub fn size() -> (usize, usize) {
    measured()
        .map(|size| (size.columns as usize, size.rows as usize))
        .unwrap_or((80, 24))
}

pub fn cell_pixels() -> Option<(usize, usize)> {
    let size = measured()?;
    let width = usize::from(size.x) / usize::from(size.columns);
    let height = usize::from(size.y) / usize::from(size.rows);
    (width > 0 && height > 0).then_some((width, height))
}
