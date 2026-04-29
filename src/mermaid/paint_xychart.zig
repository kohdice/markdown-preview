const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const compile_mod = @import("compile.zig");
const ansi_mod = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    UnsupportedFeature,
    WidthTooSmall,
    OutOfMemory,
    WriteFailed,
};

pub const Options = struct {
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
    enable_ansi: bool,
    use_ascii: bool = false,
    color_mode: ansi_mod.ColorMode = .truecolor,
};

fn seriesRole(idx: usize) u8 {
    return @as(u8, @intCast(idx & 0x07));
}

const PLOT_ROWS: usize = 20;
const MAX_SERIES_POINTS: usize = 1024;

const PLOT_WIDTH_MIN: usize = 60;
const BAND_MIN_WIDTH: usize = 6;
const BAR_WIDTH_MAX: usize = 8;
const YPAD_FRACTION: f64 = 0.10;
const YFLOOR_TRIGGER: f64 = 0.5;
const AUTORANGE_FALLBACK_MAX: f64 = 100;
const TICK_TARGET: usize = 6;

pub const XyGlyphs = struct {
    h_line: u21,
    v_line: u21,
    origin: u21,
    y_tick: u21,
    x_tick: u21,
    bar: u21,
    grid: u21,
    corner_tl: u21,
    corner_tr: u21,
    corner_bl: u21,
    corner_br: u21,
};

pub const UNICODE_GLYPHS: XyGlyphs = .{
    .h_line = '─',
    .v_line = '│',
    .origin = '┼',
    .y_tick = '┤',
    .x_tick = '┬',
    .bar = '█',
    .grid = '·',
    .corner_tl = '╭',
    .corner_tr = '╮',
    .corner_bl = '╰',
    .corner_br = '╯',
};

pub const ASCII_GLYPHS: XyGlyphs = .{
    .h_line = '-',
    .v_line = '|',
    .origin = '+',
    .y_tick = '+',
    .x_tick = '+',
    .bar = '#',
    .grid = '.',
    .corner_tl = '+',
    .corner_tr = '+',
    .corner_bl = '+',
    .corner_br = '+',
};

pub fn paintXyChart(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    chart_ptr: *const types.XyChart,
    opts: Options,
) RenderError!void {
    const chart = chart_ptr.*;

    for (chart.series) |s| {
        if (s.data.len > MAX_SERIES_POINTS) return error.UnsupportedFeature;
    }

    if (chart.orientation == .horizontal) {
        return writeHorizontal(writer, allocator, &chart, opts);
    }
    return writeVertical(writer, allocator, &chart, opts);
}

fn writeVertical(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    chart: *const types.XyChart,
    opts: Options,
) RenderError!void {
    const xy: XyGlyphs = if (opts.use_ascii) ASCII_GLYPHS else UNICODE_GLYPHS;
    const yr = computeYRange(chart);
    const has_x_labels = chart.x_axis.kind == .category and chart.x_axis.categories.len > 0;
    const has_legend = chart.series.len >= 2;

    const tick_values = niceTickValues(allocator, yr.min, yr.max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tick_values);

    const tick_bufs = allocator.alloc([24]u8, tick_values.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tick_bufs);
    const tick_strs = allocator.alloc([]const u8, tick_values.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tick_strs);

    var max_tick_w: usize = 0;
    for (tick_values, 0..) |t, i| {
        tick_strs[i] = formatTickValue(&tick_bufs[i], t);
        const w = width_mod.displayWidth(tick_strs[i], opts.ambiguous_width);
        if (w > max_tick_w) max_tick_w = w;
    }

    var n_bar_series: usize = 0;
    for (chart.series) |s| {
        if (s.kind == .bar) n_bar_series += 1;
    }

    const title_rows: usize = if (chart.title != null) 2 else 0;
    const x_label_rows: usize = if (has_x_labels) 1 else 0;
    const legend_rows: usize = if (has_legend) 1 else 0;
    const has_x_title = chart.x_axis.title != null;
    const x_title_rows: usize = if (has_x_title) 1 else 0;
    const y_label_cols: usize = max_tick_w + 1;
    const y_axis_col = y_label_cols;
    const plot_left = y_axis_col + 1;

    const data_count = dataCountFor(chart);
    const plot_w: usize = @max(PLOT_WIDTH_MIN, data_count * BAND_MIN_WIDTH);
    const band_w: usize = plot_w / data_count;

    const canvas_rows = title_rows + legend_rows + PLOT_ROWS + 1 + x_label_rows + x_title_rows;
    const canvas_cols = plot_left + band_w * data_count + 2;

    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const plot_top = title_rows + legend_rows;
    const plot_bottom = plot_top + PLOT_ROWS - 1;
    const axis_row = plot_top + PLOT_ROWS;

    if (chart.title) |t| try canvas.drawLabel(0, 0, t, opts.ambiguous_width);

    var r: usize = plot_top;
    while (r <= plot_bottom) : (r += 1) canvas.setGlyph(r, y_axis_col, xy.v_line);
    canvas.setGlyph(axis_row, y_axis_col, xy.origin);
    var c: usize = plot_left;
    while (c < plot_left + band_w * data_count) : (c += 1) canvas.setGlyph(axis_row, c, xy.h_line);

    if (chart.x_axis.kind == .category and chart.x_axis.categories.len > 0) {
        var ci: usize = 0;
        while (ci < chart.x_axis.categories.len) : (ci += 1) {
            const tick_col = plot_left + ci * band_w + band_w / 2;
            canvas.setGlyph(axis_row, tick_col, xy.x_tick);
        }
    }

    for (tick_values, 0..) |t, i| {
        const tick_row = yPosForValue(t, yr, plot_bottom);
        const tick_w = width_mod.displayWidth(tick_strs[i], opts.ambiguous_width);
        try canvas.drawLabel(tick_row, max_tick_w - tick_w, tick_strs[i], opts.ambiguous_width);
        canvas.setGlyph(tick_row, y_axis_col, xy.y_tick);
    }

    var bar_idx: usize = 0;
    var line_idx: usize = 0;
    for (chart.series, 0..) |series, series_idx| {
        const n = series.data.len;
        const role = seriesRole(series_idx);
        if (n == 0) {
            if (series.kind == .bar) bar_idx += 1 else line_idx += 1;
            continue;
        }
        switch (series.kind) {
            .bar => {
                for (series.data, 0..) |v, i| {
                    const row = yPosForValue(v, yr, plot_bottom);
                    const span = barColSpan(chart, i, n, n_bar_series, bar_idx, plot_left, band_w, plot_w);
                    var bc = span.start;
                    while (bc < span.end) : (bc += 1) {
                        var br = row;
                        while (br <= plot_bottom) : (br += 1) canvas.setGlyphRole(br, bc, xy.bar, role);
                    }
                }
                bar_idx += 1;
            },
            .line => {
                drawStaircaseLine(&canvas, chart, series.data, yr, plot_left, plot_bottom, band_w, plot_w, &xy, role);
                line_idx += 1;
            },
        }
    }

    for (tick_values) |t| {
        const tick_row = yPosForValue(t, yr, plot_bottom);
        var gc: usize = plot_left;
        while (gc < plot_left + band_w * data_count) : (gc += 1) {
            const cell = canvas.cells[tick_row * canvas.cols + gc];
            if (cell.kind == .glyph and cell.cp == ' ') {
                canvas.setGlyph(tick_row, gc, xy.grid);
            }
        }
    }

    if (has_x_labels) {
        const label_row = axis_row + 1;
        for (chart.x_axis.categories, 0..) |label, i| {
            const slot_start = plot_left + i * band_w;
            try canvas.drawLabel(label_row, slot_start, label, opts.ambiguous_width);
        }
    }

    if (has_x_title) {
        const x_title = chart.x_axis.title.?;
        const x_title_row = axis_row + 1 + x_label_rows;
        const x_title_w = width_mod.displayWidth(x_title, opts.ambiguous_width);
        const x_title_start: usize = if (canvas_cols > x_title_w) (canvas_cols - x_title_w) / 2 else 0;
        try canvas.drawLabel(x_title_row, x_title_start, x_title, opts.ambiguous_width);
    }

    if (has_legend) {
        const legend_row: usize = if (chart.title != null) 1 else 0;
        const legend_w = computeLegendWidth(chart, opts.ambiguous_width);
        const legend_start: usize = if (canvas_cols > legend_w) (canvas_cols - legend_w) / 2 else 0;
        try drawLegend(&canvas, legend_row, legend_start, chart, opts.ambiguous_width, &xy);
    }

    if (opts.enable_ansi and chart.series.len > 0) {
        canvas_mod.writeCanvasAnsi(writer, &canvas, opts.wrap_width, opts.ambiguous_width, &theme.default_series_palette, opts.color_mode) catch return error.WriteFailed;
    } else {
        canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
    }
}

