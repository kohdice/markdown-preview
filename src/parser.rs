use pulldown_cmark::{Alignment, CodeBlockKind};

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
}

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

#[derive(Debug, Default, Clone)]
pub struct ParserState {
    pub buffer: String,
    pub in_code_block: bool,
    pub code_fence: Option<String>,
    pub in_table: bool,
}
