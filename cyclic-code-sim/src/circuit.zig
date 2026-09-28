const std = @import("std");
const vaxis = @import("vaxis");
const code = @import("code.zig");

const vxfw = vaxis.vxfw;

pub const normal: vaxis.Style = .{};
pub const title_style: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };
pub const section_style: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true };
pub const active_style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true };
pub const success_style: vaxis.Style = .{ .fg = .{ .index = 2 }, .bold = true };
pub const warning_style: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
pub const error_style: vaxis.Style = .{ .fg = .{ .index = 1 }, .bold = true };
pub const changed_style: vaxis.Style = .{ .fg = .{ .index = 1 }, .reverse = true, .bold = true };
pub const corrected_style: vaxis.Style = .{ .fg = .{ .index = 2 }, .reverse = true, .bold = true };
pub const muted_style: vaxis.Style = .{ .dim = true };
pub const wire_one: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
pub const xor_style: vaxis.Style = .{ .fg = .{ .index = 5 }, .bold = true };
pub const ff_style: vaxis.Style = .{ .fg = .{ .index = 6 } };

const ff_w: u16 = 10;
const xor_w: u16 = 5;

pub fn putText(surface: vxfw.Surface, start_col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= surface.size.height) return;
    var col = start_col;
    var i: usize = 0;
    while (i < text.len) {
        if (col >= surface.size.width) break;
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq_len, text.len);
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = text[i..end], .width = 1 },
            .style = style,
        });
        col += 1;
        i = end;
    }
}

pub fn putBits(
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
    bits: anytype,
    highlighted_index: ?usize,
    style: vaxis.Style,
) void {
    var col = start_col;
    for (bits, 0..) |bit, index| {
        if (col + 2 >= surface.size.width) return;
        putText(surface, col, row, "[", muted_style);
        surface.writeCell(col + 1, row, .{
            .char = .{ .grapheme = if (bit == 0) "0" else "1" },
            .style = if (highlighted_index == index) changed_style else style,
        });
        putText(surface, col + 2, row, "]", muted_style);
        col += 4;
    }
}

pub fn bitStyle(bit: code.Bit) vaxis.Style {
    return if (bit == 1) wire_one else muted_style;
}

pub fn drawFooter(surface: vxfw.Surface, text: []const u8) void {
    if (surface.size.height < 2) return;
    putText(surface, 1, surface.size.height - 2, text, muted_style);
}

pub fn centeredColumn(width: u16, text_width: u16) u16 {
    return if (width > text_width) (width - text_width) / 2 else 0;
}

pub fn circuitHeight() u16 {
    return 8;
}

pub fn drawEncoderCircuit(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snap: ?code.EncoderSnapshot,
    clock_index: usize,
    message: code.Message,
) void {
    const fb: code.Bit = if (snap) |s| s.fb else 0;
    const in_bit: code.Bit = if (snap) |s| s.in_bit else 0;
    const before: code.Register = if (snap) |s| s.before else @splat(0);
    const after: code.Register = if (snap) |s| s.after else @splat(0);
    const gate = if (snap) |s| s.gate else clock_index < code.k;
    const xs = ffPositions(col + 6);

    drawFeedbackLoop(surface, col + 4, row, xs, fb, true);
    drawLfsrBody(surface, xs, row + 2, after, before, fb, "r");

    const xor_col = xs[code.parity_len - 1] + ff_w + 2;
    drawXor(surface, xor_col, row + 2, fb);
    putText(surface, xor_col + xor_w, row + 3, "<", bitStyle(in_bit));
    putText(surface, xor_col + xor_w + 1, row + 3, "━━━━", bitStyle(in_bit));
    drawInputLabel(surface, xor_col + xor_w + 1, row + 3, snap);

    putText(surface, xs[0] - 6, row + 3, "●━━━━>", bitStyle(fb));
    putText(surface, xs[0] - 6, row + 2, "g0", muted_style);

    const join_col = xs[code.parity_len - 1] + ff_w;
    putText(surface, join_col, row + 3, "━┴━>", bitStyle(fb));

    drawClkLabels(surface, xs, row + 5);
    drawEncoderStatus(surface, col, row + 6, snap, clock_index, message, gate, fb, in_bit);
}

