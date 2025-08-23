use pulldown_cmark::Alignment;

pub enum ContentType<'a> {
    Text(&'a str),
    Code(&'a str),
    Html(&'a str),
    SoftBreak,
    HardBreak,
    Rule,
    TaskMarker(bool),
}

#[derive(Debug, Default, Clone)]
pub struct EmphasisState {
    pub strong: bool,
    pub italic: bool,
}

#[derive(Debug, Clone, Default)]
pub struct LinkState {
    pub text: String,
    pub url: String,
}

#[derive(Debug, Clone, Default)]
pub struct ImageState {
    pub alt_text: String,
    pub url: String,
}

#[derive(Debug, Clone)]
pub struct CodeBlockState {
    pub language: Option<String>,
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct TableState {
    pub alignments: Vec<Alignment>,
    pub current_row: Vec<String>,
    pub is_header: bool,
}

#[derive(Debug, Clone)]
pub enum ListType {
    Ordered { current: usize },
    Unordered,
}

#[derive(Debug, Clone)]
pub enum ActiveElement {
    Link(LinkState),
    Image(ImageState),
    CodeBlock(CodeBlockState),
    Table(TableState),
}

#[derive(Debug, Default, Clone)]
pub struct RenderState {
    pub emphasis: EmphasisState,

    /// Currently active complex element that requires text accumulation.
    /// Enforces single-context parsing - only one of link/image/code/table can be active
    pub active_element: Option<ActiveElement>,

    /// Stack tracking nested list contexts for proper indentation and numbering
    pub list_stack: Vec<ListType>,

    /// Buffer for accumulating text within the current line
    pub current_line: String,
}

impl RenderState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn has_link(&self) -> bool {
        matches!(self.active_element, Some(ActiveElement::Link(_)))
    }

    /// Determines text color based on emphasis combination and link context.
    /// Priority: strong+italic > strong > italic, with link state affecting color choices.
    pub fn get_text_color(&self) -> (u8, u8, u8) {
        match (self.emphasis.strong, self.emphasis.italic, self.has_link()) {
            (true, true, _) => (181, 137, 0),
            (true, false, _) => (203, 75, 22),
            (false, true, false) => (133, 153, 0),
            (false, true, true) => (38, 139, 210),
            (false, false, true) => (38, 139, 210),
            _ => (147, 161, 161),
        }
    }
}

impl ActiveElement {
    pub fn as_link(&self) -> Option<&LinkState> {
        match self {
            ActiveElement::Link(link) => Some(link),
            _ => None,
        }
    }

    pub fn as_link_mut(&mut self) -> Option<&mut LinkState> {
        match self {
            ActiveElement::Link(link) => Some(link),
            _ => None,
        }
    }

    pub fn as_image(&self) -> Option<&ImageState> {
        match self {
            ActiveElement::Image(image) => Some(image),
            _ => None,
        }
    }

    pub fn as_image_mut(&mut self) -> Option<&mut ImageState> {
        match self {
            ActiveElement::Image(image) => Some(image),
            _ => None,
        }
    }

    pub fn as_code_block(&self) -> Option<&CodeBlockState> {
        match self {
            ActiveElement::CodeBlock(code_block) => Some(code_block),
            _ => None,
        }
    }

    pub fn as_code_block_mut(&mut self) -> Option<&mut CodeBlockState> {
        match self {
            ActiveElement::CodeBlock(code_block) => Some(code_block),
            _ => None,
        }
    }

    pub fn as_table(&self) -> Option<&TableState> {
        match self {
            ActiveElement::Table(table) => Some(table),
            _ => None,
        }
    }

    pub fn as_table_mut(&mut self) -> Option<&mut TableState> {
        match self {
            ActiveElement::Table(table) => Some(table),
            _ => None,
        }
    }
}
