const std = @import("std");
const helpers = @import("../helpers/render_from_source.zig");
const internals = @import("internals");

fn renderFence(allocator: std.mem.Allocator, source: []const u8, enable_ansi: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var doc = try internals.parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();
    var renderer = internals.render.Renderer.init(allocator, .{
        .enable_ansi = enable_ansi,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();
    try renderer.render(&output.writer, &doc, null, allocator);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "flowchart nested subgraph renders to stable ASCII snapshot" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\flowchart TD
        \\    subgraph outer [Services]
        \\        A[Load] --> B[Validate]
        \\        subgraph inner [Adapters]
        \\            C[DB] --> D[Cache]
        \\        end
        \\        B --> C
        \\    end
        \\```
        \\
    ;
    const rendered = try renderFence(allocator, source, false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\```mermaid
        \\┌─Services───────────────────┐
        \\│                            │
        \\│ ┌──────────┐               │
        \\│ │   Load   │               │
        \\│ └─────┬────┘               │
        \\│       │                    │
        \\│       ▼                    │
        \\│ ┌──────────┐               │
        \\│ │ Validate │               │
        \\│ └─────┬────┘               │
        \\│       └─────────────┐      │
        \\│              ┌─Adapters───┐│
        \\│              │┌──────────┐││
        \\│              ││    DB    │││
        \\│              │└─────┬────┘││
        \\│              │      │     ││
        \\│              │      ▼     ││
        \\│              │┌──────────┐││
        \\│              ││  Cache   │││
        \\│              │└──────────┘││
        \\│              └────────────┘│
        \\└────────────────────────────┘
        \\```
        \\
    , rendered);
}

test "stateDiagram composite state renders to stable ASCII snapshot" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    state Active {
        \\        [*] --> Waiting
        \\        Waiting --> Working : request
        \\    }
        \\    Idle --> Active : start
        \\    Active --> [*]
        \\```
        \\
    ;
    const rendered = try renderFence(allocator, source, false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\```mermaid
        \\             ┌─Active────┐
        \\ ╭─────────╮ │╭─────────╮│
        \\ │    ●    │ ││    ●    ││
        \\ ╰────┬────╯ │╰────┬────╯│
        \\      │      │     │     │
        \\      ▼      │     ▼     │
        \\ ╭────────start─────────╮│
        \\ │  Idle   ├┬┤│ Waiting ││
        \\ ╰─────────╯││╰────┬────╯│
        \\            ││  request  │
        \\            ││     ▼     │
        \\            ││╭─────────╮│
        \\            │││ Working ││
        \\            ││╰─────────╯│
        \\            │└───────────┘
        \\            │
        \\ ╭─────────╮│
        \\ │    ●    ◄┘
        \\ ╰─────────╯
        \\
        \\```
        \\
    , rendered);
}

test "sequenceDiagram alt/else/par/Note renders to stable ASCII snapshot" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\sequenceDiagram
        \\    participant Client
        \\    participant API
        \\    Client->>API: request
        \\    alt ok
        \\        API-->>Client: 200
        \\    else error
        \\        API-->>Client: 500
        \\    end
        \\    par a
        \\        Client->>API: p1
        \\    and b
        \\        Client->>API: p2
        \\    end
        \\    Note over Client,API: done
        \\```
        \\
    ;
    const rendered = try renderFence(allocator, source, false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\```mermaid
        \\┌────────┐             ┌────────┐
        \\│ Client │             │  API   │
        \\└────┬───┘             └────┬───┘
        \\     │                      │
        \\     │       request        │
        \\     ├──────────────────────►
        \\┌ alt [ok]──────────────────┬───┐
        \\│    │         200          │   │
        \\│    ◄╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌│   │
        \\├ error╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
        \\│    │         500          │   │
        \\│    ◄╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌│   │
        \\└───────────────────────────┴───┘
        \\┌ par [a]───────────────────┬───┐
        \\│    │         p1           │   │
        \\│    ├──────────────────────►   │
        \\├ b╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
        \\│    │         p2           │   │
        \\│    ├──────────────────────►   │
        \\│  ┌─┼──────────────────────┬┐  │
        \\│  │ │        done          ││  │
        \\│  └─┴──────────────────────┴┘  │
        \\└────┬──────────────────────┬───┘
        \\     │                      │
        \\┌────┴───┐             ┌────┴───┐
        \\│ Client │             │  API   │
        \\└────────┘             └────────┘
        \\```
        \\
    , rendered);
}

test "sequenceDiagram critical/option renders a divider for the option branch" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    critical connect
        \\        A->>B: hello
        \\    option failure
        \\        B-->>A: retry
        \\    end
        \\```
        \\
    ;
    const rendered = try renderFence(allocator, source, false);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\```mermaid
        \\┌────┐                       ┌────┐
        \\│ A  │                       │ B  │
        \\└──┬─┘                       └──┬─┘
        \\   │                            │
        \\┌ critical [connect]────────────┼─┐
        \\│  │           hello            │ │
        \\│  ├────────────────────────────► │
        \\├ failure╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
        \\│  │           retry            │ │
        \\│  ◄╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌│ │
        \\└──┬────────────────────────────┼─┘
        \\   │                            │
        \\┌──┴─┐                       ┌──┴─┐
        \\│ A  │                       │ B  │
        \\└────┘                       └────┘
        \\```
        \\
    , rendered);
}

test "classDiagram namespace with static/abstract members emits correct SGR frames" {
    const allocator = std.testing.allocator;
    const source =
        \\```mermaid
        \\classDiagram
        \\    namespace Billing {
        \\        class Account {
        \\            <<abstract>>
        \\            +String ownerId
        \\            +int balance$
        \\            +settle()*
        \\        }
        \\    }
        \\```
        \\
    ;
    const rendered = try renderFence(allocator, source, true);
    defer allocator.free(rendered);

    const expected =
        "\x1b[2m\x1b[38;2;88;110;117m```mermaid\x1b[0m\n" ++
        "┌─Billing───────────────┐\n" ++
        "│                       │\n" ++
        "│ ┌───────────────────┐ │\n" ++
        "│ │    «abstract»     │ │\n" ++
        "│ │      Account      │ │\n" ++
        "│ ├───────────────────┤ │\n" ++
        "│ │ + ownerId: String │ │\n" ++
        "│ │ + \x1b[4mbalance: int\x1b[24m    │ │\n" ++
        "│ ├───────────────────┤ │\n" ++
        "│ │ + \x1b[3msettle(): *\x1b[23m     │ │\n" ++
        "│ └───────────────────┘ │\n" ++
        "│                       │\n" ++
        "└───────────────────────┘\n" ++
        "\x1b[2m\x1b[38;2;88;110;117m```\x1b[0m\n";

    try std.testing.expectEqualStrings(expected, rendered);
}
