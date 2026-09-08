use std::time::Duration;

const SPIRAL: [&str; 10] = [
    "███████████",
    "█         █",
    "█ ███████ █",
    "█ █     █ █",
    "█ █ ███ █ █",
    "█ █ █ █ █ █",
    "█ █ █   █ █",
    "█ █ █████ █",
    "█ █       █",
    "█ █████████",
];
const PHRASES: [&str; 8] = [
    "NOTHING HERE YET",
    "A VERY TIDY DIRECTORY",
    "NOT A FILE IN SIGHT",
    "THIS FOLDER KEEPS ITS SECRETS",
    "QUIET IN HERE",
    "NO CLUTTER TO REPORT",
    "WAITING FOR SOMETHING TO LAND",
    "EMPTY, AND THAT IS FINE",
];
const ROTATE_MS: u128 = 2800;
pub fn line(y: usize, height: usize, width: usize, elapsed: Duration) -> String {
    let phrase = PHRASES[(elapsed.as_millis() / ROTATE_MS) as usize % PHRASES.len()];
    let block_height = SPIRAL.len() + 2;
    let start = height.saturating_sub(block_height) / 2;
    let text = if height >= block_height && y >= start && y < start + SPIRAL.len() {
        SPIRAL[y - start]
    } else if y
        == if height >= block_height {
            start + SPIRAL.len() + 1
        } else {
            height / 2
        }
    {
        phrase
    } else {
        ""
    };
    let padding = width.saturating_sub(text.chars().count()) / 2;
    super::render::fit(&format!("{}{}", " ".repeat(padding), text), width)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn caption_rotates_at_oem_cadence() {
        assert_ne!(
            line(5, 10, 40, Duration::ZERO),
            line(5, 10, 40, Duration::from_millis(2800))
        );
        assert_eq!(
            line(5, 10, 40, Duration::ZERO),
            line(5, 10, 40, Duration::from_millis(1000))
        );
    }
}
