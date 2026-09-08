// GIO owns the shared Trash store; this worker owns only a listing and a reviewed confirmation.
use crate::backend::opsreq::OpMsg;
use crate::backend::trashdelete::Reviewed;
use crate::json::{escape, field_bool, field_str, field_str_array, field_usize};
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::{channel, Sender};
use std::thread;
use std::time::{Duration, Instant};

const SUMMARY_BUDGET_MS: u64 = 2000;

#[derive(Clone, Debug, PartialEq)]
struct Item {
    uri: String,
    original: String,
}
#[derive(Clone, Debug, PartialEq)]
struct Detail {
    item: Item,
    size: u64,
    deleted: String,
    identity: String,
    directory: bool,
    icon: String,
    backing: Option<Reviewed>,
}
struct Confirmation {
    token: usize,
    items: Vec<Detail>,
    listing: Vec<Item>,
}
#[derive(Default)]
struct Session {
    items: Vec<Item>,
    confirmation: Option<Confirmation>,
    next_token: usize,
}

pub struct TrashBrowser {
    tx: Sender<String>,
}
impl TrashBrowser {
    pub fn new(replies: Sender<OpMsg>) -> Self {
        let (tx, rx) = channel::<String>();
        thread::spawn(move || {
            let mut session = Session::default();
            for request in rx {
                let line = session.handle(&request);
                if replies.send(OpMsg::Meta { line }).is_err() {
                    break;
                }
            }
        });
        Self { tx }
    }
    pub fn request(&self, line: String) {
        let _ = self.tx.send(line);
    }
}

fn gio(args: &[&str]) -> Result<String, String> {
    let output = Command::new("gio")
        .env("LC_ALL", "C")
        .args(args)
        .output()
        .map_err(|e| format!("Could not run gio: {}", e))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr)
            .lines()
            .last()
            .unwrap_or("gio failed")
            .to_string());
    }
    String::from_utf8(output.stdout).map_err(|_| "GIO returned invalid text.".into())
}

// Sample input: "trash:///a.txt\t/home/gm/a.txt\n"; malformed framing must not silently lose an item.
fn parse_list(text: &str) -> Result<Vec<Item>, String> {
    let mut items = Vec::new();
    for line in text.lines() {
        let (uri, original) = line
            .split_once('\t')
            .ok_or("GIO returned an unreadable Trash listing.")?;
        if !uri.starts_with("trash:///")
            || uri.len() <= "trash:///".len()
            || !original.starts_with('/')
        {
            return Err("GIO returned an invalid Trash identity.".into());
        }
        items.push(Item {
            uri: uri.into(),
            original: original.into(),
        });
    }
    items.sort_by(|a, b| a.uri.cmp(&b.uri));
    if items.windows(2).any(|pair| pair[0].uri == pair[1].uri) {
        return Err("GIO returned duplicate Trash identities.".into());
    }
    Ok(items)
}
fn list() -> Result<Vec<Item>, String> {
    parse_list(&gio(&["trash", "--list"])?)
}

// Sample input, gio info: "  standard::size: 123\n  trash::deletion-date: 2026-09-08T10:00:00".
fn attribute<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    text.lines().find_map(|line| {
        line.trim_start()
            .strip_prefix(name)
            .and_then(|rest| rest.strip_prefix(": "))
    })
}
fn detail(item: &Item) -> Result<Detail, String> {
    let text = gio(&["info", "--nofollow-symlinks", "--attributes=standard::size,standard::type,trash::deletion-date,id::file,id::filesystem,standard::icon,standard::target-uri", &item.uri])?;
    let size = attribute(&text, "standard::size")
        .and_then(|s| s.parse().ok())
        .ok_or("GIO did not report Trash item size.")?;
    let identity = match (
        attribute(&text, "id::filesystem"),
        attribute(&text, "id::file"),
    ) {
        (Some(fs), Some(file)) if !fs.is_empty() && !file.is_empty() => format!("{}:{}", fs, file),
        _ => String::new(),
    };
    let backing = attribute(&text, "standard::target-uri")
        .and_then(|uri| uri.strip_prefix("file://"))
        .and_then(|path| {
            Reviewed::inspect(
                PathBuf::from(crate::paths::percent_decode(path)),
                attribute(&text, "id::file").unwrap_or(""),
            )
            .ok()
        });
    Ok(Detail {
        backing,
        item: item.clone(),
        size,
        deleted: attribute(&text, "trash::deletion-date")
            .unwrap_or("")
            .into(),
        identity,
        directory: attribute(&text, "standard::type") == Some("2"),
        icon: attribute(&text, "standard::icon")
            .unwrap_or("")
            .split(", ")
            .next()
            .unwrap_or("")
            .into(),
    })
}
fn row(item: &Detail) -> String {
    format!(
        r#"{{"uri":"{}","original":"{}","size":{},"deleted":"{}","directory":{},"icon":"{}"}}"#,
        escape(&item.item.uri),
        escape(&item.item.original),
        item.size,
        escape(&item.deleted),
        item.directory,
        escape(&item.icon)
    )
}

