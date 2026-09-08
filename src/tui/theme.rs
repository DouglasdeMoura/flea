use std::collections::HashMap;

pub struct Theme {
    pub foreground: String,
    pub muted: String,
    pub accent: String,
    pub error: String,
    pub background: String,
    pub symlink: String,
    pub executable: String,
    pub selected: String,
    pub border: String,
}
impl Theme {
    pub fn load() -> Self {
        let path = std::env::var("HOME").unwrap_or_default()
            + "/.local/state/omarchy/current/theme/colors.toml";
        let values = parse(&std::fs::read_to_string(path).unwrap_or_default());
        let role = |key: &str, fallback: &str, bg: bool| {
            ansi(values.get(key).map(String::as_str).unwrap_or(fallback), bg)
        };
        Self {
            foreground: role("foreground", "#ffffff", false),
            muted: role("muted", "#707880", false),
            accent: role("accent", "#ffffff", false),
            error: role("color1", "#ff0000", false),
            background: role("background", "#101315", true),
            symlink: role(if values.contains_key("cyan") { "cyan" } else { "color6" }, "#94e2d5", false),
            executable: role(if values.contains_key("green") { "green" } else { "color2" }, "#a6e3a1", false),
            selected: ansi(&blend(values.get("accent").map(String::as_str).unwrap_or("#ffffff"), values.get("background").map(String::as_str).unwrap_or("#101315"), 0.22), true),
            border: role("muted", "#707880", false),
        }
    }
}
fn blend(foreground: &str, background: &str, opacity: f64) -> String {
    let channel = |i| {
        let fg = u8::from_str_radix(&foreground[i..i + 2], 16).unwrap_or(0) as f64;
        let bg = u8::from_str_radix(&background[i..i + 2], 16).unwrap_or(0) as f64;
        (fg * opacity + bg * (1.0 - opacity)).round() as u8
    };
    format!("#{:02x}{:02x}{:02x}", channel(1), channel(3), channel(5))
}
// Sample input: accent = "#a9b665"; values outside six-digit RGB are ignored.
fn parse(text: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in text.lines() {
        if let Some((key, value)) = line.split_once('=') {
            let value = value.trim().trim_start_matches(['"', '\'']);
            let value = value.get(..7).unwrap_or("");
            if value.len() == 7
                && value.starts_with('#')
                && value[1..].bytes().all(|b| b.is_ascii_hexdigit())
            {
                out.insert(key.trim().into(), value.into());
            }
        }
    }
    out
}
fn ansi(hex: &str, bg: bool) -> String {
    let channel = |start| u8::from_str_radix(&hex[start..start + 2], 16).unwrap_or(0);
    format!(
        "\x1b[{};2;{};{};{}m",
        if bg { 48 } else { 38 },
        channel(1),
        channel(3),
        channel(5)
    )
}
