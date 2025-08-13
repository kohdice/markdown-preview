// Re-export state types to maintain backward compatibility after module reorganization.
// These types were originally in parser.rs but have been moved to renderer/state.rs
// for better architectural separation of concerns.
pub use crate::renderer::state::{
    ActiveElement, CodeBlockState, ContentType, EmphasisState, ImageState, LinkState, ListType,
    RenderState, TableState,
};
