use super::{
    keymap::Map,
    model::{Model, Row},
    theme::Theme,
};
use std::io::{self, Write};

extern "C" {
    fn wcwidth(c: i32) -> i32;
    fn ctime_r(time: *const i64, buffer: *mut std::ffi::c_char) -> *mut std::ffi::c_char;
}
pub fn clean(text: &str) -> String {
    text.chars().filter(|c| safe(*c)).collect()
}
pub fn safe(c: char) -> bool { !c.is_control() && !matches!(c,'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'|'\u{200e}'|'\u{200f}'|'\u{061c}') }
fn width(c: char) -> usize {
    let n = unsafe { wcwidth(c as i32) };
    if n < 0 {
        1
    } else {
        n as usize
    }
}
pub fn text_width(text: &str) -> usize { clean(text).chars().map(width).sum() }
pub struct Wrapped<'a> { remaining: Option<&'a str>, columns: usize }
impl<'a> Wrapped<'a> {
    pub fn new(text: &'a str, columns: usize) -> Self { Self { remaining: (columns > 0).then_some(text), columns } }
}
impl<'a> Iterator for Wrapped<'a> {
    type Item = &'a str;
    fn next(&mut self) -> Option<Self::Item> {
        let text = self.remaining.take()?;
        let mut used = 0;
        for (offset, c) in text.char_indices() {
            let cells = width(c);
            if used + cells > self.columns && offset > 0 {
                self.remaining = Some(&text[offset..]);
                return Some(&text[..offset]);
            }
            used += cells;
        }
        Some(text)
    }
}
pub fn panes(columns: usize, preview: bool) -> (usize, usize, usize) {
    let left = columns * 22 / 100;
    let middle = if preview { columns * 40 / 100 } else { columns.saturating_sub(left + 1) };
    (left, middle, if preview { columns.saturating_sub(left + middle + 2) } else { 0 })
}
pub fn fit(text: &str, limit: usize) -> String {
    let mut result = String::new();
    let mut used = 0;
    for c in clean(text).chars() {
        let n = width(c);
        if used + n > limit {
            break;
        }
        result.push(c);
        used += n;
    }
    result.push_str(&" ".repeat(limit - used));
    result
}
pub fn bytes(n: usize) -> String {
    const BYTES_PER_UNIT: f64 = 1000.0;
    const UNITS: [&str; 5] = ["B", "kB", "MB", "GB", "TB"];
    if n < BYTES_PER_UNIT as usize { return format!("{} B", n); }
    let mut value = n as f64;
    let mut unit = 0;
    while value >= BYTES_PER_UNIT && unit < UNITS.len() - 1 { value /= BYTES_PER_UNIT; unit += 1; }
    format!("{:.1} {}", value, UNITS[unit])
}
pub fn modified(mtime: i64) -> String {
    if mtime <= 0 { return String::new(); }
    const SECONDS_PER_MINUTE: u64 = 60;
    const SECONDS_PER_HOUR: u64 = 3600;
    const SECONDS_PER_DAY: u64 = 86400;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();
    let age = now.saturating_sub(mtime as u64);
    if age < SECONDS_PER_HOUR { return format!("{} min", age / SECONDS_PER_MINUTE); }
    if age < SECONDS_PER_DAY { return format!("{} h", age / SECONDS_PER_HOUR); }
    if age < SECONDS_PER_DAY * 7 { return format!("{} d", age / SECONDS_PER_DAY); }
    let mut buffer = [0; 32];
    if unsafe { ctime_r(&mtime, buffer.as_mut_ptr()) }.is_null() { return String::new(); }
    // Sample input: Mon Sep  7 23:16:02 2026; ctime_r supplies the local calendar without a subprocess.
    let stamp = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy();
    let parts: Vec<&str> = stamp.split_whitespace().collect();
    if parts.len() >= 3 { format!("{} {}", parts[1], parts[2]) } else { String::new() }
}
fn row(row: &Row, columns: usize) -> String {
    let mark = if !row.link.is_empty() {
        "@"
    } else if row.directory {
        "›"
    } else if row.mode & 0o111 != 0 {
        "*"
    } else {
        "□"
    };
    let label = format!(
        "{} {}{}{}",
        mark,
        row.name,
        if row.directory { "/" } else { "" },
        if row.link.is_empty() {
            String::new()
        } else {
            format!(" → {}", row.link)
        }
    );
    if columns > 18 && row.link.is_empty() {
        let size = if row.directory { modified(row.modified) } else { bytes(row.size) };
        format!("{} {}", fit(&label, columns - size.len() - 1), size)
    } else {
        fit(&label, columns)
    }
}
pub fn draw(
    m: &Model,
    theme: &Theme,
    map: &Map,
    columns: usize,
    lines: usize,
    elapsed: std::time::Duration,
    last: &mut String,
) -> io::Result<bool> {
    if columns < 12 || lines < 4 {
        print!("\x1b[H\x1b[2J{}", fit("Window too small", columns));
        io::stdout().flush()?;
        return Ok(true);
    }
    let (left, middle, right) = panes(columns, m.preview_visible);
    let body = lines - 2;
    let graphical = m.player.is_some() || m.pdf.is_some() || m.image_file.is_some();
    let details = m.preview_metadata.len().min(3);
    let details_start = body.saturating_sub(2 + details);
    let base = format!("\x1b[0m{}{}", theme.background, theme.foreground);
    let mut out = format!("\x1b[H{}", base);
    let home = std::env::var("HOME").unwrap_or_default();
    let path = if !home.is_empty() && m.path.starts_with(&home) { format!("~{}", &m.path.to_string_lossy()[home.len()..]) } else { m.path.to_string_lossy().into_owned() };
    let title = format!(
        "{} · {} {}",
        path,
        m.sort,
        if m.reverse { "▾" } else { "▴" }
    );
    let title_width = text_width(&title).min(columns / 2);
    let mut used = 0;
    for (i, tab) in m.tabs.iter().enumerate() {
        let label = format!("{} {}  ", i + 1, tab.path.file_name().unwrap_or_default().to_string_lossy());
        let width = text_width(&label);
        if used + width > columns.saturating_sub(title_width) { break; }
        out.push_str(if i == m.tab { &theme.accent } else { &theme.foreground });
        out.push_str(&clean(&label));
        used += width;
    }
    out.push_str(&base);
    out.push_str(&" ".repeat(columns.saturating_sub(used + title_width)));
    out.push_str(&fit(&title, title_width));
    for y in 0..body {
        out.push_str(&format!("\x1b[{};1H{}", y + 2, base));
        if m.quicklook {
            let content = if m.selected.len() > 1 {
                selection_line(m, y, columns)
            } else if y == body.saturating_sub(2) {
                m.player
                    .as_ref()
                    .map(|p| p.line(columns))
                    .or_else(|| m.pdf.as_ref().map(|p| p.line(true)))
                    .unwrap_or_default()
            } else if graphical && y >= details_start && y < details_start + details {
                m.preview_metadata[y - details_start].clone()
            } else if graphical && y >= 2 { String::new() } else {
                m.preview_display
                    .get(y)
                    .cloned()
                    .unwrap_or_default()
            };
            out.push_str(&fit(&content, columns));
            continue;
        }
        if let Some(parent) = m.parents.get(y) {
            if m.path.file_name().is_some_and(|name| name == parent.name.as_str()) { out.push_str(&theme.selected); }
            let label = format!("{} {}", if parent.directory { "›" } else { "□" }, parent.name);
            out.push_str(&fit(&label, left));
        } else { out.push_str(&" ".repeat(left)); }
        out.push_str(&base);
        out.push_str(&theme.border);
        out.push('│');
        out.push_str(&base);
        let index = if m.filter.is_empty() {
            m.top + y
        } else {
            m.shown().get(y).copied().unwrap_or(usize::MAX)
        };
        if let Some(entry) = m.rows.get(&index) {
            if index == m.cursor {
                out.push_str(&theme.accent);
                out.push_str("\x1b[7m");
            } else if m.selected.contains(&index) {
                out.push_str(&theme.selected);
            } else if !entry.link.is_empty() {
                out.push_str(&theme.symlink);
            } else if entry.mode & 0o111 != 0 && !entry.directory {
                out.push_str(&theme.executable);
            }
            out.push_str(&row(entry, middle));
            out.push_str(&base);
        } else if m.total == 0 {
            if m.pending.is_some() {
                out.push_str(&fit(if y == body / 2 { "Loading…" } else { "" }, middle));
            } else {
                out.push_str(&super::empty::line(y, body, middle, elapsed));
            }
        } else {
            out.push_str(&" ".repeat(middle));
        }
        if !m.preview_visible { continue; }
        out.push_str(&theme.border);
        out.push('│');
        out.push_str(&base);
        let preview = if y == body.saturating_sub(2) && (m.player.is_some() || m.pdf.is_some()) {
            m.player
                .as_ref()
                .map(|p| p.line(right))
                .or_else(|| m.pdf.as_ref().map(|p| p.line(false)))
                .unwrap_or_default()
        } else if m.selected.len() > 1 {
            selection_line(m, y, right)
        } else if graphical && y >= details_start && y < details_start + details {
            m.preview_metadata[y - details_start].clone()
        } else if graphical && y >= 2 {
            String::new()
        } else if m.preview_visible || m.quicklook {
            m.preview_display
                .get(y)
                .cloned()
                .unwrap_or_default()
        } else {
            String::new()
        };
        out.push_str(if m.selected.len() > 1 && y == 0 { &theme.accent } else { &theme.foreground });
        out.push_str(&fit(&preview, right));
        out.push_str(&base);
    }
    out.push_str(&format!("\x1b[{};1H{}", lines, base));
    let status = if m.editor.is_some() {
        String::new()
    } else {
        let primary = if !m.error.is_empty() {
            &m.error
        } else if !m.transfer.is_empty() {
            &m.transfer
        } else if !m.search.is_empty() {
            &m.search
        } else {
            &m.message
        };
        let secondary = if !m.search.is_empty() && primary != &m.search {
            format!(" · {}", m.search)
        } else {
            String::new()
        };
        let progress = if !m.transfer.is_empty() && primary == &m.transfer {
            const FRAMES: [&str; 3] = ["░▒▓", "▒▓░", "▓░▒"];
            format!(" {}", FRAMES[(elapsed.as_millis() / 200) as usize % FRAMES.len()])
        } else { String::new() };
        format!(
            "{}{} items  {}{}{}  ? keys",
            if m.selected.is_empty() {
                String::new()
            } else {
                format!("V {}  ", m.selected.len())
            },
            m.total,
            primary,
            progress,
            secondary
        )
    };
    if !m.error.is_empty() {
        out.push_str(&theme.error);
    }
    if let Some(editor) = &m.editor {
        let prefix = if editor.kind == "path" { ": ".into() } else { format!("{}: ", editor.kind) };
        let suffix = if editor.pending { " · Working…".into() }
            else if editor.kind == "path" { m.completion.strip_prefix(&editor.value).unwrap_or("").into() }
            else if editor.kind == "search" { format!(" · in {} · Tab changes scope", if m.search_here { path.clone() } else { "Home".into() }) }
            else { String::new() };
        out.push_str(&editor.line(&prefix, &suffix, columns, &base, &theme.muted));
    } else { out.push_str(&fit(&status, columns)); }
    if m.sheet {
        let sheet = map.sheet(&m.preset);
        overlay(
            &mut out,
            &sheet[m.sheet_top.min(sheet.len())..],
            columns,
            lines,
            &base,
            None,
            "keys",
            None,
        );
    }
    if m.menu {
        overlay(
            &mut out,
            &menu_rows(m),
            columns,
            lines,
            &base,
            Some(m.menu_cursor),
            if m.taildrop.submenu { "taildrop" } else { "open" },
            if !m.taildrop.submenu && m.taildrop.peers.is_empty() { Some((&theme.muted, 2)) } else { None },
        );
    }
    if *last != out {
        print!("{}\x1b[0m", out);
        io::stdout().flush()?;
        *last = out;
        return Ok(true);
    }
    Ok(false)
}
fn selection_line(m: &Model, y: usize, columns: usize) -> String {
    if y == 0 { return format!("{} items selected", m.selected.len()); }
    if y == 1 { return "─".repeat(columns); }
    if let Some(row) = m.selected_rows.values().nth(y - 2) {
        let size = bytes(row.size);
        return format!("{} {}", fit(&row.name, columns.saturating_sub(size.len() + 1)), size);
    }
    let footer = y.saturating_sub(m.selected_rows.len() + 2);
    if footer == 1 {
        if m.selected_rows.len() == m.selected.len() {
            let total = m.selected_rows.values().fold(0usize, |sum, row| sum.saturating_add(row.size));
            return format!("Selection total · {}", bytes(total));
        }
        return format!("{} marked items outside loaded rows", m.selected.len() - m.selected_rows.len());
    }
    if footer == 2 { return "Preview follows the marked set while visual mode is active.".into(); }
    String::new()
}
pub fn menu_rows(m: &Model) -> Vec<String> {
    if m.taildrop.submenu {
        return m.taildrop.peers.iter().map(|p| p.label.clone()).collect();
    }
    vec!["open".into(), "show hidden".into(), "taildrop  ▶".into()]
}
pub fn overlay_rect(rows: &[String], columns: usize, lines: usize) -> (usize, usize, usize, usize) {
    let width = rows.iter().map(|row| text_width(row)).max().unwrap_or(0).saturating_add(2).max(13).min(columns.saturating_sub(6));
    let count = rows.len().min(lines.saturating_sub(4));
    ((columns.saturating_sub(width + 2)) / 2, (lines.saturating_sub(count + 2)) / 2, width, count)
}
fn overlay(
    out: &mut String,
    rows: &[String],
    columns: usize,
    lines: usize,
    base: &str,
    selected: Option<usize>,
    title: &str,
    dim: Option<(&str, usize)>,
) {
    let (x, y, width, count) = overlay_rect(rows, columns, lines);
    let heading = format!("─ {} ", title);
    out.push_str(&format!(
        "\x1b[{};{}H{}┌{}{}┐",
        y + 1,
        x + 1,
        base,
        fit(&heading, text_width(&heading).min(width)),
        "─".repeat(width.saturating_sub(text_width(&heading)))
    ));
    for (i, row) in rows.iter().take(count).enumerate() {
        out.push_str(&format!(
            "\x1b[{};{}H{}│{}{}{}{}│",
            y + i + 2,
            x + 1,
            base,
            dim.filter(|(_, index)| *index == i).map(|(color, _)| color).unwrap_or(""),
            if selected == Some(i) { "\x1b[7m" } else { "" },
            fit(row, width),
            base
        ));
    }
    out.push_str(&format!(
        "\x1b[{};{}H{}└{}┘",
        y + count + 2,
        x + 1,
        base,
        "─".repeat(width)
    ));
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unsafe_names_cannot_emit_terminal_commands() {
        assert_eq!(clean("a\x1b]52;c;evil\x07\u{202e}b"), "a]52;c;evilb");
        assert_eq!(fit("abcdef", 3), "abc");
        assert_eq!(fit("a", 3), "a  ");
        assert_eq!(Wrapped::new("abcdef", 2).collect::<Vec<_>>(), vec!["ab", "cd", "ef"]);
        assert_eq!(Wrapped::new("", 2).collect::<Vec<_>>(), vec![""]);
        assert!(Wrapped::new("abc", 0).next().is_none());
        assert_eq!(panes(100, true), (22, 40, 36));
        assert_eq!(panes(100, false), (22, 77, 0));
        assert_eq!(bytes(999), "999 B");
        assert_eq!(bytes(1000), "1.0 kB");
        assert_eq!(bytes(1_200_000_000), "1.2 GB");
    }
}
