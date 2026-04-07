//! markdown_preview — render CommonMark + GFM markdown to an
//! ANSI-styled terminal byte stream.
//!
//! # Public API
//!
//! - `renderMarkdown(allocator, writer, input, opts)` — the only
//!   entry point. Consumes a `[]const u8` markdown source and
//!   writes the styled output to `writer` in a single streaming
//!   pass.
//! - `RenderOptions` — configuration for a render pass (ANSI
//!   toggle, theme selection, optional wrap width).
//! - `Theme` — color theme enum (currently only `.solarized_dark`).
//!
//! Anything not re-exported from this file is an implementation
//! detail and may change between releases without notice.
//!
//! # Consumption pattern
//!
//! This module is consumed both by the bundled `mp` CLI and by
//! any external Zig project that depends on this package. Both
//! use the same entry point:
//!
//! ```zig
//! const mp = @import("markdown_preview");
//! try mp.renderMarkdown(allocator, writer, input, .{
//!     .enable_ansi = true,
//!     .theme = .solarized_dark,
//!     .wrap_width = 80,
//! });
//! ```
//!
//! The bundled CLI (`src/cli.zig`) uses exactly this import
//! shape and is treated as an external consumer of the library.
//! It does not reach into internal modules directly, even though
//! Zig's `@import` would technically allow it from the same `src/`
//! tree — the discipline is by convention, not by compiler
//! enforcement. That makes the boundary testable by social contract:
//! if `cli.zig` compiles without touching internals, the public
//! surface is sufficient for external use.
//!
//! A future Neovim plugin is expected to invoke the `mp` binary
//! as a subprocess in Neovim's built-in `:terminal` buffer,
//! piping the markdown file through the CLI and letting the
//! terminal emulator handle the ANSI output natively. That path
//! does not consume this library directly — it consumes the
//! binary. If an in-process Zig consumer eventually appears, it
//! can `@import("markdown_preview")` via `build.zig.zon` and use
//! exactly the same three symbols below.
//!
//! # Internal layering (implementation detail)
//!
//! - `parse_*.zig` — CommonMark + GFM parsing (bytes → classified
//!   structured data).
//! - `render.zig`, `render_inline.zig`, `render_table.zig` —
//!   rendering (classified data → ANSI-styled bytes).
//! - `ansi.zig`, `theme.zig`, `width.zig`, `entity.zig`,
//!   `highlight.zig` — primitives with no Markdown knowledge.

pub const Theme = @import("theme.zig").Theme;
pub const RenderOptions = @import("render.zig").RenderOptions;
pub const renderMarkdown = @import("render.zig").renderMarkdown;

test {
    _ = @import("render.zig");
    _ = @import("highlight.zig");
    _ = @import("parse_document.zig");
}
