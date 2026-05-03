const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const compile_mod = @import("compile.zig");
const route_mod = @import("route.zig");
const text_layout = @import("text_layout.zig");
const ansi_mod = @import("../term/ansi.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    UnsupportedFeature,
    WidthTooSmall,
    OutOfMemory,
    Overflow,
    WriteFailed,
};

pub const Options = struct {
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
    enable_ansi: bool = false,
};

const StyleKind = enum { static_, abstract_ };

const StyledSpan = struct {
    row: usize,
    col_start: usize,
    col_end: usize,
    kind: StyleKind,
};

const empty_class_box_height: usize = 3;
const class_box_min_width: usize = 6;
const class_box_border_columns: usize = 2;
const class_box_side_spacing: usize = 4;
const class_box_content_offset: usize = 2;
const namespace_outer_padding: usize = 2;
const namespace_frame_padding: usize = 1;
const cardinality_label_gap: usize = 2;

const MemberBoxLayout = struct {
    lines: text_layout.LabelLayout,
    is_static: bool,
    is_abstract: bool,
    first_line_style_start: usize,

    pub fn deinit(self: *MemberBoxLayout) void {
        self.lines.deinit();
    }
};

const ClassBoxLayout = struct {
    annotation: ?text_layout.LabelLayout = null,
    name: text_layout.LabelLayout,
    attributes: []MemberBoxLayout,
    methods: []MemberBoxLayout,
    height: usize,
    max_content_width: usize,

    pub fn deinit(self: *ClassBoxLayout, allocator: std.mem.Allocator) void {
        if (self.annotation) |*annotation| annotation.deinit();
        self.name.deinit();
        for (self.attributes) |*attr| attr.deinit();
        allocator.free(self.attributes);
        for (self.methods) |*method| method.deinit();
        allocator.free(self.methods);
    }
};

const ClassLayout = struct {
    base: types.Layout,
    classes: []ClassBoxLayout,

    pub fn deinit(self: *ClassLayout) void {
        for (self.classes) |*class_layout| class_layout.deinit(self.base.allocator);
        self.base.allocator.free(self.classes);
        self.base.deinit();
    }
};