fn writeHorizontal(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    chart: *const types.XyChart,
    opts: Options,
) RenderError!void {
    const xy: XyGlyphs = if (opts.use_ascii) ASCII_GLYPHS else UNICODE_GLYPHS;
    const yr = computeYRange(chart);
    const has_x_labels = chart.x_axis.kind == .category and chart.x_axis.categories.len > 0;
    const has_legend = chart.series.len >= 2;
    const has_x_title = chart.x_axis.title != null;
    const has_y_title = chart.y_axis.title != null;
    const data_count = dataCountFor(chart);

    const tick_values = niceTickValues(allocator, yr.min, yr.max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tick_values);

    const tick_bufs = allocator.alloc([24]u8, tick_values.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tick_bufs);
    const tick_strs = allocator.alloc([]const u8, tick_values.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(tick_strs);
    for (tick_values, 0..) |t, i| {
        tick_strs[i] = formatTickValue(&tick_bufs[i], t);
    }

    var max_cat_w: usize = 0;
    if (has_x_labels) {
        for (chart.x_axis.categories) |cat| {
            const w = width_mod.displayWidth(cat, opts.ambiguous_width);
            if (w > max_cat_w) max_cat_w = w;
        }
    }

    const title_rows: usize = if (chart.title != null) 2 else 0;
    const legend_rows: usize = if (has_legend) 1 else 0;
    const tick_label_rows: usize = 1;
    const x_title_rows: usize = if (has_x_title) 1 else 0;
    const y_title_rows: usize = if (has_y_title) 1 else 0;
    const cat_label_cols: usize = if (has_x_labels) max_cat_w + 1 else 0;
    const y_axis_col: usize = cat_label_cols;
    const plot_left: usize = y_axis_col + 1;
    const plot_w: usize = PLOT_WIDTH_MIN;

    const canvas_rows = title_rows + legend_rows + PLOT_ROWS + 1 + tick_label_rows + x_title_rows + y_title_rows;
    const canvas_cols = plot_left + plot_w + 2;

    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const plot_top = title_rows + legend_rows;
    const plot_bottom = plot_top + PLOT_ROWS - 1;
    const axis_row = plot_top + PLOT_ROWS;
    const tick_label_row = axis_row + 1;

    if (chart.title) |t| try canvas.drawLabel(0, 0, t, opts.ambiguous_width);

    var r: usize = plot_top;
    while (r <= plot_bottom) : (r += 1) canvas.setGlyph(r, y_axis_col, xy.v_line);
    canvas.setGlyph(axis_row, y_axis_col, xy.origin);
    var c: usize = plot_left;
    while (c < plot_left + plot_w) : (c += 1) canvas.setGlyph(axis_row, c, xy.h_line);

    for (tick_values) |t| {
        const col = tickColHorizontal(t, yr, plot_left, plot_w);
        canvas.setGlyph(axis_row, col, xy.x_tick);
    }

    if (has_x_labels) {
        for (chart.x_axis.categories, 0..) |_, i| {
            const row = bandRowHorizontal(i, data_count, plot_top);
            canvas.setGlyph(row, y_axis_col, xy.y_tick);
        }
    }

    for (tick_values, 0..) |t, i| {
        const col = tickColHorizontal(t, yr, plot_left, plot_w);
        const tick_w = width_mod.displayWidth(tick_strs[i], opts.ambiguous_width);
        const start_col: usize = if (col >= tick_w / 2) col - tick_w / 2 else 0;
        try canvas.drawLabel(tick_label_row, start_col, tick_strs[i], opts.ambiguous_width);
    }

    if (has_x_labels) {
        for (chart.x_axis.categories, 0..) |cat, i| {
            const row = bandRowHorizontal(i, data_count, plot_top);
            const cat_w = width_mod.displayWidth(cat, opts.ambiguous_width);
            const start: usize = if (y_axis_col > cat_w) y_axis_col - cat_w else 0;
            try canvas.drawLabel(row, start, cat, opts.ambiguous_width);
        }
    }

    for (chart.series, 0..) |series, series_idx| {
        const n = series.data.len;
        if (n == 0) continue;
        const role = seriesRole(series_idx);
        switch (series.kind) {
            .bar => {
                for (series.data, 0..) |v, i| {
                    const row = bandRowHorizontal(i, data_count, plot_top);
                    const frac = computeFrac(v, yr);
                    const length: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(plot_w - 1))));
                    var bc: usize = plot_left;
                    const end = plot_left + length + 1;
                    while (bc < end) : (bc += 1) canvas.setGlyphRole(row, bc, xy.bar, role);
                }
            },
            .line => {
                drawHorizontalStaircaseLine(&canvas, series.data, yr, plot_top, plot_left, plot_w, data_count, &xy, role);
            },
        }
    }

    for (tick_values) |t| {
        const col = tickColHorizontal(t, yr, plot_left, plot_w);
        var gr: usize = plot_top;
        while (gr <= plot_bottom) : (gr += 1) {
            const cell = canvas.cells[gr * canvas.cols + col];
            if (cell.kind == .glyph and cell.cp == ' ') {
                canvas.setGlyph(gr, col, xy.grid);
            }
        }
    }

    if (has_legend) {
        const legend_row: usize = if (chart.title != null) 1 else 0;
        const legend_w = computeLegendWidth(chart, opts.ambiguous_width);
        const legend_start: usize = if (canvas_cols > legend_w) (canvas_cols - legend_w) / 2 else 0;
        try drawLegend(&canvas, legend_row, legend_start, chart, opts.ambiguous_width, &xy);
    }

    if (has_x_title) {
        const x_title = chart.x_axis.title.?;
        const x_title_row = tick_label_row + 1;
        const x_title_w = width_mod.displayWidth(x_title, opts.ambiguous_width);
        const x_title_start: usize = if (canvas_cols > x_title_w) (canvas_cols - x_title_w) / 2 else 0;
        try canvas.drawLabel(x_title_row, x_title_start, x_title, opts.ambiguous_width);
    }

    if (has_y_title) {
        const y_title = chart.y_axis.title.?;
        const y_title_row = canvas_rows - 1;
        const y_title_w = width_mod.displayWidth(y_title, opts.ambiguous_width);
        const y_title_start: usize = if (canvas_cols > y_title_w) (canvas_cols - y_title_w) / 2 else 0;
        try canvas.drawLabel(y_title_row, y_title_start, y_title, opts.ambiguous_width);
    }

    if (opts.enable_ansi and chart.series.len > 0) {
        canvas_mod.writeCanvasAnsi(writer, &canvas, opts.wrap_width, opts.ambiguous_width, &theme.default_series_palette, opts.color_mode) catch return error.WriteFailed;
    } else {
        canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
    }
}

