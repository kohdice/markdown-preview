use std::path::{Path, PathBuf};

use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    widgets::{Block, Borders, List, ListItem},
};

#[derive(Clone, Debug)]
pub struct FileNode {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub is_expanded: bool,
    pub children: Vec<FileNode>,
    pub depth: usize,
}

impl FileNode {
    fn contains_markdown(dir: &Path) -> bool {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if (path.is_file()
                    && path
                        .extension()
                        .map(|ext| ext == "md" || ext == "markdown")
                        .unwrap_or(false))
                    || (path.is_dir() && Self::contains_markdown(&path))
                {
                    return true;
                }
            }
        }
        false
    }

    pub fn new(path: PathBuf, depth: usize) -> Self {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();

        let is_dir = path.is_dir();
        let mut children = Vec::new();

        if is_dir {
            if let Ok(entries) = std::fs::read_dir(&path) {
                for entry in entries.flatten() {
                    let child_path = entry.path();
                    if child_path.is_dir() {
                        if Self::contains_markdown(&child_path) {
                            children.push(FileNode::new(child_path, depth + 1));
                        }
                    } else if child_path
                        .extension()
                        .and_then(|ext| ext.to_str())
                        .map(|ext| ext == "md" || ext == "markdown")
                        .unwrap_or(false)
                    {
                        children.push(FileNode::new(child_path, depth + 1));
                    }
                }
            }
            children.sort_by(|a, b| match (a.is_dir, b.is_dir) {
                (true, false) => std::cmp::Ordering::Less,
                (false, true) => std::cmp::Ordering::Greater,
                _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            });
        }

        Self {
            path,
            name,
            is_dir,
            is_expanded: false,
            children,
            depth,
        }
    }

    pub fn flatten(&self) -> Vec<FileNode> {
        let mut result = vec![self.clone()];
        if self.is_expanded {
            for child in &self.children {
                result.extend(child.flatten());
            }
        }
        result
    }

    pub fn toggle_expanded(&mut self) {
        if self.is_dir {
            self.is_expanded = !self.is_expanded;
        }
    }
}

pub struct FileTreeWidget {
    pub root: FileNode,
    pub selected_index: usize,
    pub search_query: String,
    pub search_mode: bool,
    pub filtered_indices: Vec<usize>,
    pub scroll_offset: usize,
}

impl FileTreeWidget {
    pub fn new(root_path: PathBuf) -> Self {
        Self {
            root: FileNode::new(root_path, 0),
            selected_index: 0,
            search_query: String::new(),
            search_mode: false,
            filtered_indices: Vec::new(),
            scroll_offset: 0,
        }
    }

    pub fn get_flat_list(&self) -> Vec<FileNode> {
        self.root.flatten()
    }

    pub fn get_filtered_list(&self) -> Vec<(usize, FileNode)> {
        let flat_list = self.get_flat_list();

        if self.search_query.is_empty() {
            flat_list.into_iter().enumerate().collect()
        } else {
            let query = self.search_query.to_lowercase();
            flat_list
                .into_iter()
                .enumerate()
                .filter(|(_, node)| {
                    node.name.to_lowercase().contains(&query)
                        || node.path.to_string_lossy().to_lowercase().contains(&query)
                })
                .collect()
        }
    }

    pub fn toggle_selected(&mut self) {
        let flat_list = &mut self.get_flat_list();
        if let Some(mut selected) = flat_list.get(self.selected_index).cloned() {
            selected.toggle_expanded();
            self.update_node(&selected);
        }
    }

    fn update_node(&mut self, updated: &FileNode) {
        Self::update_node_recursive(&mut self.root, updated);
    }

    fn update_node_recursive(node: &mut FileNode, updated: &FileNode) -> bool {
        if node.path == updated.path {
            node.is_expanded = updated.is_expanded;
            return true;
        }

        for child in &mut node.children {
            if Self::update_node_recursive(child, updated) {
                return true;
            }
        }
        false
    }

    pub fn move_selection_up(&mut self) {
        let filtered = self.get_filtered_list();
        if !filtered.is_empty() && self.selected_index > 0 {
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

    pub fn get_selected_file(&self) -> Option<PathBuf> {
        let flat_list = self.get_flat_list();
        flat_list
            .get(self.selected_index)
            .filter(|node| !node.is_dir)
            .map(|node| node.path.clone())
    }

    pub fn start_search(&mut self) {
        self.search_mode = true;
        self.search_query.clear();
    }

    pub fn cancel_search(&mut self) {
        self.search_mode = false;
        self.search_query.clear();
        self.filtered_indices.clear();
    }

    pub fn add_search_char(&mut self, c: char) {
        self.search_query.push(c);
        self.update_filter();
    }

    pub fn remove_search_char(&mut self) {
        self.search_query.pop();
        self.update_filter();
    }

    fn update_filter(&mut self) {
        let filtered = self.get_filtered_list();
        self.filtered_indices = filtered.iter().map(|(i, _)| *i).collect();

        if !self.filtered_indices.is_empty()
            && !self.filtered_indices.contains(&self.selected_index)
        {
            self.selected_index = self.filtered_indices[0];
        }
    }

    fn adjust_scroll_for_selection(&mut self) {}

    pub fn render(&self, frame: &mut Frame, area: Rect, is_focused: bool) {
        let filtered = self.get_filtered_list();

        let items: Vec<ListItem> = filtered
            .iter()
            .map(|(idx, node)| {
                let indent = "  ".repeat(node.depth);
                let icon = if node.is_dir {
                    if node.is_expanded { "▼ " } else { "▶ " }
                } else {
                    "⏺ "
                };

                let style = if *idx == self.selected_index {
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_file_node_creation() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().to_path_buf();

        let node = FileNode::new(path.clone(), 0);
        assert_eq!(node.depth, 0);
        assert!(node.is_dir);
        assert!(!node.is_expanded);
        assert!(node.children.is_empty());
    }

    #[test]
    fn test_file_tree_navigation() {
        let temp_dir = TempDir::new().unwrap();
        let root_path = temp_dir.path().to_path_buf();

        fs::write(root_path.join("test1.md"), "content").unwrap();
        fs::write(root_path.join("test2.md"), "content").unwrap();

        let mut widget = FileTreeWidget::new(root_path.clone());
        widget.root.is_expanded = true;

        widget.root = FileNode::new(root_path, 0);
        widget.root.is_expanded = true;

        let flat_list = widget.get_flat_list();
        assert!(flat_list.len() >= 3);

        assert_eq!(widget.selected_index, 0);
        widget.move_selection_down();
        assert_eq!(widget.selected_index, 1);
        widget.move_selection_up();
        assert_eq!(widget.selected_index, 0);
    }

    #[test]
    fn test_search_functionality() {
        let temp_dir = TempDir::new().unwrap();
        let root_path = temp_dir.path().to_path_buf();

        fs::write(root_path.join("hello.md"), "content").unwrap();
        fs::write(root_path.join("world.md"), "content").unwrap();
        fs::write(root_path.join("test.md"), "content").unwrap();

        let mut widget = FileTreeWidget::new(root_path.clone());
        widget.root = FileNode::new(root_path, 0);
        widget.root.is_expanded = true;

        widget.start_search();
        assert!(widget.search_mode);

        widget.add_search_char('h');
        widget.add_search_char('e');
        assert_eq!(widget.search_query, "he");

        let filtered = widget.get_filtered_list();
        assert!(filtered.iter().any(|(_, node)| node.name.contains("hello")));

        widget.cancel_search();
        assert!(!widget.search_mode);
        assert!(widget.search_query.is_empty());
    }
}
