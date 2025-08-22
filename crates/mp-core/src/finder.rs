use std::path::{Path, PathBuf};

use anyhow::Result;
use ignore::WalkBuilder;

#[derive(Debug, Default, Clone, Copy)]
pub struct FinderConfig {
    pub hidden: bool,
    pub no_ignore: bool,
    pub no_ignore_parent: bool,
    pub no_global_ignore_file: bool,
}

#[derive(Debug, Clone)]
pub struct FileTreeNode {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub children: Vec<FileTreeNode>,
}

pub fn find_markdown_files(config: FinderConfig) -> Result<Vec<PathBuf>> {
    find_markdown_files_in_dir(".", config)
}

pub fn find_markdown_files_in_dir(dir: &str, config: FinderConfig) -> Result<Vec<PathBuf>> {
    let base_path = Path::new(dir);

    let mut builder = WalkBuilder::new(dir);
    configure_walker(&mut builder, &config);
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

pub fn build_markdown_tree(config: FinderConfig) -> Result<FileTreeNode> {
    build_markdown_tree_in_dir(".", config)
}

pub fn build_markdown_tree_in_dir(dir: &str, config: FinderConfig) -> Result<FileTreeNode> {
    let base_path = Path::new(dir);

    let root_name = if dir == "." {
        std::env::current_dir()
            .ok()
            .and_then(|d| d.file_name().and_then(|n| n.to_str()).map(String::from))
            .unwrap_or_else(|| ".".to_string())
    } else {
        base_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(dir)
            .to_string()
    };

    let mut root = FileTreeNode {
        path: base_path.to_path_buf(),
        name: root_name,
        is_dir: true,
        children: Vec::new(),
    };

    // Create the walker with the same configuration as find_markdown_files
    let mut builder = WalkBuilder::new(dir);
    configure_walker(&mut builder, &config);
    let walker = builder.build();

    // Collect all paths first
    let mut all_entries = Vec::new();
    for entry in walker.flatten() {
        let path = entry.path();
        // Skip the root directory itself
        if path == base_path {
            continue;
        }

        // Check if it's a markdown file or a directory that might contain markdown files
        if path.is_file() {
            if path
                .extension()
                .is_some_and(|ext| ext == "md" || ext == "markdown")
            {
                all_entries.push(path.to_path_buf());
            }
        } else if path.is_dir() {
            // Add directories that might contain markdown files
            all_entries.push(path.to_path_buf());
        }
    }

    // Build the tree structure from the collected paths
    build_tree_from_paths(&mut root, &all_entries, base_path)?;

    // Remove empty directories from the tree
    remove_empty_directories(&mut root);

    Ok(root)
}

fn configure_walker(builder: &mut WalkBuilder, config: &FinderConfig) {
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
}

fn build_tree_from_paths(root: &mut FileTreeNode, paths: &[PathBuf], base: &Path) -> Result<()> {
    for path in paths {
        if let Ok(relative) = path.strip_prefix(base) {
            insert_path_into_tree(root, relative, path)?;
        }
    }

    // Sort children at each level
    sort_tree_children(root);

    Ok(())
}

fn insert_path_into_tree(node: &mut FileTreeNode, relative: &Path, full_path: &Path) -> Result<()> {
    let components: Vec<_> = relative.components().collect();

    if components.is_empty() {
        return Ok(());
    }

    let first = &components[0];
    let first_str = first.as_os_str().to_string_lossy().to_string();

    if components.len() == 1 {
        // This is a direct child
        let child = FileTreeNode {
            path: full_path.to_path_buf(),
            name: first_str,
            is_dir: full_path.is_dir(),
            children: Vec::new(),
        };

        // Check if this child already exists (in case of directories)
        if !node.children.iter().any(|c| c.name == child.name) {
            node.children.push(child);
        }
    } else {
        // Need to recurse into subdirectory
        let dir_name = first_str.clone();

        // Find or create the directory node
        let dir_node = if let Some(existing) = node
            .children
            .iter_mut()
            .find(|c| c.name == dir_name && c.is_dir)
        {
            existing
        } else {
            // Create the directory node
            let dir_path = node.path.join(&dir_name);
            let new_dir = FileTreeNode {
                path: dir_path,
                name: dir_name,
                is_dir: true,
                children: Vec::new(),
            };
            node.children.push(new_dir);
            node.children.last_mut().unwrap()
        };

        // Recurse with the remaining path
        let remaining: PathBuf = components[1..].iter().collect();
        insert_path_into_tree(dir_node, &remaining, full_path)?;
    }

    Ok(())
}

fn sort_tree_children(node: &mut FileTreeNode) {
    node.children.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });

    // Recursively sort children
    for child in &mut node.children {
        if child.is_dir {
            sort_tree_children(child);
        }
    }
}

