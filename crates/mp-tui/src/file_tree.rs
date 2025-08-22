use std::collections::HashSet;
use std::path::PathBuf;

use crate::tree_builder::{DefaultTreeBuilder, TreeBuilder};
use mp_core::{FileTreeNode, FinderConfig};
use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    widgets::{Block, Borders, List, ListItem},
};

#[derive(Clone, Debug)]
pub struct DisplayNode {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub is_expanded: bool,
    pub depth: usize,
    pub has_children: bool,
}

pub struct FileTreeWidget {
    tree_data: FileTreeNode,
    display_nodes: Vec<DisplayNode>,
    pub selected_index: usize,
    pub search_query: String,
    pub search_mode: bool,
    pub scroll_offset: usize,
    finder_config: FinderConfig,
    tree_builder: Box<dyn TreeBuilder>,
}

impl FileTreeWidget {
    pub fn new(_root_path: PathBuf) -> Self {
        Self::with_builder(Box::new(DefaultTreeBuilder), FinderConfig::default())
    }

    pub fn with_builder(tree_builder: Box<dyn TreeBuilder>, finder_config: FinderConfig) -> Self {
        // Build the tree using the provided builder
        let tree_data = tree_builder.build_tree(finder_config).unwrap_or_else(|_| {
            // Fallback to empty tree on error
            FileTreeNode {
                path: PathBuf::from("."),
                name: "Current Directory".to_string(),
                is_dir: true,
                children: Vec::new(),
            }
        });

        let mut widget = Self {
            display_nodes: Vec::new(),
            tree_data,
            selected_index: 0,
            search_query: String::new(),
            search_mode: false,
            scroll_offset: 0,
            finder_config,
            tree_builder,
        };

        // Initialize display nodes with root expanded
        let mut initial_expanded = HashSet::new();
        initial_expanded.insert(widget.tree_data.path.clone());
        widget.display_nodes.clear();
        widget.add_node_to_display(&widget.tree_data.clone(), 0, true, &initial_expanded);

        widget
    }

    fn rebuild_display_nodes(&mut self) {
        // Save the expanded state before clearing
        let expanded_paths: std::collections::HashSet<_> = self
            .display_nodes
            .iter()
            .filter(|n| n.is_expanded)
            .map(|n| n.path.clone())
            .collect();

        self.display_nodes.clear();
        self.add_node_to_display(&self.tree_data.clone(), 0, true, &expanded_paths);
    }

    /// Recursively add nodes to the display list
    fn add_node_to_display(
        &mut self,
        node: &FileTreeNode,
        depth: usize,
        is_root: bool,
        expanded_paths: &std::collections::HashSet<PathBuf>,
    ) {
        // Check if this node was previously expanded
        let was_expanded = if is_root && depth == 0 {
            // Root is initially expanded
            true
        } else {
            expanded_paths.contains(&node.path)
        };

        let display_node = DisplayNode {
            path: node.path.clone(),
            name: if is_root && node.name == "." {
                "Current Directory".to_string()
            } else {
                node.name.clone()
            },
            is_dir: node.is_dir,
            is_expanded: was_expanded,
            depth,
            has_children: !node.children.is_empty(),
        };

        let is_expanded = display_node.is_expanded;
        self.display_nodes.push(display_node);

        // Add children if expanded
        if is_expanded {
            for child in &node.children {
                self.add_node_to_display(child, depth + 1, false, expanded_paths);
            }
        }
    }

    /// Get the filtered list of display nodes based on search query
    pub fn get_filtered_list(&self) -> Vec<(usize, &DisplayNode)> {
        if self.search_query.is_empty() {
            self.display_nodes.iter().enumerate().collect()
        } else {
            let query = self.search_query.to_lowercase();
            self.display_nodes
                .iter()
                .enumerate()
                .filter(|(_, node)| {
                    node.name.to_lowercase().contains(&query)
                        || node.path.to_string_lossy().to_lowercase().contains(&query)
                })
                .collect()
        }
    }

    pub fn toggle_selected(&mut self) {
        let filtered = self.get_filtered_list();
        if let Some((original_idx, node)) = filtered.get(self.selected_index) {
            let original_idx = *original_idx;
            let is_dir = node.is_dir;
            let has_children = node.has_children;

            if is_dir && has_children {
                // Toggle the expansion state in our display nodes
                if let Some(display_node) = self.display_nodes.get_mut(original_idx) {
                    display_node.is_expanded = !display_node.is_expanded;
                }
                // Rebuild the display list
                self.rebuild_display_nodes();

                // Adjust selected index if needed
                self.adjust_selection_after_toggle();
            }
        }
    }

    fn adjust_selection_after_toggle(&mut self) {
        let filtered = self.get_filtered_list();
        if self.selected_index >= filtered.len() && !filtered.is_empty() {
            self.selected_index = filtered.len() - 1;
        }
    }

