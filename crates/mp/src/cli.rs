use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;

use mp_stdout::MarkdownRenderer;

#[derive(Debug, Parser)]
#[command(name = "mp", version, about = "Markdown previewer in terminal")]
pub struct Args {
    /// Markdown file to preview (optional, opens TUI mode if not provided)
    #[arg(name = "FILE")]
    pub file: Option<PathBuf>,

    /// Show hidden files (files starting with '.')
    #[arg(long = "hidden")]
    pub hidden: bool,

    /// Do not respect .gitignore files
    #[arg(long = "no-ignore")]
    pub no_ignore: bool,

    /// Do not respect .gitignore files in parent directories
    #[arg(long = "no-ignore-parent")]
    pub no_ignore_parent: bool,

    /// Do not respect the global gitignore file
    #[arg(long = "no-global-ignore-file")]
    pub no_global_ignore_file: bool,
}

pub fn run() -> Result<()> {
    let args = Args::parse();

    match args.file {
        Some(path) => {
            if !path.exists() {
                anyhow::bail!("File not found: '{}'", path.display());
            }

            if !path.is_file() {
                anyhow::bail!("Path is not a file: '{}'", path.display());
            }

            let mut renderer = MarkdownRenderer::new();
            renderer
                .render_file(&path)
                .with_context(|| format!("Failed to render markdown file: {}", path.display()))?;
        }
        None => {
            let finder_config = mp_core::FinderConfig {
                hidden: args.hidden,
                no_ignore: args.no_ignore,
                no_ignore_parent: args.no_ignore_parent,
                no_global_ignore_file: args.no_global_ignore_file,
            };

            mp_tui::run_tui(finder_config)
                .map_err(|e| anyhow::anyhow!("Failed to run TUI mode: {}", e))?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_args_parsing_with_file() {
        let result = Args::try_parse_from(vec!["mp", "test.md"]);
        assert!(result.is_ok());
        let args = result.unwrap();
        assert_eq!(args.file, Some(PathBuf::from("test.md")));
    }

    #[test]
    fn test_args_parsing_without_file_now_succeeds() {
        let result = Args::try_parse_from(vec!["mp"]);
        assert!(result.is_ok());
        let args = result.unwrap();
        assert!(args.file.is_none());
        assert!(!args.hidden);
        assert!(!args.no_ignore);
    }

    #[test]
    fn test_args_parsing_with_flags() {
        let result = Args::try_parse_from(vec!["mp", "--hidden", "--no-ignore"]);
        assert!(result.is_ok());
        let args = result.unwrap();
        assert!(args.file.is_none());
        assert!(args.hidden);
        assert!(args.no_ignore);
    }
}