fn tickColHorizontal(v: f64, yr: YRange, plot_left: usize, plot_w: usize) usize {
    const frac = computeFrac(v, yr);
    const offset: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(plot_w - 1))));
    return plot_left + offset;
}

fn bandRowHorizontal(i: usize, data_count: usize, plot_top: usize) usize {
    return plot_top + (i * PLOT_ROWS + PLOT_ROWS / 2) / data_count;
}

fn drawHorizontalStaircaseLine(
    canvas: *canvas_mod.Canvas,
    data: []const f64,
    yr: YRange,
    plot_top: usize,
    plot_left: usize,
    plot_w: usize,
    data_count: usize,
    xy: *const XyGlyphs,
    role: u8,
) void {
    const n = data.len;
    if (n == 0) return;
    if (n == 1) {
        const row = bandRowHorizontal(0, data_count, plot_top);
        const col = tickColHorizontal(data[0], yr, plot_left, plot_w);
        canvas.setGlyphRole(row, col, xy.v_line, role);
        return;
    }

    for (data, 0..) |v, pi| {
        const row = bandRowHorizontal(pi, data_count, plot_top);
        const col = tickColHorizontal(v, yr, plot_left, plot_w);
        canvas.setGlyphRole(row, col, xy.v_line, role);
    }

    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const r1 = bandRowHorizontal(i, data_count, plot_top);
        const r2 = bandRowHorizontal(i + 1, data_count, plot_top);
        const c1 = tickColHorizontal(data[i], yr, plot_left, plot_w);
        const c2 = tickColHorizontal(data[i + 1], yr, plot_left, plot_w);

        if (c1 == c2) {
            var r: usize = r1 + 1;
            while (r < r2) : (r += 1) canvas.setGlyphRole(r, c1, xy.v_line, role);
            continue;
        }

        const mid_row = (r1 + r2 + 1) / 2;
        var r: usize = r1 + 1;
        while (r < mid_row) : (r += 1) canvas.setGlyphRole(r, c1, xy.v_line, role);

        if (c2 > c1) {
            canvas.setGlyphRole(mid_row, c1, xy.corner_bl, role);
            canvas.setGlyphRole(mid_row, c2, xy.corner_tr, role);
            var hc: usize = c1 + 1;
            while (hc < c2) : (hc += 1) canvas.setGlyphRole(mid_row, hc, xy.h_line, role);
        } else {
            canvas.setGlyphRole(mid_row, c1, xy.corner_br, role);
            canvas.setGlyphRole(mid_row, c2, xy.corner_tl, role);
            var hc: usize = c2 + 1;
            while (hc < c1) : (hc += 1) canvas.setGlyphRole(mid_row, hc, xy.h_line, role);
        }

        r = mid_row + 1;
        while (r < r2) : (r += 1) canvas.setGlyphRole(r, c2, xy.v_line, role);
    }

    const first_r1 = bandRowHorizontal(0, data_count, plot_top);
    const first_r2 = bandRowHorizontal(1, data_count, plot_top);
    const first_c = tickColHorizontal(data[0], yr, plot_left, plot_w);
    const lead_extend = (first_r2 - first_r1) / 4;
    if (lead_extend > 0 and first_r1 > lead_extend) {
        var r: usize = first_r1 - lead_extend;
        while (r < first_r1) : (r += 1) canvas.setGlyphRole(r, first_c, xy.v_line, role);
    }

    const last_r1 = bandRowHorizontal(n - 2, data_count, plot_top);
    const last_r2 = bandRowHorizontal(n - 1, data_count, plot_top);
    const last_c = tickColHorizontal(data[n - 1], yr, plot_left, plot_w);
    const trail_extend = (last_r2 - last_r1) / 4;
    var tr: usize = last_r2 + 1;
    const tr_end = last_r2 + trail_extend + 1;
    while (tr < tr_end) : (tr += 1) canvas.setGlyphRole(tr, last_c, xy.v_line, role);
}

