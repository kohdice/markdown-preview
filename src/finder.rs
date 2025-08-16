use anyhow::Result;
use ignore::WalkBuilder;
use std::path::PathBuf;

#[derive(Debug, Default)]
pub struct FinderConfig {
    pub hidden: bool,
    pub no_ignore: bool,
    pub no_ignore_parent: bool,
    pub no_global_ignore_file: bool,
}

/// Search for markdown files
pub fn find_markdown_files(config: FinderConfig) -> Result<Vec<PathBuf>> {
    find_markdown_files_in_dir(".", config)
}

/// Search for markdown files in the specified directory (also used for testing)
pub fn find_markdown_files_in_dir(dir: &str, config: FinderConfig) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();

    let mut builder = WalkBuilder::new(dir);

    builder
        .hidden(!config.hidden) // Exclude hidden files by default
        .parents(!config.no_ignore_parent) // Consider .gitignore in parent directories
        .add_custom_ignore_filename(".mpignore"); // mp-specific ignore file

    if config.no_ignore {
        builder
            .ignore(false)
            .git_ignore(false)
            .git_global(false)
            .git_exclude(false);
    } else {
        builder
            .ignore(true)
            .git_ignore(true)
            .git_global(!config.no_global_ignore_file)
            .git_exclude(true);
    }

    let walker = builder.build();

    for result in walker {
        let entry = result?;
        let path = entry.path();

        // Collect only .md files
        if path.is_file() && path.extension().is_some_and(|ext| ext == "md") {
            // Relative path from base directory
            let relative_path = if let Ok(rel) = path.strip_prefix(dir) {
                rel.to_path_buf()
            } else {
                // Use as-is if strip_prefix fails
                path.to_path_buf()
            };
            files.push(relative_path);
        }
    }

    // Sort alphabetically
    files.sort();
    Ok(files)
}

/// Display file list
pub fn display_files(files: &[PathBuf]) {
    if files.is_empty() {
        // Like fd, output nothing if no files are found
        return;
    }

    for file in files {
        println!("{}", file.display());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_test_dir() -> TempDir {
        let dir = TempDir::new().unwrap();

        fs::write(dir.path().join("README.md"), "# Test").unwrap();
        fs::write(dir.path().join("test.md"), "Test content").unwrap();
        fs::write(dir.path().join("test.txt"), "Not markdown").unwrap();

        // Hidden file
        fs::write(dir.path().join(".hidden.md"), "Hidden markdown").unwrap();

        // Subdirectory
        let sub_dir = dir.path().join("subdir");
        fs::create_dir(&sub_dir).unwrap();
        fs::write(sub_dir.join("sub.md"), "Sub markdown").unwrap();

        dir
    }

    #[test]
    fn test_find_markdown_files_default() {
        let temp_dir = create_test_dir();

        let config = FinderConfig::default();
        let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        // Hidden files are excluded by default
        assert_eq!(files.len(), 3);

        // Compare only filename portions
        let file_names: Vec<String> = files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();

        assert!(file_names.iter().any(|f| f.ends_with("README.md")));
        assert!(file_names.iter().any(|f| f.ends_with("test.md")));
        assert!(file_names.iter().any(|f| f.ends_with("subdir/sub.md")));
        assert!(!file_names.iter().any(|f| f.ends_with(".hidden.md")));
    }

    #[test]
    fn test_find_markdown_files_with_hidden() {
        let temp_dir = create_test_dir();

        let config = FinderConfig {
            hidden: true,
            ..Default::default()
        };
        let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        // Hidden files are included
        assert_eq!(files.len(), 4);

        let file_names: Vec<String> = files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();

        assert!(file_names.iter().any(|f| f.ends_with(".hidden.md")));
    }

    #[test]
    fn test_find_markdown_files_empty_dir() {
        let temp_dir = TempDir::new().unwrap();

        let config = FinderConfig::default();
        let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        assert!(files.is_empty());
    }

    #[test]
    fn test_files_are_sorted() {
        let temp_dir = TempDir::new().unwrap();

        fs::write(temp_dir.path().join("zebra.md"), "").unwrap();
        fs::write(temp_dir.path().join("apple.md"), "").unwrap();
        fs::write(temp_dir.path().join("banana.md"), "").unwrap();

        let config = FinderConfig::default();
        let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        let file_names: Vec<String> = files
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();

        assert_eq!(file_names[0], "apple.md");
        assert_eq!(file_names[1], "banana.md");
        assert_eq!(file_names[2], "zebra.md");
    }
}
