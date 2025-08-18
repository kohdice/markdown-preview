//! HTML entity decoding with AhoCorasick algorithm

use std::borrow::Cow;
use std::sync::LazyLock;

use aho_corasick::AhoCorasick;
use anyhow::{Context, Result};

/// Efficient HTML entity decoder
pub struct EntityDecoder {
    matcher: AhoCorasick,
    replacements: Vec<&'static str>,
}

/// Initialize entity decoder
fn init_entity_decoder() -> Result<EntityDecoder> {
    let patterns = vec![
        "&lt;", "&gt;", "&amp;", "&quot;", "&apos;", "&#39;", "&nbsp;", "&copy;", "&reg;",
        "&trade;", "&euro;", "&pound;", "&yen;", "&cent;", "&sect;", "&para;", "&bull;",
        "&middot;", "&hellip;", "&mdash;", "&ndash;", "&lsquo;", "&rsquo;", "&ldquo;", "&rdquo;",
        "&laquo;", "&raquo;", "&times;", "&divide;", "&plusmn;", "&ne;", "&le;", "&ge;", "&infin;",
        "&sum;", "&prod;", "&radic;", "&larr;", "&rarr;", "&uarr;", "&darr;", "&harr;",
    ];

    let replacements = vec![
        "<", ">", "&", "\"", "'", "'", " ", "©", "®", "™", "€", "£", "¥", "¢", "§", "¶", "•", "·",
        "…", "—", "–", "'", "'", "\u{201C}", "\u{201D}", "«", "»", "×", "÷", "±", "≠", "≤", "≥",
        "∞", "∑", "∏", "√", "←", "→", "↑", "↓", "↔",
    ];

    let matcher = AhoCorasick::builder()
        .match_kind(aho_corasick::MatchKind::LeftmostFirst)
        .build(patterns)
        .context("Failed to build AhoCorasick matcher for HTML entity decoding")?;

    Ok(EntityDecoder {
        matcher,
        replacements,
    })
}

/// Global entity decoder
static ENTITY_DECODER: LazyLock<EntityDecoder> = LazyLock::new(|| {
    init_entity_decoder()
        .expect("Failed to initialize HTML entity decoder - this is a critical error")
});

/// Decode HTML entities using AhoCorasick pattern matching
pub fn decode_html_entities(text: &str) -> Cow<'_, str> {
    if !text.contains('&') {
        return Cow::Borrowed(text);
    }

    let mut result = String::with_capacity(text.len());
    let mut last_end = 0;

    for mat in ENTITY_DECODER.matcher.find_iter(text) {
        result.push_str(&text[last_end..mat.start()]);
        result.push_str(ENTITY_DECODER.replacements[mat.pattern().as_usize()]);
        last_end = mat.end();
    }

    result.push_str(&text[last_end..]);

    Cow::Owned(decode_numeric_entities(&result))
}

/// Decode numeric HTML entities
fn decode_numeric_entities(text: &str) -> String {
    if !text.contains("&#") {
        return text.to_string();
    }

    let mut result = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '&' && chars.peek() == Some(&'#') {
            chars.next();

            let mut entity = String::with_capacity(10);
            let is_hex = if chars.peek() == Some(&'x') || chars.peek() == Some(&'X') {
                chars.next();
                true
            } else {
                false
            };

            let mut valid_entity = true;
            while let Some(&next_ch) = chars.peek() {
                if next_ch == ';' {
                    chars.next();
                    break;
                } else if (is_hex && next_ch.is_ascii_hexdigit())
                    || (!is_hex && next_ch.is_ascii_digit())
                {
                    entity.push(next_ch);
                    chars.next();
                } else {
                    valid_entity = false;
                    break;
                }
            }

            if valid_entity && !entity.is_empty() {
                if let Ok(code) = if is_hex {
                    u32::from_str_radix(&entity, 16)
                } else {
                    entity.parse::<u32>()
                } {
                    if let Some(decoded_char) = char::from_u32(code) {
                        result.push(decoded_char);
                    } else {
                        result.push('&');
                        result.push('#');
                        if is_hex {
                            result.push('x');
                        }
                        result.push_str(&entity);
                        result.push(';');
                    }
                } else {
                    result.push('&');
                    result.push('#');
                    if is_hex {
                        result.push('x');
                    }
                    result.push_str(&entity);
                    result.push(';');
                }
            } else {
                result.push('&');
                result.push('#');
                if is_hex {
                    result.push('x');
                }
                result.push_str(&entity);
            }
        } else {
            result.push(ch);
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_entities() {
        assert_eq!(decode_html_entities("&lt;"), "<");
        assert_eq!(decode_html_entities("&gt;"), ">");
        assert_eq!(decode_html_entities("&amp;"), "&");
        assert_eq!(decode_html_entities("&quot;"), "\"");
        assert_eq!(decode_html_entities("&#39;"), "'");
    }

    #[test]
    fn test_numeric_entities() {
        assert_eq!(decode_html_entities("&#60;"), "<");
        assert_eq!(decode_html_entities("&#62;"), ">");
        assert_eq!(decode_html_entities("&#38;"), "&");
        assert_eq!(decode_html_entities("&#x3C;"), "<");
        assert_eq!(decode_html_entities("&#x3E;"), ">");
        assert_eq!(decode_html_entities("&#x26;"), "&");
    }

    #[test]
    fn test_mixed_text() {
        assert_eq!(
            decode_html_entities("Hello &lt;world&gt; &amp; &#39;friends&#39;"),
            "Hello <world> & 'friends'"
        );
    }

    #[test]
    fn test_special_characters() {
        assert_eq!(decode_html_entities("&copy;"), "©");
        assert_eq!(decode_html_entities("&reg;"), "®");
        assert_eq!(decode_html_entities("&euro;"), "€");
        assert_eq!(decode_html_entities("&mdash;"), "—");
    }

    #[test]
    fn test_invalid_entities() {
        assert_eq!(decode_html_entities("&invalid;"), "&invalid;");
        assert_eq!(decode_html_entities("&#99999999;"), "&#99999999;");
        assert_eq!(decode_html_entities("&#xZZZ;"), "&#xZZZ;");
    }

    #[test]
    fn test_no_entities() {
        assert_eq!(decode_html_entities("Hello World"), "Hello World");
        assert_eq!(
            decode_html_entities("Simple text without entities"),
            "Simple text without entities"
        );
    }

    #[test]
    fn test_multiple_entities() {
        let input = "&lt;div&gt;&lt;p&gt;Hello &amp; welcome to &ldquo;testing&rdquo;&lt;/p&gt;&lt;/div&gt;";
        let expected = "<div><p>Hello & welcome to \u{201C}testing\u{201D}</p></div>";
        assert_eq!(decode_html_entities(input), expected);
    }

    #[test]
    fn test_performance_edge_cases() {
        assert_eq!(decode_html_entities("&lt;&lt;&lt;"), "<<<");
        assert_eq!(decode_html_entities("&amp;&amp;&amp;"), "&&&");

        assert_eq!(decode_html_entities("&lt;text&gt;"), "<text>");
        assert_eq!(decode_html_entities("start&lt;"), "start<");
        assert_eq!(decode_html_entities("&gt;end"), ">end");
    }
}