fn computeLegendWidth(chart: *const types.XyChart, ambiguous: width_mod.AmbiguousWidth) usize {
    var total: usize = 0;
    var bar_n: usize = 0;
    var line_n: usize = 0;
    var count: usize = 0;
    for (chart.series) |series| {
        var buf: [32]u8 = undefined;
        const name = switch (series.kind) {
            .bar => blk: {
                bar_n += 1;
                break :blk std.fmt.bufPrint(&buf, "Bar {d}", .{bar_n}) catch "";
            },
            .line => blk: {
                line_n += 1;
                break :blk std.fmt.bufPrint(&buf, "Line {d}", .{line_n}) catch "";
            },
        };
        total += 2 + width_mod.displayWidth(name, ambiguous);
        count += 1;
    }
    if (count > 1) total += (count - 1) * 2;
    return total;
}

fn drawLegend(
    canvas: *canvas_mod.Canvas,
    row: usize,
    start_col: usize,
    chart: *const types.XyChart,
    ambiguous: width_mod.AmbiguousWidth,
    xy: *const XyGlyphs,
) error{OutOfMemory}!void {
    var col = start_col;
    var bar_n: usize = 0;
    var line_n: usize = 0;
    for (chart.series, 0..) |series, series_idx| {
        if (col >= canvas.cols) return;
        const g: u21 = switch (series.kind) {
            .bar => xy.bar,
            .line => xy.h_line,
        };
        canvas.setGlyphRole(row, col, g, seriesRole(series_idx));
        col += 2;
        var buf: [32]u8 = undefined;
        const name = switch (series.kind) {
            .bar => blk: {
                bar_n += 1;
                break :blk std.fmt.bufPrint(&buf, "Bar {d}", .{bar_n}) catch "";
            },
            .line => blk: {
                line_n += 1;
                break :blk std.fmt.bufPrint(&buf, "Line {d}", .{line_n}) catch "";
            },
        };
        try canvas.drawLabel(row, col, name, ambiguous);
        col += width_mod.displayWidth(name, ambiguous) + 2;
    }
}

const YRange = struct { min: f64, max: f64 };

fn computeYRange(chart: *const types.XyChart) YRange {
    if (chart.y_axis.has_explicit_range) {
        return .{ .min = chart.y_axis.numeric_min, .max = chart.y_axis.numeric_max };
    }
    var min: f64 = 0;
    var max: f64 = 0;
    var any = false;
    for (chart.series) |s| {
        for (s.data) |v| {
            if (!any) {
                min = v;
                max = v;
                any = true;
            } else {
                if (v < min) min = v;
                if (v > max) max = v;
            }
        }
    }
    if (!any) return .{ .min = 0, .max = AUTORANGE_FALLBACK_MAX };
    const span: f64 = if (max > min) max - min else 1;
    min -= span * YPAD_FRACTION;
    max += span * YPAD_FRACTION;
    if (min > 0 and min < span * YFLOOR_TRIGGER) min = 0;
    return .{ .min = min, .max = max };
}

fn computeFrac(v: f64, yr: YRange) f64 {
    const span = yr.max - yr.min;
    const frac = if (span > 0) (v - yr.min) / span else 0.5;
    return std.math.clamp(frac, 0.0, 1.0);
}

fn yPosForValue(v: f64, yr: YRange, plot_bottom: usize) usize {
    const steps: f64 = @floatFromInt(PLOT_ROWS - 1);
    const offset: usize = @intFromFloat(@round(computeFrac(v, yr) * steps));
    return plot_bottom - offset;
}

pub fn niceTickValues(allocator: std.mem.Allocator, min: f64, max: f64) error{OutOfMemory}![]f64 {
    var list: std.ArrayList(f64) = .empty;
    errdefer list.deinit(allocator);

    const span = max - min;
    if (span <= 0) {
        try list.append(allocator, min);
        return list.toOwnedSlice(allocator);
    }

    const raw_interval = span / @as(f64, @floatFromInt(TICK_TARGET));
    const magnitude = std.math.pow(f64, 10, @floor(std.math.log10(raw_interval)));
    const residual = raw_interval / magnitude;

    const nice_interval = if (residual <= 1.5)
        magnitude
    else if (residual <= 3)
        2 * magnitude
    else if (residual <= 7)
        5 * magnitude
    else
        10 * magnitude;

    const start = @ceil(min / nice_interval) * nice_interval;
    const tolerance = nice_interval * 0.001;

    var v = start;
    while (v <= max + tolerance) : (v += nice_interval) {
        const rounded = @round(v * 1e10) / 1e10;
        try list.append(allocator, rounded);
    }

    return list.toOwnedSlice(allocator);
}

