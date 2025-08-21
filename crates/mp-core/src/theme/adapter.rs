use super::{color::ThemeColor, style::ThemeStyle};

/// Base trait for theme adapters that convert theme types to backend-specific types
pub trait ThemeAdapter {
    /// The backend-specific color type
    type Color;
    /// The backend-specific style type
    type Style;

    /// Convert ThemeColor to backend-specific color
    fn to_color(&self, color: &ThemeColor) -> Self::Color;

    /// Convert ThemeStyle to backend-specific style
    fn to_style(&self, style: &ThemeStyle) -> Self::Style;
}
