# markdown-preview

Command to preview Markdown

## Usage

```console
mp [--] <FILE>
```

Use a bare `--` to separate a file whose name starts with `--` from the
argument list (for example, `mp -- --notes.md`).

## Syntax highlighting

Fenced code blocks are highlighted with
[tree-sitter](https://tree-sitter.github.io) when the fence carries a
language tag. Supported tags (case-insensitive):

| Language   | Tags                                           |
| ---------- | ---------------------------------------------- |
| Zig        | `zig`                                          |
| C          | `c`                                            |
| C++        | `cpp`, `c++`, `cxx`, `cc`, `hpp`, `hxx`, `h++` |
| Rust       | `rust`, `rs`                                   |
| Go         | `go`                                           |
| Python     | `python`, `py`                                 |
| JavaScript | `javascript`, `js`, `jsx`                      |
| TypeScript | `typescript`, `ts`, `mts`, `cts`               |
| TSX        | `tsx`                                          |
| Bash       | `bash`, `sh`, `shell`                          |
| HTML       | `html`, `htm`                                  |
| CSS        | `css`                                          |
| JSON       | `json`                                         |

Unrecognized language tags fall back to a single-color inline code style.
Highlighting is disabled automatically when the output is not a TTY or
when `NO_COLOR` is set.
