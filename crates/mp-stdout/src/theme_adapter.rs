use crossterm::style::{Attribute, Color, StyledContent, Stylize};
use mp_core::theme::{ThemeColor, ThemeStyle};

/// Adapter trait for converting ThemeColor to Crossterm Color
pub trait CrosstermAdapter {
    fn to_crossterm_color(&self) -> Color;
}

/// Adapter trait for applying ThemeStyle to text using Crossterm
pub trait CrosstermStyleAdapter {
    fn apply_crossterm_style<S: AsRef<str>>(&self, text: S) -> StyledContent<String>;
}

impl CrosstermAdapter for ThemeColor {
    fn to_crossterm_color(&self) -> Color {
        Color::Rgb {
            r: self.r,
            g: self.g,
            b: self.b,
        }
    }
}

impl CrosstermStyleAdapter for ThemeStyle {
    fn apply_crossterm_style<S: AsRef<str>>(&self, text: S) -> StyledContent<String> {
        let mut styled = text
            .as_ref()
            .to_string()
            .with(self.color.to_crossterm_color());
        if self.bold {
            styled = styled.attribute(Attribute::Bold);
        }
        if self.italic {
            styled = styled.attribute(Attribute::Italic);
        }
        if self.underline {
            styled = styled.attribute(Attribute::Underlined);
        }
        styled
    }
}

/// Helper function to apply style to text
pub fn styled_text<S: AsRef<str>>(text: S, style: &ThemeStyle) -> StyledContent<String> {
    style.apply_crossterm_style(text)
}

/// Helper function to apply style with background color
pub fn styled_text_with_bg<S: AsRef<str>>(
    text: S,
    style: &ThemeStyle,
    bg: &ThemeColor,
) -> StyledContent<String> {
    let mut styled = text
        .as_ref()
        .to_string()
        .with(style.color.to_crossterm_color())
        .on(bg.to_crossterm_color());
    if style.bold {
        styled = styled.attribute(Attribute::Bold);
    }
    if style.italic {
        styled = styled.attribute(Attribute::Italic);
    }
    if style.underline {
        styled = styled.attribute(Attribute::Underlined);
    }
    styled
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_theme_color_to_crossterm() {
        let theme_color = ThemeColor {
            r: 255,
            g: 128,
            b: 64,
        };
        let crossterm_color = theme_color.to_crossterm_color();
        match crossterm_color {
            Color::Rgb { r, g, b } => {
                assert_eq!(r, 255);
                assert_eq!(g, 128);
                assert_eq!(b, 64);
            }
            _ => panic!("Expected RGB color"),
        }
    }

    #[test]
    fn test_theme_style_application() {
        let style = ThemeStyle {
            color: ThemeColor { r: 255, g: 0, b: 0 },
            bold: true,
            italic: false,
            underline: true,
        };
        let styled = style.apply_crossterm_style("test");
        let formatted = format!("{}", styled);
        assert!(formatted.contains("test"));
    }

    #[test]
    fn test_styled_text_helper() {
        let style = ThemeStyle {
            color: ThemeColor { r: 0, g: 255, b: 0 },
            bold: false,
            italic: true,
            underline: false,
        };
        let styled = styled_text("hello", &style);
        let formatted = format!("{}", styled);
        assert!(formatted.contains("hello"));
    }

    #[test]
    fn test_styled_text_with_bg_helper() {
        let style = ThemeStyle {
            color: ThemeColor {
                r: 255,
                g: 255,
                b: 255,
            },
            bold: true,
            italic: false,
            underline: false,
        };
        let bg = ThemeColor { r: 0, g: 0, b: 0 };
        let styled = styled_text_with_bg("text", &style, &bg);
        let formatted = format!("{}", styled);
        assert!(formatted.contains("text"));
    }
}
