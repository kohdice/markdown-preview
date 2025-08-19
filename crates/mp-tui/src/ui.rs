use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
};

use crate::{app::App, widgets};

pub fn draw(frame: &mut Frame, app: &App) {
    let chunks = Layout::horizontal([Constraint::Percentage(30), Constraint::Percentage(70)])
        .split(frame.area());

    draw_file_tree(frame, app, chunks[0]);
    draw_preview(frame, app, chunks[1]);
}

fn draw_file_tree(frame: &mut Frame, app: &App, area: Rect) {
    let file_list = widgets::file_tree::create_file_list(app);
    frame.render_stateful_widget(file_list, area, &mut app.list_state.clone());
}

fn draw_preview(frame: &mut Frame, app: &App, area: Rect) {
    let preview = widgets::preview::create_preview(app);
    frame.render_widget(preview, area);
}
