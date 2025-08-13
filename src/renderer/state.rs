use pulldown_cmark::{Alignment, CodeBlockKind};
use std::collections::HashMap;

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

/// Represents different element types during rendering
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ElementType {
    Link,
    Image,
    StrongEmphasis,
    ItalicEmphasis,
    CodeBlock,
    Table,
    List,
}

/// Represents a single state frame in the rendering stack
#[derive(Debug, Clone)]
pub struct StateFrame {
    pub element_type: ElementType,
    pub attributes: HashMap<String, String>,
}

impl StateFrame {
    /// Create a new state frame
    pub fn new(element_type: ElementType) -> Self {
        Self {
            element_type,
            attributes: HashMap::new(),
        }
    }

    /// Create a new state frame with attributes
    pub fn with_attributes(element_type: ElementType, attributes: HashMap<String, String>) -> Self {
        Self {
            element_type,
            attributes,
        }
    }
}

/// Simplified render state using stack-based management
#[derive(Debug, Clone)]
pub struct RenderState {
    pub stack: Vec<StateFrame>,
    pub list_stack: Vec<ListType>,
    pub current_line: String,
}

impl RenderState {
    /// Create a new render state
    pub fn new() -> Self {
        Self {
            stack: Vec::new(),
            list_stack: Vec::new(),
            current_line: String::new(),
        }
    }

    /// Push a new state frame onto the stack
    pub fn push(&mut self, frame: StateFrame) {
        self.stack.push(frame);
    }

    /// Pop a state frame from the stack
    pub fn pop(&mut self) -> Option<StateFrame> {
        self.stack.pop()
    }

    /// Check if a specific element type is active
    pub fn has_element(&self, element_type: &ElementType) -> bool {
        self.stack
            .iter()
            .any(|frame| frame.element_type == *element_type)
    }

    /// Get the topmost frame of a specific type
    pub fn get_frame(&self, element_type: &ElementType) -> Option<&StateFrame> {
        self.stack
            .iter()
            .rev()
            .find(|frame| frame.element_type == *element_type)
    }

    /// Get the topmost frame of a specific type (mutable)
    pub fn get_frame_mut(&mut self, element_type: &ElementType) -> Option<&mut StateFrame> {
        self.stack
            .iter_mut()
            .rev()
            .find(|frame| frame.element_type == *element_type)
    }

    /// Add text to the appropriate state container
    pub fn add_text(&mut self, text: &str) -> bool {
        if let Some(link_text) = self
            .get_frame_mut(&ElementType::Link)
            .and_then(|frame| frame.attributes.get_mut("text"))
        {
            link_text.push_str(text);
            return true;
        }
        if let Some(alt_text) = self
            .get_frame_mut(&ElementType::Image)
            .and_then(|frame| frame.attributes.get_mut("alt_text"))
        {
            alt_text.push_str(text);
            return true;
        }
        false
    }

    /// Check if currently inside a link
    pub fn has_link(&self) -> bool {
        self.has_element(&ElementType::Link)
    }

    /// Get text color based on current emphasis state
    pub fn get_text_color(&self) -> (u8, u8, u8) {
        let has_strong = self.has_element(&ElementType::StrongEmphasis);
        let has_italic = self.has_element(&ElementType::ItalicEmphasis);
        let has_link = self.has_link();

        match (has_strong, has_italic, has_link) {
            (true, true, _) => (181, 137, 0),       // Yellow for bold italic
            (true, false, _) => (203, 75, 22),      // Orange for bold
            (false, true, false) => (133, 153, 0),  // Bright green for italic
            (false, true, true) => (38, 139, 210),  // Blue for italic links
            (false, false, true) => (38, 139, 210), // Blue for links
            _ => (147, 161, 161),                   // Default base1
        }
    }

    /// Create an immutable copy with a modification
    pub fn with_change<F>(self, modifier: F) -> Self
    where
        F: FnOnce(&mut Self),
    {
        let mut new_state = self;
        modifier(&mut new_state);
        new_state
    }
}

impl Default for RenderState {
    fn default() -> Self {
        Self::new()
    }
}

