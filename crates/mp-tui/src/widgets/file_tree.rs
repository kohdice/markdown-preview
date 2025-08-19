use ratatui::{
    style::{Color, Modifier, Style},
    widgets::{Block, Borders, List, ListItem},
};

use crate::app::{App, Focus};

pub fn create_file_list(app: &App) -> List<'static> {
    let items: Vec<ListItem> = app
        .file_list
        .iter()
        .map(|path| {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            ListItem::new(name.to_string())
        })
        .collect();

    let border_style = if app.focus == Focus::FileTree {
        Style::default().fg(Color::Rgb(38, 139, 210))
    } else {
        Style::default().fg(Color::Rgb(101, 123, 131))
    };

    List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title("📁 Files")
                .border_style(border_style),
        )
        .highlight_style(
            Style::default()
                .bg(Color::Rgb(38, 139, 210))
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("> ")
}
