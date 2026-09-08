use std::collections::HashMap;

pub struct Theme { pub foreground:String, pub muted:String, pub accent:String, pub error:String, pub background:String, pub symlink:String, pub executable:String }
impl Theme {
    pub fn load()->Self {
        let path=std::env::var("HOME").unwrap_or_default()+"/.local/state/omarchy/current/theme/colors.toml";
        let values=parse(&std::fs::read_to_string(path).unwrap_or_default());
        let role=|key:&str, fallback:&str,bg:bool|ansi(values.get(key).map(String::as_str).unwrap_or(fallback),bg);
        Self { foreground:role("foreground","#ffffff",false),muted:role("comment","#888888",false),accent:role("accent","#ffffff",false),error:role("color1","#ff0000",false),background:role("background","#000000",true),symlink:role("color6","#00ffff",false),executable:role("color2","#00ff00",false) }
    }
}
// Sample input: accent = "#a9b665"; values outside six-digit RGB are ignored.
fn parse(text:&str)->HashMap<String,String> {
    let mut out=HashMap::new();
    for line in text.lines() {
        if let Some((key,value))=line.split_once('=') {
            let value=value.trim().trim_matches('"');
            if value.len()==7 && value.starts_with('#') && value[1..].bytes().all(|b|b.is_ascii_hexdigit()) { out.insert(key.trim().into(),value.into()); }
        }
    }
    out
}
fn ansi(hex:&str,bg:bool)->String {
    let channel=|start|u8::from_str_radix(&hex[start..start+2],16).unwrap_or(0);
    format!("\x1b[{};2;{};{};{}m",if bg {48}else{38},channel(1),channel(3),channel(5))
}
