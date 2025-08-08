# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

markdown-preview is a Rust CLI tool for previewing Markdown files in the terminal. The binary is provided as `mp`.

## Development Commands

### Build
```bash
# Debug build
cargo build

# Release build (optimized)
cargo build --release
```

### Test
```bash
# Run all tests
cargo test --verbose

# Run a single test
cargo test <test_name>

# Run tests with output displayed
cargo test -- --nocapture
```

### Linting & Formatting
```bash
# Format code
cargo fmt

# Check formatting (used in CI)
cargo fmt --all --check

# Lint with Clippy
cargo clippy --all-targets --all-features
```

### Run
```bash
# Run development version
cargo run -- <markdown_file>

# Run with release optimization
cargo run --release -- <markdown_file>

# Or run binary directly
./target/debug/mp <markdown_file>
./target/release/mp <markdown_file>  # Release binary
```

## Architecture

### Module Design
- `src/main.rs`: Entry point. Handles error handling and exit codes
- `src/cli.rs`: CLI parser and command execution logic. Uses clap v4

### Error Handling
- Error management using anyhow crate
- Unified error output and exit code handling in main function

### Dependencies
Core dependencies used in this project:
- `clap` v4: Command-line argument parsing with derive macros
- `anyhow`: Simplified error handling and propagation

## Commit Convention

Use commit types defined in CONTRIBUTING.md:
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring
- `test`: Adding or modifying tests
- `style`: Code style changes
- `chore`: Build process or tool changes
- `docs`: Documentation changes

## CI/CD Configuration

GitHub Actions automatically runs:
- Build verification (`cargo build --release`)
- Test execution (`cargo test`)
- Clippy lint (`cargo clippy`)
- Format verification (`cargo fmt --check`)

All CI jobs run with `RUSTFLAGS: -Dwarnings`, treating warnings as errors.

## Text Linting Configuration

`.textlintrc.json` configures Japanese technical documentation linting:
- preset-ja-technical-writing
- textlint-rule-preset-ai-writing