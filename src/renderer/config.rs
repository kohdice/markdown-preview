/// Configuration for markdown rendering behavior and visual settings.
/// Dynamically adjusts to terminal capabilities.
#[derive(Debug, Clone)]
pub struct RenderConfig {
    /// Number of spaces for list item indentation
    pub indent_width: usize,

    /// Table column separator character
    pub table_separator: String,

    /// Table alignment indicators
    pub table_alignment: TableAlignmentConfig,

    /// Enable color output
    pub enable_colors: bool,

    /// Enable bold text styling
    pub enable_bold: bool,

    /// Enable italic text styling  
    pub enable_italic: bool,

    /// Enable underline text styling
    pub enable_underline: bool,
}

/// Configuration for table alignment indicators
#[derive(Debug, Clone)]
pub struct TableAlignmentConfig {
    pub left: String,
    pub center: String,
    pub right: String,
    pub none: String,
}

impl Default for RenderConfig {
    fn default() -> Self {
        Self {
            indent_width: 2,
            table_separator: "|".to_string(),
            table_alignment: TableAlignmentConfig::default(),
            enable_colors: true,
            enable_bold: true,
            enable_italic: true,
            enable_underline: true,
        }
    }
}

impl Default for TableAlignmentConfig {
    fn default() -> Self {
        Self {
            left: ":---".to_string(),
            center: ":---:".to_string(),
            right: "---:".to_string(),
            none: "---".to_string(),
        }
    }
}

impl RenderConfig {
    /// Creates a new configuration with default values
    pub fn new() -> Self {
        Self::default()
    }

    /// Gets the current terminal width, auto-detecting dynamically
    pub fn get_terminal_width() -> usize {
        terminal_size::terminal_size()
            .map(|(width, _)| width.0 as usize)
            .unwrap_or(80) // Fallback to 80 columns if detection fails
    }

    /// Creates indentation string for the given depth level
    pub fn create_indent(&self, depth: usize) -> String {
        " ".repeat(self.indent_width * depth)
    }

    /// Creates a horizontal rule string that adapts to terminal width
    pub fn create_horizontal_rule(&self) -> String {
        let width = Self::get_terminal_width();
        // Use 80% of terminal width for horizontal rule, max 100 chars
        let rule_length = ((width as f32 * 0.8) as usize).min(100);
        "─".repeat(rule_length)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = RenderConfig::default();
        assert_eq!(config.indent_width, 2);
        assert_eq!(config.table_separator, "|");
        assert!(config.enable_colors);
        assert!(config.enable_bold);
    }

    #[test]
    fn test_create_indent() {
        let config = RenderConfig::default();
        assert_eq!(config.create_indent(0), "");
        assert_eq!(config.create_indent(1), "  ");
        assert_eq!(config.create_indent(2), "    ");
    }

    #[test]
    fn test_create_horizontal_rule() {
        let config = RenderConfig::default();
        let rule = config.create_horizontal_rule();
        // Rule should be dynamic based on terminal width
        assert!(rule.chars().count() > 0); // Should have some length
        assert!(rule.chars().count() <= 100); // Max 100 chars
        assert!(rule.chars().all(|c| c == '─'));
    }

    #[test]
    fn test_get_terminal_width() {
        let width = RenderConfig::get_terminal_width();
        // Should return at least the fallback value
        assert!(width >= 80);
    }
}