fn remove_empty_directories(node: &mut FileTreeNode) {
    if !node.is_dir {
        return;
    }

    // Recursively process children first
    for child in &mut node.children {
        remove_empty_directories(child);
    }

    // Remove empty directories from children
    node.children.retain(|child| {
        if child.is_dir {
            // Keep directory only if it has children (after recursive processing)
            !child.children.is_empty()
        } else {
            // Always keep files
            true
        }
    });
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

    #[test]
    fn test_build_markdown_tree() {
        let temp_dir = create_test_dir();

        let config = FinderConfig::default();
        let tree = build_markdown_tree_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        // Check root
        assert!(tree.is_dir);

        // Should have at least 2 direct children (files) and 1 directory
        let file_count = tree.children.iter().filter(|c| !c.is_dir).count();
        let dir_count = tree.children.iter().filter(|c| c.is_dir).count();

        assert_eq!(file_count, 2); // README.md and test.md
        assert_eq!(dir_count, 1); // subdir

        // Check that the subdir has the markdown file
        let subdir = tree.children.iter().find(|c| c.name == "subdir").unwrap();
        assert!(subdir.is_dir);
        assert_eq!(subdir.children.len(), 1);
        assert_eq!(subdir.children[0].name, "sub.md");
    }

    #[test]
    fn test_tree_removes_empty_directories() {
        let temp_dir = TempDir::new().unwrap();

        // Create a structure with some empty directories
        fs::write(temp_dir.path().join("README.md"), "# Test").unwrap();

        let empty_dir = temp_dir.path().join("empty");
        fs::create_dir(&empty_dir).unwrap();

        let dir_with_md = temp_dir.path().join("with_md");
        fs::create_dir(&dir_with_md).unwrap();
        fs::write(dir_with_md.join("test.md"), "Test").unwrap();

        let config = FinderConfig::default();
        let tree = build_markdown_tree_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        // Should not include the empty directory
        assert!(!tree.children.iter().any(|c| c.name == "empty"));

        // Should include the directory with markdown
        assert!(tree.children.iter().any(|c| c.name == "with_md"));
    }

    #[test]
    fn test_tree_sorting() {
        let temp_dir = TempDir::new().unwrap();

        // Create files and directories
        fs::write(temp_dir.path().join("zebra.md"), "").unwrap();
        fs::write(temp_dir.path().join("apple.md"), "").unwrap();

        let dir_b = temp_dir.path().join("b_dir");
        fs::create_dir(&dir_b).unwrap();
        fs::write(dir_b.join("file.md"), "").unwrap();

        let dir_a = temp_dir.path().join("a_dir");
        fs::create_dir(&dir_a).unwrap();
        fs::write(dir_a.join("file.md"), "").unwrap();

        let config = FinderConfig::default();
        let tree = build_markdown_tree_in_dir(temp_dir.path().to_str().unwrap(), config).unwrap();

        // Directories should come first, then files, all sorted alphabetically
        assert_eq!(tree.children[0].name, "a_dir");
        assert!(tree.children[0].is_dir);

        assert_eq!(tree.children[1].name, "b_dir");
        assert!(tree.children[1].is_dir);

        assert_eq!(tree.children[2].name, "apple.md");
        assert!(!tree.children[2].is_dir);

        assert_eq!(tree.children[3].name, "zebra.md");
        assert!(!tree.children[3].is_dir);
    }
}
