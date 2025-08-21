use ratatui::style::{Color, Modifier, Style};

use mp_core::theme::{ThemeAdapter, ThemeColor, ThemeStyle};

/// Ratatui-specific theme adapter
pub struct RatatuiThemeAdapter;

impl ThemeAdapter for RatatuiThemeAdapter {
    type Color = Color;
    type Style = Style;

    fn to_color(&self, color: &ThemeColor) -> Self::Color {
        Color::Rgb(color.r, color.g, color.b)
    }

    fn to_style(&self, style: &ThemeStyle) -> Self::Style {
        let mut ratatui_style = Style::default().fg(self.to_color(&style.color));
        let mut modifiers = Modifier::empty();

        if style.bold {
            modifiers |= Modifier::BOLD;
        }
        if style.italic {
            modifiers |= Modifier::ITALIC;
        }
        if style.underline {
            modifiers |= Modifier::UNDERLINED;
        }

        if !modifiers.is_empty() {
            ratatui_style = ratatui_style.add_modifier(modifiers);
        }

        ratatui_style
    }
}

/// Legacy adapter trait for converting ThemeColor to Ratatui Color
/// Kept for backward compatibility
pub trait RatatuiAdapter {
    fn to_ratatui_color(&self) -> Color;
}

/// Legacy adapter trait for converting ThemeStyle to Ratatui Style
/// Kept for backward compatibility
pub trait RatatuiStyleAdapter {
    fn to_ratatui_style(&self) -> Style;
}

impl RatatuiAdapter for ThemeColor {
    fn to_ratatui_color(&self) -> Color {
        let adapter = RatatuiThemeAdapter;
        adapter.to_color(self)
    }
}

impl RatatuiStyleAdapter for ThemeStyle {
    fn to_ratatui_style(&self) -> Style {
        let adapter = RatatuiThemeAdapter;
        adapter.to_style(self)
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
