//! File I/O operations for the renderer
//!
//! This module handles file reading and metadata operations
//! for the Markdown renderer.

use anyhow::{Context, Result};
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;

use crate::utils::normalize_line_endings;

/// Reads a file from the given path and returns its content with normalized line endings
///
/// # Arguments
/// * `path` - The path to the file to read
///
/// # Returns
/// * `Result<String>` - The file content as a string with Unix-style line endings
///
/// # Errors
/// Returns an error if:
/// * The file doesn't exist
/// * The file cannot be read
/// * The content is not valid UTF-8
pub fn read_file(path: &Path) -> Result<String> {
    if !path.exists() {
        return Err(anyhow::anyhow!("File not found: {}", path.display()));
    }

    let metadata = fs::metadata(path)
        .with_context(|| format!("Failed to get metadata for: {}", path.display()))?;
    let file_size = metadata.len();

    let mut file =
        File::open(path).with_context(|| format!("Failed to open file: {}", path.display()))?;

    let mut content = String::with_capacity(file_size as usize);
    file.read_to_string(&mut content)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    Ok(normalize_line_endings(&content).into_owned())
}