pub fn paintClass(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    diagram_ptr: *const types.ClassDiagram,
    opts: Options,
) RenderError!void {
    const diagram = diagram_ptr.*;

    if (diagram.classes.len == 0) return;

    var layout = computeClassLayout(allocator, &diagram, opts.wrap_width, opts.ambiguous_width) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.Overflow,
        error.WidthTooSmall => return error.WidthTooSmall,
    };
    defer layout.deinit();

    if (layout.base.rows == 0 or layout.base.cols == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;

    const canvas_rows = route_mod.canvasRows(&layout.base);
    const canvas_cols = route_mod.canvasCols(&layout.base);
    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    for (diagram.namespaces) |ns| {
        try drawNamespaceFrame(allocator, &canvas, &layout, ns, &glyphs, opts.ambiguous_width);
    }

    var spans: std.ArrayList(StyledSpan) = .empty;
    defer spans.deinit(allocator);

    for (diagram.classes, 0..) |_, i| {
        const pos = layout.base.positions[i];
        const top = route_mod.boxTop(&layout.base, pos.row);
        const left = route_mod.boxLeft(&layout.base, pos.col);
        try drawClassBox(&canvas, top, left, layout.base.cell_w, &layout.classes[i], &glyphs, opts.ambiguous_width, if (opts.enable_ansi) &spans else null);
    }

    const protected_rects = try classProtectedRects(allocator, &layout);
    defer allocator.free(protected_rects);
    var route_scratch: route_mod.RouteScratch = .{};
    defer route_scratch.deinit(allocator);

    const defer_relation_labels = opts.wrap_width != null;
    const relation_label_wrap_width = @min(text_layout.edgeLabelWrapWidth(opts.wrap_width orelse canvas.cols), canvas.cols);

    for (diagram.relations) |rel| {
        drawRelation(allocator, &route_scratch, &canvas, &layout, protected_rects, rel, &glyphs, defer_relation_labels, relation_label_wrap_width, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WidthTooSmall => return error.WidthTooSmall,
        };
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (opts.enable_ansi and spans.items.len > 0) {
        try writeCanvasWithSpans(writer, allocator, &canvas, spans.items, opts);
    } else {
        canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
    }
}

fn writeCanvasWithSpans(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    canvas: *const canvas_mod.Canvas,
    spans: []const StyledSpan,
    opts: Options,
) RenderError!void {
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    canvas_mod.writeCanvas(&sink.writer, canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;

    const plain = sink.writer.buffered();

    var row: usize = 0;
    var line_it = std.mem.splitScalar(u8, plain, '\n');
    var first = true;
    while (line_it.next()) |line| : (row += 1) {
        if (!first) writer.writeByte('\n') catch return error.WriteFailed;
        first = false;
        try writeLineWithSpans(writer, line, row, spans, opts.ambiguous_width);
    }
}

fn writeLineWithSpans(
    writer: *std.Io.Writer,
    line: []const u8,
    row: usize,
    spans: []const StyledSpan,
    ambiguous: width_mod.AmbiguousWidth,
) RenderError!void {
    var col: usize = 0;
    var open_static = false;
    var open_abstract = false;
    var clusters = width_mod.DisplayClusterIterator.init(line, ambiguous);
    while (clusters.next()) |cluster| {
        const cluster_w = cluster.width;

        if (!open_static and hasSpanStart(spans, row, col, .static_)) {
            try writeStyleOpen(writer, .static_);
            open_static = true;
        }
        if (!open_abstract and hasSpanStart(spans, row, col, .abstract_)) {
            try writeStyleOpen(writer, .abstract_);
            open_abstract = true;
        }

        writer.writeAll(cluster.bytes) catch return error.WriteFailed;

        if (open_static and spanEndsAt(spans, row, col + cluster_w, .static_)) {
            try writeStyleClose(writer, .static_);
            open_static = false;
        }
        if (open_abstract and spanEndsAt(spans, row, col + cluster_w, .abstract_)) {
            try writeStyleClose(writer, .abstract_);
            open_abstract = false;
        }

        col += cluster_w;
    }
    if (open_static) try writeStyleClose(writer, .static_);
    if (open_abstract) try writeStyleClose(writer, .abstract_);
}

fn hasSpanStart(spans: []const StyledSpan, row: usize, col: usize, kind: StyleKind) bool {
    for (spans) |s| {
        if (s.row == row and s.col_start == col and s.kind == kind) return true;
    }
    return false;
}

fn spanEndsAt(spans: []const StyledSpan, row: usize, col: usize, kind: StyleKind) bool {
    for (spans) |s| {
        if (s.row == row and s.kind == kind and s.col_end == col) return true;
    }
    return false;
}

fn writeStyleOpen(writer: *std.Io.Writer, kind: StyleKind) RenderError!void {
    const seq: []const u8 = switch (kind) {
        .static_ => ansi_mod.underline_on,
        .abstract_ => ansi_mod.italic_on,
    };
    writer.writeAll(seq) catch return error.WriteFailed;
}

fn writeStyleClose(writer: *std.Io.Writer, kind: StyleKind) RenderError!void {
    const seq: []const u8 = switch (kind) {
        .static_ => ansi_mod.underline_off,
        .abstract_ => ansi_mod.italic_off,
    };
    writer.writeAll(seq) catch return error.WriteFailed;
}

pub const ClassLayoutError = error{ OutOfMemory, Overflow, WidthTooSmall };

fn computeClassLayout(
    allocator: std.mem.Allocator,
    diagram: *const types.ClassDiagram,
    wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError!ClassLayout {
    const n = diagram.classes.len;
    if (n == 0) {
        const positions: []types.GridPos = &.{};
        const labels: []types.NodeLabelLayout = &.{};
        const class_layouts: []ClassBoxLayout = &.{};
        const base: types.Layout = .{
            .allocator = allocator,
            .positions = positions,
            .node_labels = labels,
            .rows = 0,
            .cols = 0,
            .cell_w = 0,
            .cell_h = 0,
        };
        return .{
            .base = base,
            .classes = class_layouts,
        };
    }

    const levels = try allocator.alloc(usize, n);
    defer allocator.free(levels);
    @memset(levels, 0);

    try assignClassLevels(allocator, diagram.relations, n, levels);

    var max_level: usize = 0;
    for (levels) |l| max_level = @max(max_level, l);

    const level_slots = try std.math.add(usize, max_level, 1);
    const level_counts = try allocator.alloc(usize, level_slots);
    defer allocator.free(level_counts);
    @memset(level_counts, 0);

    for (0..n) |i| level_counts[levels[i]] += 1;

    const outer_pad: usize = if (diagram.namespaces.len > 0) namespace_outer_padding else 0;
    const content_budget = try classContentBudget(wrap_width, outer_pad);
    const class_layouts = try computeClassBoxLayouts(allocator, diagram, content_budget, ambiguous);
    errdefer deinitClassBoxLayouts(allocator, class_layouts);

    const cell_w = computeRequiredBoxWidth(class_layouts);

    const max_cols_per_row = maxColumnsForWrap(wrap_width, cell_w, n, outer_pad);
    var cols: usize = 0;
    for (level_counts) |c| cols = @max(cols, @min(c, max_cols_per_row));
    if (cols == 0) cols = 1;

    const label_wrap_width = if (wrap_width) |w|
        @min(text_layout.edgeLabelWrapWidth(w), route_mod.canvasColsForGrid(cols, cell_w, outer_pad))
    else
        null;
    var cell_h = computeRequiredBoxHeight(class_layouts);
    cell_h = try std.math.add(usize, cell_h, try extraCellHeightForRelationLabels(allocator, diagram, label_wrap_width, ambiguous));

    const level_row_starts = try allocator.alloc(usize, level_slots);
    defer allocator.free(level_row_starts);

    var rows: usize = 0;
    var level_cursor = level_slots;
    while (level_cursor > 0) {
        level_cursor -= 1;
        level_row_starts[level_cursor] = rows;
        rows = try std.math.add(usize, rows, std.math.divCeil(usize, level_counts[level_cursor], max_cols_per_row) catch unreachable);
    }
    if (rows == 0) rows = 1;

    const positions = try allocator.alloc(types.GridPos, n);
    errdefer allocator.free(positions);

    const level_next_indices = try allocator.alloc(usize, level_slots);
    defer allocator.free(level_next_indices);
    @memset(level_next_indices, 0);

    for (0..n) |i| {
        const level = levels[i];
        const local_idx = level_next_indices[level];
        level_next_indices[level] += 1;
        positions[i] = .{
            .row = try std.math.add(usize, level_row_starts[level], local_idx / max_cols_per_row),
            .col = local_idx % max_cols_per_row,
        };
    }

    const node_labels: []types.NodeLabelLayout = &.{};

    const outer_pad_y = try computeNamespaceOuterPadY(allocator, diagram, positions, class_layouts, cell_w, outer_pad, ambiguous);

    const base: types.Layout = .{
        .allocator = allocator,
        .positions = positions,
        .node_labels = node_labels,
        .rows = rows,
        .cols = cols,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .outer_pad = outer_pad,
        .outer_pad_y = outer_pad_y,
    };
    return .{
        .base = base,
        .classes = class_layouts,
    };
}

fn assignClassLevels(
    allocator: std.mem.Allocator,
    relations: []const types.ClassRelation,
    n: usize,
    levels: []usize,
) ClassLayoutError!void {
    const remaining = try allocator.alloc(u32, n);
    defer allocator.free(remaining);
    @memset(remaining, 0);
    for (relations) |rel| {
        if (rel.to < n) remaining[rel.to] += 1;
    }

    var queue: std.ArrayList(types.NodeId) = .empty;
    defer queue.deinit(allocator);

    for (0..n) |i| {
        if (remaining[i] == 0) try queue.append(allocator, @intCast(i));
    }
    if (queue.items.len == 0) {
        try queue.append(allocator, 0);
        remaining[0] = 0;
    }

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const u = queue.items[qi];
        for (relations) |rel| {
            if (rel.from != u) continue;
            const v = rel.to;
            if (v >= n) continue;
            const candidate = levels[u] + 1;
            if (candidate > levels[v]) levels[v] = candidate;
            if (remaining[v] > 0) {
                remaining[v] -= 1;
                if (remaining[v] == 0) try queue.append(allocator, v);
            }
        }
    }
}

fn maxColumnsForWrap(wrap_width: ?usize, cell_w: usize, class_count: usize, outer_pad: usize) usize {
    const w = wrap_width orelse return @max(class_count, 1);
    if (route_mod.canvasColsForGrid(1, cell_w, outer_pad) >= w) return 1;
    const available = w - route_mod.canvasColsForGrid(1, 0, outer_pad);
    const step_w = std.math.add(usize, cell_w, route_mod.gutter_w) catch return 1;
    return 1 + (available - cell_w) / step_w;
}

fn classContentBudget(wrap_width: ?usize, outer_pad: usize) ClassLayoutError!?usize {
    const w = wrap_width orelse return null;
    if (w <= 2 * outer_pad) return error.WidthTooSmall;
    const available = w - 2 * outer_pad;
    if (available < class_box_min_width) return error.WidthTooSmall;
    if (available <= class_box_side_spacing) return error.WidthTooSmall;
    return available - class_box_side_spacing;
}

fn computeClassBoxLayouts(
    allocator: std.mem.Allocator,
    diagram: *const types.ClassDiagram,
    max_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError![]ClassBoxLayout {
    const layouts = try allocator.alloc(ClassBoxLayout, diagram.classes.len);
    var initialized: usize = 0;
    errdefer {
        deinitClassBoxLayoutItems(allocator, layouts[0..initialized]);
        allocator.free(layouts);
    }

    for (diagram.classes, 0..) |cls, i| {
        layouts[i] = try computeClassBoxLayout(allocator, &cls, max_width, ambiguous);
        initialized += 1;
    }

    return layouts;
}

fn deinitClassBoxLayoutItems(allocator: std.mem.Allocator, layouts: []ClassBoxLayout) void {
    for (layouts) |*layout| layout.deinit(allocator);
}

fn deinitClassBoxLayouts(allocator: std.mem.Allocator, layouts: []ClassBoxLayout) void {
    deinitClassBoxLayoutItems(allocator, layouts);
    allocator.free(layouts);
}

fn computeClassBoxLayout(
    allocator: std.mem.Allocator,
    cls: *const types.ClassNode,
    max_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError!ClassBoxLayout {
    var annotation: ?text_layout.LabelLayout = null;
    errdefer if (annotation) |*a| a.deinit();

    var max_content_width: usize = 0;
    var annotation_lines: usize = 0;
    if (cls.annotation) |st| {
        const annotation_text = try std.fmt.allocPrint(allocator, "«{s}»", .{st});
        defer allocator.free(annotation_text);
        annotation = text_layout.layoutLabel(allocator, annotation_text, max_width, ambiguous) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        annotation_lines = annotation.?.lines.len;
        max_content_width = @max(max_content_width, annotation.?.max_line_width);
    }

    var name = text_layout.layoutLabel(allocator, cls.label, max_width, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer name.deinit();
    max_content_width = @max(max_content_width, name.max_line_width);

    const attrs = try computeMemberLayouts(allocator, cls.attributes, false, max_width, ambiguous);
    errdefer deinitMemberLayouts(allocator, attrs);
    const methods = try computeMemberLayouts(allocator, cls.methods, true, max_width, ambiguous);
    errdefer deinitMemberLayouts(allocator, methods);

    var attr_lines: usize = 0;
    for (attrs) |attr| {
        attr_lines += attr.lines.lines.len;
        max_content_width = @max(max_content_width, attr.lines.max_line_width);
    }
    var method_lines: usize = 0;
    for (methods) |method| {
        method_lines += method.lines.lines.len;
        max_content_width = @max(max_content_width, method.lines.max_line_width);
    }

    const has_fields = attrs.len > 0;
    const has_methods = methods.len > 0;
    const height = if (!has_fields and !has_methods)
        @max(@as(usize, empty_class_box_height), 2 + annotation_lines + name.lines.len)
    else
        2 + annotation_lines + name.lines.len + 1 + attr_lines + method_lines + if (has_fields and has_methods) @as(usize, 1) else 0;

    return .{
        .annotation = annotation,
        .name = name,
        .attributes = attrs,
        .methods = methods,
        .height = height,
        .max_content_width = max_content_width,
    };
}

fn computeMemberLayouts(
    allocator: std.mem.Allocator,
    members: []const types.ClassMember,
    is_method: bool,
    max_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError![]MemberBoxLayout {
    const layouts = try allocator.alloc(MemberBoxLayout, members.len);
    var initialized: usize = 0;
    errdefer {
        deinitMemberLayoutItems(layouts[0..initialized]);
        allocator.free(layouts);
    }

    for (members, 0..) |member, i| {
        const formatted = try formatMember(allocator, &member, is_method);
        defer allocator.free(formatted.text);

        var lines = text_layout.layoutLabel(allocator, formatted.text, max_width, ambiguous) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer lines.deinit();

        layouts[i] = .{
            .lines = lines,
            .is_static = member.is_static,
            .is_abstract = member.is_abstract,
            .first_line_style_start = formatted.style_start,
        };
        initialized += 1;
    }

    return layouts;
}

fn deinitMemberLayoutItems(layouts: []MemberBoxLayout) void {
    for (layouts) |*layout| layout.deinit();
}

fn deinitMemberLayouts(allocator: std.mem.Allocator, layouts: []MemberBoxLayout) void {
    deinitMemberLayoutItems(layouts);
    allocator.free(layouts);
}

const FormattedMember = struct {
    text: []u8,
    style_start: usize,
};

fn formatMember(allocator: std.mem.Allocator, member: *const types.ClassMember, is_method: bool) ClassLayoutError!FormattedMember {
    var sigil_buf: [4]u8 = undefined;
    const sigil = if (visibilitySigil(member.visibility)) |s|
        sigil_buf[0..(std.unicode.utf8Encode(s, &sigil_buf) catch unreachable)]
    else
        "";
    const sigil_sep: []const u8 = if (sigil.len > 0) " " else "";
    const params = if (member.params) |p| p else "";
    const style_start = sigil.len + sigil_sep.len;
    const text = if (is_method)
        if (member.type_text) |type_text|
            try std.fmt.allocPrint(allocator, "{s}{s}{s}({s}): {s}", .{ sigil, sigil_sep, member.name, params, type_text })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}{s}({s})", .{ sigil, sigil_sep, member.name, params })
    else if (member.type_text) |type_text|
        try std.fmt.allocPrint(allocator, "{s}{s}{s}: {s}", .{ sigil, sigil_sep, member.name, type_text })
    else
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sigil, sigil_sep, member.name });

    return .{
        .text = text,
        .style_start = style_start,
    };
}

fn computeRequiredBoxHeight(layouts: []const ClassBoxLayout) usize {
    var max_h: usize = empty_class_box_height;
    for (layouts) |layout| max_h = @max(max_h, layout.height);
    return max_h;
}

fn computeRequiredBoxWidth(layouts: []const ClassBoxLayout) usize {
    var max_w: usize = 0;
    for (layouts) |layout| max_w = @max(max_w, layout.max_content_width);
    return @max(max_w + class_box_side_spacing, class_box_min_width);
}

fn extraCellHeightForRelationLabels(
    allocator: std.mem.Allocator,
    diagram: *const types.ClassDiagram,
    label_wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError!usize {
    const w = label_wrap_width orelse return 0;
    var max_lines: usize = 0;
    for (diagram.relations) |rel| {
        const relation_lines = try labelLineCount(allocator, rel.label, w, ambiguous);
        const from_cardinality_lines = try labelLineCount(allocator, rel.from_cardinality, w, ambiguous);
        const to_cardinality_lines = try labelLineCount(allocator, rel.to_cardinality, w, ambiguous);
        max_lines = @max(max_lines, relation_lines + from_cardinality_lines + to_cardinality_lines);
    }
    const drawable_gutter = if (route_mod.gutter_h > 0) route_mod.gutter_h - 1 else 0;
    if (max_lines <= drawable_gutter) return 0;
    return max_lines - drawable_gutter;
}

fn labelLineCount(
    allocator: std.mem.Allocator,
    maybe_label: ?[]const u8,
    max_width: usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError!usize {
    const label = maybe_label orelse return 0;
    if (label.len == 0) return 0;
    var layout = text_layout.layoutLabel(allocator, label, max_width, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer layout.deinit();
    return layout.lines.len;
}

const NamespaceBounds = struct {
    min_row: usize,
    max_row: usize,
    min_col: usize,
    max_col: usize,
    max_h_in_row: usize,
};

fn namespaceBounds(ns: types.ClassNamespace, positions: []const types.GridPos, classes: []const ClassBoxLayout) ?NamespaceBounds {
    if (ns.class_ids.len == 0) return null;

    var bounds: NamespaceBounds = .{
        .min_row = std.math.maxInt(usize),
        .max_row = 0,
        .min_col = std.math.maxInt(usize),
        .max_col = 0,
        .max_h_in_row = empty_class_box_height,
    };

    for (ns.class_ids) |id| {
        if (id >= classes.len or id >= positions.len) continue;
        const pos = positions[id];
        const h = classes[id].height;
        bounds.min_row = @min(bounds.min_row, pos.row);
        bounds.max_row = @max(bounds.max_row, pos.row);
        bounds.min_col = @min(bounds.min_col, pos.col);
        bounds.max_col = @max(bounds.max_col, pos.col);
        bounds.max_h_in_row = @max(bounds.max_h_in_row, h);
    }

    if (bounds.min_row == std.math.maxInt(usize)) return null;
    return bounds;
}

fn namespaceFrameWidth(bounds: NamespaceBounds, cell_w: usize) usize {
    const class_cols = bounds.max_col - bounds.min_col + 1;
    return route_mod.canvasColsForGrid(class_cols, cell_w, namespace_frame_padding) +| 2;
}

fn namespaceTitleWidth(frame_w: usize) ClassLayoutError!usize {
    if (frame_w <= class_box_side_spacing) return error.WidthTooSmall;
    return frame_w - class_box_side_spacing;
}

fn computeNamespaceOuterPadY(
    allocator: std.mem.Allocator,
    diagram: *const types.ClassDiagram,
    positions: []const types.GridPos,
    class_layouts: []const ClassBoxLayout,
    cell_w: usize,
    outer_pad: usize,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError!?usize {
    if (diagram.namespaces.len == 0) return null;

    var pad_y = outer_pad;
    for (diagram.namespaces) |ns| {
        if (ns.name.len == 0) continue;
        const bounds = namespaceBounds(ns, positions, class_layouts) orelse continue;
        const title_w = try namespaceTitleWidth(namespaceFrameWidth(bounds, cell_w));
        var title = text_layout.layoutLabel(allocator, ns.name, title_w, ambiguous) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer title.deinit();
        pad_y = @max(pad_y, title.lines.len + namespace_frame_padding);
    }

    return pad_y;
}

fn drawNamespaceFrame(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const ClassLayout,
    ns: types.ClassNamespace,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) RenderError!void {
    const bounds = namespaceBounds(ns, layout.base.positions, layout.classes) orelse return;
    const frame_title_width = try namespaceTitleWidth(namespaceFrameWidth(bounds, layout.base.cell_w));
    var title = text_layout.layoutLabel(allocator, ns.name, frame_title_width, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer title.deinit();

    const inner_top = route_mod.boxTop(&layout.base, bounds.min_row);
    const inner_left = route_mod.boxLeft(&layout.base, bounds.min_col);
    const inner_bottom = route_mod.boxTop(&layout.base, bounds.max_row) + bounds.max_h_in_row;
    const inner_right = route_mod.boxLeft(&layout.base, bounds.max_col) + layout.base.cell_w;

    const pad: usize = namespace_frame_padding;
    const title_rows = @max(title.lines.len, @as(usize, 1));
    const top_gap = pad + title_rows;
    const top = if (inner_top >= top_gap) inner_top - top_gap else return error.WidthTooSmall;
    const left = if (inner_left >= pad + 1) inner_left - pad - 1 else 0;
    const bottom_raw = inner_bottom + pad;
    const right_raw = inner_right + pad;
    const bottom = if (bottom_raw >= canvas.rows) canvas.rows - 1 else bottom_raw;
    const right = if (right_raw >= canvas.cols) canvas.cols - 1 else right_raw;
    if (bottom <= top or right <= left) return;

    const h = bottom - top + 1;
    const w = right - left + 1;
    canvas.drawRect(top, left, h, w, glyphs);

    if (ns.name.len > 0) {
        const title_col = left + class_box_content_offset;
        for (title.lines, 0..) |line, idx| {
            const row = top + idx;
            if (row >= inner_top) return error.WidthTooSmall;
            try canvas.drawLabel(row, title_col, line.text, ambiguous);
        }
    }
}

fn drawClassBox(
    canvas: *canvas_mod.Canvas,
    top: usize,
    left: usize,
    width: usize,
    layout: *const ClassBoxLayout,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
    spans: ?*std.ArrayList(StyledSpan),
) RenderError!void {
    const height = layout.height;
    canvas.drawRect(top, left, height, width, glyphs);

    const inner_w = width - class_box_border_columns;
    var name_row = top + 1;

    if (layout.annotation) |annotation| {
        for (annotation.lines) |line| {
            const stereo_off = if (inner_w > line.width) (inner_w - line.width) / 2 else 0;
            try canvas.drawLabel(name_row, left + 1 + stereo_off, line.text, ambiguous);
            name_row += 1;
        }
    }

    for (layout.name.lines) |line| {
        const name_col_off = if (inner_w > line.width) (inner_w - line.width) / 2 else 0;
        try canvas.drawLabel(name_row, left + 1 + name_col_off, line.text, ambiguous);
        name_row += 1;
    }

    const has_fields = layout.attributes.len > 0;
    const has_methods = layout.methods.len > 0;
    if (!has_fields and !has_methods) return;

    const divider_row = name_row;
    drawDivider(canvas, divider_row, left, width, glyphs);

    var row = divider_row + 1;
    if (has_fields) {
        for (layout.attributes) |member| {
            row = try drawMemberLayout(canvas, row, left, &member, ambiguous, spans);
        }
    }

    if (has_fields and has_methods and row + 1 < top + height) {
        drawDivider(canvas, row, left, width, glyphs);
        row += 1;
    }

    if (has_methods) {
        for (layout.methods) |member| {
            row = try drawMemberLayout(canvas, row, left, &member, ambiguous, spans);
        }
    }
}

fn drawDivider(canvas: *canvas_mod.Canvas, row: usize, left: usize, width: usize, glyphs: *const canvas_mod.GlyphSet) void {
    var c = left + 1;
    while (c + 1 < left + width) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line);
    }
    canvas.setGlyph(row, left, glyphs.tee_l);
    canvas.setGlyph(row, left + width - 1, glyphs.tee_r);
}

fn drawMemberLayout(
    canvas: *canvas_mod.Canvas,
    row: usize,
    left: usize,
    member: *const MemberBoxLayout,
    ambiguous: width_mod.AmbiguousWidth,
    spans: ?*std.ArrayList(StyledSpan),
) RenderError!usize {
    var current_row = row;
    for (member.lines.lines, 0..) |line, line_idx| {
        const col = left + class_box_content_offset;
        try canvas.drawLabel(current_row, col, line.text, ambiguous);

        if (spans) |list| {
            const style_start = if (line_idx == 0) member.first_line_style_start else 0;
            if (line.width > style_start) {
                const span_start = col + style_start;
                const span_end = col + line.width;
                if (member.is_static) {
                    list.append(canvas.allocator, .{ .row = current_row, .col_start = span_start, .col_end = span_end, .kind = .static_ }) catch return error.OutOfMemory;
                }
                if (member.is_abstract) {
                    list.append(canvas.allocator, .{ .row = current_row, .col_start = span_start, .col_end = span_end, .kind = .abstract_ }) catch return error.OutOfMemory;
                }
            }
        }
        current_row += 1;
    }
    return current_row;
}

fn visibilitySigil(v: types.Visibility) ?u21 {
    return switch (v) {
        .public => '+',
        .private => '-',
        .protected => '#',
        .package => '~',
        .unknown => null,
    };
}

fn classProtectedRects(allocator: std.mem.Allocator, layout: *const ClassLayout) error{OutOfMemory}![]route_mod.ProtectedRect {
    const rects = try allocator.alloc(route_mod.ProtectedRect, layout.classes.len);
    for (layout.classes, 0..) |class_layout, i| {
        const pos = layout.base.positions[i];
        rects[i] = .{
            .top = route_mod.boxTop(&layout.base, pos.row),
            .left = route_mod.boxLeft(&layout.base, pos.col),
            .height = class_layout.height,
            .width = layout.base.cell_w,
        };
    }
    return rects;
}

fn drawRelation(
    allocator: std.mem.Allocator,
    route_scratch: *route_mod.RouteScratch,
    canvas: *canvas_mod.Canvas,
    layout: *const ClassLayout,
    protected_rects: []const route_mod.ProtectedRect,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
    defer_label_placement: bool,
    label_wrap_width: usize,
    ambiguous: width_mod.AmbiguousWidth,
) error{ OutOfMemory, WidthTooSmall }!void {
    const base = &layout.base;
    const src_pos = base.positions[rel.from];
    const tgt_pos = base.positions[rel.to];

    const src_top = route_mod.boxTop(base, src_pos.row);
    const src_left = route_mod.boxLeft(base, src_pos.col);
    const tgt_top = route_mod.boxTop(base, tgt_pos.row);
    const tgt_left = route_mod.boxLeft(base, tgt_pos.col);

    const src_box_h = layout.classes[rel.from].height;
    const tgt_box_h = layout.classes[rel.to].height;

    const start_row = src_top;
    const start_col = src_left + base.cell_w / 2;
    const goal_row = tgt_top + tgt_box_h;
    const goal_col = tgt_left + base.cell_w / 2;

    var route = try route_mod.routeEdgeWithPortsScratch(
        allocator,
        route_scratch,
        canvas,
        base,
        rel.from,
        rel.to,
        start_row,
        start_col,
        .up,
        goal_row,
        goal_col,
        rel.label,
        edgeStyleFor(rel.kind),
        glyphs,
        defer_label_placement,
        ambiguous,
    );
    defer route.deinit(allocator);

    if (defer_label_placement) {
        if (rel.label) |label| {
            if (label.len > 0) {
                if (route.label_path.points.len == 0) return error.WidthTooSmall;
                const placed = try route_mod.placeWrappedLabelOnRouteAnchored(
                    allocator,
                    canvas,
                    protected_rects,
                    route.label_path.points,
                    label,
                    label_wrap_width,
                    ambiguous,
                    glyphs,
                    .middle,
                );
                if (!placed) return error.WidthTooSmall;
            }
        }
    }

    switch (rel.marker_at) {
        .to => replaceArrowHeadAtBottom(canvas, tgt_top, tgt_left, tgt_box_h, base.cell_w, rel, glyphs),
        .from => replaceArrowHeadAtTop(canvas, src_top, src_left, src_box_h, base.cell_w, rel, glyphs),
    }

    if (defer_label_placement) {
        if (rel.from_cardinality) |c| try placeWrappedCardinalityLabel(
            allocator,
            canvas,
            protected_rects,
            route.label_path.points,
            c,
            label_wrap_width,
            .source,
            glyphs,
            ambiguous,
        );
        if (rel.to_cardinality) |c| try placeWrappedCardinalityLabel(
            allocator,
            canvas,
            protected_rects,
            route.label_path.points,
            c,
            label_wrap_width,
            .target,
            glyphs,
            ambiguous,
        );
    } else {
        if (rel.from_cardinality) |c| try drawCardinalityLabel(canvas, start_row, start_col, c, ambiguous, .source);
        if (rel.to_cardinality) |c| try drawCardinalityLabel(canvas, goal_row, goal_col, c, ambiguous, .target);
    }
}

const CardinalitySide = enum { source, target };

fn drawCardinalityLabel(
    canvas: *canvas_mod.Canvas,
    endpoint_row: usize,
    endpoint_col: usize,
    text: []const u8,
    ambiguous: width_mod.AmbiguousWidth,
    side: CardinalitySide,
) error{OutOfMemory}!void {
    if (text.len == 0) return;
    const text_w = width_mod.displayWidth(text, ambiguous);
    const col = endpoint_col + cardinality_label_gap;
    if (col + text_w > canvas.cols) return;

    const row = switch (side) {
        .source => if (endpoint_row == 0) return else endpoint_row - 1,
        .target => endpoint_row + 1,
    };
    if (row >= canvas.rows) return;

    try canvas.drawLabel(row, col, text, ambiguous);
}

fn placeWrappedCardinalityLabel(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    protected_rects: []const route_mod.ProtectedRect,
    path: []const route_mod.SearchKey,
    text: []const u8,
    max_width: usize,
    side: CardinalitySide,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) error{ OutOfMemory, WidthTooSmall }!void {
    if (text.len == 0) return;
    if (path.len == 0) return error.WidthTooSmall;
    const anchor: route_mod.WrappedLabelAnchor = switch (side) {
        .source => .start,
        .target => .end,
    };
    const placed = try route_mod.placeWrappedLabelOnRouteAnchored(
        allocator,
        canvas,
        protected_rects,
        path,
        text,
        max_width,
        ambiguous,
        glyphs,
        anchor,
    );
    if (!placed) return error.WidthTooSmall;
}

fn replaceArrowHeadAtBottom(
    canvas: *canvas_mod.Canvas,
    box_top: usize,
    box_left: usize,
    box_h: usize,
    cell_w: usize,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const center = box_left + cell_w / 2;

    const border_row = box_top + box_h - 1;
    if (border_row < canvas.rows and center < canvas.cols) {
        canvas.setGlyph(border_row, center, glyphs.tee_t);
    }

    const arrow_row = box_top + box_h;
    if (arrow_row < canvas.rows and center < canvas.cols) {
        canvas.setGlyph(arrow_row, center, relationHead(rel.kind, glyphs));
    }
}

fn replaceArrowHeadAtTop(
    canvas: *canvas_mod.Canvas,
    box_top: usize,
    box_left: usize,
    box_h: usize,
    cell_w: usize,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    _ = box_h;
    const center = box_left + cell_w / 2;

    if (box_top < canvas.rows and center < canvas.cols) {
        canvas.setGlyph(box_top, center, glyphs.tee_b);
    }

    if (box_top > 0 and center < canvas.cols) {
        canvas.setGlyph(box_top - 1, center, relationHead(rel.kind, glyphs));
    }
}

fn edgeStyleFor(kind: types.ClassRelationKind) types.EdgeStyle {
    return switch (kind) {
        .inheritance,
        .realization,
        .composition,
        .aggregation,
        .association,
        .dependency,
        => .arrow,
    };
}

fn relationHead(kind: types.ClassRelationKind, glyphs: *const canvas_mod.GlyphSet) u21 {
    return switch (kind) {
        .inheritance, .realization => '△',
        .composition => '◆',
        .aggregation => '◇',
        .association, .dependency => glyphs.arrow_up,
    };
}

test "paintClass renders class box with attribute type and method params" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class Animal
        \\    Animal : +str name
        \\    Animal : +save(entity) Result
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "Animal") != null);
    try std.testing.expect(std.mem.find(u8, out, "+ name: str") != null);
    try std.testing.expect(std.mem.find(u8, out, "+ save(entity): Result") != null);
}

test "paintClass collapses multi-whitespace and tabs in attribute name" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc, "classDiagram\n    class C {\n        +int retry   count\n        +bool is\tready\n    }\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "+ retry count: int") != null);
    try std.testing.expect(std.mem.find(u8, out, "+ is ready: bool") != null);
    try std.testing.expect(std.mem.find(u8, out, "retry   count") == null);
    try std.testing.expect(std.mem.find(u8, out, "is\tready") == null);
}

test "paintClass renders inheritance with triangle head" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Animal <|-- Dog
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "△") != null);
}

