/// Configuration for markdown rendering behavior and visual settings.
#[derive(Debug, Clone)]
pub struct RenderConfig {
    pub indent_width: usize,

    pub table_separator: String,

    pub table_alignment: TableAlignmentConfig,

    pub enable_colors: bool,

    pub enable_bold: bool,

    pub enable_italic: bool,

    pub enable_underline: bool,
}

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
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get_terminal_width() -> usize {
        terminal_size::terminal_size()
            .map(|(width, _)| width.0 as usize)
            .unwrap_or(80)
    }

    pub fn create_indent(&self, depth: usize) -> String {
        " ".repeat(self.indent_width * depth)
    }

    pub fn create_horizontal_rule(&self) -> String {
        let width = Self::get_terminal_width();
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
        assert!(rule.chars().count() > 0);
        assert!(rule.chars().count() <= 100);
        assert!(rule.chars().all(|c| c == '─'));
    }

    #[test]
    fn test_get_terminal_width() {
        let width = RenderConfig::get_terminal_width();
        assert!(width >= 80);
    }
}
