use ratatui::style::{Color, Style};

use crate::{
    app::{App, Focus},
    renderer::MarkdownWidget,
};

pub fn create_preview(app: &App) -> MarkdownWidget {
    let border_style = if app.focus == Focus::Preview {
        Style::default().fg(Color::Rgb(38, 139, 210))
    } else {
        Style::default().fg(Color::Rgb(101, 123, 131))
    };

    MarkdownWidget::new(app.preview_content.clone())
        .scroll_offset(app.preview_scroll.0)
        .border_style(border_style)
}