test "paintClass renders composition with filled diamond" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Car *-- Engine
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "◆") != null);
}

test "paintClass renders aggregation with empty diamond" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Library o-- Book
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "◇") != null);
}

test "paintClass association arrow head points toward target (upward)" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    A --> B
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "▲") != null);
    try std.testing.expect(std.mem.find(u8, out, "▼") == null);
}

test "paintClass shows literal star in abstract method type label" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class C {
        \\        +run()*
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "run(): *") != null);
}

test "paintClass wraps static member with SGR underline when enable_ansi" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\x1b[4m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[24m") != null);
}

test "paintClass wraps static and abstract method with both SGR when enable_ansi" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class C {
        \\        +run$()*
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\x1b[4m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[24m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[3m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[23m") != null);
}

test "paintClass wraps abstract method with SGR italic when enable_ansi" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class C {
        \\        +run()*
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\x1b[3m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[23m") != null);
}

test "paintClass emits no SGR when enable_ansi is false" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\        +run()*
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\x1b[") == null);
}

test "paintClass hides stripped dollar on static attribute" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "count") != null);
    try std.testing.expect(std.mem.find(u8, out, "$") == null);
}

test "paintClass separates attributes and methods with a divider" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class Animal {
        \\        +str name
        \\        +eat()
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();

    var tee_l_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.findPos(u8, out, idx, "├")) |found| {
        tee_l_count += 1;
        idx = found + "├".len;
    }
    try std.testing.expect(tee_l_count >= 2);
}

test "paintClass renders namespace frame with name" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    namespace Shapes {
        \\        class Circle
        \\        class Square
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "Shapes") != null);
    try std.testing.expect(std.mem.find(u8, out, "Circle") != null);
    try std.testing.expect(std.mem.find(u8, out, "Square") != null);
}

fn expectComputeClassBoxLayoutsHandlesAllocationFailures(allocator: std.mem.Allocator) !void {
    var customer_attrs = [_]types.ClassMember{
        .{ .visibility = .public, .name = "veryLongCustomerIdentifier", .type_text = "string", .is_static = true },
        .{ .visibility = .private, .name = "displayName", .type_text = "string" },
    };
    var customer_methods = [_]types.ClassMember{
        .{ .visibility = .public, .name = "save", .params = "entity", .type_text = "Result", .is_abstract = true },
    };
    var empty_members = [_]types.ClassMember{};
    var classes = [_]types.ClassNode{
        .{
            .id = 0,
            .id_text = "Customer",
            .label = "Customer",
            .attributes = customer_attrs[0..],
            .methods = customer_methods[0..],
        },
        .{
            .id = 1,
            .id_text = "Order",
            .label = "Order",
            .attributes = empty_members[0..],
            .methods = empty_members[0..],
        },
    };
    var relations = [_]types.ClassRelation{};
    var namespaces = [_]types.ClassNamespace{};
    var diagram: types.ClassDiagram = .{
        .allocator = allocator,
        .classes = classes[0..],
        .relations = relations[0..],
        .namespaces = namespaces[0..],
    };

    const layouts = try computeClassBoxLayouts(allocator, &diagram, 12, .narrow);
    defer deinitClassBoxLayouts(allocator, layouts);
}

test "computeClassBoxLayouts cleans up partial layouts on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expectComputeClassBoxLayoutsHandlesAllocationFailures,
        .{},
    );
}

