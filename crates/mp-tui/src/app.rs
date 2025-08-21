use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;

use crate::widgets::{FileTreeWidget, PreviewWidget, StatusBar, StatusMode};

pub struct App {
    pub file_tree: FileTreeWidget,
    pub preview: PreviewWidget,
    pub status_bar: StatusBar,
    pub focus: AppFocus,
    pub should_quit: bool,
    pub show_help: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AppFocus {
    FileTree,
    Preview,
}

impl App {
    pub fn new() -> Result<Self> {
        let current_dir = std::env::current_dir()?;
        let mut file_tree = FileTreeWidget::new(current_dir);

        file_tree.root.is_expanded = true;

        let mut app = Self {
            file_tree,
            preview: PreviewWidget::new(),
            status_bar: StatusBar::new(),
            focus: AppFocus::FileTree,
            should_quit: false,
            show_help: false,
        };

        app.load_selected_file()?;

        Ok(app)
    }

    pub fn run(mut self, mut terminal: DefaultTerminal) -> Result<()> {
        terminal.draw(|frame| self.draw(frame))?;

        loop {
            if event::poll(Duration::from_millis(100))?
                && let Event::Key(key) = event::read()?
            {
                if self.handle_key(key)? {
                    break;
                }
                terminal.draw(|frame| self.draw(frame))?;
            }
        }
        Ok(())
    }

    fn handle_key(&mut self, key: KeyEvent) -> Result<bool> {
        if self.show_help {
            self.show_help = false;
            self.status_bar.set_mode(StatusMode::Normal);
            return Ok(false);
        }

        if self.file_tree.search_mode {
            match key.code {
                KeyCode::Esc => {
                    self.file_tree.cancel_search();
                    self.status_bar.set_mode(StatusMode::Normal);
                }
                KeyCode::Enter => {
                    self.file_tree.search_mode = false;
                    self.status_bar.set_mode(StatusMode::Normal);
                    self.load_selected_file()?;
                }
                KeyCode::Backspace => {
                    self.file_tree.remove_search_char();
                }
                KeyCode::Char(c) => {
                    self.file_tree.add_search_char(c);
                }
                _ => {}
            }
            return Ok(false);
        }

        match (self.focus, key.code, key.modifiers) {
            (_, KeyCode::Char('q'), _) | (_, KeyCode::Esc, _) => {
                self.should_quit = true;
                return Ok(true);
            }
            (_, KeyCode::Char('?'), _) => {
                self.show_help = true;
                self.status_bar.set_mode(StatusMode::Help);
                self.status_bar.set_message(
                    "Help: Use arrow keys to navigate, Enter to expand/select, Tab to switch focus",
                );
            }
            (_, KeyCode::Char('/'), _) => {
                self.file_tree.start_search();
                self.status_bar.set_mode(StatusMode::Search);
            }
            (_, KeyCode::Tab, _) => {
                self.focus = match self.focus {
                    AppFocus::FileTree => AppFocus::Preview,
                    AppFocus::Preview => AppFocus::FileTree,
                };
                self.status_bar
                    .set_message(format!("Focus: {:?}", self.focus));
            }

            (AppFocus::FileTree, KeyCode::Down, _)
            | (AppFocus::FileTree, KeyCode::Char('j'), _) => {
                self.file_tree.move_selection_down();
                self.load_selected_file()?;
            }
            (AppFocus::FileTree, KeyCode::Up, _) | (AppFocus::FileTree, KeyCode::Char('k'), _) => {
                self.file_tree.move_selection_up();
                self.load_selected_file()?;
            }
            (AppFocus::FileTree, KeyCode::Enter, _)
            | (AppFocus::FileTree, KeyCode::Char(' '), _) => {
                self.file_tree.toggle_selected();
                if let Some(_file) = self.file_tree.get_selected_file() {
                    self.focus = AppFocus::Preview;
                    self.status_bar.set_message("Switched to preview");
                }
            }
            (AppFocus::FileTree, KeyCode::Right, _)
            | (AppFocus::FileTree, KeyCode::Char('l'), _) => {
                self.file_tree.toggle_selected();
            }
            (AppFocus::FileTree, KeyCode::Left, _)
            | (AppFocus::FileTree, KeyCode::Char('h'), _) => {
                self.file_tree.toggle_selected();
            }

            (AppFocus::Preview, KeyCode::Down, _) | (AppFocus::Preview, KeyCode::Char('j'), _) => {
                self.preview.scroll_down(1);
            }
            (AppFocus::Preview, KeyCode::Up, _) | (AppFocus::Preview, KeyCode::Char('k'), _) => {
                self.preview.scroll_up(1);
            }
            (AppFocus::Preview, KeyCode::PageDown, _)
            | (AppFocus::Preview, KeyCode::Char('f'), KeyModifiers::CONTROL) => {
                self.preview.page_down();
            }
            (AppFocus::Preview, KeyCode::PageUp, _)
            | (AppFocus::Preview, KeyCode::Char('b'), KeyModifiers::CONTROL) => {
                self.preview.page_up();
            }
            (AppFocus::Preview, KeyCode::Home, _) | (AppFocus::Preview, KeyCode::Char('g'), _) => {
                self.preview.scroll_to_top();
            }
            (AppFocus::Preview, KeyCode::End, _)
            | (AppFocus::Preview, KeyCode::Char('G'), KeyModifiers::SHIFT) => {
                self.preview.scroll_to_bottom();
            }

            _ => {}
        }

        Ok(false)
    }