/// Represents different state changes during rendering
#[derive(Debug, Clone)]
pub enum StateChange {
    SetStrongEmphasis(bool),
    SetItalicEmphasis(bool),
    SetLink(String),
    SetImage(String),
    SetCodeBlock(CodeBlockKind<'static>),
    SetTable(Vec<Alignment>),
    PushList(Option<u64>),
    PopList,
    ClearTable,
}

impl StateChange {
    /// Apply this state change to the given render context
    pub fn apply_to(self, context: &mut RenderContext) {
        match self {
            StateChange::SetStrongEmphasis(value) => context.emphasis.strong = value,
            StateChange::SetItalicEmphasis(value) => context.emphasis.italic = value,
            StateChange::SetLink(url) => {
                context.link = Some(LinkState {
                    text: String::new(),
                    url,
                });
            }
            StateChange::SetImage(url) => {
                context.image = Some(ImageState {
                    alt_text: String::new(),
                    url,
                });
            }
            StateChange::SetCodeBlock(kind) => {
                let language = match kind {
                    CodeBlockKind::Indented => None,
                    CodeBlockKind::Fenced(lang) => {
                        if lang.is_empty() {
                            None
                        } else {
                            Some(lang.to_string())
                        }
                    }
                };
                context.code_block = Some(CodeBlockState {
                    language,
                    content: String::new(),
                });
            }
            StateChange::SetTable(alignments) => {
                let expected_cells = alignments.len();
                let current_row = Vec::with_capacity(expected_cells);

                context.table = Some(TableState {
                    alignments,
                    current_row,
                    is_header: true,
                });
            }
            StateChange::PushList(start) => {
                let list_type = if let Some(n) = start {
                    ListType::Ordered {
                        current: n as usize,
                    }
                } else {
                    ListType::Unordered
                };
                context.list_stack.push(list_type);
            }
            StateChange::PopList => {
                context.list_stack.pop();
            }
            StateChange::ClearTable => context.table = None,
        }
    }