pub fn drawSyndromeCircuit(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snap: ?code.SyndromeSnapshot,
    clock_index: usize,
    received: code.Codeword,
    meggitt: bool,
    match: bool,
) void {
    const fb: code.Bit = if (snap) |s| s.fb else 0;
    const in_bit: code.Bit = if (snap) |s| s.in_bit else 0;
    const before: code.Register = if (snap) |s| s.before else @splat(0);
    const after: code.Register = if (snap) |s| s.after else @splat(0);
    const xs = ffPositions(col + 14);

    drawFeedbackLoop(surface, col + 6, row, xs, fb, false);
    drawXor(surface, col + 6, row + 2, if (snap) |s| s.d[0] else 0);
    putText(surface, col, row + 3, "r", bitStyle(in_bit));
    putText(surface, col + 1, row + 3, "━━━━>", bitStyle(in_bit));
    putText(surface, col + 11, row + 3, "━━━━>", bitStyle(if (snap) |s| s.d[0] else 0));

    drawLfsrBody(surface, xs, row + 2, after, before, fb, "s");

    const join_col = xs[code.parity_len - 1] + ff_w;
    putText(surface, join_col, row + 3, "━━┘", bitStyle(fb));
    drawClkLabels(surface, xs, row + 5);

    if (snap) |s| {
        var buf: [80]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "clock {d}/{d}   in c{d}={d}   fb={d}   S={d}{d}{d}{d}", .{
            if (clock_index == 0) @as(usize, 0) else s.clock,
            code.n,
            s.in_index,
            s.in_bit,
            s.fb,
            after[0],
            after[1],
            after[2],
            after[3],
        }) catch return;
        putText(surface, col, row + 6, text, normal);
    } else {
        putText(surface, col, row + 6, "clock 0/15   registers cleared   waiting for first bit", muted_style);
    }

    drawReceivedStrip(surface, col, row + 7, received, if (snap) |s| s.in_index else null, clock_index == 0);

    if (meggitt) {
        var pat_buf: [4]u8 = undefined;
        const pat = code.formatBits(code.MEGGITT_PATTERN, &pat_buf);
        const box_style = if (match) error_style else muted_style;
        putText(surface, col + 62, row + 2, "┌────────────────────┐", box_style);
        putText(surface, col + 62, row + 3, if (match) " MATCH x^14  CORRECT " else " s == pattern ?     ", if (match) changed_style else muted_style);
        var line_buf: [32]u8 = undefined;
        const pat_line = std.fmt.bufPrint(&line_buf, "│ pattern {s}        │", .{pat}) catch return;
        putText(surface, col + 62, row + 4, pat_line, box_style);
        putText(surface, col + 62, row + 5, "└────────────────────┘", box_style);
    }
}

pub fn drawEncoderLog(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snaps: []const code.EncoderSnapshot,
    clock_index: usize,
    max_rows: u16,
) void {
    putText(surface, col, row, "clk  in fb  r0 r1 r2 r3  out gate", section_style);
    if (clock_index == 0 or max_rows == 0) return;
    const shown = @min(@as(usize, max_rows), clock_index);
    const start = clock_index - shown;
    var line: u16 = 1;
    var i = start;
    while (i < clock_index) : (i += 1) {
        const s = snaps[i];
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " {d:2}   {d}  {d}   {d}  {d}  {d}  {d}   {d}   {s}", .{
            s.clock,
            s.in_bit,
            s.fb,
            s.after[0],
            s.after[1],
            s.after[2],
            s.after[3],
            s.out,
            if (s.gate) "ON " else "OFF",
        }) catch return;
        putText(surface, col, row + line, text, if (i + 1 == clock_index) active_style else normal);
        line += 1;
    }
}