test "drawRelation returns WidthTooSmall when deferred label has no route path" {
    const alloc = std.testing.allocator;
    var positions = [_]types.GridPos{
        .{ .row = 0, .col = 0 },
        .{ .row = 1, .col = 0 },
    };
    var node_labels = [_]types.NodeLabelLayout{};
    var empty_members = [_]MemberBoxLayout{};
    var class_layouts = [_]ClassBoxLayout{
        .{
            .name = undefined,
            .attributes = empty_members[0..],
            .methods = empty_members[0..],
            .height = empty_class_box_height,
            .max_content_width = 1,
        },
        .{
            .name = undefined,
            .attributes = empty_members[0..],
            .methods = empty_members[0..],
            .height = empty_class_box_height,
            .max_content_width = 1,
        },
    };
    var layout: ClassLayout = .{
        .base = .{
            .allocator = alloc,
            .positions = positions[0..],
            .node_labels = node_labels[0..],
            .rows = 2,
            .cols = 1,
            .cell_w = class_box_min_width,
            .cell_h = empty_class_box_height,
        },
        .classes = class_layouts[0..],
    };
    var canvas = try canvas_mod.Canvas.init(alloc, route_mod.canvasRows(&layout.base), route_mod.canvasCols(&layout.base));
    defer canvas.deinit();
    const glyphs = canvas_mod.GlyphSet.unicode;
    const protected_rects = try classProtectedRects(alloc, &layout);
    defer alloc.free(protected_rects);
    var route_scratch: route_mod.RouteScratch = .{};
    defer route_scratch.deinit(alloc);

    try std.testing.expectError(
        error.WidthTooSmall,
        drawRelation(
            alloc,
            &route_scratch,
            &canvas,
            &layout,
            protected_rects,
            .{
                .from = 0,
                .to = 1,
                .kind = .association,
                .marker_at = .to,
                .label = "must remain visible",
            },
            &glyphs,
            true,
            6,
            .narrow,
        ),
    );
}

