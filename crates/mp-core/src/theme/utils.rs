use super::{color::*, style::ThemeStyle};

/// Merge two styles, with the second style taking precedence
pub fn merge_styles(base: &ThemeStyle, overlay: &ThemeStyle) -> ThemeStyle {
    ThemeStyle {
        color: overlay.color,
        bold: overlay.bold || base.bold,
        italic: overlay.italic || base.italic,
        underline: overlay.underline || base.underline,
    }
}

/// Create a dimmed version of a style (reduces color brightness by 30%)
pub fn dim_style(style: &ThemeStyle) -> ThemeStyle {
    ThemeStyle {
        color: adjust_brightness(&style.color, -30),
        ..*style
    }
}

/// Create a highlighted version of a style (increases brightness by 20%)
pub fn highlight_style(style: &ThemeStyle) -> ThemeStyle {
    ThemeStyle {
        color: adjust_brightness(&style.color, 20),
        bold: true,
        ..*style
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_styles() {
        let base = ThemeStyle {
            color: ThemeColor {
                r: 100,
                g: 100,
                b: 100,
            },
            bold: true,
            italic: false,
            underline: true,
        };

        let overlay = ThemeStyle {
            color: ThemeColor {
                r: 200,
                g: 200,
                b: 200,
            },
            bold: false,
            italic: true,
            underline: false,
        };

        let merged = merge_styles(&base, &overlay);
        assert_eq!(merged.color.r, 200);
        assert!(merged.bold); // base.bold || overlay.bold
        assert!(merged.italic); // overlay.italic
        assert!(merged.underline); // base.underline || overlay.underline
    }

    #[test]
    fn test_dim_style() {
        let style = ThemeStyle {
            color: ThemeColor {
                r: 100,
                g: 100,
                b: 100,
            },
            bold: true,
            italic: false,
            underline: false,
        };

        let dimmed = dim_style(&style);
        assert_eq!(dimmed.color.r, 70);
        assert_eq!(dimmed.color.g, 70);
        assert_eq!(dimmed.color.b, 70);
        assert_eq!(dimmed.bold, style.bold);
        assert_eq!(dimmed.italic, style.italic);
        assert_eq!(dimmed.underline, style.underline);
    }

    #[test]
    fn test_highlight_style() {
        let style = ThemeStyle {
            color: ThemeColor {
                r: 100,
                g: 100,
                b: 100,
            },
            bold: false,
            italic: true,
            underline: false,
        };

        let highlighted = highlight_style(&style);
        assert_eq!(highlighted.color.r, 120);
        assert_eq!(highlighted.color.g, 120);
        assert_eq!(highlighted.color.b, 120);
        assert!(highlighted.bold); // Always true for highlighted
        assert_eq!(highlighted.italic, style.italic);
        assert_eq!(highlighted.underline, style.underline);
    }
}
