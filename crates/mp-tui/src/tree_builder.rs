use anyhow::Result;
use mp_core::{FileTreeNode, FinderConfig};

pub trait TreeBuilder: Send + Sync {
    fn build_tree(&self, config: FinderConfig) -> Result<FileTreeNode>;
}

pub struct DefaultTreeBuilder;

impl TreeBuilder for DefaultTreeBuilder {
    fn build_tree(&self, config: FinderConfig) -> Result<FileTreeNode> {
        mp_core::build_markdown_tree(".", config)
    }
}
