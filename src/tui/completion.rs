use crate::jsondoc::Json;
use std::path::{Path, PathBuf};

pub fn expand(value: &str, home: &Path, current: &Path) -> PathBuf {
    if value == "~" {
        home.into()
    } else if let Some(tail) = value.strip_prefix("~/") {
        home.join(tail)
    } else {
        current.join(value)
    }
}

pub fn suggest(value: &str, current: &Path) -> String {
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let settings = crate::uistore::Store::user().map(|store| store.read()).unwrap_or(Json::Null);
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home.join(".config"));
    let dirs = std::fs::read_to_string(config.join("user-dirs.dirs")).unwrap_or_default();
    let mut places = vec![("Home".into(), home.to_string_lossy().into_owned())];
    // Sample input: XDG_DOWNLOAD_DIR="$HOME/Downloads"; this file is data, never shell code.
    for line in dirs.lines() {
        let Some((key, path)) = line.trim().split_once('=') else { continue };
        if !key.starts_with("XDG_") || !key.ends_with("_DIR") { continue; }
        let Some(path) = path.trim().strip_prefix('"').and_then(|v| v.strip_suffix('"')) else { continue };
        let path = path.replace("$HOME", &home.to_string_lossy());
        if Path::new(&path).is_absolute() {
            places.push((Path::new(&path).file_name().unwrap_or_default().to_string_lossy().into_owned(), path));
        }
    }
    if let Some(records) = settings.get("places").and_then(|p| p.get("favourites")).and_then(Json::as_array) {
        for record in records {
            let label = record.get("label").and_then(Json::as_str).unwrap_or("");
            let path = record.get("path").and_then(Json::as_str).unwrap_or("");
            if !label.is_empty() && (path.starts_with('/') || path == "~" || path.starts_with("~/")) {
                places.push((label.into(), path.into()));
            }
        }
    }
    complete(value, current, &home, &places)
}

fn complete(value: &str, current: &Path, home: &Path, places: &[(String, String)]) -> String {
    if value.is_empty() { return String::new(); }
    if value == "~" { return "~/".into(); }
    for (label, path) in places {
        if label.to_lowercase().starts_with(&value.to_lowercase()) || path.starts_with(value) {
            return path.clone();
        }
    }
    let expanded = expand(value, home, current);
    let (parent, prefix) = if value.ends_with('/') {
        (expanded.as_path(), "")
    } else {
        (expanded.parent().unwrap_or(current), expanded.file_name().and_then(|n| n.to_str()).unwrap_or(""))
    };
    let Ok(entries) = std::fs::read_dir(parent) else { return String::new() };
    let mut names: Vec<String> = entries.filter_map(Result::ok).filter_map(|entry| {
        let name = entry.file_name().into_string().ok()?;
        (name.starts_with(prefix) && entry.file_type().is_ok_and(|t| t.is_dir())).then_some(name)
    }).collect();
    names.sort();
    let Some(name) = names.first() else { return String::new() };
    format!("{}{}/", &value[..value.len() - prefix.len()], name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn completion_follows_prefix_without_importing_or_rewriting_places() {
        let root = TestDir::new("tui-completion");
        std::fs::create_dir(root.join("Documents")).unwrap();
        std::fs::create_dir(root.join("Downloads")).unwrap();
        root.file("Door.txt", "not a directory");
        assert_eq!(complete("Do", root.path(), root.path(), &[]), "Documents/");
        assert_eq!(complete("Dow", root.path(), root.path(), &[]), "Downloads/");
        assert_eq!(complete("missing/", root.path(), root.path(), &[]), "");
        assert_eq!(expand("~/Documents", root.path(), Path::new("/")), root.join("Documents"));
        assert_eq!(complete("w", root.path(), root.path(), &[("Work".into(), "/data/work".into())]), "/data/work");
    }
}