pub fn formatTickValue(buf: []u8, v: f64) []const u8 {
    if (v == @floor(v)) {
        return std.fmt.bufPrint(buf, "{d}", .{v}) catch buf[0..0];
    }
    if (@abs(v) < 10) {
        return std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch buf[0..0];
}

fn dataCountFor(chart: *const types.XyChart) usize {
    if (chart.x_axis.kind == .category and chart.x_axis.categories.len > 0) {
        return chart.x_axis.categories.len;
    }
    var max_n: usize = 0;
    for (chart.series) |s| {
        if (s.data.len > max_n) max_n = s.data.len;
    }
    return @max(@as(usize, 1), max_n);
}

fn drawStaircaseLine(
    canvas: *canvas_mod.Canvas,
    chart: *const types.XyChart,
    data: []const f64,
    yr: YRange,
    plot_left: usize,
    plot_bottom: usize,
    band_w: usize,
    plot_w: usize,
    xy: *const XyGlyphs,
    role: u8,
) void {
    const n = data.len;
    if (n == 0) return;
    if (n == 1) {
        const col = lineColVertical(chart, 0, 1, plot_left, band_w, plot_w);
        const row = yPosForValue(data[0], yr, plot_bottom);
        canvas.setGlyphRole(row, col, xy.h_line, role);
        return;
    }

    for (data, 0..) |v, pi| {
        const col = lineColVertical(chart, pi, n, plot_left, band_w, plot_w);
        const row = yPosForValue(v, yr, plot_bottom);
        canvas.setGlyphRole(row, col, xy.h_line, role);
    }

    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const c1 = lineColVertical(chart, i, n, plot_left, band_w, plot_w);
        const c2 = lineColVertical(chart, i + 1, n, plot_left, band_w, plot_w);
        const r1 = yPosForValue(data[i], yr, plot_bottom);
        const r2 = yPosForValue(data[i + 1], yr, plot_bottom);

        if (r1 == r2) {
            var c: usize = c1 + 1;
            while (c < c2) : (c += 1) canvas.setGlyphRole(r1, c, xy.h_line, role);
            continue;
        }

        const mid_col = (c1 + c2 + 1) / 2;
        var c: usize = c1 + 1;
        while (c < mid_col) : (c += 1) canvas.setGlyphRole(r1, c, xy.h_line, role);

        if (r2 < r1) {
            canvas.setGlyphRole(r1, mid_col, xy.corner_br, role);
            canvas.setGlyphRole(r2, mid_col, xy.corner_tl, role);
            var vr: usize = r2 + 1;
            while (vr < r1) : (vr += 1) canvas.setGlyphRole(vr, mid_col, xy.v_line, role);
        } else {
            canvas.setGlyphRole(r1, mid_col, xy.corner_tr, role);
            canvas.setGlyphRole(r2, mid_col, xy.corner_bl, role);
            var vr: usize = r1 + 1;
            while (vr < r2) : (vr += 1) canvas.setGlyphRole(vr, mid_col, xy.v_line, role);
        }

        c = mid_col + 1;
        while (c < c2) : (c += 1) canvas.setGlyphRole(r2, c, xy.h_line, role);
    }

    const first_c1 = lineColVertical(chart, 0, n, plot_left, band_w, plot_w);
    const first_c2 = lineColVertical(chart, 1, n, plot_left, band_w, plot_w);
    const first_r = yPosForValue(data[0], yr, plot_bottom);
    const lead_extend = (first_c2 - first_c1) / 4;
    if (lead_extend > 0 and first_c1 > lead_extend) {
        var c: usize = first_c1 - lead_extend;
        while (c < first_c1) : (c += 1) canvas.setGlyphRole(first_r, c, xy.h_line, role);
    }

    const last_c1 = lineColVertical(chart, n - 2, n, plot_left, band_w, plot_w);
    const last_c2 = lineColVertical(chart, n - 1, n, plot_left, band_w, plot_w);
    const last_r = yPosForValue(data[n - 1], yr, plot_bottom);
    const trail_extend = (last_c2 - last_c1) / 4;
    var tc: usize = last_c2 + 1;
    const tc_end = last_c2 + trail_extend + 1;
    while (tc < tc_end) : (tc += 1) canvas.setGlyphRole(last_r, tc, xy.h_line, role);
}

const BarSpan = struct { start: usize, end: usize };

fn barColSpan(
    chart: *const types.XyChart,
    i: usize,
    n: usize,
    n_bar_series: usize,
    bar_idx: usize,
    plot_left: usize,
    band_w: usize,
    plot_w: usize,
) BarSpan {
    if (chart.x_axis.kind == .category and chart.x_axis.categories.len > 0) {
        const n_cats = chart.x_axis.categories.len;
        std.debug.assert(i < n_cats);
        const bar_count = @max(@as(usize, 1), n_bar_series);
        const usable: usize = if (band_w >= 3) band_w - 2 else 1;
        const single_bar_w = @max(@as(usize, 1), @min(usable / bar_count, BAR_WIDTH_MAX));
        const group_w = single_bar_w * bar_count + (bar_count - 1);
        const cx = plot_left + i * band_w + band_w / 2;
        const group_left = if (cx >= group_w / 2) cx - group_w / 2 else 0;
        const bx = group_left + bar_idx * (single_bar_w + 1);
        return .{ .start = bx, .end = bx + single_bar_w };
    }
    const center = if (n <= 1) plot_left else plot_left + i * (plot_w - 1) / (n - 1);
    return .{ .start = center, .end = center + 1 };
}

fn lineColVertical(
    chart: *const types.XyChart,
    i: usize,
    n: usize,
    plot_left: usize,
    band_w: usize,
    plot_w: usize,
) usize {
    if (chart.x_axis.kind == .category and chart.x_axis.categories.len > 0) {
        const n_cats = chart.x_axis.categories.len;
        std.debug.assert(i < n_cats);
        return plot_left + i * band_w + band_w / 2;
    }
    if (n <= 1) return plot_left;
    return plot_left + i * (plot_w - 1) / (n - 1);
}

fn renderToString(allocator: std.mem.Allocator, chart: *const types.XyChart) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(allocator);
    errdefer sink.deinit();
    try paintXyChart(&sink.writer, allocator, chart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });
    return sink.toOwnedSlice();
}

test "niceTickValues(0, 10) yields [0, 2, 4, 6, 8, 10]" {
    const ticks = try niceTickValues(std.testing.allocator, 0, 10);
    defer std.testing.allocator.free(ticks);
    try std.testing.expectEqual(@as(usize, 6), ticks.len);
    try std.testing.expectEqual(@as(f64, 0), ticks[0]);
    try std.testing.expectEqual(@as(f64, 2), ticks[1]);
    try std.testing.expectEqual(@as(f64, 4), ticks[2]);
    try std.testing.expectEqual(@as(f64, 6), ticks[3]);
    try std.testing.expectEqual(@as(f64, 8), ticks[4]);
    try std.testing.expectEqual(@as(f64, 10), ticks[5]);
}

