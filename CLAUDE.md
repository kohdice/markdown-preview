# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A CLI tool for previewing Markdown files in the terminal. Executed as the `mp` command.

## Development Commands

### Build
```bash
cargo build              # Debug build
cargo build --release    # Release build
```

### Test
```bash
cargo test              # Run all tests
cargo test <TEST_NAME>  # Run specific test
```

### Quality Checks
```bash
cargo fmt               # Format code
cargo clippy            # Lint check
cargo clippy -- -D warnings  # Treat warnings as errors
```

## Architecture

### Module Structure

- **cli.rs**: CLI parser and entry point (`Args` struct, `run` function)
- **renderer/**: Core rendering implementation
  - `markdown.rs`: MarkdownRenderer implementation
  - `base.rs`: BaseRenderer base implementation
  - `terminal.rs`: Terminal output interface
  - `theme.rs`: Theme configuration (SolarizedOsaka)
  - `state.rs`: Parser and rendering state management
  - `handlers.rs`: Event handler interface
  - `traits.rs`: MarkdownProcessor, TableRenderer traits
- **html_entity.rs**: HTML entity decoding

### Key Dependencies

- `pulldown-cmark`: Markdown parsing
- `colored`: Terminal color output
- `clap`: CLI parsing
- `anyhow`: Error handling

## Running

```bash
cargo run -- <FILE>     # Run during development
mp <FILE>              # Run after installation
```