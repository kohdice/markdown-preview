use unicode_width::UnicodeWidthStr;

/// Truncates a Unicode string to fit within a specified display width.
pub(crate) fn truncate_unicode_string(text: &str, max_width: usize) -> (String, usize) {
    let mut current_width = 0;
    let mut char_count = 0;

    for ch in text.chars() {
        let ch_width = ch.to_string().width();
        if current_width + ch_width > max_width {
            break;
        }
        current_width += ch_width;
        char_count += 1;
    }

    let truncated: String = text.chars().take(char_count).collect();
    (truncated, current_width)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ascii_only() {
        let (result, width) = truncate_unicode_string("Hello World", 5);
        assert_eq!(result, "Hello");
        assert_eq!(width, 5);
    }

    #[test]
    fn test_japanese_only() {
        let (result, width) = truncate_unicode_string("こんにちは", 6);
        assert_eq!(result, "こんに");
        assert_eq!(width, 6);
    }

    #[test]
    fn test_mixed_ascii_japanese() {
        let (result, width) = truncate_unicode_string("Hello世界", 7);
        assert_eq!(result, "Hello世");
        assert_eq!(width, 7);
    }

    #[test]
    fn test_exact_fit() {
        let (result, width) = truncate_unicode_string("Test", 4);
        assert_eq!(result, "Test");
        assert_eq!(width, 4);
    }

    #[test]
    fn test_empty_string() {
        let (result, width) = truncate_unicode_string("", 10);
        assert_eq!(result, "");
        assert_eq!(width, 0);
    }

    #[test]
    fn test_zero_width() {
        let (result, width) = truncate_unicode_string("Hello", 0);
        assert_eq!(result, "");
        assert_eq!(width, 0);
    }

    #[test]
    fn test_emoji() {
        let (result, width) = truncate_unicode_string("👍Test", 3);
        assert_eq!(result, "👍T");
        assert_eq!(width, 3);
    }
}