pub fn drawSyndromeLog(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snaps: []const code.SyndromeSnapshot,
    clock_index: usize,
    max_rows: u16,
) void {
    putText(surface, col, row, "clk  in@  in fb  s0 s1 s2 s3", section_style);
    if (clock_index == 0 or max_rows == 0) return;
    const shown = @min(@as(usize, max_rows), clock_index);
    const start = clock_index - shown;
    var line: u16 = 1;
    var i = start;
    while (i < clock_index) : (i += 1) {
        const s = snaps[i];
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " {d:2}  c{d:<2}  {d}  {d}   {d}  {d}  {d}  {d}", .{
            s.clock,
            s.in_index,
            s.in_bit,
            s.fb,
            s.after[0],
            s.after[1],
            s.after[2],
            s.after[3],
        }) catch return;
        putText(surface, col, row + line, text, if (i + 1 == clock_index) active_style else normal);
        line += 1;
    }
}

pub fn drawMeggittLog(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snaps: []const code.MeggittSnapshot,
    clock_index: usize,
    max_rows: u16,
) void {
    putText(surface, col, row, "clk  look  bit match  s0 s1 s2 s3", section_style);
    if (clock_index == 0 or max_rows == 0) return;
    const shown = @min(@as(usize, max_rows), clock_index);
    const start = clock_index - shown;
    var line: u16 = 1;
    var i = start;
    while (i < clock_index) : (i += 1) {
        const s = snaps[i];
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " {d:2}   c{d:<2}  {d}   {s}    {d}  {d}  {d}  {d}", .{
            s.clock,
            s.examine_index,
            s.examine_bit,
            if (s.match) "YES" else "no ",
            s.after[0],
            s.after[1],
            s.after[2],
            s.after[3],
        }) catch return;
        putText(surface, col, row + line, text, if (s.match) changed_style else if (i + 1 == clock_index) active_style else normal);
        line += 1;
    }
}

fn ffPositions(origin: u16) [code.parity_len]u16 {
    var xs: [code.parity_len]u16 = undefined;
    xs[0] = origin;
    var i: usize = 1;
    while (i < code.parity_len) : (i += 1) {
        const gap: u16 = if (code.G[i] == 1) 3 + xor_w + 3 else 6;
        xs[i] = xs[i - 1] + ff_w + gap;
    }
    return xs;
}

fn drawFeedbackLoop(
    surface: vxfw.Surface,
    left: u16,
    row: u16,
    xs: [code.parity_len]u16,
    fb: code.Bit,
    encoder: bool,
) void {
    const right = xs[code.parity_len - 1] + ff_w + if (encoder) @as(u16, 8) else 2;
    const style = bitStyle(fb);
    putText(surface, left, row, "╭", style);
    var x = left + 1;
    while (x < right) : (x += 1) {
        putText(surface, x, row, "─", style);
    }
    putText(surface, right, row, "╮", style);
    putText(surface, left + 8, row, if (fb == 1) " fb=1 " else " fb=0 ", if (fb == 1) warning_style else muted_style);
    putText(surface, left, row + 1, "│", style);
    putText(surface, left, row + 2, "▼", style);
    putText(surface, right, row + 1, "│", style);
    if (encoder) {
        putText(surface, xs[code.parity_len - 1] + ff_w + 4, row + 1, "│", style);
    }
}

