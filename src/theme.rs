use colored::*;

pub trait MarkdownTheme {
    fn heading_color(&self, level: u8) -> (u8, u8, u8);
    fn strong_color(&self) -> (u8, u8, u8);
    fn emphasis_color(&self) -> (u8, u8, u8);
    fn link_color(&self) -> (u8, u8, u8);
    fn code_color(&self) -> (u8, u8, u8);
    fn code_background(&self) -> (u8, u8, u8);
    fn list_marker_color(&self) -> (u8, u8, u8);
    fn delimiter_color(&self) -> (u8, u8, u8);
    fn text_color(&self) -> (u8, u8, u8);
    fn cyan(&self) -> (u8, u8, u8);
}

#[derive(Debug, Clone, Copy)]
pub struct SolarizedOsaka;

impl SolarizedOsaka {
    const BASE02: (u8, u8, u8) = (7, 54, 66);
    const BASE01: (u8, u8, u8) = (88, 110, 117);
    const BASE0: (u8, u8, u8) = (131, 148, 150);
    const YELLOW: (u8, u8, u8) = (181, 137, 0);
    const ORANGE: (u8, u8, u8) = (203, 75, 22);
    const MAGENTA: (u8, u8, u8) = (211, 54, 130);
    const BLUE: (u8, u8, u8) = (38, 139, 210);
    const CYAN: (u8, u8, u8) = (42, 161, 152);
    const GREEN: (u8, u8, u8) = (133, 153, 0);
}

impl MarkdownTheme for SolarizedOsaka {
    fn heading_color(&self, level: u8) -> (u8, u8, u8) {
        match level {
            1 => Self::BLUE,
            2 => Self::GREEN,
            3 => Self::CYAN,
            4 => Self::YELLOW,
            5 => Self::ORANGE,
            _ => Self::MAGENTA,
        }
    }

    fn strong_color(&self) -> (u8, u8, u8) {
        Self::ORANGE
    }

    fn emphasis_color(&self) -> (u8, u8, u8) {
        Self::GREEN
    }

    fn link_color(&self) -> (u8, u8, u8) {
        Self::CYAN
    }

    fn code_color(&self) -> (u8, u8, u8) {
        Self::GREEN
    }

    fn code_background(&self) -> (u8, u8, u8) {
        Self::BASE02
    }

    fn list_marker_color(&self) -> (u8, u8, u8) {
        Self::BLUE
    }

    fn delimiter_color(&self) -> (u8, u8, u8) {
        Self::BASE01
    }

    fn text_color(&self) -> (u8, u8, u8) {
        Self::BASE0
    }

    fn cyan(&self) -> (u8, u8, u8) {
        Self::CYAN
    }
}

pub fn styled_text<S: AsRef<str>>(
    text: S,
    color: (u8, u8, u8),
    bold: bool,
    italic: bool,
    underline: bool,
) -> ColoredString {
    let mut result = text.as_ref().truecolor(color.0, color.1, color.2);
    if bold {
        result = result.bold();
    }
    if italic {
        result = result.italic();
    }
    if underline {
        result = result.underline();
    }
    result
}

pub fn styled_text_with_bg<S: AsRef<str>>(
    text: S,
    fg: (u8, u8, u8),
    bg: (u8, u8, u8),
) -> ColoredString {
    text.as_ref()
        .on_truecolor(bg.0, bg.1, bg.2)
        .truecolor(fg.0, fg.1, fg.2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_solarized_osaka_theme_colors() {
        let theme = SolarizedOsaka;

        // Heading colors by level
        assert_eq!(theme.heading_color(1), SolarizedOsaka::BLUE);
        assert_eq!(theme.heading_color(2), SolarizedOsaka::GREEN);
        assert_eq!(theme.heading_color(3), SolarizedOsaka::CYAN);
        assert_eq!(theme.heading_color(4), SolarizedOsaka::YELLOW);
        assert_eq!(theme.heading_color(5), SolarizedOsaka::ORANGE);
        assert_eq!(theme.heading_color(6), SolarizedOsaka::MAGENTA);

        // Text style colors
        assert_eq!(theme.strong_color(), SolarizedOsaka::ORANGE);
        assert_eq!(theme.emphasis_color(), SolarizedOsaka::GREEN);
        assert_eq!(theme.link_color(), SolarizedOsaka::CYAN);
        assert_eq!(theme.code_color(), SolarizedOsaka::GREEN);
        assert_eq!(theme.code_background(), SolarizedOsaka::BASE02);

        // UI element colors
        assert_eq!(theme.list_marker_color(), SolarizedOsaka::BLUE);
        assert_eq!(theme.delimiter_color(), SolarizedOsaka::BASE01);
        assert_eq!(theme.text_color(), SolarizedOsaka::BASE0);
        assert_eq!(theme.cyan(), SolarizedOsaka::CYAN);
    }

    #[test]
    fn test_styled_text_functions() {
        // Test basic styled_text with &str
        let text = "test";
        let result = styled_text(text, (255, 0, 0), true, false, false);
        assert!(result.to_string().contains("test"));

        // Test styled_text with String
        let string = String::from("test");
        let result = styled_text(string, (0, 255, 0), false, true, false);
        assert!(result.to_string().contains("test"));

        // Test styled_text_with_bg with &str
        let result = styled_text_with_bg("test", (255, 255, 255), (0, 0, 0));
        assert!(result.to_string().contains("test"));

        // Test styled_text_with_bg with String
        let string = String::from("test");
        let result = styled_text_with_bg(string, (255, 255, 255), (0, 0, 0));
        assert!(result.to_string().contains("test"));
    }
}