    /// Apply this state change to the new RenderState
    pub fn apply_to_state(self, state: &mut RenderState) {
        match self {
            StateChange::SetStrongEmphasis(value) => {
                if value {
                    state.push(StateFrame::new(ElementType::StrongEmphasis));
                } else {
                    state
                        .stack
                        .retain(|f| f.element_type != ElementType::StrongEmphasis);
                }
            }
            StateChange::SetItalicEmphasis(value) => {
                if value {
                    state.push(StateFrame::new(ElementType::ItalicEmphasis));
                } else {
                    state
                        .stack
                        .retain(|f| f.element_type != ElementType::ItalicEmphasis);
                }
            }
            StateChange::SetLink(url) => {
                let mut attrs = HashMap::new();
                attrs.insert("url".to_string(), url);
                attrs.insert("text".to_string(), String::new());
                state.push(StateFrame::with_attributes(ElementType::Link, attrs));
            }
            StateChange::SetImage(url) => {
                let mut attrs = HashMap::new();
                attrs.insert("url".to_string(), url);
                attrs.insert("alt_text".to_string(), String::new());
                state.push(StateFrame::with_attributes(ElementType::Image, attrs));
            }
            StateChange::SetCodeBlock(kind) => {
                let mut attrs = HashMap::new();
                match kind {
                    CodeBlockKind::Indented => {}
                    CodeBlockKind::Fenced(lang) => {
                        if !lang.is_empty() {
                            attrs.insert("language".to_string(), lang.to_string());
                        }
                    }
                }
                attrs.insert("content".to_string(), String::new());
                state.push(StateFrame::with_attributes(ElementType::CodeBlock, attrs));
            }
            StateChange::SetTable(alignments) => {
                let mut attrs = HashMap::new();
                attrs.insert("alignments".to_string(), format!("{:?}", alignments));
                attrs.insert("is_header".to_string(), "true".to_string());
                state.push(StateFrame::with_attributes(ElementType::Table, attrs));
            }
            StateChange::PushList(start) => {
                let list_type = if let Some(n) = start {
                    ListType::Ordered {
                        current: n as usize,
                    }
                } else {
                    ListType::Unordered
                };
                state.list_stack.push(list_type);
            }
            StateChange::PopList => {
                state.list_stack.pop();
            }
            StateChange::ClearTable => {
                state.stack.retain(|f| f.element_type != ElementType::Table);
            }
        }
    }
}

/// Represents the context for rendering Markdown content
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

#[derive(Debug, Default, Clone)]
pub struct EmphasisState {
    pub strong: bool,
    pub italic: bool,
}

#[derive(Debug, Clone)]
pub enum ListType {
    Ordered { current: usize },
    Unordered,
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
            (true, true, _) => (181, 137, 0),       // Yellow for bold italic
            (true, false, _) => (203, 75, 22),      // Orange for bold
            (false, true, false) => (133, 153, 0),  // Bright green for italic
            (false, true, true) => (38, 139, 210),  // Blue for italic links
            (false, false, true) => (38, 139, 210), // Blue for links
            _ => (147, 161, 161),                   // Default base1
        }
    }

    /// Convert from RenderState for backward compatibility
    pub fn from_state(state: &RenderState) -> Self {
        let mut context = RenderContext::default();

        // Restore emphasis states
        if state.has_element(&ElementType::StrongEmphasis) {
            context.emphasis.strong = true;
        }
        if state.has_element(&ElementType::ItalicEmphasis) {
            context.emphasis.italic = true;
        }

        // Restore link state
        if let Some(link_frame) = state.get_frame(&ElementType::Link).and_then(|frame| {
            match (frame.attributes.get("url"), frame.attributes.get("text")) {
                (Some(url), Some(text)) => Some(LinkState {
                    url: url.clone(),
                    text: text.clone(),
                }),
                _ => None,
            }
        }) {
            context.link = Some(link_frame);
        }

        // Restore image state
        if let Some(image_frame) = state.get_frame(&ElementType::Image).and_then(|frame| {
            match (
                frame.attributes.get("url"),
                frame.attributes.get("alt_text"),
            ) {
                (Some(url), Some(alt_text)) => Some(ImageState {
                    url: url.clone(),
                    alt_text: alt_text.clone(),
                }),
                _ => None,
            }
        }) {
            context.image = Some(image_frame);
        }

        // Restore code block state
        if let Some(code_frame) = state.get_frame(&ElementType::CodeBlock) {
            let language = code_frame.attributes.get("language").cloned();
            let content = code_frame
                .attributes
                .get("content")
                .cloned()
                .unwrap_or_default();
            context.code_block = Some(CodeBlockState { language, content });
        }

        // Restore table state
        if let Some(table_frame) = state.get_frame(&ElementType::Table) {
            // For now, create a simple default table state
            // In production, you'd parse the alignments from the stored string
            context.table = Some(TableState {
                alignments: Vec::new(),
                current_row: Vec::new(),
                is_header: table_frame
                    .attributes
                    .get("is_header")
                    .map(|s| s == "true")
                    .unwrap_or(false),
            });
        }

        // Copy list stack and current line
        context.list_stack = state.list_stack.clone();
        context.current_line = state.current_line.clone();

        context
    }

    /// Convert to RenderState for new implementation
    pub fn to_state(&self) -> RenderState {
        let mut state = RenderState::new();

        // Convert emphasis states
        if self.emphasis.strong {
            state.push(StateFrame::new(ElementType::StrongEmphasis));
        }
        if self.emphasis.italic {
            state.push(StateFrame::new(ElementType::ItalicEmphasis));
        }

        // Convert link state
        if let Some(ref link) = self.link {
            let mut attrs = HashMap::new();
            attrs.insert("url".to_string(), link.url.clone());
            attrs.insert("text".to_string(), link.text.clone());
            state.push(StateFrame::with_attributes(ElementType::Link, attrs));
        }

        // Convert image state
        if let Some(ref image) = self.image {
            let mut attrs = HashMap::new();
            attrs.insert("url".to_string(), image.url.clone());
            attrs.insert("alt_text".to_string(), image.alt_text.clone());
            state.push(StateFrame::with_attributes(ElementType::Image, attrs));
        }

        // Convert code block state
        if let Some(ref code_block) = self.code_block {
            let mut attrs = HashMap::new();
            if let Some(ref lang) = code_block.language {
                attrs.insert("language".to_string(), lang.clone());
            }
            attrs.insert("content".to_string(), code_block.content.clone());
            state.push(StateFrame::with_attributes(ElementType::CodeBlock, attrs));
        }

        // Convert table state
        if let Some(ref table) = self.table {
            let mut attrs = HashMap::new();
            attrs.insert("alignments".to_string(), format!("{:?}", table.alignments));
            attrs.insert("is_header".to_string(), table.is_header.to_string());
            state.push(StateFrame::with_attributes(ElementType::Table, attrs));
        }

        // Copy list stack and current line
        state.list_stack = self.list_stack.clone();
        state.current_line = self.current_line.clone();

        state
    }
}
