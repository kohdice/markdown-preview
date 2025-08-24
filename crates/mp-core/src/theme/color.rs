#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThemeColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// Calculate the relative luminance of a color using WCAG 2.0 formula
/// Returns a value between 0.0 (darkest) and 1.0 (lightest)
pub fn relative_luminance(color: &ThemeColor) -> f32 {
    let r = srgb_to_linear(color.r as f32 / 255.0);
    let g = srgb_to_linear(color.g as f32 / 255.0);
    let b = srgb_to_linear(color.b as f32 / 255.0);

    0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// Convert sRGB to linear RGB for luminance calculation
fn srgb_to_linear(channel: f32) -> f32 {
    if channel <= 0.03928 {
        channel / 12.92
    } else {
        ((channel + 0.055) / 1.055).powf(2.4)
    }
}

/// Calculate contrast ratio between two colors using WCAG 2.0 formula
/// Returns a value between 1.0 and 21.0
pub fn contrast_ratio(fg: &ThemeColor, bg: &ThemeColor) -> f32 {
    let l1 = relative_luminance(fg);
    let l2 = relative_luminance(bg);

    let lighter = l1.max(l2);
    let darker = l1.min(l2);

    (lighter + 0.05) / (darker + 0.05)
}

/// Check if the contrast ratio meets WCAG AA standard (4.5:1 for normal text)
pub fn meets_wcag_aa(fg: &ThemeColor, bg: &ThemeColor) -> bool {
    contrast_ratio(fg, bg) >= 4.5
}

/// Check if the contrast ratio meets WCAG AAA standard (7:1 for normal text)
pub fn meets_wcag_aaa(fg: &ThemeColor, bg: &ThemeColor) -> bool {
    contrast_ratio(fg, bg) >= 7.0
}

/// Adjust color brightness by a percentage (-100 to 100)
pub fn adjust_brightness(color: &ThemeColor, percent: i16) -> ThemeColor {
    let factor = 1.0 + (percent as f32 / 100.0);
    ThemeColor {
        r: ((color.r as f32 * factor).clamp(0.0, 255.0)) as u8,
        g: ((color.g as f32 * factor).clamp(0.0, 255.0)) as u8,
        b: ((color.b as f32 * factor).clamp(0.0, 255.0)) as u8,
    }
}

/// Mix two colors with the given ratio (0.0 = all color1, 1.0 = all color2)
pub fn mix_colors(color1: &ThemeColor, color2: &ThemeColor, ratio: f32) -> ThemeColor {
    let ratio = ratio.clamp(0.0, 1.0);
    let inv_ratio = 1.0 - ratio;

    ThemeColor {
        r: ((color1.r as f32 * inv_ratio + color2.r as f32 * ratio) as u8),
        g: ((color1.g as f32 * inv_ratio + color2.g as f32 * ratio) as u8),
        b: ((color1.b as f32 * inv_ratio + color2.b as f32 * ratio) as u8),
    }
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

    #[test]
    fn test_relative_luminance() {
        let white = ThemeColor {
            r: 255,
            g: 255,
            b: 255,
        };
        let black = ThemeColor { r: 0, g: 0, b: 0 };

        assert!((relative_luminance(&white) - 1.0).abs() < 0.01);
        assert!((relative_luminance(&black) - 0.0).abs() < 0.01);
    }

    #[test]
    fn test_contrast_ratio() {
        let white = ThemeColor {
            r: 255,
            g: 255,
            b: 255,
        };
        let black = ThemeColor { r: 0, g: 0, b: 0 };

        assert!((contrast_ratio(&white, &black) - 21.0).abs() < 0.1);
    }

    #[test]
    fn test_wcag_compliance() {
        let white = ThemeColor {
            r: 255,
            g: 255,
            b: 255,
        };
        let black = ThemeColor { r: 0, g: 0, b: 0 };
        let gray = ThemeColor {
            r: 128,
            g: 128,
            b: 128,
        };

        assert!(meets_wcag_aa(&white, &black));
        assert!(meets_wcag_aaa(&white, &black));
        assert!(!meets_wcag_aa(&white, &gray));
    }

    #[test]
    fn test_adjust_brightness() {
        let color = ThemeColor {
            r: 100,
            g: 100,
            b: 100,
        };

        let brighter = adjust_brightness(&color, 50);
        assert_eq!(brighter.r, 150);
        assert_eq!(brighter.g, 150);
        assert_eq!(brighter.b, 150);

        let darker = adjust_brightness(&color, -50);
        assert_eq!(darker.r, 50);
        assert_eq!(darker.g, 50);
        assert_eq!(darker.b, 50);

        let very_bright = adjust_brightness(&color, 200);
        assert_eq!(very_bright.r, 255);
        assert_eq!(very_bright.g, 255);
        assert_eq!(very_bright.b, 255);
    }

    #[test]
    fn test_mix_colors() {
        let red = ThemeColor { r: 255, g: 0, b: 0 };
        let blue = ThemeColor { r: 0, g: 0, b: 255 };

        let purple = mix_colors(&red, &blue, 0.5);
        assert_eq!(purple.r, 127);
        assert_eq!(purple.g, 0);
        assert_eq!(purple.b, 127);

        let mostly_red = mix_colors(&red, &blue, 0.25);
        assert_eq!(mostly_red.r, 191);
        assert_eq!(mostly_red.g, 0);
        assert_eq!(mostly_red.b, 63);
    }
}
