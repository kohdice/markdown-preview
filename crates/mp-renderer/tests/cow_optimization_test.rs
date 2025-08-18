use std::borrow::Cow;

/// Helper function to demonstrate Cow optimization
/// Returns borrowed data when no transformation is needed
fn optimize_string<'a>(input: &'a str, needs_transformation: bool) -> Cow<'a, str> {
    if needs_transformation {
        Cow::Owned(input.to_uppercase())
    } else {
        Cow::Borrowed(input)
    }
}

#[test]
fn test_cow_borrowed_when_no_change() {
    let input = "hello world";
    let result = optimize_string(input, false);

    // Verify it's borrowed
    assert!(matches!(result, Cow::Borrowed(_)));
    assert_eq!(result, "hello world");
}

#[test]
fn test_cow_owned_when_changed() {
    let input = "hello world";
    let result = optimize_string(input, true);

    // Verify it's owned
    assert!(matches!(result, Cow::Owned(_)));
    assert_eq!(result, "HELLO WORLD");
}

/// Function that demonstrates efficient string building with Cow
fn build_formatted_string<'a>(base: &'a str, needs_formatting: bool) -> Cow<'a, str> {
    if needs_formatting {
        Cow::Owned(format!("[{}]", base))
    } else {
        Cow::Borrowed(base)
    }
}

#[test]
fn test_efficient_string_building() {
    // No allocation when formatting not needed
    let result1 = build_formatted_string("test", false);
    assert!(matches!(result1, Cow::Borrowed(_)));
    assert_eq!(result1, "test");

    // Allocation only when needed
    let result2 = build_formatted_string("test", true);
    assert!(matches!(result2, Cow::Owned(_)));
    assert_eq!(result2, "[test]");
}

/// Demonstrates chaining Cow operations efficiently
fn chain_cow_operations<'a>(text: &'a str, add_prefix: bool, add_suffix: bool) -> Cow<'a, str> {
    let mut result = if add_prefix {
        Cow::Owned(format!("PREFIX_{}", text))
    } else {
        Cow::Borrowed(text)
    };

    if add_suffix {
        // Only convert to owned if not already owned
        result = match result {
            Cow::Borrowed(s) => Cow::Owned(format!("{}_SUFFIX", s)),
            Cow::Owned(mut s) => {
                s.push_str("_SUFFIX");
                Cow::Owned(s)
            }
        };
    }

    result
}

#[test]
fn test_chained_cow_operations() {
    // No allocation
    let result1 = chain_cow_operations("test", false, false);
    assert!(matches!(result1, Cow::Borrowed(_)));
    assert_eq!(result1, "test");

    // Single allocation for prefix
    let result2 = chain_cow_operations("test", true, false);
    assert!(matches!(result2, Cow::Owned(_)));
    assert_eq!(result2, "PREFIX_test");

    // Single allocation for suffix
    let result3 = chain_cow_operations("test", false, true);
    assert!(matches!(result3, Cow::Owned(_)));
    assert_eq!(result3, "test_SUFFIX");

    // Single allocation for both (reuses existing String)
    let result4 = chain_cow_operations("test", true, true);
    assert!(matches!(result4, Cow::Owned(_)));
    assert_eq!(result4, "PREFIX_test_SUFFIX");
}
