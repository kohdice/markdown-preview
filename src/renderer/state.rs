use pulldown_cmark::Alignment;

#[derive(Debug, Clone)]
pub enum StateChange {
    SetStrongEmphasis(bool),
    SetItalicEmphasis(bool),
    SetLink { url: String },
    SetImage { url: String },
    SetCodeBlock { language: Option<String> },
    SetTable { alignments: Vec<Alignment> },
    PushList(ListType),
    PopList,
    ClearTable,
}

impl StateChange {
    /// Apply this state change to the given render state
    pub fn apply_to(self, state: &mut RenderState) {
        match self {
            StateChange::SetStrongEmphasis(value) => state.emphasis.strong = value,
            StateChange::SetItalicEmphasis(value) => state.emphasis.italic = value,
            StateChange::SetLink { url } => {
                state.link = Some(LinkState {
                    text: String::new(),
                    url,
                });
            }
            StateChange::SetImage { url } => {
                state.image = Some(ImageState {
                    alt_text: String::new(),
                    url,
                });
            }
            StateChange::SetCodeBlock { language } => {
                state.code_block = Some(CodeBlockState {
                    language,
                    content: String::new(),
                });
            }
            StateChange::SetTable { alignments } => {
                let expected_cells = alignments.len();
                let current_row = Vec::with_capacity(expected_cells);

                state.table = Some(TableState {
                    alignments,
                    current_row,
                    is_header: true,
                });
            }
            StateChange::PushList(list_type) => {
                state.list_stack.push(list_type);
            }
            StateChange::PopList => {
                state.list_stack.pop();
            }
            StateChange::ClearTable => state.table = None,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct RenderState {
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
