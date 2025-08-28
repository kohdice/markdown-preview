# markdown-preview

[![Rust](https://img.shields.io/badge/Rust-1.89%2B-orange.svg)](https://www.rust-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Crates.io](https://img.shields.io/crates/v/mp.svg)](https://crates.io/crates/mp)

A beautiful and feature-rich CLI tool for previewing Markdown files directly in your terminal with syntax highlighting and interactive file browsing.

![Demo](https://via.placeholder.com/800x400?text=markdown-preview+demo)

## ✨ Features

- 🎨 **Beautiful Rendering**: Syntax-highlighted Markdown with Solarized Osaka theme
- 📁 **Two Modes**: 
  - **Stdout Mode**: Quick preview of a single file
  - **TUI Mode**: Interactive file browser with live preview
- 🚀 **Fast & Efficient**: Built with Rust for optimal performance
- 📊 **Full Markdown Support**: 
  - Tables with alignment
  - Code blocks with syntax highlighting
  - Nested lists (ordered, unordered, task lists)
  - Blockquotes
  - Links and images (as alt text)
  - HTML entities
- 🎯 **Smart File Finding**: Respects .gitignore and hidden files
- ⌨️ **Keyboard Navigation**: Intuitive shortcuts for efficient browsing

## 📦 Installation

### From crates.io

```bash
cargo install mp
```

### From Source

```bash
# Clone the repository
git clone https://github.com/kohdice/markdown-preview.git
cd markdown-preview

# Build and install
cargo install --path crates/mp
```

### Prerequisites

- Rust 1.89 or higher (2024 Edition)
- Cargo package manager

## 🚀 Usage

### Basic Usage (Stdout Mode)

Preview a single Markdown file in your terminal:

```bash
# Preview a specific file
mp README.md

# Preview any Markdown file
mp path/to/your/file.md
```

### Interactive TUI Mode

Launch the interactive file browser:

```bash
# Start TUI mode (no arguments)
mp

# TUI mode with options
mp --hidden              # Show hidden files
mp --no-ignore          # Don't respect .gitignore
mp --no-ignore-parent   # Don't respect parent .gitignore files
```

### Keyboard Shortcuts (TUI Mode)

| Key | Action |
|-----|--------|
| `↑/k` | Navigate up in file tree |
| `↓/j` | Navigate down in file tree |
| `Enter` | Select/preview file |
| `Space` | Expand/collapse directory |
| `Tab` | Switch focus between tree and preview |
| `h/←` | Scroll preview left |
| `l/→` | Scroll preview right |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `q/Esc` | Quit application |

## 📋 Supported Markdown Elements

- **Headings** (H1-H6)
- **Emphasis** (bold, italic, strikethrough)
- **Lists** (ordered, unordered, nested, task lists)
- **Code** (inline and fenced blocks with language detection)
- **Tables** (with alignment support)
- **Blockquotes** (including nested)
- **Links** (displayed with URL)
- **Images** (displayed as alt text)
- **Horizontal rules**
- **HTML entities** (&copy;, &reg;, etc.)
- **Escape sequences**

## 🎨 Theme

The application uses a color scheme inspired by **Solarized Osaka**, providing:
- High contrast for optimal readability
- Consistent and harmonious color palette
- Syntax highlighting for code blocks
- Distinct styling for different Markdown elements

The color values are based on the Solarized Osaka theme by @craftzdog, which itself is inspired by the original Solarized color scheme by Ethan Schoonover.

## 🙏 Acknowledgments

- [pulldown-cmark](https://github.com/raphlinus/pulldown-cmark) - Markdown parsing
- [ratatui](https://github.com/ratatui-org/ratatui) - Terminal UI framework
- [crossterm](https://github.com/crossterm-rs/crossterm) - Cross-platform terminal manipulation
- [clap](https://github.com/clap-rs/clap) - Command-line argument parsing
- [Solarized Osaka](https://github.com/craftzdog/solarized-osaka.nvim) by @craftzdog - Color scheme inspiration
- [Solarized](https://ethanschoonover.com/solarized/) by Ethan Schoonover - Original color palette