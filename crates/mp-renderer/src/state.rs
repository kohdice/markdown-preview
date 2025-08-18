use pulldown_cmark::Alignment;

/// Different types of Markdown content
pub enum ContentType<'a> {
    Text(&'a str),
    Code(&'a str),
    Html(&'a str),
    SoftBreak,
    HardBreak,
    Rule,
    TaskMarker(bool),
}

/// Text emphasis states
#[derive(Debug, Default, Clone)]
pub struct EmphasisState {
    pub strong: bool,
    pub italic: bool,
}

/// Link element data
#[derive(Debug, Clone, Default)]
pub struct LinkState {
    pub text: String,
    pub url: String,
}

/// Image element data
#[derive(Debug, Clone, Default)]
pub struct ImageState {
    pub alt_text: String,
    pub url: String,
}

/// Code block content and language
#[derive(Debug, Clone)]
pub struct CodeBlockState {
    pub language: Option<String>,
    pub content: String,
}

/// Table parsing state
#[derive(Debug, Clone)]
pub struct TableState {
    pub alignments: Vec<Alignment>,
    pub current_row: Vec<String>,
    pub is_header: bool,
}

/// List type enumeration
#[derive(Debug, Clone)]
pub enum ListType {
    Ordered { current: usize },
    Unordered,
}

/// Currently active complex element
#[derive(Debug, Clone)]
pub enum ActiveElement {
    Link(LinkState),
    Image(ImageState),
    CodeBlock(CodeBlockState),
    Table(TableState),
}

/// Central rendering state
#[derive(Debug, Default, Clone)]
pub struct RenderState {
    /// Current text emphasis (bold/italic) that applies to all text rendering
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

    /// Routes text to the active element's text buffer.
    /// Returns true if text was consumed by an active element, false otherwise.
    pub fn add_text(&mut self, text: &str) -> bool {
        match &mut self.active_element {
            Some(ActiveElement::Link(link)) => {
                link.text.push_str(text);
                true
            }
            Some(ActiveElement::Image(image)) => {
                image.alt_text.push_str(text);
                true
            }
            _ => false,
        }
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
