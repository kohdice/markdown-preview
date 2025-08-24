use std::borrow::Cow;

pub fn normalize_line_endings(text: &str) -> Cow<'_, str> {
    if !text.contains('\r') {
        return Cow::Borrowed(text);
    }
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    Cow::Owned(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_line_endings_windows() {
        let input = "line1\r\nline2\r\nline3";
        let expected = "line1\nline2\nline3";
        assert_eq!(normalize_line_endings(input), expected);
    }

    #[test]
    fn test_normalize_line_endings_mac_classic() {
        let input = "line1\rline2\rline3";
        let expected = "line1\nline2\nline3";
        assert_eq!(normalize_line_endings(input), expected);
    }

    #[test]
    fn test_normalize_line_endings_unix() {
        let input = "line1\nline2\nline3";
        assert!(matches!(normalize_line_endings(input), Cow::Borrowed(_)));
        assert_eq!(normalize_line_endings(input), input);
    }

    #[test]
    fn test_normalize_line_endings_mixed() {
        let input = "line1\r\nline2\rline3\nline4";
        let expected = "line1\nline2\nline3\nline4";
        assert_eq!(normalize_line_endings(input), expected);
    }

    #[test]
    fn test_normalize_line_endings_empty() {
        assert_eq!(normalize_line_endings(""), "");
    }

    #[test]
    fn test_normalize_line_endings_no_newlines() {
        let input = "single line without newlines";
        assert!(matches!(normalize_line_endings(input), Cow::Borrowed(_)));
        assert_eq!(normalize_line_endings(input), input);
    }
}