    fn load_selected_file(&mut self) -> Result<()> {
        if let Some(path) = self.file_tree.get_selected_file() {
            match std::fs::read_to_string(&path) {
                Ok(content) => {
                    self.preview.set_content(Arc::new(content));
                    self.status_bar.set_file(&path);
                    self.status_bar.clear_message();
                }
                Err(e) => {
                    self.status_bar
                        .set_error(format!("Failed to load file: {}", e));
                }
            }
        }
        Ok(())
    }

    fn draw(&mut self, frame: &mut ratatui::Frame) {
        use ratatui::layout::{Constraint, Direction, Layout};

        let main_chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(0), Constraint::Length(1)])
            .split(frame.area());

        let content_chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(30), Constraint::Percentage(70)])
            .split(main_chunks[0]);

        self.file_tree
            .render(frame, content_chunks[0], self.focus == AppFocus::FileTree);
        self.preview
            .render(frame, content_chunks[1], self.focus == AppFocus::Preview);
        self.status_bar.render(frame, main_chunks[1]);

        if self.show_help {
            self.render_help(frame);
        }
    }

    fn render_help(&self, frame: &mut ratatui::Frame) {
        use ratatui::{
            layout::{Alignment, Constraint, Direction, Layout},
            style::{Color, Modifier, Style},
            text::{Line, Span},
            widgets::{Block, Borders, Clear, Paragraph},
        };

        let area = frame.area();
        let popup_area = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Percentage(20),
                Constraint::Percentage(60),
                Constraint::Percentage(20),
            ])
            .split(area)[1];

        let popup_area = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Percentage(20),
                Constraint::Percentage(60),
                Constraint::Percentage(20),
            ])
            .split(popup_area)[1];

        let help_text = vec![
            Line::from(vec![Span::styled(
                "Markdown Preview TUI Help",
                Style::default()
                    .fg(Color::Rgb(181, 137, 0))
                    .add_modifier(Modifier::BOLD),
            )]),
            Line::from(""),
            Line::from(vec![Span::styled(
                "Navigation:",
                Style::default()
                    .fg(Color::Rgb(38, 139, 210))
                    .add_modifier(Modifier::BOLD),
            )]),
            Line::from("  ↑/k     - Move up"),
            Line::from("  ↓/j     - Move down"),
            Line::from("  Enter   - Expand/Select"),
            Line::from("  Tab     - Switch focus"),
            Line::from(""),
            Line::from(vec![Span::styled(
                "Preview:",
                Style::default()
                    .fg(Color::Rgb(38, 139, 210))
                    .add_modifier(Modifier::BOLD),
            )]),
            Line::from("  PgUp/^b - Page up"),
            Line::from("  PgDn/^f - Page down"),
            Line::from("  Home/g  - Go to top"),
            Line::from("  End/G   - Go to bottom"),
            Line::from(""),
            Line::from(vec![Span::styled(
                "General:",
                Style::default()
                    .fg(Color::Rgb(38, 139, 210))
                    .add_modifier(Modifier::BOLD),
            )]),
            Line::from("  /       - Search files"),
            Line::from("  ?       - Show this help"),
            Line::from("  q/Esc   - Quit"),
            Line::from(""),
            Line::from(vec![Span::styled(
                "Press any key to close",
                Style::default()
                    .fg(Color::Rgb(88, 110, 117))
                    .add_modifier(Modifier::ITALIC),
            )]),
        ];

        let help = Paragraph::new(help_text)
            .block(
                Block::default()
                    .title("Help")
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::Rgb(38, 139, 210))),
            )
            .style(Style::default().bg(Color::Rgb(7, 54, 66)))
            .alignment(Alignment::Left);

        frame.render_widget(Clear, popup_area);
        frame.render_widget(help, popup_area);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_creation() {
        // This test might fail if run in a directory without proper permissions
        // or without any markdown files
        if let Ok(app) = App::new() {
            assert_eq!(app.focus, AppFocus::FileTree);
            assert!(!app.should_quit);
            assert!(!app.show_help);
        }
    }

    #[test]
    fn test_focus_switching() {
        if let Ok(mut app) = App::new() {
            assert_eq!(app.focus, AppFocus::FileTree);

            app.focus = AppFocus::Preview;
            assert_eq!(app.focus, AppFocus::Preview);

            app.focus = AppFocus::FileTree;
            assert_eq!(app.focus, AppFocus::FileTree);
        }
    }
}
