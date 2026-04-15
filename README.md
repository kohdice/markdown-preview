# markdown-preview

Command to preview Markdown

## Usage

```console
mp [--watch] [--] <FILE>
```

Use a bare `--` to separate a file whose name starts with `--` from the
argument list (for example, `mp -- --notes.md`).

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

The following diagram types are rendered as ASCII art.

### `flowchart` / `graph`

- Directions: `TD`, `TB`, `BT`, `LR`, `RL`
- Node shapes: `[rect]`, `(round)`, `([stadium])`, `((circle))`, `{diamond}`,
  `[[subroutine]]`, `{{hexagon}}`, `[(cylinder)]`, `>asym]`, `[/trap\]`,
  `[\trap/]`, `(((double-circle)))`
- Edges: `-->`, `---`, `-.->`, `==>`, `-.-`, `===`,
  bidirectional `<-->`, `<-.->`, `<==>`
- Labelled arrows: `-->|label|`, `-- label -->`
- `&` fan-out, hyphenated identifiers (`feature-login`)

### `sequenceDiagram`

- `participant A` / `actor U` with `as` aliases
- Message arrows: `->>`, `-->>`, `->`, `-->`, `-x`, `--x`, `-)`, `--)`
- Activation shortcuts: `->>+`, `->>-`
- `<br>` / `<BR>` / `<br/>` normalisation in labels

### `classDiagram` / `classDiagram-v2`

- Relations: `<|--`, `*--`, `o--`, `-->`, `..>`, `--` (and reverses)
- Visibility: `+`, `-`, `#`, `~`
- Fields and methods (methods accept return types: `+get(k) V`)
- Block form: `class X { ... }`
- Stereotypes: `<<interface>>`, `<<abstract>>` — inside a block body,
  inline `class Foo { <<interface>> }`, or trailing `class Foo <<interface>>`
- Multiplicity: `"1" --> "*"`
- Generics: `class List~T~` (rendered as `List<T>`)
- `namespace Foo { ... }`

### `stateDiagram` / `stateDiagram-v2`

- `[*]` initial / final
- Transitions with labels: `s1 --> s2 : event`
- Alias: `state "Description" as S`
- Inline description: `S : text`
- `<br>` normalisation in labels

### `erDiagram`

- Relations: `A CARD--CARD B : label`
- Entities: `E { TYPE NAME [PK|FK|UK] }`, standalone `E`, `E {}`
- Cardinality: `||`, `|o`, `o|`, `o{`, `}o`, `|{`, `}|`
- Identifying `--` and non-identifying `..`

### `gitGraph`

- `commit`, `branch`, `checkout` / `switch`, `merge`
- `commit` / `merge` options: `id:"..."`, `tag:"..."`,
  `type: NORMAL|REVERSE|HIGHLIGHT`
- Headers: `gitGraph`, `gitGraph:`, `gitGraph LR:`
