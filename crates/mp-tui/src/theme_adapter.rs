use mp_core::theme::{ThemeColor, ThemeStyle};
use ratatui::style::{Color, Modifier, Style};

/// Adapter trait for converting ThemeColor to Ratatui Color
pub trait RatatuiAdapter {
    fn to_ratatui_color(&self) -> Color;
}

/// Adapter trait for converting ThemeStyle to Ratatui Style
pub trait RatatuiStyleAdapter {
    fn to_ratatui_style(&self) -> Style;
}

impl RatatuiAdapter for ThemeColor {
    fn to_ratatui_color(&self) -> Color {
        Color::Rgb(self.r, self.g, self.b)
    }
}

impl RatatuiStyleAdapter for ThemeStyle {
    fn to_ratatui_style(&self) -> Style {
        let mut style = Style::default().fg(self.color.to_ratatui_color());
        let mut modifiers = Modifier::empty();

        if self.bold {
            modifiers |= Modifier::BOLD;
        }
        if self.italic {
            modifiers |= Modifier::ITALIC;
        }
        if self.underline {
            modifiers |= Modifier::UNDERLINED;
        }

        if !modifiers.is_empty() {
            style = style.add_modifier(modifiers);
        }

        style
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_theme_color_conversion() {
        let theme_color = ThemeColor {
            r: 255,
            g: 128,
            b: 64,
        };
        let ratatui_color = theme_color.to_ratatui_color();
        match ratatui_color {
            Color::Rgb(r, g, b) => {
                assert_eq!(r, 255);
                assert_eq!(g, 128);
                assert_eq!(b, 64);
            }
            _ => panic!("Expected RGB color"),
        }
    }

    #[test]
    fn test_theme_style_conversion() {
        let theme_style = ThemeStyle {
            color: ThemeColor { r: 255, g: 0, b: 0 },
            bold: true,
            italic: false,
            underline: true,
        };
        let ratatui_style = theme_style.to_ratatui_style();

        // Check color
        match ratatui_style.fg {
            Some(Color::Rgb(r, g, b)) => {
                assert_eq!(r, 255);
                assert_eq!(g, 0);
                assert_eq!(b, 0);
            }
            _ => panic!("Expected RGB color"),
        }

        // Check modifiers
        assert!(ratatui_style.add_modifier.contains(Modifier::BOLD));
        assert!(ratatui_style.add_modifier.contains(Modifier::UNDERLINED));
        assert!(!ratatui_style.add_modifier.contains(Modifier::ITALIC));
    }

    #[test]
    fn test_style_with_all_modifiers() {
        let theme_style = ThemeStyle {
            color: ThemeColor { r: 0, g: 255, b: 0 },
            bold: true,
            italic: true,
            underline: true,
        };
        let ratatui_style = theme_style.to_ratatui_style();

        assert!(ratatui_style.add_modifier.contains(Modifier::BOLD));
        assert!(ratatui_style.add_modifier.contains(Modifier::ITALIC));
        assert!(ratatui_style.add_modifier.contains(Modifier::UNDERLINED));
    }

    #[test]
    fn test_style_with_no_modifiers() {
        let theme_style = ThemeStyle {
            color: ThemeColor {
                r: 100,
                g: 100,
                b: 100,
            },
            bold: false,
            italic: false,
            underline: false,
        };
        let ratatui_style = theme_style.to_ratatui_style();

        assert!(ratatui_style.add_modifier.is_empty());
    }
}
