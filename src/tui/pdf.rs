use super::{
    graphics::{kitty, Protocol},
    job::Job,
};
use std::path::PathBuf;

pub struct Pdf {
    pub path: PathBuf,
    pub page: usize,
    pub pages: usize,
    pub zoom: usize,
    pub scroll: usize,
    pub control: usize,
    pub bytes: Vec<u8>,
    pub error: String,
    pub columns: usize,
    pub rows: usize,
    pub pixels: (usize, usize),
    protocol: Protocol,
    info: Option<Job>,
    image: Option<Job>,
}
impl Pdf {
    pub fn new(
        path: PathBuf,
        protocol: Protocol,
        columns: usize,
        rows: usize,
        pixels: (usize, usize),
    ) -> Self {
        let info = Some(Job::start(
            path.clone(),
            vec!["/usr/bin/pdfinfo".into(), "{input}".into()],
        ));
        let mut pdf = Self {
            path,
            page: 1,
            pages: 0,
            zoom: 100,
            scroll: 0,
            control: 0,
            bytes: Vec::new(),
            error: String::new(),
            columns,
            rows,
            pixels,
            protocol,
            info,
            image: None,
        };
        pdf.refresh();
        pdf
    }
    pub fn refresh(&mut self) {
        if self.protocol == Protocol::None {
            return;
        }
        let (width, height) = self.pixels;
        let format = if self.protocol == Protocol::Kitty {
            "png:-"
        } else {
            "sixel:-"
        };
        // The script has only numeric positional arguments; /input is the sandbox's held file descriptor.
        let script="/usr/bin/pdftoppm -f \"$1\" -l \"$1\" -singlefile -scale-to \"$2\" -png /input | /usr/bin/magick png:- -resize \"$3\" -resize \"$4\" -crop \"$5\" +repage \"$6\"";
        self.image = Some(Job::start(
            self.path.clone(),
            vec![
                "/usr/bin/bash".into(),
                "-o".into(),
                "pipefail".into(),
                "-c".into(),
                script.into(),
                "flea-pdf".into(),
                self.page.to_string(),
                width.max(height).saturating_mul(3).min(4096).to_string(),
                format!("{}x{}", width, height),
                format!("{}%", self.zoom),
                format!("{}x{}+0+{}", width, height, self.scroll),
                format.into(),
            ],
        ));
    }
    pub fn poll(&mut self) -> bool {
        let mut changed = false;
        if let Some(info) = &self.info {
            if let Ok(result) = info.result.try_recv() {
                self.info = None;
                match result {
                    Ok(bytes) => self.pages = pages(&String::from_utf8_lossy(&bytes)),
                    Err(e) => self.error = e,
                }
                changed = true;
            }
        }
        if let Some(image) = &self.image {
            if let Ok(result) = image.result.try_recv() {
                self.image = None;
                match result {
                    Ok(bytes) => {
                        self.bytes = if self.protocol == Protocol::Kitty {
                            kitty(&bytes, self.columns, self.rows)
                        } else {
                            bytes
                        }
                    }
                    Err(e) => self.error = e,
                }
                changed = true;
            }
        }
        changed
    }
    pub fn turn(&mut self, delta: isize) {
        let next = (self.page as isize + delta).max(1) as usize;
        let next = if self.pages > 0 {
            next.min(self.pages)
        } else {
            1
        };
        if next != self.page {
            self.page = next;
            self.scroll = 0;
            self.refresh();
        }
    }
    pub fn zoom(&mut self, delta: isize) {
        let next = (self.zoom as isize + delta * 25).clamp(50, 300) as usize;
        if next != self.zoom {
            self.zoom = next;
            self.scroll = 0;
            self.refresh();
        }
    }
    pub fn scroll(&mut self, delta: isize) {
        let next = (self.scroll as isize + delta * (self.pixels.1 / self.rows.max(1)) as isize)
            .max(0)
            .min(self.pixels.1 as isize * 2) as usize;
        if next != self.scroll {
            self.scroll = next;
            self.refresh();
        }
    }
    pub fn prefix(&self) -> String {
        format!("Page {} / {} · {}%  ", self.page, if self.pages == 0 { "?".into() } else { self.pages.to_string() }, self.zoom)
    }
    pub fn control_at(&self, cell: usize, quicklook: bool) -> Option<usize> {
        let mut x = 0;
        for index in 0..if quicklook { 6 } else { 5 } {
            let width = if index == self.control { 3 } else { 1 };
            if cell >= x && cell < x + width { return Some(index); }
            x += width + 2;
        }
        None
    }
    pub fn line(&self, quicklook: bool) -> String {
        let labels = ["‹", "›", "−", "+", "↗", "×"];
        let buttons = labels
            .iter()
            .take(if quicklook { 6 } else { 5 })
            .enumerate()
            .map(|(i, label)| {
                if i == self.control {
                    format!("[{}]", label)
                } else {
                    label.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("  ");
        buttons
    }
}
// Sample input: Pages:           12
fn pages(text: &str) -> usize {
    text.lines()
        .find_map(|line| {
            line.strip_prefix("Pages:")
                .and_then(|v| v.trim().parse().ok())
        })
        .unwrap_or(0)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn page_count_uses_named_fact() {
        assert_eq!(pages("Title: 99\nPages: 12\n"), 12);
        assert_eq!(pages("Pages: unknown"), 0);
    }
}
