use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;

use markdown_preview::MarkdownRenderer;

#[derive(Debug, Parser)]
#[command(name = "mp", version, about = "Markdown previewer in terminal")]
pub struct Args {
    #[arg(name = "FILE", required = true, help = "Markdown file to preview")]
    pub file: PathBuf,
}

pub fn run() -> Result<()> {
    let args = Args::parse();

    if !args.file.exists() {
        anyhow::bail!("File not found: '{}'", args.file.display());
    }

    if !args.file.is_file() {
        anyhow::bail!("Path is not a file: '{}'", args.file.display());
    }

    let mut renderer = MarkdownRenderer::new();
    renderer
        .render_file(&args.file)
        .with_context(|| format!("Failed to render markdown file: {}", args.file.display()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_args_parsing() {
        let result = Args::try_parse_from(vec!["mp", "test.md"]);
        assert!(result.is_ok());
    }
}
