use std::path::PathBuf;
use std::time::Duration;

use color_eyre::eyre::Result;
use crossterm::event::{self, Event, KeyCode, KeyEvent};
use ratatui::DefaultTerminal;
use ratatui::widgets::ListState;

pub struct App {
    pub file_list: Vec<PathBuf>,
    pub list_state: ListState,
    pub preview_content: String,
    pub preview_scroll: (u16, u16),
    pub focus: Focus,
    pub should_quit: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Focus {
    FileTree,
    Preview,
}

impl App {
    pub fn new() -> Result<Self> {
        let config = mp_core::finder::FinderConfig::default();
        let file_list = mp_core::finder::find_markdown_files(config)
            .map_err(|e| color_eyre::eyre::eyre!("Failed to find markdown files: {}", e))?;
        let mut list_state = ListState::default();

        if !file_list.is_empty() {
            list_state.select(Some(0));
        }

        let mut app = Self {
            file_list,
            list_state,
            preview_content: String::new(),
            preview_scroll: (0, 0),
            focus: Focus::FileTree,
            should_quit: false,
        };

        app.load_preview()?;
        Ok(app)
    }

    pub fn run(mut self, mut terminal: DefaultTerminal) -> Result<()> {
        loop {
            terminal.draw(|frame| crate::ui::draw(frame, &self))?;

            if event::poll(Duration::from_millis(16))?
                && let Event::Key(key) = event::read()?
                && self.handle_key(key)?
            {
                break;
            }
        }
        Ok(())
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> Result<bool> {
        match (self.focus, key.code) {
            (Focus::FileTree, KeyCode::Down | KeyCode::Char('j')) => {
                self.next_file();
                self.load_preview()?;
            }
            (Focus::FileTree, KeyCode::Up | KeyCode::Char('k')) => {
                self.previous_file();
                self.load_preview()?;
            }
            (Focus::FileTree, KeyCode::Enter) => {
                self.focus = Focus::Preview;
            }

            (Focus::Preview, KeyCode::Char('j')) => {
                self.preview_scroll.0 = self.preview_scroll.0.saturating_add(1);
            }
            (Focus::Preview, KeyCode::Char('k')) => {
                self.preview_scroll.0 = self.preview_scroll.0.saturating_sub(1);
            }
            (Focus::Preview, KeyCode::PageDown) => {
                self.preview_scroll.0 = self.preview_scroll.0.saturating_add(10);
            }
            (Focus::Preview, KeyCode::PageUp) => {
                self.preview_scroll.0 = self.preview_scroll.0.saturating_sub(10);
            }

            (_, KeyCode::Tab) => {
                self.focus = match self.focus {
                    Focus::FileTree => Focus::Preview,
                    Focus::Preview => Focus::FileTree,
                };
            }
            (_, KeyCode::Char('q') | KeyCode::Esc) => {
                self.should_quit = true;
                return Ok(true);
            }
            _ => {}
        }
        Ok(false)
    }

    fn next_file(&mut self) {
        if self.file_list.is_empty() {
            return;
        }

        let selected = self.list_state.selected().unwrap_or(0);
        let next = if selected >= self.file_list.len() - 1 {
            0
        } else {
            selected + 1
        };
        self.list_state.select(Some(next));
    }

    fn previous_file(&mut self) {
        if self.file_list.is_empty() {
            return;
        }

        let selected = self.list_state.selected().unwrap_or(0);
        let previous = if selected == 0 {
            self.file_list.len() - 1
        } else {
            selected - 1
        };
        self.list_state.select(Some(previous));
    }

    fn load_preview(&mut self) -> Result<()> {
        if let Some(selected) = self.list_state.selected()
            && let Some(path) = self.file_list.get(selected)
        {
            self.preview_content = std::fs::read_to_string(path)?;
            self.preview_scroll = (0, 0);
        }
        Ok(())
    }
}
