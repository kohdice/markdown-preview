use super::{color::ThemeColor, style::ThemeStyle};

pub trait MarkdownTheme {
    fn heading_style(&self, level: u8) -> ThemeStyle;
    fn strong_style(&self) -> ThemeStyle;
    fn emphasis_style(&self) -> ThemeStyle;
    fn link_style(&self) -> ThemeStyle;
    fn code_style(&self) -> ThemeStyle;
    fn code_background(&self) -> ThemeColor;
    fn list_marker_style(&self) -> ThemeStyle;
    fn delimiter_style(&self) -> ThemeStyle;
    fn text_style(&self) -> ThemeStyle;
    fn focus_border_style(&self) -> ThemeStyle;

    fn status_normal_color(&self) -> ThemeColor;
    fn status_search_color(&self) -> ThemeColor;
    fn status_help_color(&self) -> ThemeColor;
    fn status_error_color(&self) -> ThemeColor;
    fn status_message_color(&self) -> ThemeColor;
    fn status_background_color(&self) -> ThemeColor;
}

/// Solarized Osaka theme implementation
#[derive(Debug, Clone, Copy, Default)]
pub struct SolarizedOsaka;

impl SolarizedOsaka {
    pub const BASE02: ThemeColor = ThemeColor { r: 7, g: 54, b: 66 };
    pub const BASE01: ThemeColor = ThemeColor {
        r: 88,
        g: 110,
        b: 117,
    };
    pub const BASE0: ThemeColor = ThemeColor {
        r: 131,
        g: 148,
        b: 150,
    };
    pub const YELLOW: ThemeColor = ThemeColor {
        r: 181,
        g: 137,
        b: 0,
    };
    pub const ORANGE: ThemeColor = ThemeColor {
        r: 203,
        g: 75,
        b: 22,
    };
    pub const MAGENTA: ThemeColor = ThemeColor {
        r: 211,
        g: 54,
        b: 130,
    };
    pub const BLUE: ThemeColor = ThemeColor {
        r: 38,
        g: 139,
        b: 210,
    };
    pub const CYAN: ThemeColor = ThemeColor {
        r: 42,
        g: 161,
        b: 152,
    };
    pub const GREEN: ThemeColor = ThemeColor {
        r: 133,
        g: 153,
        b: 0,
    };
    pub const RED: ThemeColor = ThemeColor {
        r: 220,
        g: 50,
        b: 47,
    };

    const STRONG: ThemeStyle = ThemeStyle {
        color: Self::ORANGE,
        bold: true,
        italic: false,
        underline: false,
    };

    const EMPHASIS: ThemeStyle = ThemeStyle {
        color: Self::GREEN,
        bold: false,
        italic: true,
        underline: false,
    };

    const LINK: ThemeStyle = ThemeStyle {
        color: Self::CYAN,
        bold: false,
        italic: false,
        underline: true,
    };

    const CODE: ThemeStyle = ThemeStyle {
        color: Self::GREEN,
        bold: false,
        italic: false,
        underline: false,
    };

    const LIST_MARKER: ThemeStyle = ThemeStyle {
        color: Self::BLUE,
        bold: false,
        italic: false,
        underline: false,
    };

    const DELIMITER: ThemeStyle = ThemeStyle {
        color: Self::BASE01,
        bold: false,
        italic: false,
        underline: false,
    };

    const TEXT: ThemeStyle = ThemeStyle {
        color: Self::BASE0,
        bold: false,
        italic: false,
        underline: false,
    };

    const FOCUS_BORDER: ThemeStyle = ThemeStyle {
        color: Self::BLUE,
        bold: false,
        italic: false,
        underline: false,
    };
}

impl MarkdownTheme for SolarizedOsaka {
    fn heading_style(&self, level: u8) -> ThemeStyle {
        let color = match level {
            1 => Self::BLUE,
            2 => Self::GREEN,
            3 => Self::CYAN,
            4 => Self::YELLOW,
            5 => Self::ORANGE,
            _ => Self::MAGENTA,
        };
        ThemeStyle {
            color,
            bold: level <= 2,
            italic: false,
            underline: false,
        }
    }

