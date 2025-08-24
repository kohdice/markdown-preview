use crossterm::style::{Attribute, Color, StyledContent, Stylize};

use mp_core::theme::{ThemeAdapter, ThemeColor, ThemeStyle};

pub struct CrosstermThemeAdapter;

impl ThemeAdapter for CrosstermThemeAdapter {
    type Color = Color;
    type Style = StyledContent<String>;

    fn to_color(&self, color: &ThemeColor) -> Self::Color {
        Color::Rgb {
            r: color.r,
            g: color.g,
            b: color.b,
        }
    }

    fn to_style(&self, style: &ThemeStyle) -> Self::Style {
        apply_style_attributes(String::new().with(self.to_color(&style.color)), style)
    }
}

pub trait CrosstermAdapter {
    fn to_crossterm_color(&self) -> Color;
}

impl CrosstermAdapter for ThemeColor {
    fn to_crossterm_color(&self) -> Color {
        let adapter = CrosstermThemeAdapter;
        adapter.to_color(self)
    }
}

fn apply_style_attributes(
    mut styled: StyledContent<String>,
    style: &ThemeStyle,
) -> StyledContent<String> {
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

pub fn styled_text<S: AsRef<str>>(text: S, style: &ThemeStyle) -> StyledContent<String> {
    let adapter = CrosstermThemeAdapter;
    let styled = text
        .as_ref()
        .to_string()
        .with(adapter.to_color(&style.color));
    apply_style_attributes(styled, style)
}

pub fn styled_text_with_bg<S: AsRef<str>>(
    text: S,
    style: &ThemeStyle,
    bg: &ThemeColor,
) -> StyledContent<String> {
    let adapter = CrosstermThemeAdapter;
    let styled = text
        .as_ref()
        .to_string()
        .with(adapter.to_color(&style.color))
        .on(adapter.to_color(bg));
    apply_style_attributes(styled, style)
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
        let styled = styled_text("test", &style);
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
