#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ElementPhase {
    Start,
    End,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ElementKind {
    Heading(u8),
    Paragraph,
    ListItem,
    BlockQuote,
    Table(TableVariant),
}

pub enum OutputType {
    Element {
        kind: ElementKind,
        phase: ElementPhase,
    },
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
