use pulldown_cmark::Alignment;

/// Text content types
pub enum ContentType<'a> {
    Text(&'a str),
    Code(&'a str),
    Html(&'a str),
    SoftBreak,
    HardBreak,
    Rule,
    TaskMarker(bool),
}

/// Emphasis state management
#[derive(Debug, Default, Clone)]
pub struct EmphasisState {
    pub strong: bool,
    pub italic: bool,
}

/// Link state
#[derive(Debug, Clone, Default)]
pub struct LinkState {
    pub text: String,
    pub url: String,
}

/// Image state
#[derive(Debug, Clone, Default)]
pub struct ImageState {
    pub alt_text: String,
    pub url: String,
}

/// Code block state
#[derive(Debug, Clone)]
pub struct CodeBlockState {
    pub language: Option<String>,
    pub content: String,
}

/// Table state
#[derive(Debug, Clone)]
pub struct TableState {
    pub alignments: Vec<Alignment>,
    pub current_row: Vec<String>,
    pub is_header: bool,
}

/// List type
#[derive(Debug, Clone)]
pub enum ListType {
    Ordered { current: usize },
    Unordered,
}

/// Active element type
#[derive(Debug, Clone)]
pub enum ActiveElement {
    Link(LinkState),
    Image(ImageState),
    CodeBlock(CodeBlockState),
    Table(TableState),
}

/// Simple and clear state management structure
#[derive(Debug, Default, Clone)]
pub struct RenderState {
    /// Text decoration state
    pub emphasis: EmphasisState,

    /// Active element (only one can be active at a time)
    pub active_element: Option<ActiveElement>,

    /// List management
    pub list_stack: Vec<ListType>,

    /// Current line being processed
    pub current_line: String,
}

impl RenderState {
    /// Create a new render state
    pub fn new() -> Self {
        Self::default()
    }

    /// Add text to the appropriate state container
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

    /// Check if currently inside a link
    pub fn has_link(&self) -> bool {
        matches!(self.active_element, Some(ActiveElement::Link(_)))
    }

    /// Get text color based on current emphasis state
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

// Legacy RenderContext for gradual migration
#[derive(Debug, Default, Clone)]
pub struct RenderContext {
    pub link: Option<LinkState>,
    pub image: Option<ImageState>,
    pub emphasis: EmphasisState,
    pub list_stack: Vec<ListType>,
    pub code_block: Option<CodeBlockState>,
    pub table: Option<TableState>,
    pub current_line: String,
}

impl RenderContext {
    /// Add text to the appropriate state container
    pub fn add_text(&mut self, text: &str) -> bool {
        if let Some(ref mut link) = self.link {
            link.text.push_str(text);
            true
        } else if let Some(ref mut image) = self.image {
            image.alt_text.push_str(text);
            true
        } else {
            false
        }
    }

    /// Check if currently inside a link
    pub fn has_link(&self) -> bool {
        self.link.is_some()
    }

    /// Get text color based on current emphasis state
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

    /// Convert RenderContext to new RenderState
    pub fn to_render_state(&self) -> RenderState {
        let mut state = RenderState::new();

        state.emphasis = self.emphasis.clone();
        state.list_stack = self.list_stack.clone();
        state.current_line = self.current_line.clone();

        if let Some(ref link) = self.link {
            state.active_element = Some(ActiveElement::Link(link.clone()));
        } else if let Some(ref image) = self.image {
            state.active_element = Some(ActiveElement::Image(image.clone()));
        } else if let Some(ref code_block) = self.code_block {
            state.active_element = Some(ActiveElement::CodeBlock(code_block.clone()));
        } else if let Some(ref table) = self.table {
            state.active_element = Some(ActiveElement::Table(table.clone()));
        }

        state
    }

    /// Create RenderContext from new RenderState
    pub fn from_render_state(state: &RenderState) -> Self {
        let (link, image, code_block, table) = match &state.active_element {
            Some(ActiveElement::Link(l)) => (Some(l.clone()), None, None, None),
            Some(ActiveElement::Image(i)) => (None, Some(i.clone()), None, None),
            Some(ActiveElement::CodeBlock(c)) => (None, None, Some(c.clone()), None),
            Some(ActiveElement::Table(t)) => (None, None, None, Some(t.clone())),
            None => (None, None, None, None),
        };

        RenderContext {
            emphasis: state.emphasis.clone(),
            list_stack: state.list_stack.clone(),
            current_line: state.current_line.clone(),
            link,
            image,
            code_block,
            table,
        }
    }
}
