use std::panic;

use anyhow::Result;

mod app;
mod file_tree;
mod preview;
pub mod renderer;
mod status_bar;
mod theme_adapter;
pub mod widgets;

pub use app::{App, AppFocus};
pub use renderer::MarkdownWidget;

pub fn run_tui() -> Result<()> {
    install_panic_handler();

    let terminal = ratatui::init();
    let app_result = App::new()?.run(terminal);

    ratatui::restore();
    app_result
}

fn install_panic_handler() {
    let original_hook = panic::take_hook();
    panic::set_hook(Box::new(move |panic_info| {
        ratatui::restore();
        original_hook(panic_info);
    }));
}
