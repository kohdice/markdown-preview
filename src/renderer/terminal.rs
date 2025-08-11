use pulldown_cmark::{Alignment, CodeBlockKind};

use super::markdown::MarkdownRenderer;
use super::state::{ListType, StateChange};
use super::theme::{MarkdownTheme, styled_text, styled_text_with_bg};

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

/// State operation types
pub enum StateOperation<'a> {
    SetStrong(bool),
    SetEmphasis(bool),
    SetLink(String),
    SetImage(String),
    SetCodeBlock(CodeBlockKind<'a>),
    SetTable(Vec<Alignment>),
    PushList(Option<u64>),
    PopList,
    ClearTable,
}

/// Unified trait for terminal output
pub trait TerminalRenderer {
    /// Unified output method
    fn print_output(&mut self, output_type: OutputType) -> anyhow::Result<()>;

    /// Unified state change method
    fn apply_state(&mut self, operation: StateOperation<'_>);
}

impl TerminalRenderer for MarkdownRenderer {
    fn print_output(&mut self, output_type: OutputType) -> anyhow::Result<()> {
        match output_type {
            OutputType::Heading { level, is_end } => {
                if is_end {
                    println!("\n");
                } else {
                    let heading_marker = "#".repeat(level as usize);
                    let color = self.base.theme.heading_color(level);
                    let styled_marker =
                        styled_text(format!("{} ", heading_marker), color, true, false, false);
                    print!("{}", styled_marker);
                }
            }
            OutputType::Paragraph { is_end } => {
                if is_end {
                    println!();
                }
            }
            OutputType::HorizontalRule => {
                let line = "─".repeat(40);
                let styled_line = styled_text(
                    &line,
                    self.base.theme.delimiter_color(),
                    false,
                    false,
                    false,
                );
                println!("\n{}\n", styled_line);
            }
            OutputType::InlineCode { ref code } => {
                let styled_code = styled_text_with_bg(
                    code,
                    self.base.theme.code_color(),
                    self.base.theme.code_background(),
                );
                print!("{}", styled_code);
            }
            OutputType::TaskMarker { checked } => {
                let marker = if checked { "[x] " } else { "[ ] " };
                let styled_marker = styled_text(
                    marker,
                    self.base.theme.list_marker_color(),
                    false,
                    false,
                    false,
                );
                print!("{}", styled_marker);
            }
            OutputType::ListItem { is_end } => {
                if is_end {
                    println!();
                } else {
                    let depth = self.base.state.list_stack.len();
                    let indent = "  ".repeat(depth.saturating_sub(1));
                    print!("{}", indent);

                    if let Some(list_type) = self.base.state.list_stack.last_mut() {
                        let marker = match list_type {
                            ListType::Unordered => "• ".to_string(),
                            ListType::Ordered { current } => {
                                let m = format!("{}. ", current);
                                *current += 1;
                                m
                            }
                        };
                        let styled_marker = styled_text(
                            &marker,
                            self.base.theme.list_marker_color(),
                            false,
                            false,
                            false,
                        );
                        print!("{}", styled_marker);
                    }
                }
            }
            OutputType::BlockQuote { is_end } => {
                if is_end {
                    println!();
                } else {
                    let marker =
                        styled_text("> ", self.base.theme.delimiter_color(), false, false, false);
                    print!("{}", marker);
                }
            }
            OutputType::Link => {
                if let Some(link) = self.base.state.link.take() {
                    let styled_link =
                        styled_text(&link.text, self.base.theme.link_color(), false, false, true);
                    let url_text = styled_text(
                        format!(" ({})", link.url),
                        self.base.theme.delimiter_color(),
                        false,
                        false,
                        false,
                    );
                    print!("{}{}", styled_link, url_text);
                }
            }
            OutputType::Image => {
                if let Some(image) = self.base.state.image.take() {
                    let display_text = if image.alt_text.is_empty() {
                        "[Image]"
                    } else {
                        &image.alt_text
                    };
                    let styled_alt =
                        styled_text(display_text, self.base.theme.cyan(), false, true, false);
                    let url_text = styled_text(
                        format!(" ({})", image.url),
                        self.base.theme.delimiter_color(),
                        false,
                        false,
                        false,
                    );
                    print!("{}{}", styled_alt, url_text);
                }
            }
            OutputType::Table { ref variant } => match variant {
                TableVariant::HeadStart => {
                    if let Some(ref mut table) = self.base.state.table {
                        table.is_header = true;
                    }
                }
                TableVariant::HeadEnd => {
                    if let Some(ref table) = self.base.state.table {
                        // Use reference for better performance
                        self.base.render_table_row(&table.current_row, true)?;
                        self.base.render_table_separator(&table.alignments)?;
                    }

                    // Reset table state
                    if let Some(ref mut table) = self.base.state.table {
                        table.current_row.clear();
                        table.is_header = false;
                    }
                }
                TableVariant::RowEnd => {
                    if let Some(ref table) = self.base.state.table {
                        // Use direct reference (no clone needed)
                        self.base.render_table_row(&table.current_row, false)?;
                    }

                    if let Some(ref mut table) = self.base.state.table {
                        table.current_row.clear();
                    }
                }
            },
            OutputType::CodeBlock => {
                if let Some(code_block) = self.base.state.code_block.take() {
                    self.base.render_code_block(&code_block)?;
                }
            }
        }
        Ok(())
    }

    fn apply_state(&mut self, operation: StateOperation<'_>) {
        match operation {
            StateOperation::SetStrong(value) => {
                self.base
                    .apply_state_change(StateChange::SetStrongEmphasis(value));
            }
            StateOperation::SetEmphasis(value) => {
                self.base
                    .apply_state_change(StateChange::SetItalicEmphasis(value));
            }
            StateOperation::SetLink(url) => {
                self.base.apply_state_change(StateChange::SetLink { url });
            }
            StateOperation::SetImage(url) => {
                self.base.apply_state_change(StateChange::SetImage { url });
            }
            StateOperation::SetCodeBlock(kind) => {
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
                self.base
                    .apply_state_change(StateChange::SetCodeBlock { language });
            }
            StateOperation::SetTable(alignments) => {
                self.base
                    .apply_state_change(StateChange::SetTable { alignments });
            }
            StateOperation::PushList(start) => {
                let list_type = if let Some(n) = start {
                    ListType::Ordered {
                        current: n as usize,
                    }
                } else {
                    ListType::Unordered
                };
                self.base
                    .apply_state_change(StateChange::PushList(list_type));
            }
            StateOperation::PopList => {
                self.base.apply_state_change(StateChange::PopList);
                if self.base.state.list_stack.is_empty() {
                    println!();
                }
            }
            StateOperation::ClearTable => {
                self.base.apply_state_change(StateChange::ClearTable);
                println!();
            }
        }
    }
}