test "niceTickValues(0, 100) yields [0, 20, 40, 60, 80, 100]" {
    const ticks = try niceTickValues(std.testing.allocator, 0, 100);
    defer std.testing.allocator.free(ticks);
    try std.testing.expectEqual(@as(usize, 6), ticks.len);
    try std.testing.expectEqual(@as(f64, 0), ticks[0]);
    try std.testing.expectEqual(@as(f64, 20), ticks[1]);
    try std.testing.expectEqual(@as(f64, 40), ticks[2]);
    try std.testing.expectEqual(@as(f64, 60), ticks[3]);
    try std.testing.expectEqual(@as(f64, 80), ticks[4]);
    try std.testing.expectEqual(@as(f64, 100), ticks[5]);
}

test "niceTickValues(0, 6) yields [0, 1, 2, 3, 4, 5, 6]" {
    const ticks = try niceTickValues(std.testing.allocator, 0, 6);
    defer std.testing.allocator.free(ticks);
    try std.testing.expectEqual(@as(usize, 7), ticks.len);
    try std.testing.expectEqual(@as(f64, 0), ticks[0]);
    try std.testing.expectEqual(@as(f64, 6), ticks[6]);
}

test "niceTickValues(-5, 5) spans negative and positive, includes 0" {
    const ticks = try niceTickValues(std.testing.allocator, -5, 5);
    defer std.testing.allocator.free(ticks);
    try std.testing.expect(ticks.len >= 5);
    try std.testing.expect(ticks[0] >= -5);
    try std.testing.expect(ticks[ticks.len - 1] <= 5);
    var found_zero = false;
    for (ticks) |t| {
        if (t == 0) found_zero = true;
    }
    try std.testing.expect(found_zero);
}

test "niceTickValues(0, 0.5) yields sub-integer ticks" {
    const ticks = try niceTickValues(std.testing.allocator, 0, 0.5);
    defer std.testing.allocator.free(ticks);
    try std.testing.expect(ticks.len >= 5);
    for (ticks) |t| try std.testing.expect(t <= 1.0);
}

test "formatTickValue(10) returns \"10\"" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("10", formatTickValue(&buf, 10));
}

test "formatTickValue(10.5) rounds to \"11\" via toFixed(0)" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("11", formatTickValue(&buf, 10.5));
}

test "formatTickValue(1.5) returns \"1.5\"" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", formatTickValue(&buf, 1.5));
}

test "formatTickValue(0) returns \"0\"" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTickValue(&buf, 0));
}

test "formatTickValue(100) returns \"100\"" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("100", formatTickValue(&buf, 100));
}

test "formatTickValue(99.7) rounds up to \"100\"" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("100", formatTickValue(&buf, 99.7));
}

test "paintXyChart renders empty chart (title only) as bare plot frame" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\title "Demo"
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "─") != null);
}

test "paintXyChart renders vertical bar chart with category x-axis" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "█") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") != null);
}

test "paintXyChart renders vertical line chart across 4 data points" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 2, 3, 4]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╯") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") != null);
}

test "paintXyChart places title text on the top row" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\title "Hello"
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    const nl = std.mem.indexOfScalar(u8, out, '\n') orelse out.len;
    try std.testing.expectEqualStrings("Hello", out[0..nl]);
}

test "paintXyChart falls back to 0..100 range when no series present" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\title "T"
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "100") != null);
}

test "paintXyChart pads auto-range for bar [50, 100] to span 45..105" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [50, 100]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "100") != null);
}

test "paintXyChart does not floor auto-range when min >= span * 0.5" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "0") == null);
}

test "paintXyChart preserves negative values in auto-range for bar [-10, 10]" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [-10, 10]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-10") != null);
}

test "paintXyChart emits y-axis nice tick labels for explicit range 0-->100" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\y-axis 0 --> 100
        \\bar [50]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "40") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "100") != null);
}

test "paintXyChart does not emit old fixed-interval tick labels for 0-->100" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\y-axis 0 --> 100
        \\bar [50]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "33.3") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "66.7") == null);
}

test "paintXyChart does not clip overlong category labels with ellipsis" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis ["VeryLongCategoryLabel1", "B", "C"]
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "…") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "VeryLongCategoryLab") != null);
}

test "paintXyChart renders x-axis title below category labels" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis "Months" [Jan, Feb]
        \\bar [1, 2]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    const jan_pos = std.mem.indexOf(u8, out, "Jan") orelse return error.TestUnexpectedResult;
    const months_pos = std.mem.indexOf(u8, out, "Months") orelse return error.TestUnexpectedResult;
    try std.testing.expect(months_pos > jan_pos);
}

test "paintXyChart adds exactly one row for x-axis title vs no title" {
    var titled_diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis "Months" [a, b]
        \\bar [1, 2]
    );
    defer titled_diagram.deinit();
    const titled = try renderToString(std.testing.allocator, &titled_diagram.xychart);
    defer std.testing.allocator.free(titled);

    var untitled_diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
        \\bar [1, 2]
    );
    defer untitled_diagram.deinit();
    const untitled = try renderToString(std.testing.allocator, &untitled_diagram.xychart);
    defer std.testing.allocator.free(untitled);

    const titled_nl = std.mem.count(u8, titled, "\n");
    const untitled_nl = std.mem.count(u8, untitled, "\n");
    try std.testing.expectEqual(untitled_nl + 1, titled_nl);
}

test "paintXyChart horizontal renders y-axis title on last row" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\y-axis "Revenue" 0 --> 100
        \\bar [10, 20, 30]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    const trimmed = std.mem.trimEnd(u8, out, "\n");
    const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
    const last_line = if (nl) |i| trimmed[i + 1 ..] else trimmed;
    try std.testing.expect(std.mem.indexOf(u8, last_line, "Revenue") != null);
}

test "paintXyChart auto-ranges y-axis from series data when range absent" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [5, 10, 15]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "16") != null);
}

test "paintXyChart differentiates two line series with ascending and descending staircase" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 2, 3]
        \\line [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╯") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╰") != null);
}

test "paintXyChart horizontal places category labels on the left of y-axis" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis [alpha, beta, gamma]
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gamma") != null);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const alpha_byte = std.mem.indexOf(u8, line, "alpha") orelse continue;
        const axis_byte = std.mem.indexOf(u8, line, "┼") orelse std.mem.indexOf(u8, line, "│");
        if (axis_byte) |ab| try std.testing.expect(alpha_byte < ab);
    }
}