impl Session {
    // Sample input: {"c":"trashbrowse","op":"prepare","id":1,"uris":["trash:///a.txt"],"all":false}.
    fn handle(&mut self, line: &str) -> String {
        let id = field_usize(line, "id").unwrap_or(0);
        let op = field_str(line, "op").unwrap_or_default();
        match self.execute(&op, line) {
            Ok(fields) => format!(
                r#"{{"t":"trashbrowse","id":{},"op":"{}","ok":true,{}}}"#,
                id,
                escape(&op),
                fields
            ),
            Err(error) => format!(
                r#"{{"t":"trashbrowse","id":{},"op":"{}","ok":false,"error":"{}"}}"#,
                id,
                escape(&op),
                escape(&error)
            ),
        }
    }
    fn execute(&mut self, op: &str, line: &str) -> Result<String, String> {
        match op {
            "list" => {
                self.items = list()?;
                self.window(
                    field_usize(line, "start").unwrap_or(0),
                    field_usize(line, "count").unwrap_or(100),
                )
            }
            "summary" => self.summary(),
            "window" => self.window(
                field_usize(line, "start").unwrap_or(0),
                field_usize(line, "count").unwrap_or(100),
            ),
            "prepare" => self.prepare(field_bool(line, "all"), &field_str_array(line, "uris")),
            "check" => {
                let valid = self.valid(field_usize(line, "token").unwrap_or(0))?;
                if !valid {
                    self.confirmation = None;
                }
                Ok(format!(r#""valid":{}"#, valid))
            }
            "cancel" => {
                self.confirmation = None;
                Ok(r#""cancelled":true"#.into())
            }
            "restore" => self.restore(field_bool(line, "all"), &field_str_array(line, "uris")),
            "delete" => {
                if !self.valid(field_usize(line, "token").unwrap_or(0))? {
                    self.confirmation = None;
                    return Err("Trash changed; review a fresh confirmation.".into());
                }
                let confirmation = self
                    .confirmation
                    .take()
                    .ok_or("Trash confirmation expired.")?;
                let mut done = 0;
                let mut failures = Vec::new();
                for item in confirmation.items {
                    match item
                        .backing
                        .as_ref()
                        .ok_or("Trash backing identity is unavailable.".to_string())
                        .and_then(Reviewed::delete)
                    {
                        Ok(()) => done += 1,
                        Err(error) => failures.push(format!(
                            r#"{{"uri":"{}","error":"{}"}}"#,
                            escape(&item.item.uri),
                            escape(&error)
                        )),
                    }
                }
                Ok(format!(
                    r#""done":{},"failed":{},"failures":[{}]"#,
                    done,
                    failures.len(),
                    failures.join(",")
                ))
            }
            _ => Err("Unknown Trash request.".into()),
        }
    }
    fn window(&self, start: usize, count: usize) -> Result<String, String> {
        let start = start.min(self.items.len());
        let rows: Result<Vec<_>, _> = self
            .items
            .iter()
            .skip(start)
            .take(count.min(350))
            .map(detail)
            .collect();
        let rows = rows?;
        Ok(format!(
            r#""total":{},"start":{},"rows":[{}]"#,
            self.items.len(),
            start,
            rows.iter().map(row).collect::<Vec<_>>().join(",")
        ))
    }
    fn summary(&self) -> Result<String, String> {
        let deadline = Instant::now() + Duration::from_millis(SUMMARY_BUDGET_MS);
        let mut bytes = 0u64;
        let mut partial = false;
        for item in &self.items {
            if Instant::now() >= deadline {
                partial = true;
                break;
            }
            let detail = detail(item)?;
            match detail.backing {
                Some(backing) => {
                    let size = backing.bytes(deadline);
                    bytes += size.bytes;
                    partial |= size.partial;
                }
                None => {
                    bytes += detail.size;
                    partial |= detail.directory;
                }
            }
        }
        Ok(format!(r#""bytes":{},"partial":{}"#, bytes, partial))
    }
    fn selected(&self, all: bool, uris: &[String]) -> Result<Vec<Item>, String> {
        if all {
            return Ok(self.items.clone());
        }
        let mut result = Vec::new();
        for uri in uris {
            let item = self
                .items
                .iter()
                .find(|item| &item.uri == uri)
                .ok_or("Trash selection expired; refresh the view.")?;
            if !result.contains(item) {
                result.push(item.clone());
            }
        }
        if result.is_empty() {
            return Err("Select at least one Trash item.".into());
        }
        Ok(result)
    }
    fn prepare(&mut self, all: bool, uris: &[String]) -> Result<String, String> {
        self.confirmation = None;
        self.items = list()?;
        let items: Result<Vec<_>, _> = self.selected(all, uris)?.iter().map(detail).collect();
        let items = items?;
        if items.is_empty() {
            return Err("Trash is empty.".into());
        }
        if items
            .iter()
            .any(|item| item.identity.is_empty() || item.backing.is_none())
        {
            return Err("The Trash provider did not report stable item identities; deletion is unavailable.".into());
        }
        self.next_token += 1;
        let deadline = Instant::now() + Duration::from_millis(SUMMARY_BUDGET_MS);
        let mut bytes = 0;
        let mut partial = false;
        for item in &items {
            let size = item
                .backing
                .as_ref()
                .ok_or("Trash backing identity is unavailable.")?
                .bytes(deadline);
            bytes += size.bytes;
            partial |= size.partial;
        }
        let fields = format!(
            r#""token":{},"all":{},"count":{},"bytes":{},"partial":{}"#,
            self.next_token,
            all,
            items.len(),
            bytes,
            partial
        );
        self.confirmation = Some(Confirmation {
            token: self.next_token,
            items,
            listing: self.items.clone(),
        });
        Ok(fields)
    }
    fn valid(&self, token: usize) -> Result<bool, String> {
        let confirmation = match self.confirmation.as_ref() {
            Some(c) if c.token == token => c,
            _ => return Ok(false),
        };
        let current = list()?;
        if current != confirmation.listing {
            return Ok(false);
        }
        for old in &confirmation.items {
            if !current.contains(&old.item)
                || old.identity.is_empty()
                || !old
                    .backing
                    .as_ref()
                    .map(Reviewed::unchanged)
                    .unwrap_or(false)
                || detail(&old.item)? != *old
            {
                return Ok(false);
            }
        }
        Ok(true)
    }
    fn restore(&mut self, all: bool, uris: &[String]) -> Result<String, String> {
        self.items = list()?;
        let selected = self.selected(all, uris)?;
        let mut done = 0;
        let mut failures = Vec::new();
        for item in &selected {
            match gio(&["trash", "--restore", &item.uri]) {
                Ok(_) => done += 1,
                Err(error) => failures.push(format!(
                    r#"{{"uri":"{}","error":"{}"}}"#,
                    escape(&item.uri),
                    escape(&error)
                )),
            }
        }
        self.confirmation = None;
        Ok(format!(
            r#""done":{},"failed":{},"failures":[{}]"#,
            done,
            failures.len(),
            failures.join(",")
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_or_duplicate_listing_fails_closed() {
        assert!(parse_list("").unwrap().is_empty());
        for text in [
            "bad",
            "file:///x\t/x",
            "trash:///\t/x",
            "trash:///a\trelative",
            "trash:///a\t/a\ntrash:///a\t/a",
        ] {
            assert!(parse_list(text).is_err());
        }
        assert_eq!(
            parse_list("trash:///a\t/tmp/a b\n").unwrap()[0].original,
            "/tmp/a b"
        );
    }
    #[test]
    fn selected_uris_never_accept_arbitrary_paths() {
        let session = Session {
            items: parse_list("trash:///a\t/tmp/a\n").unwrap(),
            ..Session::default()
        };
        assert!(session.selected(false, &["/tmp/a".into()]).is_err());
        assert!(session.selected(false, &[]).is_err());
        assert_eq!(
            session
                .selected(false, &["trash:///a".into(), "trash:///a".into()])
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn expired_confirmation_never_reaches_provider() {
        assert!(!Session::default().valid(1).unwrap());
    }
    #[test]
    fn attributes_require_exact_names() {
        let text = "  standard::size: 12\n  id::file: abc\n";
        assert_eq!(attribute(text, "standard::size"), Some("12"));
        assert_eq!(attribute(text, "standard::siz"), None);
    }
}