test "paintClass marker_at from places triangle at source end" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Animal <|-- Dog
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();

    var line_iter = std.mem.splitScalar(u8, out, '\n');
    var triangle_line: ?usize = null;
    var animal_line: ?usize = null;
    var dog_line: ?usize = null;
    var idx: usize = 0;
    while (line_iter.next()) |line| : (idx += 1) {
        if (std.mem.find(u8, line, "△") != null and triangle_line == null) triangle_line = idx;
        if (std.mem.find(u8, line, "Animal") != null and animal_line == null) animal_line = idx;
        if (std.mem.find(u8, line, "Dog") != null and dog_line == null) dog_line = idx;
    }
    try std.testing.expect(triangle_line != null);
    try std.testing.expect(animal_line != null);
    try std.testing.expect(dog_line != null);

    const t = triangle_line.?;
    const a = animal_line.?;
    const d = dog_line.?;
    const dist_to_animal = if (t > a) t - a else a - t;
    const dist_to_dog = if (t > d) t - d else d - t;
    try std.testing.expect(dist_to_animal < dist_to_dog);
}

test "paintClass bare -- renders as association with arrow" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\classDiagram
        \\    A -- B
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintClass(&sink.writer, alloc, &diagram.class_, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "▲") != null);
}

test "computeClassLayout places single class at origin with rows=cols=1" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\classDiagram
        \\    class Animal
    );
    defer compiled.deinit();
    const diagram = &compiled.class_;

    var layout = try computeClassLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[0].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[0].col);
    try std.testing.expectEqual(@as(usize, 1), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.base.cols);
}

