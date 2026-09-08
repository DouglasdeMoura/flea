use super::wire::{count, flag, number, text, word, Wire};
use crate::jsondoc::Json;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub struct Row {
    pub name: String,
    pub directory: bool,
    pub size: usize,
    pub mode: usize,
    pub link: String,
    pub kind: String,
    pub thumbnail: bool,
}
impl Row {
    pub fn parse(row: &Json, kinds: &[Json]) -> Self {
        Self {
            name: text(row, "n").into(),
            directory: flag(row, "d"),
            size: count(row, "s"),
            mode: count(row, "p"),
            link: text(row, "l").into(),
            thumbnail: flag(row, "t"),
            kind: kinds
                .get(count(row, "k"))
                .and_then(Json::as_str)
                .unwrap_or("")
                .into(),
        }
    }
}
#[derive(Clone)]
pub struct Tab {
    pub path: PathBuf,
    pub cursor: usize,
    pub back: Vec<PathBuf>,
    pub forward: Vec<PathBuf>,
}
pub struct Model {
    pub path: PathBuf,
    pub pending: Option<PathBuf>,
    pub rows: BTreeMap<usize, Row>,
    pub parents: Vec<Row>,
    pub total: usize,
    pub cursor: usize,
    pub top: usize,
    pub height: usize,
    pub hidden: bool,
    pub sort: String,
    pub reverse: bool,
    pub folders_first: bool,
    pub group_by_kind: bool,
    pub selected: BTreeSet<usize>,
    pub tabs: Vec<Tab>,
    pub tab: usize,
    pub error: String,
    pub message: String,
    pub search: String,
    pub searching: bool,
    pub transfer: String,
    pub pending_clipboard: bool,
    pub clipboard: Vec<String>,
    pub cut: bool,
    pub preview: Vec<String>,
    pub preview_path: PathBuf,
    pub preview_visible: bool,
    pub preview_auto: bool,
    pub preview_focus: bool,
    pub quicklook: bool,
    pub sheet: bool,
    pub menu: bool,
    pub menu_cursor: usize,
    pub editor: Option<(String, String)>,
    pub preset: String,
    pub player: Option<super::media::Player>,
    pub pdf: Option<super::pdf::Pdf>,
    pub preview_scroll: usize,
    pub image_file: Option<PathBuf>,
    pub thumb_index: Option<usize>,
    pub filter: String,
    pub restore_cursor: Option<usize>,
    pub sheet_top: usize,
    pub transfer_id: usize,
    pub transfer_total: usize,
    pub transfer_moving: bool,
    pub quit: bool,
    pub back: Vec<PathBuf>,
    pub forward: Vec<PathBuf>,
    pub wrap: bool,
}
impl Model {
    pub fn new(path: PathBuf, settings: &Json) -> Self {
        let preview = settings.get("preview").unwrap_or(&Json::Null);
        Self {
            path: path.clone(),
            pending: None,
            rows: BTreeMap::new(),
            parents: Vec::new(),
            total: 0,
            cursor: 0,
            top: 0,
            height: 20,
            hidden: flag(settings, "hidden"),
            sort: settings
                .get("sort")
                .map(|s| text(s, "key"))
                .filter(|s| !s.is_empty())
                .unwrap_or("name")
                .into(),
            reverse: settings.get("sort").is_some_and(|s| flag(s, "reverse")),
            folders_first: settings
                .get("foldersFirst")
                .and_then(Json::as_bool)
                .unwrap_or(true),
            group_by_kind: flag(settings, "groupByKind"),
            selected: BTreeSet::new(),
            tabs: vec![Tab {
                path,
                cursor: 0,
                back: Vec::new(),
                forward: Vec::new(),
            }],
            tab: 0,
            error: String::new(),
            message: String::new(),
            search: String::new(),
            searching: false,
            transfer: String::new(),
            pending_clipboard: false,
            clipboard: Vec::new(),
            cut: false,
            preview: Vec::new(),
            preview_path: PathBuf::new(),
            preview_visible: preview
                .get("column")
                .and_then(Json::as_bool)
                .unwrap_or(true),
            preview_auto: text(preview, "loadOn") != "manual",
            preview_focus: false,
            quicklook: false,
            sheet: false,
            menu: false,
            menu_cursor: 0,
            editor: None,
            preset: match text(settings, "keys") {
                "vim" => "vim",
                "mac" => "mac",
                "windows" => "windows",
                _ => "default",
            }
            .into(),
            player: None,
            pdf: None,
            preview_scroll: 0,
            image_file: None,
            thumb_index: None,
            filter: String::new(),
            restore_cursor: None,
            sheet_top: 0,
            transfer_id: 0,
            transfer_total: 0,
            transfer_moving: false,
            quit: false,
            back: Vec::new(),
            forward: Vec::new(),
            wrap: flag(settings, "wrapAtEnds"),
        }
    }
    pub fn open(&mut self, path: PathBuf, wire: &mut Wire) -> io::Result<()> {
        if self.pending.is_some() {
            return Ok(());
        }
        self.pending = Some(path.clone());
        wire.send(vec![
            ("c", word("list")),
            ("path", word(&path.to_string_lossy())),
            ("first", number(self.height)),
            ("hidden", Json::Bool(self.hidden)),
            ("by", word(&self.sort)),
            ("desc", Json::Bool(self.reverse)),
            ("foldersFirst", Json::Bool(self.folders_first)),
            ("groupByKind", Json::Bool(self.group_by_kind)),
        ])
    }
    pub fn window(&mut self, wire: &mut Wire) -> io::Result<()> {
        if self.cursor < self.top {
            self.top = self.cursor;
        }
        if self.cursor >= self.top + self.height {
            self.top = self.cursor + 1 - self.height;
        }
        wire.send(vec![
            ("c", word("window")),
            ("start", number(self.top)),
            ("count", number(self.height)),
        ])
    }
    pub fn row_path(&self, row: &Row) -> PathBuf {
        if self.search.is_empty() {
            self.path.join(&row.name)
        } else {
            Path::new("/").join(&row.name)
        }
    }
    pub fn current_path(&self) -> Option<PathBuf> {
        self.rows.get(&self.cursor).map(|row| self.row_path(row))
    }
    pub fn shown(&self) -> Vec<usize> {
        self.rows
            .iter()
            .filter(|(_, row)| {
                self.filter.is_empty()
                    || row
                        .name
                        .to_lowercase()
                        .contains(&self.filter.to_lowercase())
            })
            .map(|(&i, _)| i)
            .collect()
    }
    pub fn apply_filter(&mut self, query: String) {
        self.filter = query;
        let shown = self.shown();
        self.selected.retain(|i| shown.contains(i));
        if !shown.contains(&self.cursor) {
            self.cursor = shown.first().copied().unwrap_or(self.top);
        }
    }
    pub fn indices(&self) -> Json {
        Json::Arr(if self.selected.is_empty() {
            vec![number(self.cursor)]
        } else {
            self.selected.iter().copied().map(number).collect()
        })
    }
    pub fn move_by(&mut self, delta: isize, extend: bool, wire: &mut Wire) -> io::Result<()> {
        if self.total == 0 || self.pending.is_some() {
            return Ok(());
        }
        if !self.filter.is_empty() {
            let shown = self.shown();
            if shown.is_empty() {
                return Ok(());
            }
            let index = shown.iter().position(|i| *i == self.cursor).unwrap_or(0);
            if extend {
                self.selected.insert(self.cursor);
            }
            let next = (index as isize + delta)
                .max(0)
                .min(shown.len() as isize - 1) as usize;
            self.cursor = shown[next];
            if extend {
                self.selected.insert(self.cursor);
            }
            return Ok(());
        }
        if extend {
            self.selected.insert(self.cursor);
        }
        let next = self.cursor as isize + delta;
        self.cursor = if self.wrap {
            next.rem_euclid(self.total as isize) as usize
        } else {
            next.max(0).min(self.total as isize - 1) as usize
        };
        if extend {
            self.selected.insert(self.cursor);
        }
        self.window(wire)
    }
    pub fn receive(&mut self, value: Json, wire: &mut Wire) -> io::Result<()> {
        match text(&value, "t") {
            "listed" => {
                if let Some(path) = self.pending.take() {
                    self.path = path;
                    self.cursor = self.restore_cursor.take().unwrap_or(0);
                    self.top = self.cursor;
                    self.search.clear();
                    self.filter.clear();
                }
                self.total = count(&value, "n");
                self.preview_path = PathBuf::new();
                self.image_file = None;
                self.thumb_index = None;
                self.rows.clear();
                self.selected.clear();
                self.cursor = self.cursor.min(self.total.saturating_sub(1));
                let parent = self
                    .path
                    .parent()
                    .unwrap_or(&self.path)
                    .to_string_lossy()
                    .into_owned();
                wire.send(vec![
                    ("c", word("peek")),
                    ("path", word(&parent)),
                    ("first", number(self.height)),
                    ("hidden", Json::Bool(self.hidden)),
                ])?;
                self.window(wire)?;
            }
            "rows" => {
                let empty = Vec::new();
                let kinds = value
                    .get("kinds")
                    .and_then(Json::as_array)
                    .unwrap_or(&empty);
                let rows = value.get("rows").and_then(Json::as_array).unwrap_or(&empty);
                let start = count(&value, "start");
                self.rows.clear();
                for (i, row) in rows.iter().enumerate() {
                    self.rows.insert(start + i, Row::parse(row, kinds));
                }
            }
            "thumbed" => {
                if self.thumb_index == Some(count(&value, "row"))
                    && !text(&value, "file").is_empty()
                {
                    self.image_file = Some(PathBuf::from(text(&value, "file")));
                }
            }
            "peeked" => {
                if self
                    .path
                    .parent()
                    .map(|p| p.to_string_lossy() == text(&value, "path"))
                    .unwrap_or(false)
                {
                    self.parents = value
                        .get("rows")
                        .and_then(Json::as_array)
                        .unwrap_or(&[])
                        .iter()
                        .map(|r| Row::parse(r, &[]))
                        .collect();
                }
            }
            "changed" => {
                if self.pending.is_none()
                    && self.search.is_empty()
                    && text(&value, "path") == self.path.to_string_lossy()
                {
                    self.open(self.path.clone(), wire)?;
                }
            }
            "paths" => {
                if self.pending_clipboard {
                    self.pending_clipboard = false;
                    self.clipboard = value
                        .get("paths")
                        .and_then(Json::as_array)
                        .unwrap_or(&[])
                        .iter()
                        .filter_map(Json::as_str)
                        .map(str::to_owned)
                        .collect();
                    self.message = format!(
                        "{} items {}",
                        self.clipboard.len(),
                        if self.cut { "cut" } else { "copied" }
                    );
                }
            }
            "searching" | "searched" => {
                self.total = count(&value, "n");
                self.searching = text(&value, "t") == "searching";
                self.search = format!(
                    "Search: {} matches · {} scanned",
                    self.total,
                    count(&value, "scanned")
                );
                self.selected.clear();
                self.cursor = self.cursor.min(self.total.saturating_sub(1));
                self.window(wire)?;
            }
            "transferstarted" => {
                self.transfer_id = count(&value, "id");
                self.transfer_total = count(&value, "n");
                self.transfer_moving = flag(&value, "moving");
                self.transfer = format!(
                    "{} 0 of {}",
                    if self.transfer_moving {
                        "Moving"
                    } else {
                        "Copying"
                    },
                    self.transfer_total
                );
            }
            "transferprogress" => {
                if count(&value, "id") == self.transfer_id {
                    self.transfer = format!(
                        "{} {} of {}",
                        if self.transfer_moving {
                            "Moving"
                        } else {
                            "Copying"
                        },
                        count(&value, "index") + 1,
                        self.transfer_total
                    );
                }
            }
            "transferitem" => {
                if !flag(&value, "ok") {
                    self.error = format!("{}: {}", text(&value, "name"), text(&value, "err"));
                }
            }
            "transferdone" | "trashed" | "undone" | "renamed" | "made" => {
                self.transfer.clear();
                self.transfer_id = 0;
                self.message = match text(&value, "t") {
                    "renamed" => "Renamed · Undo available".into(),
                    "made" => "Folder created · Undo available".into(),
                    "undone" => format!("Undid {}", text(&value, "op")),
                    "trashed" => format!(
                        "Moved {} items to Trash · Undo available",
                        count(&value, "ok")
                    ),
                    _ => format!("Transferred {} items", count(&value, "ok")),
                };
                if count(&value, "failed") > 0 {
                    self.error = format!("{} failed", count(&value, "failed"));
                }
                self.open(self.path.clone(), wire)?;
            }
            "error" => {
                self.error = format!("{}: {}", text(&value, "where"), text(&value, "msg"));
                self.pending = None;
                self.pending_clipboard = false;
            }
            _ => {}
        }
        Ok(())
    }
}
