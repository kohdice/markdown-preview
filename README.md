# markdown-preview

Command to preview Markdown

## Usage

```console
mp [options] [--] <FILE>
```

| Option              | Description                                         |
| ------------------- | --------------------------------------------------- |
| `--width <COLUMNS>` | Override wrapping width for one-shot file rendering |
| `--watch`           | Live-reload on file changes                         |
| `--version`         | Show version number and quit                        |
| `-h, --help`        | Show help and quit                                  |
| `--`                | Treat the next argument as the file                 |

### Watch mode

`--watch` enters a live-reload mode that re-renders whenever the file
changes. The output is displayed in an interactive pager with scrolling
support. Requires an interactive terminal (stdin and stdout must be a TTY).

| Key        | Action       |
| ---------- | ------------ |
| `j` / `↓`  | Scroll down  |
| `k` / `↑`  | Scroll up    |
| `PageDown` | Page down    |
| `PageUp`   | Page up      |
| `g`        | Go to top    |
| `G`        | Go to bottom |
| `q`        | Quit         |

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

## Mermaid diagrams

Fenced code blocks tagged `mermaid` are rendered as ASCII art.
Supported diagram headers:

| Diagram   | Headers                           |
| --------- | --------------------------------- |
| Flowchart | `flowchart`, `graph`              |
| Sequence  | `sequenceDiagram`                 |
| Class     | `classDiagram`, `classDiagram-v2` |
| State     | `stateDiagram`, `stateDiagram-v2` |
| ER        | `erDiagram`                       |
| Git graph | `gitGraph`                        |
| XY chart  | `xychart`                         |

When the terminal supports color, `gitGraph` and `xychart` are rendered
with lane/series colors.

Unrecognized headers, unsupported features, or parse errors fall back to a
short placeholder line (`[mermaid: ...]`) in place of the diagram.

## License

MIT
