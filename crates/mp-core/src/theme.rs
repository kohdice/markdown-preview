use crossterm::style::{Attribute, Color, StyledContent, Stylize};

pub trait MarkdownTheme {
    fn heading_color(&self, level: u8) -> Color;
    fn strong_color(&self) -> Color;
    fn emphasis_color(&self) -> Color;
    fn link_color(&self) -> Color;
    fn code_color(&self) -> Color;
    fn code_background(&self) -> Color;
    fn list_marker_color(&self) -> Color;
    fn delimiter_color(&self) -> Color;
    fn text_color(&self) -> Color;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SolarizedOsaka;

impl SolarizedOsaka {
    const BASE02: Color = Color::Rgb { r: 7, g: 54, b: 66 };
    const BASE01: Color = Color::Rgb {
        r: 88,
        g: 110,
        b: 117,
    };
    const BASE0: Color = Color::Rgb {
        r: 131,
        g: 148,
        b: 150,
    };
    const YELLOW: Color = Color::Rgb {
        r: 181,
        g: 137,
        b: 0,
    };
    const ORANGE: Color = Color::Rgb {
        r: 203,
        g: 75,
        b: 22,
    };
    const MAGENTA: Color = Color::Rgb {
        r: 211,
        g: 54,
        b: 130,
    };
    const BLUE: Color = Color::Rgb {
        r: 38,
        g: 139,
        b: 210,
    };
    const CYAN: Color = Color::Rgb {
        r: 42,
        g: 161,
        b: 152,
    };
    const GREEN: Color = Color::Rgb {
        r: 133,
        g: 153,
        b: 0,
    };
}

impl MarkdownTheme for SolarizedOsaka {
    fn heading_color(&self, level: u8) -> Color {
        match level {
            1 => Self::BLUE,
            2 => Self::GREEN,
            3 => Self::CYAN,
            4 => Self::YELLOW,
            5 => Self::ORANGE,
            _ => Self::MAGENTA,
        }
    }

    fn strong_color(&self) -> Color {
        Self::ORANGE
    }

    fn emphasis_color(&self) -> Color {
        Self::GREEN
    }

    fn link_color(&self) -> Color {
        Self::CYAN
    }

    fn code_color(&self) -> Color {
        Self::GREEN
    }

    fn code_background(&self) -> Color {
        Self::BASE02
    }

    fn list_marker_color(&self) -> Color {
        Self::BLUE
    }

    fn delimiter_color(&self) -> Color {
        Self::BASE01
    }

    fn text_color(&self) -> Color {
        Self::BASE0
    }
}

pub fn styled_text<S: AsRef<str>>(
    text: S,
    color: Color,
    bold: bool,
    italic: bool,
    underline: bool,
) -> StyledContent<String> {
    let mut styled = text.as_ref().to_string().with(color);
    if bold {
        styled = styled.attribute(Attribute::Bold);
    }
    if italic {
        styled = styled.attribute(Attribute::Italic);
    }
    if underline {
        styled = styled.attribute(Attribute::Underlined);
    }
    styled
}

pub fn styled_text_with_bg<S: AsRef<str>>(text: S, fg: Color, bg: Color) -> StyledContent<String> {
    text.as_ref().to_string().with(fg).on(bg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_solarized_osaka_theme_colors() {
        let theme = SolarizedOsaka;

        // Color comparison helper
        fn color_eq(c1: Color, c2: Color) -> bool {
            match (c1, c2) {
                (
                    Color::Rgb {
                        r: r1,
                        g: g1,
                        b: b1,
                    },
                    Color::Rgb {
                        r: r2,
                        g: g2,
                        b: b2,
                    },
                ) => r1 == r2 && g1 == g2 && b1 == b2,
                _ => false,
            }
        }

        assert!(color_eq(theme.heading_color(1), SolarizedOsaka::BLUE));
        assert!(color_eq(theme.heading_color(2), SolarizedOsaka::GREEN));
        assert!(color_eq(theme.heading_color(3), SolarizedOsaka::CYAN));
        assert!(color_eq(theme.heading_color(4), SolarizedOsaka::YELLOW));
        assert!(color_eq(theme.heading_color(5), SolarizedOsaka::ORANGE));
        assert!(color_eq(theme.heading_color(6), SolarizedOsaka::MAGENTA));

        assert!(color_eq(theme.strong_color(), SolarizedOsaka::ORANGE));
        assert!(color_eq(theme.emphasis_color(), SolarizedOsaka::GREEN));
        assert!(color_eq(theme.link_color(), SolarizedOsaka::CYAN));
        assert!(color_eq(theme.code_color(), SolarizedOsaka::GREEN));
        assert!(color_eq(theme.code_background(), SolarizedOsaka::BASE02));

        assert!(color_eq(theme.list_marker_color(), SolarizedOsaka::BLUE));
        assert!(color_eq(theme.delimiter_color(), SolarizedOsaka::BASE01));
        assert!(color_eq(theme.text_color(), SolarizedOsaka::BASE0));
    }

    #[test]
    fn test_styled_text_functions() {
        let text = "test";
        let color = Color::Rgb { r: 255, g: 0, b: 0 };
        let result = styled_text(text, color, true, false, false);
        assert!(format!("{}", result).contains("test"));

        let string = "test".to_string();
        let color = Color::Rgb { r: 0, g: 255, b: 0 };
        let result = styled_text(string, color, false, true, false);
        assert!(format!("{}", result).contains("test"));

        let fg = Color::Rgb {
            r: 255,
            g: 255,
            b: 255,
        };
        let bg = Color::Rgb { r: 0, g: 0, b: 0 };
        let result = styled_text_with_bg("test", fg, bg);
        assert!(format!("{}", result).contains("test"));

        let string = "test".to_string();
        let result = styled_text_with_bg(string, fg, bg);
        assert!(format!("{}", result).contains("test"));
    }
}
