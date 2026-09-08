use super::model::Model;
use crate::backend::regfile;
use crate::oflags::O_NOFOLLOW;
use std::io::Read;
use std::os::unix::fs::MetadataExt;

const TEXT_BYTES: u64 = 1024 * 1024;
pub fn load(m: &mut Model, force: bool) {
    if m.selected.len() > 1 || (!m.preview_visible && !m.quicklook) {
        return;
    }
    let Some(path) = m.current_path() else {
        return;
    };
    if !force && path == m.preview_path {
        return;
    }
    m.preview_path = path.clone();
    m.preview_loaded = force || m.preview_auto || m.quicklook;
    m.preview_generation = m.preview_generation.wrapping_add(1);
    m.preview_failed = None;
    m.preview_scroll = 0;
    m.preview.clear();
    m.preview_body.clear();
    m.preview_metadata.clear();
    m.preview_children = None;
    let Some(row) = m.rows.get(&m.cursor) else {
        return;
    };
    m.preview.push(row.name.clone());
    m.preview
        .push(format!("{} · {}", row.kind, super::render::bytes(row.size)));
    if row.modified > 0 { m.preview_metadata.push(format!("Modified · {}", super::render::modified(row.modified))); }
    if !row.link.is_empty() {
        m.preview.push(format!("→ {}", row.link));
        return;
    }
    if !m.preview_loaded {
        m.preview.push("Ctrl+Space to load preview".into());
        return;
    }
    if row.directory {
        m.preview.push("Folder".into());
        return;
    }
    if !row.icon.starts_with("text") && !row.kind.to_lowercase().contains("source")
    {
        return;
    }
    if row.size as u64 > TEXT_BYTES {
        m.preview.push("This file is too large to preview.".into());
        return;
    }
    let before = match std::fs::symlink_metadata(&path) {
        Ok(v) => v,
        Err(_) => {
            m.preview.push("This file could not be read.".into());
            return;
        }
    };
    let file = match regfile::open_if_regular(&path, O_NOFOLLOW) {
        Ok(v) => v,
        Err(_) => {
            m.preview.push("This file could not be read.".into());
            return;
        }
    };
    if !file
        .metadata()
        .is_ok_and(|after| before.dev() == after.dev() && before.ino() == after.ino())
    {
        m.preview.push("Selected item changed".into());
        return;
    }
    let mut body = Vec::new();
    if file.take(TEXT_BYTES + 1).read_to_end(&mut body).is_err() {
        m.preview.push("This file could not be read.".into());
        return;
    }
    if body.len() as u64 > TEXT_BYTES {
        m.preview.push("This file is too large to preview.".into());
        return;
    }
    if body.contains(&0) {
        return;
    }
    let text = String::from_utf8_lossy(&body);
    m.preview.push(String::new());
    for c in text.chars() {
        if c == '\t' { m.preview_body.push_str("        "); }
        else if c == '\n' || super::render::safe(c) { m.preview_body.push(c); }
    }
}
pub fn request(m: &mut Model, wire: &mut super::wire::Wire) -> std::io::Result<()> {
    use super::wire::{number, word};
    use crate::jsondoc::Json;
    if !m.preview_loaded || m.preview_requested == m.preview_generation || m.selected.len() > 1 || (!m.preview_visible && !m.quicklook) { return Ok(()); }
    let Some(row) = m.rows.get(&m.cursor) else { return Ok(()) };
    if m.current_path().as_ref() != Some(&m.preview_path) { return Ok(()); }
    m.preview_requested = m.preview_generation;
    if row.directory {
        m.preview_children = Some(m.preview_path.clone());
        wire.send(vec![("c", word("peek")), ("path", word(&m.preview_path.to_string_lossy())), ("first", number(m.height)), ("hidden", Json::Bool(m.hidden))])?;
    } else {
        wire.send(vec![("c", word("meta")), ("row", number(m.cursor)), ("token", number(m.preview_requested)), ("text", Json::Bool(false)), ("media", Json::Bool(row.icon.starts_with("audio") || row.icon.starts_with("video"))), ("archive", Json::Bool(row.icon.contains("package")))])?;
    }
    Ok(())
}
pub fn layout(m: &mut Model) {
    let columns = if m.quicklook { m.columns } else { super::render::panes(m.columns, m.preview_visible).2 };
    let changed = m.preview_width != columns || m.preview_layout_generation != m.preview_generation;
    if !changed && m.preview_layout_scroll == m.preview_scroll && m.preview_layout_height == m.height { return; }
    m.preview_width = columns;
    m.preview_layout_generation = m.preview_generation;
    let lines = || m.preview.iter().chain(m.preview_metadata.iter()).map(String::as_str).chain(m.preview_body.lines()).flat_map(|line| super::render::Wrapped::new(line, columns));
    if changed { m.preview_line_count = lines().count(); }
    m.preview_scroll = m.preview_scroll.min(m.preview_line_count.saturating_sub(1));
    let shown: Vec<String> = lines().skip(m.preview_scroll).take(m.height).map(super::render::clean).collect();
    m.preview_display = shown;
    m.preview_layout_scroll = m.preview_scroll;
    m.preview_layout_height = m.height;
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{backend::testdir::TestDir, jsondoc::Json, tui::model::Row};
    #[test]
    fn text_preview_neutralizes_controls_and_refuses_symlink() {
        let d = TestDir::new("tui-preview");
        d.file("note.txt", "hello\x1b[31m\n\u{202e}world");
        let mut m = Model::new(d.path().into(), &Json::Null);
        m.rows.insert(
            0,
            Row {
                name: "note.txt".into(),
                directory: false,
                size: 20,
                mode: 0o100644,
                link: String::new(),
                kind: "Plain text document".into(),
                thumbnail: false,
                modified: 0,
                icon: "text-x-generic".into(),
            },
        );
        load(&mut m, true);
        assert!(!m.preview_body.contains('\x1b'));
        assert!(!m.preview_body.contains('\u{202e}'));
        m.preview_auto = false;
        d.file("next.txt", "next body");
        m.rows.get_mut(&0).unwrap().name = "next.txt".into();
        load(&mut m, false);
        assert!(m.preview_body.is_empty());
        assert!(!m.preview_loaded);
        assert_eq!(m.preview[0], "next.txt");
        load(&mut m, true);
        assert_eq!(m.preview_body, "next body");
        m.preview_visible = false;
        m.rows.get_mut(&0).unwrap().name = "note.txt".into();
        load(&mut m, true);
        assert_eq!(m.preview_path, d.join("next.txt"));
        m.quicklook = true;
        load(&mut m, true);
        assert_eq!(m.preview_path, d.join("note.txt"));
        std::os::unix::fs::symlink(d.join("note.txt"), d.join("link")).unwrap();
        m.rows.get_mut(&0).unwrap().name = "link".into();
        load(&mut m, true);
        assert!(m.preview.iter().any(|s| s == "This file could not be read."));
    }
}
