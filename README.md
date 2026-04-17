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
- `subgraph NAME [title] ... end` with nesting; members occupy a reserved
  column band so the frame never engulfs external nodes. Label-only form
  slugifies the id using upstream's `\s+ → _`, drop `[^\w]` rule
- `classDef NAME style`, `class ids NAME`, `style id prop:val`,
  `:::className` assignments are preserved in the AST (not rendered visually)
- `linkStyle default ...` and `linkStyle idx,... ...` preserved in the AST
- Top-level `direction X` lines after the header are accepted but ignored
  (intentional deviation; upstream would bare-node the token)
- Subgraph-internal `direction X` swaps the layout axis for that group's
  members (e.g. `direction LR` inside a TD diagram arranges nodes
  horizontally). RL is normalised to LR and BT to TD

### `sequenceDiagram`

- `participant A` / `actor U` with `as` aliases
- Message arrows: `->>`, `-->>`, `->`, `-->`, `-x`, `--x`, `-)`, `--)`
- Activation shortcuts: `->>+`, `->>-`
- `<br>` / `<BR>` / `<br/>` normalisation in labels
- Block frames for `loop`, `alt` / `else`, `opt`, `par` / `and`,
  `critical` / `option`, `rect`, `break`; each branch keyword renders
  as a dotted divider on the block frame
- `Note left of`, `Note right of`, `Note over A[,B]` render as a small
  rectangle spanning the referenced participant column(s)

### `classDiagram` / `classDiagram-v2`

- Relations: `<|--`, `*--`, `o--`, `-->`, `..>`, `--` (and reverses).
  UML markers sit on the side written in the source: `<|--` places the
  triangle on the left-hand class, `--|>` on the right-hand class. Bare
  `--` is rendered as an association with the arrow on the right-hand
  (`to`) side.
- Visibility prefixes: `+`, `-`, `#`, `~`
- Members follow upstream rules: **attributes** use `Type name`
  (whitespace-split); **methods** are `name(params) ReturnType`.
  `name$` or `$` in the rest-text marks static; `name*` or `*` after
  `)` marks abstract. Both flags are retained in the AST.
- Annotations (`<<interface>>`, `<<abstract>>`): inside a block body or
  inline `class Foo { <<interface>> }`. The trailing form without braces
  (`class Foo <<interface>>`) is silently ignored to match upstream.
- Multiplicity: `"1" --> "*"`
- Generics: `class List~T~` renders as `List<T>`; multi-parameter forms
  like `class Map~K,V~` keep their raw text (upstream non-greedy
  fallback) — `id_text` and `label` both read `Map~K,V~`.
- Dotted and hyphenated class IDs (`com.example.Foo`, `a-b`) are
  accepted — class IDs follow upstream `\S+?` rules.
- `namespace Foo { ... }` wraps inner classes in an outer ASCII frame
  whose top-edge bears the namespace name.

### `stateDiagram` / `stateDiagram-v2`

- `[*]` initial / final
- Transitions with labels: `s1 --> s2 : event`
- Alias: `state "Description" as S`
- Inline description: `S : text`
- `<br>` normalisation in labels
- Composite states `state S { ... }` (and aliased `state "Label" as S { ... }`)
  render as a subgraph frame with external transitions terminating on the
  frame boundary. Empty composites (no interior members) still drop their
  external transitions because no frame is produced.
- `direction TD|TB|BT|LR|RL` at top level updates the diagram direction;
  inside a composite it swaps the layout axis for that group's members.
  RL is normalised to LR and BT to TD
- `linkStyle default ...` and `linkStyle idx,... ...` are accepted (AST only)
- Unicode letter ids are accepted for transitions (Latin extended, Greek,
  Cyrillic, CJK, etc.); emoji and symbol codepoints are rejected

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

