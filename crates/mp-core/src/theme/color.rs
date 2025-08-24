#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThemeColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_theme_color_equality() {
        let color1 = ThemeColor { r: 255, g: 0, b: 0 };
        let color2 = ThemeColor { r: 255, g: 0, b: 0 };
        let color3 = ThemeColor { r: 0, g: 255, b: 0 };

        assert_eq!(color1, color2);
        assert_ne!(color1, color3);
    }
}
