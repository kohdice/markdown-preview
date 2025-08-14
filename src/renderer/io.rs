//! File I/O operations for the renderer
//!
//! This module handles file reading and metadata operations
//! for the Markdown renderer.

use anyhow::{Context, Result};
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;

/// Reads a file from the given path and returns its content
///
/// # Arguments
/// * `path` - The path to the file to read
///
/// # Returns
/// * `Result<String>` - The file content as a string
///
/// # Errors
/// Returns an error if:
/// * The file doesn't exist
/// * The file cannot be read
/// * The content is not valid UTF-8
pub fn read_file(path: &Path) -> Result<String> {
    // Check if file exists
    if !path.exists() {
        return Err(anyhow::anyhow!("File not found: {}", path.display()));
    }

    // Get file metadata for size information
    let metadata = fs::metadata(path)
        .with_context(|| format!("Failed to get metadata for: {}", path.display()))?;
    let file_size = metadata.len();

    // Open file and read content
    let mut file =
        File::open(path).with_context(|| format!("Failed to open file: {}", path.display()))?;

    let mut content = String::with_capacity(file_size as usize);
    file.read_to_string(&mut content)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    Ok(content)
}