    fn strong_style(&self) -> ThemeStyle {
        Self::STRONG
    }

    fn emphasis_style(&self) -> ThemeStyle {
        Self::EMPHASIS
    }

    fn link_style(&self) -> ThemeStyle {
        Self::LINK
    }

    fn code_style(&self) -> ThemeStyle {
        Self::CODE
    }

    fn code_background(&self) -> ThemeColor {
        Self::BASE02
    }

    fn list_marker_style(&self) -> ThemeStyle {
        Self::LIST_MARKER
    }

    fn delimiter_style(&self) -> ThemeStyle {
        Self::DELIMITER
    }

    fn text_style(&self) -> ThemeStyle {
        Self::TEXT
    }

    fn focus_border_style(&self) -> ThemeStyle {
        Self::FOCUS_BORDER
    }

    fn status_normal_color(&self) -> ThemeColor {
        Self::GREEN
    }

    fn status_search_color(&self) -> ThemeColor {
        Self::YELLOW
    }

    fn status_help_color(&self) -> ThemeColor {
        Self::BLUE
    }

    fn status_error_color(&self) -> ThemeColor {
        Self::RED
    }

    fn status_message_color(&self) -> ThemeColor {
        Self::YELLOW
    }

    fn status_background_color(&self) -> ThemeColor {
        Self::BASE02
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_solarized_osaka_theme_styles() {
        let theme = SolarizedOsaka;
        let h1_style = theme.heading_style(1);
        assert_eq!(h1_style.color, SolarizedOsaka::BLUE);
        assert!(h1_style.bold);
        assert!(!h1_style.italic);
        assert!(!h1_style.underline);

        let h2_style = theme.heading_style(2);
        assert_eq!(h2_style.color, SolarizedOsaka::GREEN);
        assert!(h2_style.bold);

        let h3_style = theme.heading_style(3);
        assert_eq!(h3_style.color, SolarizedOsaka::CYAN);
        assert!(!h3_style.bold);

        let h4_style = theme.heading_style(4);
        assert_eq!(h4_style.color, SolarizedOsaka::YELLOW);
        assert!(!h4_style.bold);

        let h5_style = theme.heading_style(5);
        assert_eq!(h5_style.color, SolarizedOsaka::ORANGE);
        assert!(!h5_style.bold);

        let h6_style = theme.heading_style(6);
        assert_eq!(h6_style.color, SolarizedOsaka::MAGENTA);
        assert!(!h6_style.bold);
        let strong_style = theme.strong_style();
        assert_eq!(strong_style.color, SolarizedOsaka::ORANGE);
        assert!(strong_style.bold);
        assert!(!strong_style.italic);

        let emphasis_style = theme.emphasis_style();
        assert_eq!(emphasis_style.color, SolarizedOsaka::GREEN);
        assert!(!emphasis_style.bold);
        assert!(emphasis_style.italic);

        let link_style = theme.link_style();
        assert_eq!(link_style.color, SolarizedOsaka::CYAN);
        assert!(link_style.underline);

        let code_style = theme.code_style();
        assert_eq!(code_style.color, SolarizedOsaka::GREEN);
        assert!(!code_style.bold);
        assert!(!code_style.italic);
        assert!(!code_style.underline);
        assert_eq!(theme.code_background(), SolarizedOsaka::BASE02);

        let list_marker_style = theme.list_marker_style();
        assert_eq!(list_marker_style.color, SolarizedOsaka::BLUE);

        let delimiter_style = theme.delimiter_style();
        assert_eq!(delimiter_style.color, SolarizedOsaka::BASE01);

        let text_style = theme.text_style();
        assert_eq!(text_style.color, SolarizedOsaka::BASE0);
    }
}