    pub fn move_selection_up(&mut self) {
        if self.selected_index > 0 {
            self.selected_index -= 1;
            self.adjust_scroll_for_selection();
        }
    }

    pub fn move_selection_down(&mut self) {
        let filtered = self.get_filtered_list();
        if !filtered.is_empty() && self.selected_index < filtered.len() - 1 {
            self.selected_index += 1;
            self.adjust_scroll_for_selection();
        }
    }

    /// Get the currently selected file path (if it's a file)
    pub fn get_selected_file(&self) -> Option<PathBuf> {
        let filtered = self.get_filtered_list();
        filtered.get(self.selected_index).and_then(|(_, node)| {
            if !node.is_dir {
                Some(node.path.clone())
            } else {
                None
            }
        })
    }

    pub fn start_search(&mut self) {
        self.search_mode = true;
        self.search_query.clear();
    }

    pub fn cancel_search(&mut self) {
        self.search_mode = false;
        self.search_query.clear();
    }

    pub fn add_search_char(&mut self, c: char) {
        self.search_query.push(c);
        self.update_filter();
    }

    pub fn remove_search_char(&mut self) {
        self.search_query.pop();
        self.update_filter();
    }

    /// Update the filter and adjust selection
    fn update_filter(&mut self) {
        let filtered = self.get_filtered_list();

        // If current selection is not in filtered list, select first item
        if !filtered.is_empty() {
            let current_path = self.display_nodes.get(self.selected_index).map(|n| &n.path);
            let still_visible = filtered.iter().any(|(_, n)| Some(&n.path) == current_path);

            if !still_visible {
                self.selected_index = 0;
            } else {
                // Adjust index to filtered position
                if let Some(pos) = filtered
                    .iter()
                    .position(|(_, n)| Some(&n.path) == current_path)
                {
                    self.selected_index = pos;
                }
            }
        }
    }

    /// Adjust scroll offset for current selection
    fn adjust_scroll_for_selection(&mut self) {
        // This can be implemented based on the visible area height
        // For now, we'll leave it empty as the actual implementation
        // would need to know the render area height
    }

    /// Render the file tree widget
    pub fn render(&self, frame: &mut Frame, area: Rect, is_focused: bool) {
        let filtered = self.get_filtered_list();

        let items: Vec<ListItem> = filtered
            .iter()
            .map(|(_, node)| {
                let indent = "  ".repeat(node.depth);
                let icon = if node.is_dir {
                    if node.has_children {
                        if node.is_expanded { "▼ " } else { "▶ " }
                    } else {
                        "○ "
                    }
                } else {
                    "• "
                };

                let style = if filtered
                    .get(self.selected_index)
                    .map(|(_, n)| n.path == node.path)
                    .unwrap_or(false)
                {
                    Style::default()
                        .fg(Color::Black)
                        .bg(Color::Rgb(38, 139, 210))
                        .add_modifier(Modifier::BOLD)
                } else if !self.search_query.is_empty()
                    && node
                        .name
                        .to_lowercase()
                        .contains(&self.search_query.to_lowercase())
                {
                    Style::default()
                        .fg(Color::Rgb(181, 137, 0))
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(Color::Rgb(131, 148, 150))
                };

                let content = format!("{}{}{}", indent, icon, node.name);
                ListItem::new(content).style(style)
            })
            .collect();

        let border_style = if is_focused {
            Style::default().fg(Color::Rgb(38, 139, 210))
        } else {
            Style::default().fg(Color::Rgb(101, 123, 131))
        };

        let title = if self.search_mode {
            format!("Files [Search: {}]", self.search_query)
        } else {
            "Files".to_string()
        };

        let list = List::new(items).block(
            Block::default()
                .borders(Borders::ALL)
                .title(title)
                .border_style(border_style),
        );

        frame.render_widget(list, area);
    }

    /// Reload the file tree (useful for refreshing after file system changes)
    pub fn reload(&mut self) {
        if let Ok(new_tree) = self.tree_builder.build_tree(self.finder_config) {
            self.tree_data = new_tree;
            self.rebuild_display_nodes();
        }
    }

