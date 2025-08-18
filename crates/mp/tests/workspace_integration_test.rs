use std::fs;

use tempfile::TempDir;

use mp_core::finder::{FinderConfig, find_markdown_files_in_dir};
use mp_core::html_entity::decode_html_entities;

#[test]
fn test_workspace_integration() {
    let temp_dir = TempDir::new().unwrap();
    fs::write(temp_dir.path().join("test1.md"), "# Test 1").unwrap();
    fs::write(temp_dir.path().join("test2.md"), "# Test 2").unwrap();
    fs::write(temp_dir.path().join("test.txt"), "Not markdown").unwrap();

    let config = FinderConfig {
        hidden: false,
        no_ignore: false,
        no_ignore_parent: false,
        no_global_ignore_file: false,
    };

    let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();
    assert_eq!(files.len(), 2);
    assert!(files.iter().any(|f| f.ends_with("test1.md")));
    assert!(files.iter().any(|f| f.ends_with("test2.md")));
}

#[test]
fn test_html_entity_integration() {
    let text = "Hello &amp; &lt;world&gt;";
    let decoded = decode_html_entities(text);
    assert_eq!(decoded, "Hello & <world>");

    let text_with_numeric = "Test &#65; &#x42;";
    let decoded_numeric = decode_html_entities(text_with_numeric);
    assert_eq!(decoded_numeric, "Test A B");
}

#[test]
fn test_cross_crate_functionality() {
    let temp_dir = TempDir::new().unwrap();
    let test_file = temp_dir.path().join("test.md");
    fs::write(&test_file, "# Title\n\n- Item 1\n- Item 2\n\n`code`").unwrap();

    let config = FinderConfig {
        hidden: false,
        no_ignore: false,
        no_ignore_parent: false,
        no_global_ignore_file: false,
    };

    let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();
    assert_eq!(files.len(), 1);

    let full_path = temp_dir.path().join(&files[0]);
    let content = fs::read_to_string(&full_path).unwrap();
    assert!(content.contains("# Title"));
    assert!(content.contains("- Item 1"));
}
