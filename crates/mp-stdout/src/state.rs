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

    pub active_element: Option<ActiveElement>,

    pub list_stack: Vec<ListType>,
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
