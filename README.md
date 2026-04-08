# markdown-preview

Command to preview Markdown

## Requirements

- A UTF-8 capable terminal. Both the input Markdown and the rendered
  output may contain non-ASCII Unicode characters.
- A terminal with 24-bit color (true color) support is recommended for
  accurate color rendering. ANSI styling is automatically disabled when
  stdout is not a TTY.

## Usage

```
mp [--ambiguous-width=narrow|wide] [--] <FILE>
```

Use a bare `--` to separate flags from a file whose name starts with
`--` (for example, `mp -- --notes.md`).

### `--ambiguous-width=narrow|wide`

Controls how Unicode East Asian Width Ambiguous characters are sized
when computing continuation-line indentation and other width-dependent
layout. The flag follows Unicode 15.1 `EastAsianWidth.txt` category `A`
— this includes Greek letters, Cyrillic letters, box drawing, geometric
shapes, most miscellaneous symbols, and the Private Use Area. A small
additional group of Neutral glyphs the renderer emits (`◦ ▪ ☐ ☑`) is
also affected by the flag so that deeper nested bullets and task
checkboxes stay aligned on CJK-legacy terminal modes.

- `narrow` (default) — render Ambiguous characters as 1 column wide.
  Correct for modern terminals that follow Unicode 15+ grapheme cluster
  rules: Ghostty (default), Alacritty, WezTerm, iTerm2.
- `wide` — render Ambiguous characters as 2 columns wide. Use this on
  Vim built-in terminals configured with `set ambiwidth=double`, Apple
  Terminal.app with the East Asian wide setting enabled, or any
  terminal where unordered list bullets and task checkboxes visually
  exceed the width `markdown-preview` predicts by default.

### Known limitation

In `--ambiguous-width=wide` mode, table borders (`─ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼`)
will not align with cell contents. This is a structural limitation of
the current border-rendering strategy and is tracked separately. For
documents containing tables on a CJK wide terminal, prefer the default
`narrow` mode.
