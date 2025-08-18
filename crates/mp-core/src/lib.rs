pub mod finder;
pub mod html_entity;
pub mod utils;

// Public API
pub use finder::{FinderConfig, display_files, find_markdown_files};
pub use html_entity::EntityDecoder;