test "computeClassLayout sets outer_pad to 2 when namespaces exist" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\classDiagram
        \\    namespace Shapes {
        \\        class Circle
        \\    }
    );
    defer compiled.deinit();
    const diagram = &compiled.class_;

    var layout = try computeClassLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.base.outer_pad);
}

test "computeClassLayout stacks two-class inheritance as bottom_up rows" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Animal <|-- Dog
    );
    defer compiled.deinit();
    const diagram = &compiled.class_;

    var layout = try computeClassLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.base.cols);

    var row_set = [_]bool{ false, false };
    for (layout.base.positions) |pos| {
        try std.testing.expectEqual(@as(usize, 0), pos.col);
        try std.testing.expect(pos.row < 2);
        row_set[pos.row] = true;
    }
    try std.testing.expect(row_set[0] and row_set[1]);
}

test "computeClassLayout 1-parent 2-children branch separates siblings across columns" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Animal <|-- Dog
        \\    Animal <|-- Cat
    );
    defer compiled.deinit();
    const diagram = &compiled.class_;

    var layout = try computeClassLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 2), layout.base.cols);

    var id_animal: ?usize = null;
    var id_dog: ?usize = null;
    var id_cat: ?usize = null;
    for (diagram.classes, 0..) |cls, i| {
        if (std.mem.eql(u8, cls.id_text, "Animal")) id_animal = i;
        if (std.mem.eql(u8, cls.id_text, "Dog")) id_dog = i;
        if (std.mem.eql(u8, cls.id_text, "Cat")) id_cat = i;
    }
    try std.testing.expect(id_animal != null and id_dog != null and id_cat != null);

    try std.testing.expectEqual(@as(usize, 1), layout.base.positions[id_animal.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[id_dog.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[id_cat.?].row);

    const dog_col = layout.base.positions[id_dog.?].col;
    const cat_col = layout.base.positions[id_cat.?].col;
    try std.testing.expect(dog_col != cat_col);
    try std.testing.expect(dog_col < 2 and cat_col < 2);
}

test "computeClassLayout 2-parents 1-child merge stacks parents in bottom row" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\classDiagram
        \\    Vehicle <|-- Car
        \\    Trackable <|-- Car
    );
    defer compiled.deinit();
    const diagram = &compiled.class_;

    var layout = try computeClassLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 2), layout.base.cols);

    var id_vehicle: ?usize = null;
    var id_trackable: ?usize = null;
    var id_car: ?usize = null;
    for (diagram.classes, 0..) |cls, i| {
        if (std.mem.eql(u8, cls.id_text, "Vehicle")) id_vehicle = i;
        if (std.mem.eql(u8, cls.id_text, "Trackable")) id_trackable = i;
        if (std.mem.eql(u8, cls.id_text, "Car")) id_car = i;
    }
    try std.testing.expect(id_vehicle != null and id_trackable != null and id_car != null);

    try std.testing.expectEqual(@as(usize, 1), layout.base.positions[id_vehicle.?].row);
    try std.testing.expectEqual(@as(usize, 1), layout.base.positions[id_trackable.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[id_car.?].row);

    const v_col = layout.base.positions[id_vehicle.?].col;
    const t_col = layout.base.positions[id_trackable.?].col;
    try std.testing.expect(v_col != t_col);
    try std.testing.expect(v_col < 2 and t_col < 2);
}
