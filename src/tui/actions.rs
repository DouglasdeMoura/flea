use super::{
    input::Key,
    keymap::Map,
    model::{Model, Tab},
    wire::{word, Wire},
};
use crate::jsondoc::Json;
use std::{io, path::PathBuf};

pub fn key(model: &mut Model, key: &Key, map: &Map, wire: &mut Wire) -> io::Result<()> {
    if let Some(pointer) = &key.pointer {
        model.key_arm.clear();
        return pointer_key(model, key, pointer, map, wire);
    }
    if model.editor.is_some() {
        return edit(model, key, wire);
    }
    if model.sheet {
        if key.name == "Escape" || key.text == "?" {
            model.sheet = false;
        } else if key.name == "Down" || key.text == "j" {
            model.sheet_top = (model.sheet_top + 1).min(map.sheet().len().saturating_sub(1));
        } else if key.name == "Up" || key.text == "k" {
            model.sheet_top = model.sheet_top.saturating_sub(1);
        }
        return Ok(());
    }
    if model.menu {
        let count = if model.taildrop.submenu { model.taildrop.peers.len().max(1) } else { 3 };
        match key.name.as_str() {
            "Escape" | "Left" => {
                if model.taildrop.submenu {
                    model.taildrop.submenu = false;
                    model.menu_cursor = 2;
                } else { model.menu = false; }
            }
            "Down" => model.menu_cursor = (model.menu_cursor + 1) % count,
            "Up" => model.menu_cursor = (model.menu_cursor + count - 1) % count,
            "Return" | "Space" | "Right" => {
                if model.taildrop.submenu {
                    if model.pending_clipboard || model.taildrop_target.is_some() { return Ok(()); }
                    if let Some(peer) = model.taildrop.peers.get(model.menu_cursor) {
                        model.taildrop_target = Some(peer.clone());
                        wire.send(vec![("c", word("paths")), ("rows", model.indices())])?;
                        model.menu = false;
                    }
                    return Ok(());
                }
                if model.menu_cursor == 2 {
                    if model.taildrop.peers.is_empty() {
                        model.error = if model.taildrop.loading() { "Taildrop is still loading".into() } else if !model.taildrop.error.is_empty() { model.taildrop.error.clone() } else { "No reachable Taildrop devices".into() };
                    } else if model.rows.contains_key(&model.cursor) {
                        model.taildrop.submenu = true;
                        model.menu_cursor = 0;
                    }
                    return Ok(());
                }
                if key.name == "Right" { return Ok(()); }
                model.menu = false;
                return act(
                    model,
                    if model.menu_cursor == 0 {
                        "open"
                    } else {
                        "toggleHidden"
                    },
                    wire,
                );
            }
            _ => {
                if key.text == "j" || key.text == "k" {
                    model.menu_cursor = if key.text == "j" { (model.menu_cursor + 1) % count } else { (model.menu_cursor + count - 1) % count };
                }
            }
        }
        return Ok(());
    }
    if key.name == "P" && key.mods == "alt" {
        model.preview_visible = !model.preview_visible;
        model.preview_focus = false;
        save_preview_column(model);
        return Ok(());
    }
    if key.name == "Space" && key.mods == "ctrl" {
        super::preview::load(model, true);
        return Ok(());
    }
    if model.preview_focus || model.quicklook {
        if key.name == "Escape" || (key.name == "Tab" && key.mods == "ctrl") {
            model.preview_focus = false;
            model.quicklook = false;
            return Ok(());
        }
        if let Some(pdf) = &mut model.pdf {
            let controls = if model.quicklook { 6 } else { 5 };
            match key.name.as_str() {
                "Tab" => {
                    pdf.control = if key.mods == "shift" {
                        (pdf.control + controls - 1) % controls
                    } else {
                        (pdf.control + 1) % controls
                    }
                }
                "Left" => pdf.turn(-1),
                "Right" => pdf.turn(1),
                "Up" => pdf.scroll(-1),
                "Down" => pdf.scroll(1),
                "Return" | "Space" => match pdf.control {
                    0 => pdf.turn(-1),
                    1 => pdf.turn(1),
                    2 => pdf.zoom(-1),
                    3 => pdf.zoom(1),
                    4 => model.quicklook = true,
                    5 => {
                        model.quicklook = false;
                        model.preview_focus = false;
                    }
                    _ => {}
                },
                _ => match key.text.as_str() {
                    "h" => pdf.turn(-1),
                    "l" => pdf.turn(1),
                    _ => {}
                },
            }
        } else if let Some(player) = &mut model.player {
            match key.name.as_str() {
                "Tab" => player.control = 1 - player.control,
                "Space" => player.toggle()?,
                "Return" => {
                    if player.control == 0 {
                        player.toggle()?;
                    }
                }
                "Left" => {
                    if player.control == 1 {
                        player.seek(-5)?;
                    }
                }
                "Right" => {
                    if player.control == 1 {
                        player.seek(5)?;
                    }
                }
                _ => {
                    if player.control == 1 {
                        match key.text.as_str() {
                            "h" => player.seek(-5)?,
                            "l" => player.seek(5)?,
                            _ => {}
                        }
                    }
                }
            }
        } else {
            match key.name.as_str() {
                "Down" => {
                    model.preview_scroll =
                        (model.preview_scroll + 1).min(model.preview.len().saturating_sub(1))
                }
                "Up" => model.preview_scroll = model.preview_scroll.saturating_sub(1),
                _ => {}
            }
        }
        return Ok(());
    }
    if key.name == "Paste" { return Ok(()); }
    if key.mods.is_empty() && key.text.len() == 1 {
        if let Ok(n) = key.text.parse::<usize>() {
            if (1..=9).contains(&n) {
                return tab(model, n - 1, wire);
            }
        }
    }
    if key.name == "PageDown" && key.mods == "ctrl" {
        return tab(model, (model.tab + 1) % model.tabs.len(), wire);
    }
    if key.name == "PageUp" && key.mods == "ctrl" {
        return tab(
            model,
            (model.tab + model.tabs.len() - 1) % model.tabs.len(),
            wire,
        );
    }
    if key.name == "Tab" && key.mods == "ctrl" {
        model.preview_focus = model.preview_visible;
        return Ok(());
    }
    let mut action = map.action(key, &model.preset);
    if matches!(action.as_str(), "copyArm" | "cutArm" | "pasteArm" | "cursorFirstArm" | "trashArm") {
        if model.key_arm != action {
            model.key_arm = action;
            return Ok(());
        }
        action = match action.as_str() {
            "copyArm" => "copy", "cutArm" => "cut", "pasteArm" => "paste", "cursorFirstArm" => "cursorFirst", _ => "trash",
        }.into();
    }
    model.key_arm.clear();
    if action.is_empty() {
        match key.text.as_str() {
            "q" => model.quit = true,
            "H" if matches!(model.preset.as_str(), "default" | "vim") => history(model, false, wire)?,
            "L" if matches!(model.preset.as_str(), "default" | "vim") => history(model, true, wire)?,
            _ => {}
        }
        return Ok(());
    }
    act(model, &action, wire)
}
fn act(m: &mut Model, action: &str, w: &mut Wire) -> io::Result<()> {
    if m.pending.is_some() && !matches!(action, "quit" | "escape" | "keymapSheet") {
        return Ok(());
    }
    if m.searching
        && matches!(
            action,
            "paste" | "trash" | "trashArm" | "rename" | "copy" | "cut"
        )
    {
        m.error = "Wait for search to settle before a file operation".into();
        return Ok(());
    }
    if !m.rows.contains_key(&m.cursor)
        && matches!(action, "open" | "copy" | "cut" | "trash" | "trashArm" | "rename" | "preview" | "reveal" | "toggleSelect")
    {
        return Ok(());
    }
    match action {
        "cursorDown" => m.move_by(1, false, w)?,
        "cursorUp" => m.move_by(-1, false, w)?,
        "extendDown" => m.move_by(1, true, w)?,
        "extendUp" => m.move_by(-1, true, w)?,
        "pageDown" => m.move_by(m.height as isize, false, w)?,
        "pageUp" => m.move_by(-(m.height as isize), false, w)?,
        "first" | "cursorFirst" => {
            m.cursor = 0;
            m.window(w)?;
        }
        "last" | "cursorLast" => {
            m.cursor = m.total.saturating_sub(1);
            m.window(w)?;
        }
        "parent" => {
            if let Some(p) = m.path.parent().map(|p| p.to_path_buf()) {
                navigate(m, p, w)?;
            }
        }
        "historyBack" => history(m, false, w)?,
        "historyForward" => history(m, true, w)?,
        "open" => {
            if let Some(path) = m.current_path() {
                if m.rows.get(&m.cursor).is_some_and(|r| r.directory) {
                    navigate(m, path, w)?;
                } else if crate::open::open(&path.to_string_lossy()) != 0 {
                    m.error = "Could not open selected file".into();
                }
            }
        }
        "toggleSelect" => {
            if m.rows.contains_key(&m.cursor) && !m.selected.remove(&m.cursor) {
                m.selected.insert(m.cursor);
            }
        }
        "selectAll" => {
            m.selected = if m.filter.is_empty() {
                (0..m.total).collect()
            } else {
                m.shown().into_iter().collect()
            };
        }
        "toggleHidden" => {
            m.hidden = !m.hidden;
            save("hidden", Json::Bool(m.hidden), m);
            m.open(m.path.clone(), w)?;
        }
        "pathBar" => {
            m.editor = Some(("path".into(), String::new()));
            m.completion.clear();
        }
        "filter" => m.editor = Some(("filter".into(), m.filter.clone())),
        "search" => m.editor = Some(("search".into(), String::new())),
        "rename" => {
            if m.selected.len() > 1 {
                m.error = "Select one item to rename".into();
            } else if let Some(row) = m.rows.get(&m.cursor) {
                m.editor = Some(("rename".into(), row.name.clone()));
            }
        }
        "newFolder" => m.editor = Some(("mkdir".into(), "New Folder".into())),
        "copy" | "cut" => {
            if m.pending_clipboard || m.taildrop_target.is_some() { return Ok(()); }
            m.cut = action == "cut";
            m.pending_clipboard = true;
            w.send(vec![("c", word("paths")), ("rows", m.indices())])?;
        }
        "paste" => {
            if m.clipboard.is_empty() {
                m.message = "Nothing to paste".into();
            } else {
                w.send(vec![
                    ("c", word("transfer")),
                    ("op", word(if m.cut { "move" } else { "copy" })),
                    (
                        "paths",
                        Json::Arr(m.clipboard.iter().map(|p| word(p)).collect()),
                    ),
                    ("dest", word(&m.path.to_string_lossy())),
                ])?;
            }
        }
        "trash" | "trashArm" => {
            if m.total > 0 {
                w.send(vec![("c", word("trash")), ("rows", m.indices())])?;
            }
        }
        "undo" => w.send(vec![("c", word("undo"))])?,
        "sortNext" | "sortReverse" => {
            if action == "sortReverse" {
                m.reverse = !m.reverse;
            } else {
                m.sort = match m.sort.as_str() {
                    "name" => "size",
                    "size" => "mtime",
                    _ => "name",
                }
                .into();
            }
            w.send(vec![
                ("c", word("sort")),
                ("by", word(&m.sort)),
                ("desc", Json::Bool(m.reverse)),
                ("foldersFirst", Json::Bool(m.folders_first)),
                ("groupByKind", Json::Bool(m.group_by_kind)),
            ])?;
            m.invalidate_rows();
            save("sort", Json::Obj(vec![("key".into(), word(&m.sort)), ("reverse".into(), Json::Bool(m.reverse))]), m);
        }
        "tabNew" => {
            m.tabs.push(Tab {
                path: m.path.clone(),
                cursor: 0,
                back: Vec::new(),
                forward: Vec::new(),
            });
            let index = m.tabs.len() - 1;
            tab(m, index, w)?;
        }
        "tabClose" => {
            if m.tabs.len() == 1 {
                m.quit = true;
            } else {
                m.tabs.remove(m.tab);
                m.tab = m.tab.min(m.tabs.len() - 1);
                m.restore_cursor = Some(m.tabs[m.tab].cursor);
                m.back = m.tabs[m.tab].back.clone();
                m.forward = m.tabs[m.tab].forward.clone();
                let p = m.tabs[m.tab].path.clone();
                m.open(p, w)?;
            }
        }
        "preview" => {
            m.quicklook = true;
            super::preview::load(m, true);
        }
        "togglePreview" => {
            m.preview_visible = !m.preview_visible;
            m.preview_focus = false;
            save_preview_column(m);
        }
        "loadPreview" => super::preview::load(m, true),
        "focusPreview" | "focusNext" => m.preview_focus = m.preview_visible,
        "tabNext" => return tab(m, (m.tab + 1) % m.tabs.len(), w),
        "tabPrevious" => return tab(m, (m.tab + m.tabs.len() - 1) % m.tabs.len(), w),
        "menu" => {
            m.menu = true;
            m.menu_cursor = 0;
            m.taildrop.submenu = false;
            m.taildrop.refresh();
        }
        "keymapSheet" => {
            m.sheet = true;
            m.sheet_top = 0;
        }
        "reveal" => {
            if !m.search.is_empty() {
                m.restore_path = m.current_path();
                if let Some(p) = m
                    .current_path()
                    .and_then(|p| p.parent().map(|v| v.to_path_buf()))
                {
                    navigate(m, p, w)?;
                }
            }
        }
        "escape" => {
            if !m.filter.is_empty() {
                m.apply_filter(String::new());
            } else if !m.error.is_empty() {
                m.error.clear();
            } else if m.searching {
                w.send(vec![("c", word("searchcancel"))])?;
            } else if !m.search.is_empty() {
                let path = m.search_from.clone().unwrap_or_else(|| m.path.clone());
                m.open(path, w)?;
            } else if m.transfer_id > 0 {
                w.send(vec![("c", word("transfercancel")), ("id", super::wire::number(m.transfer_id))])?;
            } else {
                m.selected.clear();
            }
        }
        "quit" => m.quit = true,
        _ => {}
    }
    m.remember_selection();
    Ok(())
}
fn pointer_key(m: &mut Model, key: &Key, pointer: &super::input::Pointer, map: &Map, w: &mut Wire) -> io::Result<()> {
    if pointer.released {
        m.drag_anchor = None;
        return Ok(());
    }
    let scroll = match pointer.button { 64 => -1, 65 => 1, _ => 0 };
    if m.editor.is_some() { return Ok(()); }
    if m.sheet || m.menu {
        let rows = if m.sheet { map.sheet() } else { super::render::menu_rows(m) };
        let (x, y, width, count) = super::render::overlay_rect(&rows, m.columns, m.height + 2);
        if scroll != 0 {
            return self::key(m, &Key::named(if scroll < 0 { "Up" } else { "Down" }, ""), map, w);
        }
        if pointer.button == 0 && !pointer.motion && pointer.x > x && pointer.x <= x + width && pointer.y > y + 1 && pointer.y <= y + count + 1 {
            if m.menu {
                m.menu_cursor = pointer.y - y - 2;
                return self::key(m, &Key::named("Return", ""), map, w);
            }
        }
        return Ok(());
    }
    let (left, middle, _) = super::render::panes(m.columns, m.preview_visible);
    if m.quicklook || (m.preview_visible && pointer.x > left + middle + 2) {
        m.preview_focus = true;
        if scroll != 0 {
            return self::key(m, &Key::named(if scroll < 0 { "Up" } else { "Down" }, ""), map, w);
        }
        if pointer.button == 0 && !pointer.motion && pointer.y == m.height {
            let cell = pointer.x.saturating_sub(if m.quicklook { 1 } else { left + middle + 3 });
            if let Some(pdf) = &mut m.pdf {
                if let Some(control) = pdf.control_at(cell, m.quicklook) {
                    pdf.control = control;
                    return self::key(m, &Key::named("Return", ""), map, w);
                }
            } else if let Some(player) = &mut m.player {
                if cell < 7 {
                    player.control = 0;
                    return player.toggle();
                }
                player.control = 1;
            }
        }
        return Ok(());
    }
    if pointer.y == 1 && pointer.button == 0 && !pointer.motion {
        let mut x = 1;
        for (i, entry) in m.tabs.iter().enumerate() {
            let label = format!("{} {}", i + 1, entry.path.file_name().unwrap_or_default().to_string_lossy());
            let width = super::render::text_width(&label) + 2;
            if pointer.x >= x && pointer.x < x + width { return tab(m, i, w); }
            x += width;
        }
        return Ok(());
    }
    if pointer.y < 2 || pointer.y > m.height + 1 || m.pending.is_some() { return Ok(()); }
    if scroll != 0 {
        m.preview_focus = false;
        return m.move_by(scroll, false, w);
    }
    if pointer.x <= left {
        if pointer.button == 0 && !pointer.motion {
            if let Some(row) = m.parents.get(pointer.y - 2) {
                let path = m.path.parent().unwrap_or(&m.path).join(&row.name);
                if row.directory { navigate(m, path, w)?; }
            }
        }
        return Ok(());
    }
    if pointer.x == left + 1 || pointer.x > left + middle + 1 { return Ok(()); }
    let index = if m.filter.is_empty() { m.top + pointer.y - 2 } else { m.shown().get(pointer.y - 2).copied().unwrap_or(usize::MAX) };
    if !m.rows.contains_key(&index) { return Ok(()); }
    m.preview_focus = false;
    if pointer.motion {
        if let Some(anchor) = m.drag_anchor {
            m.selected = if m.filter.is_empty() { (anchor.min(index)..=anchor.max(index)).collect() } else { m.shown().into_iter().filter(|i| *i >= anchor.min(index) && *i <= anchor.max(index)).collect() };
            m.cursor = index;
            m.remember_selection();
        }
        return Ok(());
    }
    if pointer.button == 2 {
        m.cursor = index;
        if !m.selected.contains(&index) { m.selected.clear(); }
        return act(m, "menu", w);
    }
    if pointer.button != 0 { return Ok(()); }
    let old = m.cursor;
    m.cursor = index;
    if key.mods == "ctrl" || key.mods == "super" {
        if !m.selected.remove(&index) { m.selected.insert(index); }
    } else if key.mods == "shift" {
        m.selected = if m.filter.is_empty() { (old.min(index)..=old.max(index)).collect() } else { m.shown().into_iter().filter(|i| *i >= old.min(index) && *i <= old.max(index)).collect() };
    } else if key.mods.is_empty() {
        m.selected.clear();
        m.drag_anchor = Some(index);
        if let Some(path) = m.current_path() {
            const DOUBLE_CLICK: std::time::Duration = std::time::Duration::from_millis(400);
            if m.last_click.as_ref().is_some_and(|(previous, at)| previous == &path && at.elapsed() <= DOUBLE_CLICK) {
                m.last_click = None;
                return act(m, if m.search.is_empty() { "open" } else { "reveal" }, w);
            }
            m.last_click = Some((path, std::time::Instant::now()));
        }
    }
    m.remember_selection();
    Ok(())
}
fn navigate(m: &mut Model, path: PathBuf, w: &mut Wire) -> io::Result<()> {
    m.back.push(m.path.clone());
    m.forward.clear();
    m.open(path, w)
}
fn history(m: &mut Model, forward: bool, w: &mut Wire) -> io::Result<()> {
    let next = if forward {
        m.forward.pop()
    } else {
        m.back.pop()
    };
    if let Some(path) = next {
        if forward {
            m.back.push(m.path.clone());
        } else {
            m.forward.push(m.path.clone());
        }
        m.open(path, w)?;
    }
    Ok(())
}
fn tab(m: &mut Model, index: usize, w: &mut Wire) -> io::Result<()> {
    if index >= m.tabs.len() || index == m.tab {
        return Ok(());
    }
    m.tabs[m.tab] = Tab {
        path: m.path.clone(),
        cursor: m.cursor,
        back: m.back.clone(),
        forward: m.forward.clone(),
    };
    m.tab = index;
    let next = m.tabs[index].clone();
    m.restore_cursor = Some(next.cursor);
    m.back = next.back;
    m.forward = next.forward;
    m.open(next.path, w)
}
fn save(key: &str, value: Json, m: &mut Model) {
    if let Err(e) =
        crate::uistore::Store::user().and_then(|s| s.update(&Json::Obj(vec![(key.into(), value)])))
    {
        m.error = format!("Could not save settings: {}", e);
    }
}
fn save_preview_column(m: &mut Model) {
    save("preview", Json::Obj(vec![("column".into(), Json::Bool(m.preview_visible))]), m);
}
fn edit(m: &mut Model, key: &Key, w: &mut Wire) -> io::Result<()> {
    let (kind, mut value) = m.editor.take().unwrap();
    if key.name == "Escape" {
        if kind == "filter" {
            m.apply_filter(String::new());
        }
        return Ok(());
    }
    if key.name == "Backspace" {
        value.pop();
    } else if key.name == "Return" {
        match kind.as_str() {
            "path" => {
                let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
                let p = super::completion::expand(&value, &home, &m.path);
                navigate(m, p, w)?;
            }
            "filter" => m.apply_filter(value),
            "search" => {
                if value.is_empty() {
                    return Ok(());
                }
                if m.search_from.is_none() {
                    m.search_from = Some(m.path.clone());
                }
                let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
                if !m.search_here && home.is_absolute() && m.path.starts_with(&home) {
                    m.path = home;
                }
                m.invalidate_rows();
                m.cursor = 0;
                m.top = 0;
                m.total = 0;
                m.searching = true;
                m.search = "Search: starting".into();
                w.send(vec![
                    ("c", word("search")),
                    ("path", word(&m.path.to_string_lossy())),
                    ("query", word(&value)),
                    ("hidden", Json::Bool(m.hidden)),
                ])?;
            }
            "rename" => {
                if let Some(p) = m.current_path() {
                    w.send(vec![
                        ("c", word("rename")),
                        ("path", word(&p.to_string_lossy())),
                        ("to", word(&value)),
                    ])?;
                }
            }
            "mkdir" => w.send(vec![
                ("c", word("mkdir")),
                ("path", word(&m.path.to_string_lossy())),
                ("name", word(&value)),
            ])?,
            _ => {}
        }
        return Ok(());
    } else if key.name == "Tab" && kind == "path" {
        if !m.completion.is_empty() {
            value = m.completion.clone();
        }
    } else if key.name == "Tab" && kind == "search" {
        m.search_here = !m.search_here;
    } else if key.mods.is_empty() {
        value.push_str(&key.text);
    }
    if kind == "filter" {
        m.apply_filter(value.clone());
    }
    if kind == "path" {
        m.completion = super::completion::suggest(&value, &m.path);
    }
    m.editor = Some((kind, value));
    Ok(())
}
