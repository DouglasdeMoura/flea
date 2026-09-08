use super::input::Key;
use std::collections::HashMap;

#[derive(Default)]
pub struct Map {
    blocks: Vec<(String, HashMap<String, String>)>,
}
impl Map {
    pub fn load() -> Self {
        Self::parse(include_str!("../../keys.toml"))
    }
    // Sample input: [[text]] followed by char = "j" and action = "cursorDown".
    fn parse(text: &str) -> Self {
        let mut map = Self::default();
        for line in text.lines().map(str::trim) {
            if line.starts_with("[[") && line.ends_with("]]") {
                map.blocks
                    .push((line[2..line.len() - 2].into(), HashMap::new()));
                continue;
            }
            if line.starts_with('#') {
                continue;
            }
            if let Some((key, value)) = line.split_once('=') {
                let value = value.trim();
                if let Ok(crate::jsondoc::Json::Str(value)) = crate::jsondoc::parse(value) {
                    if let Some((_, block)) = map.blocks.last_mut() {
                        block.insert(key.trim().into(), value);
                    }
                }
            }
        }
        map
    }
    pub fn action(&self, key: &Key, preset: &str) -> String {
        self.in_context(key, preset, "listing")
    }
    pub fn in_context(&self, key: &Key, preset: &str, context: &str) -> String {
        if key.name == "Insert" && key.mods == "ctrl" {
            return "copy".into();
        }
        if key.name == "Insert" && key.mods == "shift" {
            return "paste".into();
        }
        if preset == "mac" && key.mods == "ctrl" && key.name == "X" {
            return String::new();
        }
        for name in [preset, "all"] {
            for (kind, block) in &self.blocks {
                let here = get(block, "context");
                let mods = get(block, "mods");
                let key_matches = if mods == "text" {
                    matches!(key.mods.as_str(), "" | "shift") && get(block, "key") == key.text
                } else {
                    (if mods == "none" { "" } else { mods }) == key.mods && get(block, "key") == key.name
                };
                if kind == "preset" && get(block, "name") == name
                    && get(block, "frontend") != "gui"
                    && (here == context || here == "all" || (here.is_empty() && context == "listing"))
                    && key_matches
                {
                    return get(block, "action").into();
                }
            }
        }
        if context != "listing" { return String::new(); }
        for (kind, block) in &self.blocks {
            let matches = if key.mods.is_empty() {
                (kind == "text" && get(block, "char") == key.text && !key.text.is_empty())
                    || (kind == "code" && get(block, "key") == key.name)
            } else {
                kind == &key.mods && get(block, "key") == key.name
            };
            if matches {
                return get(block, "action").into();
            }
        }
        String::new()
    }
    pub fn sheet(&self) -> Vec<String> {
        self.blocks
            .iter()
            .filter(|(kind, _)| kind == "sheet")
            .map(|(_, b)| format!("{}  {}", get(b, "keys"), get(b, "label")))
            .collect()
    }
}
fn get<'a>(map: &'a HashMap<String, String>, key: &str) -> &'a str {
    map.get(key).map(String::as_str).unwrap_or("")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compiled_source_drives_text_and_native_ctrl() {
        let map = Map::load();
        assert_eq!(
            map.action(
                &Key {
                    name: "J".into(),
                    text: "j".into(),
                    mods: "".into(),
                    pointer: None,
                },
                "default"
            ),
            "cursorDown"
        );
        assert_eq!(
            map.action(
                &Key {
                    name: "X".into(),
                    text: "X".into(),
                    mods: "ctrl".into(),
                    pointer: None,
                },
                "mac"
            ),
            ""
        );
        assert_eq!(
            map.action(
                &Key {
                    name: "Insert".into(),
                    text: "".into(),
                    mods: "shift".into(),
                    pointer: None,
                },
                "vim"
            ),
            "paste"
        );
    }
}
