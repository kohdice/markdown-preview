use std::borrow::Cow;

#[derive(Debug, Clone)]
pub struct RenderConfig {
    pub indent_width: usize,

    pub table_separator: &'static str,

    pub table_alignment: TableAlignmentConfig,
}

#[derive(Debug, Clone)]
pub struct TableAlignmentConfig {
    pub left: &'static str,
    pub center: &'static str,
    pub right: &'static str,
    pub none: &'static str,
}

impl Default for RenderConfig {
    fn default() -> Self {
        Self {
            indent_width: 2,
            table_separator: "|",
            table_alignment: TableAlignmentConfig::default(),
        }
    }
}

impl Default for TableAlignmentConfig {
    fn default() -> Self {
        Self {
            left: ":---",
            center: ":---:",
            right: "---:",
            none: "---",
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

    pub fn create_indent(&self, depth: usize) -> Cow<'static, str> {
        if depth == 0 {
            Cow::Borrowed("")
        } else {
            Cow::Owned(" ".repeat(self.indent_width * depth))
        }
    }

    pub fn create_horizontal_rule(&self) -> Cow<'static, str> {
        let width = Self::get_terminal_width();
        let rule_length = ((width as f32 * 0.8) as usize).min(100);
        Cow::Owned("─".repeat(rule_length))
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
        assert!(!rule.is_empty());
        assert!(rule.chars().count() <= 100);
        assert!(rule.chars().all(|c| c == '─'));
    }

    #[test]
    fn test_get_terminal_width() {
        let width = RenderConfig::get_terminal_width();
        assert!(width >= 80);
    }
}
