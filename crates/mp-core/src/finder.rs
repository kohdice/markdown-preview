use std::path::{Path, PathBuf};

use anyhow::Result;
use ignore::WalkBuilder;

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
    let base_path = Path::new(dir);

    let mut builder = WalkBuilder::new(dir);

    builder
        .hidden(!config.hidden)
        .parents(!config.no_ignore_parent)
        .add_custom_ignore_filename(".mpignore");

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

    let mut files: Vec<PathBuf> = walker
        .filter_map(|result| result.ok())
        .filter_map(|entry| {
            let path = entry.path();
            if path.is_file() && path.extension().is_some_and(|ext| ext == "md") {
                Some(make_relative_path(path, base_path))
            } else {
                None
            }
        })
        .collect();

    files.sort();
    Ok(files)
}

/// Create a relative path with robust cross-platform support
fn make_relative_path(path: &Path, base: &Path) -> PathBuf {
    let canonical_path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let canonical_base = base.canonicalize().unwrap_or_else(|_| base.to_path_buf());

    if let Ok(rel) = canonical_path.strip_prefix(&canonical_base) {
        return rel.to_path_buf();
    }

    if let Ok(rel) = path.strip_prefix(base) {
        return rel.to_path_buf();
    }

    path.file_name()
        .map(PathBuf::from)
        .unwrap_or_else(|| path.to_path_buf())
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

        fs::write(dir.path().join(".hidden.md"), "Hidden markdown").unwrap();

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

        assert_eq!(files.len(), 3);

        let file_names: Vec<String> = files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();

        assert!(file_names.iter().any(|f| f.ends_with("README.md")));
        assert!(file_names.iter().any(|f| f.ends_with("test.md")));

        #[cfg(windows)]
        {
            assert!(file_names.iter().any(|f| f.ends_with("subdir\\sub.md")));
        }

        #[cfg(not(windows))]
        {
            assert!(file_names.iter().any(|f| f.ends_with("subdir/sub.md")));
        }

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

        assert_eq!(files.len(), 4);

        let file_names: Vec<String> = files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();

        assert!(file_names.iter().any(|f| f.ends_with(".hidden.md")));

        #[cfg(windows)]
        {
            assert!(file_names.iter().any(|f| f.ends_with("subdir\\sub.md")));
        }

        #[cfg(not(windows))]
        {
            assert!(file_names.iter().any(|f| f.ends_with("subdir/sub.md")));
        }
    }

    #[test]
    fn test_path_separator_normalization() {
        let temp_dir = create_test_dir();

        let config = FinderConfig::default();
        let files = find_markdown_files_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        let raw_paths: Vec<String> = files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();

        #[cfg(windows)]
        {
            assert!(
                raw_paths.iter().any(|f| f.contains("subdir\\sub.md")),
                "Windows paths should contain backslashes"
            );
        }

        #[cfg(not(windows))]
        {
            assert!(
                raw_paths.iter().any(|f| f.contains("subdir/sub.md")),
                "Unix paths should contain forward slashes"
            );
        }
        let normalized_paths: Vec<String> = files
            .iter()
            .map(|p| p.to_string_lossy().replace('\\', "/"))
            .collect();

        assert!(
            normalized_paths
                .iter()
                .any(|f| f.ends_with("subdir/sub.md")),
            "Normalized paths should work with forward slashes"
        );
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
