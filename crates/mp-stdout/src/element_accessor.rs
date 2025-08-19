//! Generic element accessor traits for reducing code duplication
//!
//! This module provides a trait-based approach to accessing different element types
//! within ActiveElement, eliminating repetitive getter/setter methods.

use super::state::{ActiveElement, CodeBlockState, ImageState, LinkState, TableState};

/// Trait for extracting specific element data from ActiveElement.
/// Each element type implements this trait to provide type-safe access.
pub trait ElementData {
    /// The output type when extracting from ActiveElement
    type Output;

    /// Extract immutable reference from ActiveElement if type matches
    fn extract(element: &ActiveElement) -> Option<&Self::Output>;

    /// Extract mutable reference from ActiveElement if type matches
    fn extract_mut(element: &mut ActiveElement) -> Option<&mut Self::Output>;

    /// Create a new ActiveElement variant containing the given data
    fn create(data: Self::Output) -> ActiveElement;
}

/// Marker type for LinkState element access
pub struct LinkAccessor;

impl ElementData for LinkAccessor {
    type Output = LinkState;

    fn extract(element: &ActiveElement) -> Option<&LinkState> {
        match element {
            ActiveElement::Link(link) => Some(link),
            _ => None,
        }
    }

    fn extract_mut(element: &mut ActiveElement) -> Option<&mut LinkState> {
        match element {
            ActiveElement::Link(link) => Some(link),
            _ => None,
        }
    }

    fn create(data: LinkState) -> ActiveElement {
        ActiveElement::Link(data)
    }
}

/// Marker type for ImageState element access
pub struct ImageAccessor;

impl ElementData for ImageAccessor {
    type Output = ImageState;

    fn extract(element: &ActiveElement) -> Option<&ImageState> {
        match element {
            ActiveElement::Image(image) => Some(image),
            _ => None,
        }
    }

    fn extract_mut(element: &mut ActiveElement) -> Option<&mut ImageState> {
        match element {
            ActiveElement::Image(image) => Some(image),
            _ => None,
        }
    }

    fn create(data: ImageState) -> ActiveElement {
        ActiveElement::Image(data)
    }
}

/// Marker type for CodeBlockState element access
pub struct CodeBlockAccessor;

impl ElementData for CodeBlockAccessor {
    type Output = CodeBlockState;

    fn extract(element: &ActiveElement) -> Option<&CodeBlockState> {
        match element {
            ActiveElement::CodeBlock(code_block) => Some(code_block),
            _ => None,
        }
    }

    fn extract_mut(element: &mut ActiveElement) -> Option<&mut CodeBlockState> {
        match element {
            ActiveElement::CodeBlock(code_block) => Some(code_block),
            _ => None,
        }
    }

    fn create(data: CodeBlockState) -> ActiveElement {
        ActiveElement::CodeBlock(data)
    }
}

/// Marker type for TableState element access
pub struct TableAccessor;

impl ElementData for TableAccessor {
    type Output = TableState;

    fn extract(element: &ActiveElement) -> Option<&TableState> {
        match element {
            ActiveElement::Table(table) => Some(table),
            _ => None,
        }
    }

    fn extract_mut(element: &mut ActiveElement) -> Option<&mut TableState> {
        match element {
            ActiveElement::Table(table) => Some(table),
            _ => None,
        }
    }

    fn create(data: TableState) -> ActiveElement {
        ActiveElement::Table(data)
    }
}
