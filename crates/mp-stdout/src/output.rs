#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ElementPhase {
    Start,
    End,
}

/// Represents different kinds of Markdown elements.
#[derive(Debug, Clone, PartialEq)]
pub enum ElementKind {
    Heading(u8),
    Paragraph,
    ListItem,
    BlockQuote,
    Table(TableVariant),
}

pub enum OutputType {
    /// A structural element with a start/end phase
    Element {
        kind: ElementKind,
        phase: ElementPhase,
    },
    /// Standalone output types that don't have phases
    HorizontalRule,
    InlineCode {
        code: String,
    },
    TaskMarker {
        checked: bool,
    },
    Link,
    Image,
    CodeBlock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableVariant {
    HeadStart,
    HeadEnd,
    RowEnd,
}