test "paintXyChart horizontal renders tick labels on the bottom" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\y-axis 0 --> 100
        \\bar [50]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    const trimmed = std.mem.trimEnd(u8, out, "\n");
    const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
    const last_line = if (nl) |i| trimmed[i + 1 ..] else trimmed;
    try std.testing.expect(std.mem.indexOf(u8, last_line, "0") != null);
    try std.testing.expect(std.mem.indexOf(u8, last_line, "100") != null);
}

test "paintXyChart horizontal 2-series places legend on top" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis [a, b, c]
        \\bar [1, 2, 3]
        \\bar [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    const first_line = it.next() orelse "";
    try std.testing.expect(std.mem.indexOf(u8, first_line, "Bar 1") != null);
}

test "paintXyChart horizontal renders x-axis title below tick labels" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis "Months" [Jan, Feb, Mar]
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Months") != null);
    const months_pos = std.mem.indexOf(u8, out, "Months").?;
    const tick_pos = std.mem.indexOf(u8, out, "┼") orelse 0;
    try std.testing.expect(months_pos > tick_pos);
}

test "paintXyChart horizontal renders both x-axis and y-axis titles in correct order" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis "Months" [Jan, Feb]
        \\y-axis "Revenue"
        \\bar [10, 20]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Months") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Revenue") != null);
    const months_pos = std.mem.indexOf(u8, out, "Months").?;
    const revenue_pos = std.mem.indexOf(u8, out, "Revenue").?;
    try std.testing.expect(revenue_pos > months_pos);
}

test "paintXyChart horizontal without x-axis title has no spurious row" {
    var with_title_diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis "T" [a, b]
        \\bar [1, 2]
    );
    defer with_title_diagram.deinit();
    const with_title = try renderToString(std.testing.allocator, &with_title_diagram.xychart);
    defer std.testing.allocator.free(with_title);

    var without_title_diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis [a, b]
        \\bar [1, 2]
    );
    defer without_title_diagram.deinit();
    const without_title = try renderToString(std.testing.allocator, &without_title_diagram.xychart);
    defer std.testing.allocator.free(without_title);

    const with_nl = std.mem.count(u8, with_title, "\n");
    const without_nl = std.mem.count(u8, without_title, "\n");
    try std.testing.expectEqual(with_nl, without_nl + 1);
}

test "paintXyChart horizontal with only x-axis title adds one row vs neither" {
    var with_x_diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis "X" [a, b]
        \\bar [1, 2]
    );
    defer with_x_diagram.deinit();
    const with_x = try renderToString(std.testing.allocator, &with_x_diagram.xychart);
    defer std.testing.allocator.free(with_x);

    var neither_diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis [a, b]
        \\bar [1, 2]
    );
    defer neither_diagram.deinit();
    const neither = try renderToString(std.testing.allocator, &neither_diagram.xychart);
    defer std.testing.allocator.free(neither);

    const with_x_nl = std.mem.count(u8, with_x, "\n");
    const neither_nl = std.mem.count(u8, neither, "\n");
    try std.testing.expectEqual(with_x_nl, neither_nl + 1);
}

test "paintXyChart horizontal bar with negative values stays crash-free" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\y-axis 0 --> 10
        \\bar [-5, 0, 5]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "█") != null);
}

test "paintXyChart horizontal bar chart renders category, tick, bar, and origin" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\x-axis [a, b, c]
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "█") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "█████") != null);
}

test "paintXyChart horizontal ascending line contains staircase corners" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\line [1, 4]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╰") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╮") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "●") == null);
}

test "paintXyChart horizontal descending line contains opposite corners" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\line [4, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╯") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╭") != null);
}

test "paintXyChart horizontal single-point line renders without dot marker" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart horizontal
        \\line [42]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "●") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
}

test "paintXyChart legend uses Bar N / Line N naming for mixed series" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
        \\line [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bar 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "series") == null);
}

test "paintXyChart omits legend for single series" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Line") == null);
}

test "paintXyChart legend shows Line 1 when first series is line" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 2, 3]
        \\bar [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bar 1") != null);
}

test "paintXyChart legend numbers per-kind for bar+line+bar series" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
        \\line [2, 2, 2]
        \\bar [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bar 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bar 2") != null);
}

test "paintXyChart places legend on row 0 when no title" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
        \\line [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    const first_line = it.next() orelse "";
    try std.testing.expect(std.mem.indexOf(u8, first_line, "Bar 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "Line 1") != null);
}

test "paintXyChart places legend on row 1 just below title row 0" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\title "T"
        \\bar [1, 2, 3]
        \\line [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    const line0 = it.next() orelse "";
    const line1 = it.next() orelse "";
    try std.testing.expect(std.mem.indexOf(u8, line0, "T") != null);
    try std.testing.expect(std.mem.indexOf(u8, line0, "Bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "Bar 1") != null);
}

test "paintXyChart centers legend horizontally within totalW" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
        \\line [3, 2, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    const first_line = it.next() orelse "";
    const total_w = width_mod.displayWidth(first_line, .narrow);
    const bar_byte = std.mem.indexOf(u8, first_line, "Bar 1") orelse return error.TestUnexpectedResult;
    const bar_col = width_mod.displayWidth(first_line[0..bar_byte], .narrow);
    try std.testing.expect(bar_col >= 10);
    try std.testing.expect(bar_col < total_w - 10);
}

test "paintXyChart allocates at least 60 plot cols regardless of category count" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    var max_width: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const w = width_mod.displayWidth(line, .narrow);
        if (w > max_width) max_width = w;
    }
    try std.testing.expect(max_width >= 60);
}

test "paintXyChart renders ascending line with corner_br ╯" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 4]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╯") != null);
}

test "paintXyChart renders ascending line with corner_tl ╭" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 4]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╭") != null);
}

test "paintXyChart renders descending line with corner_tr ╮" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [4, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╮") != null);
}

test "paintXyChart renders descending line with corner_bl ╰" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [4, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "╰") != null);
}

test "paintXyChart renders flat line with ─ and no corners" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [2, 2, 2]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╭") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╮") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╰") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "╯") == null);
    try std.testing.expect(std.mem.count(u8, out, "│") <= 21);
}

test "paintXyChart renders single-point line without dot marker" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [42]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "●") == null);
}

test "paintXyChart vertical line omits dot markers" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 2]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "●") == null);
}

test "paintXyChart ascending 2-point line draws vertical staircase fill" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\line [1, 2]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.count(u8, out, "│") > 20);
}