    /// Update finder configuration
    pub fn set_finder_config(&mut self, config: FinderConfig) {
        self.finder_config = config;
        self.reload();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Result;
    use mp_core::build_markdown_tree_in_dir;
    use std::fs;
    use tempfile::TempDir;

    /// Mock tree builder for testing
    struct MockTreeBuilder {
        tree_data: FileTreeNode,
    }

    impl MockTreeBuilder {
        fn new(tree_data: FileTreeNode) -> Self {
            Self { tree_data }
        }

        fn from_directory(path: &str, config: FinderConfig) -> Result<Self> {
            let tree_data = build_markdown_tree_in_dir(path, config)?;
            Ok(Self::new(tree_data))
        }
    }

    impl TreeBuilder for MockTreeBuilder {
        fn build_tree(&self, _config: FinderConfig) -> Result<FileTreeNode> {
            Ok(self.tree_data.clone())
        }
    }

    #[test]
    fn test_file_tree_widget_creation() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().to_path_buf();

        // Create some test files
        fs::write(path.join("test.md"), "content").unwrap();

        let widget = FileTreeWidget::new(path.clone());

        // Widget should be created with display nodes
        assert!(!widget.display_nodes.is_empty());
        assert_eq!(widget.selected_index, 0);
        assert!(!widget.search_mode);
    }

    #[test]
    fn test_search_functionality() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().to_path_buf();

        fs::write(path.join("hello.md"), "content").unwrap();
        fs::write(path.join("world.md"), "content").unwrap();

        // Build tree directly for the temp directory
        let config = FinderConfig::default();
        let mock_builder = MockTreeBuilder::from_directory(path.to_str().unwrap(), config).unwrap();
        let mut widget = FileTreeWidget::with_builder(Box::new(mock_builder), config);

        widget.start_search();
        assert!(widget.search_mode);

        widget.add_search_char('h');
        widget.add_search_char('e');
        assert_eq!(widget.search_query, "he");

        let filtered = widget.get_filtered_list();
        // Check if any node contains "hello" in its name
        let has_hello = filtered
            .iter()
            .any(|(_, node)| node.name.to_lowercase().contains("hello"));
        assert!(
            has_hello,
            "Should find 'hello.md' in filtered list (found {} items matching 'he')",
            filtered.len()
        );

        widget.cancel_search();
        assert!(!widget.search_mode);
        assert!(widget.search_query.is_empty());
    }

    #[test]
    fn test_navigation() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().to_path_buf();

        fs::write(path.join("a.md"), "").unwrap();
        fs::write(path.join("b.md"), "").unwrap();

        // Build tree directly for the temp directory
        let config = FinderConfig::default();
        let mock_builder = MockTreeBuilder::from_directory(path.to_str().unwrap(), config).unwrap();
        let mut widget = FileTreeWidget::with_builder(Box::new(mock_builder), config);

        // The widget should have at least the root and some files
        // Root is expanded, so we should see: root + 2 files = 3 nodes
        assert!(
            widget.display_nodes.len() >= 3,
            "Should have root and files (got {} nodes)",
            widget.display_nodes.len()
        );

        let initial_index = widget.selected_index;
        assert_eq!(initial_index, 0);

        // Try to move down
        widget.move_selection_down();
        assert!(widget.selected_index > initial_index, "Should move down");

        // Move back up
        widget.move_selection_up();
        assert_eq!(
            widget.selected_index, initial_index,
            "Should move back to initial position"
        );
    }

    #[test]
    fn test_folder_expansion() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().to_path_buf();

        // Create a subdirectory with a markdown file
        let subdir = path.join("subdir");
        fs::create_dir(&subdir).unwrap();
        fs::write(subdir.join("test.md"), "content").unwrap();

        // Build tree directly for the temp directory
        let config = FinderConfig::default();
        let mock_builder = MockTreeBuilder::from_directory(path.to_str().unwrap(), config).unwrap();
        let mut widget = FileTreeWidget::with_builder(Box::new(mock_builder), config);

        // Find the subdirectory in the display nodes
        let subdir_index = widget
            .display_nodes
            .iter()
            .position(|n| n.name == "subdir" && n.is_dir)
            .expect("Should find subdir");

        // Select the subdirectory
        widget.selected_index = subdir_index;

        // Initially, the subdirectory should not be expanded (except root)
        let initial_node_count = widget.display_nodes.len();

        // Toggle to expand the subdirectory
        widget.toggle_selected();

        // After expanding, we should have more nodes (the subdirectory's children)
        assert!(
            widget.display_nodes.len() > initial_node_count,
            "Should have more nodes after expanding"
        );

        // Find the subdirectory again (position might have changed)
        let subdir_index_after = widget
            .display_nodes
            .iter()
            .position(|n| n.name == "subdir" && n.is_dir)
            .expect("Should find subdir after toggle");

        // The subdirectory should now be expanded
        assert!(
            widget.display_nodes[subdir_index_after].is_expanded,
            "Subdirectory should be expanded"
        );

        // Toggle again to collapse
        widget.selected_index = subdir_index_after;
        widget.toggle_selected();

        // After collapsing, we should have fewer nodes
        assert_eq!(
            widget.display_nodes.len(),
            initial_node_count,
            "Should return to initial node count after collapsing"
        );
    }
}
