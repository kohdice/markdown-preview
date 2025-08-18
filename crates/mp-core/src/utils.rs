//! Utility functions for cross-platform compatibility and text processing

use std::borrow::Cow;

/// Platform-specific line ending
#[cfg(target_os = "windows")]
pub const LINE_ENDING: &str = "\r\n";

/// Platform-specific line ending
#[cfg(not(target_os = "windows"))]
pub const LINE_ENDING: &str = "\n";

/// Normalize line endings for consistent cross-platform processing.
/// Handles Windows (CRLF), Classic Mac (CR), and Unix (LF) line endings.
///
/// By default, normalizes to Unix format (LF only).
/// Use `normalize_line_endings_with_platform` to preserve platform-specific endings.
///
/// # Examples
/// ```
/// use mp_core::utils::normalize_line_endings;
///
/// assert_eq!(normalize_line_endings("hello\r\nworld"), "hello\nworld");
/// assert_eq!(normalize_line_endings("hello\rworld"), "hello\nworld");
/// assert_eq!(normalize_line_endings("hello\nworld"), "hello\nworld");
/// ```
pub fn normalize_line_endings(text: &str) -> Cow<'_, str> {
    if !text.contains('\r') {
        return Cow::Borrowed(text);
    }
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    Cow::Owned(normalized)
}

/// Normalize line endings with option to preserve platform-specific format.
///
/// # Arguments
/// * `text` - The text to normalize
/// * `preserve_platform` - If true, converts to platform-specific line endings
///
/// # Examples
/// ```
/// use mp_core::utils::normalize_line_endings_with_platform;
///
/// // On Windows with preserve_platform=true, converts to CRLF
/// // On Unix with preserve_platform=true, keeps LF
/// let result = normalize_line_endings_with_platform("hello\r\nworld", true);
/// ```
pub fn normalize_line_endings_with_platform(text: &str, preserve_platform: bool) -> String {
    // First normalize to LF
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");

    // Then convert to platform-specific if requested
    if preserve_platform && cfg!(windows) {
        normalized.replace('\n', "\r\n")
    } else {
        normalized
    }
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

    #[test]
    fn test_normalize_with_platform_preserve_false() {
        let input = "line1\r\nline2\rline3";
        let expected = "line1\nline2\nline3";
        assert_eq!(normalize_line_endings_with_platform(input, false), expected);
    }

    #[test]
    fn test_normalize_with_platform_preserve_true() {
        let input = "line1\r\nline2\rline3";
        let result = normalize_line_endings_with_platform(input, true);

        #[cfg(windows)]
        {
            assert_eq!(result, "line1\r\nline2\r\nline3");
        }

        #[cfg(not(windows))]
        {
            assert_eq!(result, "line1\nline2\nline3");
        }
    }

    #[test]
    fn test_line_ending_constant() {
        #[cfg(windows)]
        {
            assert_eq!(LINE_ENDING, "\r\n");
        }

        #[cfg(not(windows))]
        {
            assert_eq!(LINE_ENDING, "\n");
        }
    }
}
