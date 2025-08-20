use std::panic;

use color_eyre::eyre;

mod app;
mod events;
mod renderer;
mod ui;
mod widgets {
    pub mod file_tree;
    pub mod preview;
}

pub use app::{App, Focus};
pub use renderer::MarkdownWidget;

pub fn run_tui() -> eyre::Result<()> {
    color_eyre::install()?;
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
