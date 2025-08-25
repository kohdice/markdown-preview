use super::color::ThemeColor;

#[derive(Debug, Clone, Copy)]
pub struct ThemeStyle {
    pub color: ThemeColor,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_theme_style_properties() {
        let style = ThemeStyle {
            color: ThemeColor { r: 255, g: 0, b: 0 },
            bold: true,
            italic: false,
            underline: true,
        };

        assert_eq!(style.color.r, 255);
        assert_eq!(style.color.g, 0);
        assert_eq!(style.color.b, 0);
        assert!(style.bold);
        assert!(!style.italic);
        assert!(style.underline);
    }
}
