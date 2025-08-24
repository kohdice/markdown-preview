use super::{color::ThemeColor, style::ThemeStyle};

pub trait ThemeAdapter {
    type Color;
    type Style;

    fn to_color(&self, color: &ThemeColor) -> Self::Color;

    fn to_style(&self, style: &ThemeStyle) -> Self::Style;
}