fn drawLfsrBody(
    surface: vxfw.Surface,
    xs: [code.parity_len]u16,
    row: u16,
    after: code.Register,
    before: code.Register,
    fb: code.Bit,
    prefix: []const u8,
) void {
    var i: usize = 0;
    while (i < code.parity_len) : (i += 1) {
        var name_buf: [4]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{d}", .{ prefix, i }) catch "r?";
        drawFlipFlop(surface, xs[i], row, name, after[i], after[i] != before[i]);
        if (i + 1 < code.parity_len) {
            const from = xs[i] + ff_w;
            const to = xs[i + 1];
            if (code.G[i + 1] == 1) {
                putText(surface, from, row + 1, "━━>", bitStyle(after[i]));
                drawXor(surface, from + 3, row, after[i] ^ fb);
                var tap_buf: [8]u8 = undefined;
                const tap = std.fmt.bufPrint(&tap_buf, "g{d}", .{i + 1}) catch "g";
                putText(surface, from + 3, row - 1, tap, warning_style);
                putText(surface, from + 3 + xor_w, row + 1, "━━>", bitStyle(after[i] ^ fb));
            } else {
                var x = from;
                while (x + 1 < to) : (x += 1) {
                    putText(surface, x, row + 1, "━", bitStyle(after[i]));
                }
                if (to > 0) putText(surface, to - 1, row + 1, ">", bitStyle(after[i]));
            }
        }
    }
}

fn drawFlipFlop(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    name: []const u8,
    value: code.Bit,
    changed: bool,
) void {
    const border = if (changed) changed_style else ff_style;
    putText(surface, col, row, "┏━━━━━━━━┓", border);
    var body: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "┃ {s} [{d}] ┃", .{ name, value }) catch return;
    putText(surface, col, row + 1, text, if (changed) changed_style else if (value == 1) warning_style else normal);
    putText(surface, col, row + 2, "┗━━━━━━━━┛", border);
}

fn drawXor(surface: vxfw.Surface, col: u16, row: u16, out: code.Bit) void {
    const used = if (out == 1) warning_style else xor_style;
    putText(surface, col, row, "╭───╮", used);
    putText(surface, col, row + 1, "│ ⊕ │", used);
    putText(surface, col, row + 2, "╰───╯", used);
}

fn drawClkLabels(surface: vxfw.Surface, xs: [code.parity_len]u16, row: u16) void {
    for (xs) |x| {
        putText(surface, x + 2, row, "D ▲CLK", muted_style);
    }
}

fn drawEncoderStatus(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snap: ?code.EncoderSnapshot,
    clock_index: usize,
    message: code.Message,
    gate: bool,
    fb: code.Bit,
    in_bit: code.Bit,
) void {
    var buf: [72]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "clock {d}/15   gate:{s}   in={d}   fb={d}   out={d}", .{
        clock_index,
        if (gate) "ON " else "OFF",
        in_bit,
        fb,
        if (snap) |s| s.out else 0,
    }) catch return;
    putText(surface, col, row, text, normal);

    putText(surface, col, row + 1, "queue m10..m0:", muted_style);
    const consumed: usize = if (clock_index > code.k) code.k else clock_index;
    var qcol: u16 = col + 16;
    var mi: isize = @intCast(code.k - 1);
    while (mi >= 0) : (mi -= 1) {
        const idx: usize = @intCast(mi);
        const done = (code.k - 1 - idx) < consumed;
        surface.writeCell(qcol, row + 1, .{
            .char = .{ .grapheme = if (message[idx] == 0) "0" else "1" },
            .style = if (done) muted_style else warning_style,
        });
        qcol += 2;
    }
}

fn drawInputLabel(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    snap: ?code.EncoderSnapshot,
) void {
    if (snap) |s| {
        if (s.gate) {
            const idx = code.k - s.clock;
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, " m{d}={d}", .{ idx, s.in_bit }) catch return;
            putText(surface, col, row, text, warning_style);
        } else {
            putText(surface, col, row, " (gate off)", muted_style);
        }
    } else {
        putText(surface, col, row, " m10 first", muted_style);
    }
}

fn drawReceivedStrip(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    received: code.Codeword,
    current: ?usize,
    idle: bool,
) void {
    putText(surface, col, row, "recv c14..c0:", muted_style);
    var x: u16 = col + 15;
    var i: isize = @intCast(code.n - 1);
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        surface.writeCell(x, row, .{
            .char = .{ .grapheme = if (received[idx] == 0) "0" else "1" },
            .style = if (!idle and current == idx) active_style else normal,
        });
        x += 2;
    }
}
