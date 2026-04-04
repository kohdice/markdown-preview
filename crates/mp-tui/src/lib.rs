use std::panic;

use anyhow::Result;
use mp_core::FinderConfig;

mod app;
mod file_tree;
mod preview;
pub mod renderer;
mod status_bar;
mod theme_adapter;
mod tree_builder;

pub use app::{App, AppFocus};
pub use file_tree::FileTreeWidget;
pub use preview::PreviewWidget;
pub use renderer::MarkdownWidget;
pub use status_bar::{StatusBar, StatusMode};

pub fn run_tui(finder_config: FinderConfig) -> Result<()> {
    install_panic_handler();

    let terminal = ratatui::init();
    let app_result = App::new_with_config(finder_config)?.run(terminal);

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
