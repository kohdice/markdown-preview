/// Terminal output types
pub enum OutputType {
    Heading { level: u8, is_end: bool },
    Paragraph { is_end: bool },
    HorizontalRule,
    InlineCode { code: String },
    TaskMarker { checked: bool },
    ListItem { is_end: bool },
    BlockQuote { is_end: bool },
    Link,
    Image,
    Table { variant: TableVariant },
    CodeBlock,
}

pub enum TableVariant {
    HeadStart,
    HeadEnd,
    RowEnd,
}
