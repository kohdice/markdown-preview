// Re-export all theme modules
pub mod adapter;
pub mod color;
pub mod style;
pub mod themes;
pub mod utils;

// Re-export commonly used types for convenience
pub use adapter::ThemeAdapter;
pub use color::ThemeColor;
pub use style::ThemeStyle;
pub use themes::{MarkdownTheme, SolarizedOsaka};

// Re-export color utilities
pub use color::{
    adjust_brightness, contrast_ratio, meets_wcag_aa, meets_wcag_aaa, mix_colors,
    relative_luminance,
};

// Re-export style utilities
pub use utils::{dim_style, highlight_style, merge_styles};
