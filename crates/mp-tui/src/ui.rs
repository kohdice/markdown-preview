use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Style},
};

use crate::{
    app::{App, Focus},
    widgets::file_tree,
};

pub fn draw(frame: &mut Frame, app: &mut App) {
    let chunks = Layout::horizontal([Constraint::Percentage(30), Constraint::Percentage(70)])
        .split(frame.area());

    draw_file_tree(frame, app, chunks[0]);
    draw_preview(frame, app, chunks[1]);
}

fn draw_file_tree(frame: &mut Frame, app: &App, area: Rect) {
    let file_list = file_tree::create_file_list(app);
    frame.render_stateful_widget(file_list, area, &mut app.list_state.clone());
}

fn draw_preview(frame: &mut Frame, app: &mut App, area: Rect) {
    // Update border style based on focus
    app.markdown_state.border_style = if app.focus == Focus::Preview {
        Style::default().fg(Color::Rgb(38, 139, 210))
    } else {
        Style::default().fg(Color::Rgb(101, 123, 131))
    };

    // Render the cached widget if available
    if let Some(ref widget) = app.markdown_widget {
        frame.render_stateful_widget(widget, area, &mut app.markdown_state);
    }
}