test "paintXyChart draws single bar series with singleBarW >= 8 columns wide" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [3, 3, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "████████") != null);
}

test "paintXyChart renders clustered 2-bar series with >= 240 block glyphs" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [3, 3, 3]
        \\bar [3, 3, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    const cnt = std.mem.count(u8, out, "█");
    try std.testing.expect(cnt >= 240);
}

test "paintXyChart handles 8 bar series clustered without division-by-zero" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
        \\bar [1, 1, 1]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "█") != null);
}

test "paintXyChart widens plot cols with dataCount * 6 when categories exceed PLOT_WIDTH_MIN" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    var max_width: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const w = width_mod.displayWidth(line, .narrow);
        if (w > max_width) max_width = w;
    }
    try std.testing.expect(max_width >= 90);
}

test "paintXyChart emits exactly one \xe2\x94\xbc origin glyph at axis corner" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "┼"));
}

test "paintXyChart draws \xe2\x94\xa4 y-tick glyphs along y-axis" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\y-axis 0 --> 100
        \\bar [50]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┤") != null);
}

test "paintXyChart draws \xe2\x94\xac x-tick glyphs at category band centers" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\bar [1, 2, 3]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "┬"));
}

test "paintXyChart scatters \xc2\xb7 dot grid across tick rows in plot area" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\y-axis 0 --> 100
        \\bar [50]
    );
    defer diagram.deinit();
    const out = try renderToString(std.testing.allocator, &diagram.xychart);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "·") != null);
    try std.testing.expect(std.mem.count(u8, out, "·") >= 150);
}

test "paintXyChart use_ascii=true substitutes +|-#. for unicode drawing glyphs" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a, b, c]
        \\y-axis 0 --> 100
        \\bar [50, 50, 50]
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
        .use_ascii = true,
    });
    const out = try sink.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "|") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "─") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "█") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "·") == null);
}

test "paintXyChart returns UnsupportedFeature for series exceeding 1024 points" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "xychart\nline [1");
    var k: usize = 0;
    while (k < 1024) : (k += 1) try source.appendSlice(std.testing.allocator, ",1");
    try source.appendSlice(std.testing.allocator, "]\n");

    var diagram = try compile_mod.compile(std.testing.allocator, source.items);
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(error.UnsupportedFeature, paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    }));
}

test "paintXyChart wraps series colors modulo 8 (series 0 and series 8 share role)" {
    var diagram = try compile_mod.compile(std.testing.allocator,
        \\xychart
        \\x-axis [a]
        \\bar [1]
        \\bar [2]
        \\bar [3]
        \\bar [4]
        \\bar [5]
        \\bar [6]
        \\bar [7]
        \\bar [8]
        \\bar [9]
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });
    const out = sink.writer.buffered();

    var max_sgrs: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, pos, "\x1b[38;2;")) |idx| {
            const m = std.mem.indexOfScalarPos(u8, line, idx, 'm') orelse break;
            count += 1;
            pos = m + 1;
        }
        if (count > max_sgrs) max_sgrs = count;
    }
    try std.testing.expectEqual(@as(usize, 9), max_sgrs);

    const p = theme.default_series_palette;
    var buf0: [32]u8 = undefined;
    const sgr0 = std.fmt.bufPrint(&buf0, "\x1b[38;2;{d};{d};{d}m", .{ p[0].r, p[0].g, p[0].b }) catch unreachable;
    var lines2 = std.mem.splitScalar(u8, out, '\n');
    var saw_double_sgr0 = false;
    while (lines2.next()) |line| {
        var c: usize = 0;
        var p0: usize = 0;
        while (std.mem.indexOfPos(u8, line, p0, sgr0)) |idx| {
            c += 1;
            p0 = idx + sgr0.len;
        }
        if (c >= 2) {
            saw_double_sgr0 = true;
            break;
        }
    }
    try std.testing.expect(saw_double_sgr0);
}

test "paintXyChart with enable_ansi=true emits truecolor escape for bars" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\nbar [1, 2, 3]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "\x1b[38;2;") != null);
}

test "paintXyChart with 2 bar series produces two distinct SGR foreground sequences" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\nbar [1, 2, 3]\nbar [4, 5, 6]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });
    const out = sink.writer.buffered();
    var first: ?[]const u8 = null;
    var distinct_found = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, out, pos, "\x1b[38;2;")) |idx| {
        const m = std.mem.indexOfScalarPos(u8, out, idx, 'm') orelse break;
        const seq = out[idx .. m + 1];
        if (first) |f| {
            if (!std.mem.eql(u8, f, seq)) {
                distinct_found = true;
                break;
            }
        } else {
            first = seq;
        }
        pos = m + 1;
    }
    try std.testing.expect(distinct_found);
}

test "paintXyChart with enable_ansi=false (default) emits no SGR escape" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\nbar [1, 2, 3]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "\x1b[") == null);
}

test "vertical xychart clips each line when wrap_width=30 with enable_ansi=true" {
    const src = "xychart\nx-axis [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o]\nbar [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]\n";
    var diagram = try compile_mod.compile(std.testing.allocator, src);
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = 30,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2026}") != null);
    try expectAllLinesFitAnsi(std.testing.allocator, out, 30);
}

test "horizontal xychart clips each line when wrap_width=30 with enable_ansi=true" {
    const src = "xychart horizontal\nx-axis [a, b, c]\nbar [1, 2, 3]\n";
    var diagram = try compile_mod.compile(std.testing.allocator, src);
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = 30,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2026}") != null);
    try expectAllLinesFitAnsi(std.testing.allocator, out, 30);
}

test "vertical xychart with wrap_width=null and enable_ansi=true emits no ellipsis" {
    var diagram = try compile_mod.compile(std.testing.allocator, "xychart\nbar [1, 2, 3]\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try paintXyChart(&sink.writer, std.testing.allocator, &diagram.xychart, .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "\u{2026}") == null);
}

fn expectAllLinesFitAnsi(allocator: std.mem.Allocator, out: []const u8, limit: usize) !void {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const stripped = try ansi_mod.stripCsiAlloc(allocator, line);
        defer allocator.free(stripped);
        const w = width_mod.displayWidth(stripped, .narrow);
        try std.testing.expect(w <= limit);
    }
}
