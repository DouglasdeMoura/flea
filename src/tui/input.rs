#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Key {
    pub name: String,
    pub text: String,
    pub mods: String,
}
impl Key {
    fn named(name: &str, mods: &str) -> Self {
        Self {
            name: name.into(),
            text: String::new(),
            mods: mods.into(),
        }
    }
    fn character(c: char, mods: &str) -> Self {
        let name = match c {
            ' ' => "Space".into(),
            ',' => "Comma".into(),
            '.' => "Period".into(),
            _ => c.to_uppercase().to_string(),
        };
        Self {
            name,
            text: c.to_string(),
            mods: mods.into(),
        }
    }
}
#[derive(Default)]
pub struct Decoder {
    pending: Vec<u8>,
    string_control: bool,
    pub sixel: bool,
}
impl Decoder {
    pub fn feed(&mut self, bytes: &[u8], idle: bool) -> Vec<Key> {
        self.pending.extend_from_slice(bytes);
        let mut out = Vec::new();
        while !self.pending.is_empty() {
            if self.string_control {
                let end = self.pending.iter().enumerate().find_map(|(i, byte)| {
                    if *byte == 7 || *byte == 0x9c {
                        Some(i + 1)
                    } else if *byte == 27 && self.pending.get(i + 1) == Some(&b'\\') {
                        Some(i + 2)
                    } else {
                        None
                    }
                });
                if let Some(end) = end {
                    self.pending.drain(..end);
                    self.string_control = false;
                    continue;
                }
                // Keep only a split ST introducer; terminal reply payloads never become listing keys.
                let escape = self.pending.last() == Some(&27);
                self.pending.clear();
                if escape {
                    self.pending.push(27);
                }
                break;
            }
            if matches!(self.pending[0], 0x90 | 0x9d | 0x9e | 0x9f) {
                self.pending.remove(0);
                self.string_control = true;
                continue;
            }
            if self.pending[0] == 27 {
                if self.pending.len() == 1 {
                    if idle {
                        self.pending.remove(0);
                        out.push(Key::named("Escape", ""));
                    }
                    break;
                }
                if matches!(self.pending[1], b']' | b'P' | b'_' | b'^') {
                    self.pending.drain(..2);
                    self.string_control = true;
                    continue;
                }
                if self.pending[1] == b'[' {
                    let Some(end) = self.pending[2..]
                        .iter()
                        .position(|c| (0x40..=0x7e).contains(c))
                        .map(|i| i + 2)
                    else {
                        if self.pending.len() > 64 {
                            self.pending.clear();
                        }
                        break;
                    };
                    let sequence = String::from_utf8_lossy(&self.pending[2..=end]).into_owned();
                    self.pending.drain(..=end);
                    if sequence.starts_with('?')
                        && sequence.ends_with('c')
                        && sequence[1..sequence.len() - 1].split(';').any(|p| p == "4")
                    {
                        self.sixel = true;
                    }
                    if let Some(key) = csi(&sequence) {
                        out.push(key);
                    }
                    continue;
                }
                if self.pending[1] == b'O' && self.pending.len() < 3 {
                    break;
                }
                if self.pending[1] == b'O' && self.pending.len() >= 3 {
                    let name = match self.pending[2] {
                        b'A' => "Up",
                        b'B' => "Down",
                        b'C' => "Right",
                        b'D' => "Left",
                        b'H' => "Home",
                        b'F' => "End",
                        _ => "",
                    };
                    if !name.is_empty() {
                        out.push(Key::named(name, ""));
                    }
                    self.pending.drain(..3);
                    continue;
                }
                let c = self.pending[1];
                self.pending.drain(..2);
                if c.is_ascii() {
                    out.push(Key::character(c as char, "alt"));
                }
                continue;
            }
            let first = self.pending[0];
            let named = match first {
                9 => Some("Tab"),
                10 | 13 => Some("Return"),
                127 | 8 => Some("Backspace"),
                _ => None,
            };
            if let Some(name) = named {
                self.pending.remove(0);
                out.push(Key::named(name, ""));
                continue;
            }
            if first < 32 {
                self.pending.remove(0);
                out.push(if first == 0 {
                    Key::named("Space", "ctrl")
                } else {
                    Key::character((first + 64) as char, "ctrl")
                });
                continue;
            }
            let width = if first < 128 {
                1
            } else if first < 224 {
                2
            } else if first < 240 {
                3
            } else {
                4
            };
            if self.pending.len() < width {
                break;
            }
            if let Ok(s) = std::str::from_utf8(&self.pending[..width]) {
                if let Some(c) = s.chars().next() {
                    out.push(Key::character(c, ""));
                }
            }
            self.pending.drain(..width);
        }
        out
    }
}
// Sample input: 1;5D, 2;2~, 32;5u; kitty flag 1 leaves ordinary text in legacy form.
fn csi(text: &str) -> Option<Key> {
    let last = text.chars().last()?;
    let values: Vec<u32> = text[..text.len() - 1]
        .split(';')
        .map(|v| v.split(':').next().unwrap_or("").parse().unwrap_or(0))
        .collect();
    let code = *values.first().unwrap_or(&0);
    let modifier = values.get(1).copied().unwrap_or(1).saturating_sub(1);
    let mods = match (
        modifier & 4 != 0,
        modifier & 2 != 0,
        modifier & 1 != 0,
        modifier & 8 != 0,
    ) {
        (true, _, true, _) => "ctrlshift",
        (true, _, false, _) => "ctrl",
        (_, true, _, _) => "alt",
        (_, _, _, true) => "super",
        (_, _, true, _) => "shift",
        _ => "",
    };
    if last == 'u' {
        return char::from_u32(code).map(|c| match c {
            '\r' => Key::named("Return", mods),
            '\t' => Key::named("Tab", mods),
            '\u{1b}' => Key::named("Escape", mods),
            _ => Key::character(c, mods),
        });
    }
    let name = match last {
        'A' => "Up",
        'B' => "Down",
        'C' => "Right",
        'D' => "Left",
        'H' => "Home",
        'F' => "End",
        'Z' => return Some(Key::named("Tab", "shift")),
        '~' => match code {
            1 | 7 => "Home",
            2 => "Insert",
            3 => "Delete",
            4 | 8 => "End",
            5 => "PageUp",
            6 => "PageDown",
            _ => return None,
        },
        _ => return None,
    };
    Some(Key::named(name, mods))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_replies_never_become_file_actions() {
        let mut decoder = Decoder::default();
        assert!(decoder.feed(b"\x1b_Gi=42;error: ddd", false).is_empty());
        assert!(decoder.feed(&vec![b'd'; 4096], false).is_empty());
        assert!(decoder.feed(b"\x1b", false).is_empty());
        assert_eq!(decoder.feed(b"\\j", false), vec![Key::character('j', "")]);
        assert!(decoder
            .feed(b"\x1b]52;c;ddd\x07\x1bPddd\x1b\\", false)
            .is_empty());
    }

    #[test]
    fn split_sequences_and_utf8_are_retained() {
        let mut d = Decoder::default();
        assert!(d.feed(b"\x1b[1;", false).is_empty());
        assert_eq!(d.feed(b"5D", false), vec![Key::named("Left", "ctrl")]);
        assert!(d.feed(&[0xc3], false).is_empty());
        assert_eq!(d.feed(&[0xa9], false)[0].text, "é");
    }
    #[test]
    fn legacy_and_kitty_forms_coexist() {
        let mut d = Decoder::default();
        assert_eq!(
            d.feed(b" \x1b[32;5u\x1b[2;2~", false),
            vec![
                Key::character(' ', ""),
                Key::character(' ', "ctrl"),
                Key::named("Insert", "shift")
            ]
        );
        assert!(d.feed(b"\x1b", false).is_empty());
        assert_eq!(d.feed(b"", true), vec![Key::named("Escape", "")]);
    }
}
