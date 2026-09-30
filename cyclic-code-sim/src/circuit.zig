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
/// Soft red border for a flip-flop that changed this clock (no reverse fill).
pub const ff_changed_style: vaxis.Style = .{ .fg = .{ .index = 9 }, .bold = true };

/// Large flip-flop box width in columns.
const ff_w: u16 = 13;
/// Inline XOR token width: "[XOR]".
const xor_w: u16 = 5;
const plain_gap: u16 = 6;
const tap_gap: u16 = 4 + xor_w + 4;

/// Total rows occupied by the circuit artwork (excluding status strip under it).
pub const circuit_art_rows: u16 = 11;
/// Extra rows for status / received strip under the art.
pub const circuit_status_rows: u16 = 3;
/// Preferred total circuit block height.
pub const circuit_block_rows: u16 = circuit_art_rows + circuit_status_rows;

pub fn putText(surface: vxfw.Surface, start_col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= surface.size.height) return;
    var col = start_col;
    var i: usize = 0;
    while (i < text.len) {
        if (col >= surface.size.width) break;
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq_len, text.len);
        // grapheme slice must outlive the frame: only pass static literals or arena text.
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
    putBitsStyled(surface, start_col, row, bits, highlighted_index, style, changed_style);
}

pub fn putBitsStyled(
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
    bits: anytype,
    highlighted_index: ?usize,
    style: vaxis.Style,
    highlight: vaxis.Style,
) void {
    var col = start_col;
    for (bits, 0..) |bit, index| {
        if (col + 2 >= surface.size.width) return;
        putText(surface, col, row, "[", muted_style);
        surface.writeCell(col + 1, row, .{
            .char = .{ .grapheme = digit(bit), .width = 1 },
            .style = if (highlighted_index == index) highlight else style,
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

pub fn circuitWidth() u16 {
    return encoderCircuitWidth();
}

/// Shared body: left margin for syndrome input XOR, then 4 FFs + gaps, then encoder input XOR.
/// Relative widths measured from the circuit's left `col`.
const body_origin_from_col: u16 = 16;
/// Encoder right side: "════>[XOR]<════" plus padding (label sits under the XOR).
const right_xor_width: u16 = 18;

/// Rightmost column used by the encoder diagram relative to its left `col`.
pub fn encoderCircuitWidth() u16 {
    return body_origin_from_col + bodySpan() + right_xor_width;
}

/// Rightmost column used by the syndrome diagram relative to its left `col`.
pub fn syndromeCircuitWidth() u16 {
    return body_origin_from_col + bodySpan() + 2;
}

fn bodySpan() u16 {
    // 4 FFs + 2 plain gaps + 1 tap gap
    return 4 * ff_w + 2 * plain_gap + tap_gap;
}

pub const CircuitLogLayout = struct {
    circuit_row: u16,
    log_col: u16,
    log_row: u16,
    log_rows: u16,
    side_by_side: bool,
};

/// Place the clock log to the right of the circuit when width allows; otherwise below it.
pub fn layoutCircuitAndLog(
    surface_width: u16,
    surface_height: u16,
    content_top: u16,
    circuit_left: u16,
    circuit_w: u16,
    log_w: u16,
) CircuitLogLayout {
    const footer_reserve: u16 = 3;
    const content_bottom = if (surface_height > footer_reserve) surface_height - footer_reserve else content_top;
    const content_height = if (content_bottom > content_top) content_bottom - content_top else 0;
    const gap: u16 = 3;
    const side_by_side = surface_width >= circuit_left + circuit_w + gap + log_w;

    const circuit_h = if (side_by_side) circuit_block_rows else circuit_block_rows;
    const circuit_row: u16 = content_top + if (content_height > circuit_h) (content_height - circuit_h) / 2 else 0;

    if (side_by_side) {
        const log_col = circuit_left + circuit_w + gap;
        const log_rows = if (content_bottom > circuit_row + 1) content_bottom - circuit_row - 1 else 0;
        return .{
            .circuit_row = circuit_row,
            .log_col = log_col,
            .log_row = circuit_row,
            .log_rows = log_rows,
            .side_by_side = true,
        };
    }

    // Stack the log under the circuit so it never paints over the hardware.
    const log_row = circuit_row + circuit_block_rows + 1;
    const log_rows = if (content_bottom > log_row + 1) content_bottom - log_row - 1 else 0;
    return .{
        .circuit_row = circuit_row,
        .log_col = circuit_left,
        .log_row = log_row,
        .log_rows = log_rows,
        .side_by_side = false,
    };
}

pub fn drawEncoderCircuit(
    surface: vxfw.Surface,
    arena: std.mem.Allocator,
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
    const geom = sharedGeom(col, row);

    // Left inject column (g0 / "*════>") — must match so the drop sits on the input arm.
    const inject_col = geom.origin - 6;
    // Right message XOR: r3 from the left, m from the right, fb out the top to the rail.
    const xor_col = geom.last_ff + ff_w + 5;
    const xor_mid = xor_col + 2;

    drawFeedbackRail(surface, inject_col, xor_mid, geom.rail_row, fb);

    // g0 drop aligned with the "*" of the r0 input arm.
    putText(surface, inject_col - 3, geom.rail_row + 2, "g0", muted_style);
    putText(surface, inject_col, geom.rail_row + 1, "│", bitStyle(fb));
    putText(surface, inject_col, geom.rail_row + 2, "v", bitStyle(fb));
    putText(surface, inject_col, geom.body_row + 1, "*════>", bitStyle(fb));

    drawLfsrBody(surface, geom.xs, geom.body_row, after, before, fb, "r");

    // Clean wire from r3 into the left of the message XOR (no tee / branch).
    const r3_bit: code.Bit = if (snap) |s| s.before[code.parity_len - 1] else 0;
    putText(surface, geom.last_ff + ff_w, geom.body_row + 1, "════>", bitStyle(r3_bit));

    // Message XOR: top stem feeds the feedback rail.
    drawXorBoxTopOut(surface, xor_col, geom.body_row, fb);
    putText(surface, xor_mid, geom.rail_row + 1, "│", bitStyle(fb));
    putText(surface, xor_mid, geom.rail_row + 2, "│", bitStyle(fb));

    // m enters from the right; label sits under the gate (below CLK labels).
    putText(surface, xor_col + xor_w, geom.body_row + 1, "<════", bitStyle(in_bit));
    drawInputLabel(surface, arena, xor_col, geom.body_row + 4, snap);

    drawClkLabels(surface, geom.xs, geom.body_row + 3);
    drawEncoderStatus(surface, arena, col, geom.body_row + 6, snap, clock_index, message, gate, fb, in_bit);
}

pub fn drawSyndromeCircuit(
    surface: vxfw.Surface,
    arena: std.mem.Allocator,
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
    const geom = sharedGeom(col, row);

    // Syndrome: received-bit XOR is on the LEFT. fb = s3, s0' = r XOR fb.
    // Flip-flops sit in the same columns as the encoder; only the input XOR differs.
    const left_xor_col = geom.origin - 8;
    const loop_left = left_xor_col + 2;
    const loop_right = geom.last_ff + ff_w + 1;
    drawFeedbackRail(surface, loop_left, loop_right, geom.rail_row, fb);
    putText(surface, loop_left, geom.rail_row + 1, "│", bitStyle(fb));
    putText(surface, loop_left, geom.rail_row + 2, "v", bitStyle(fb));
    putText(surface, loop_right, geom.rail_row + 1, "│", bitStyle(fb));
    putText(surface, loop_right, geom.rail_row + 2, "│", bitStyle(fb));
    putText(surface, loop_right, geom.body_row + 1, "┘", bitStyle(fb));

    const in_d0: code.Bit = if (snap) |s| s.d[0] else 0;
    putText(surface, col, geom.body_row + 1, "r ════>", bitStyle(in_bit));
    drawXorBox(surface, left_xor_col, geom.body_row, in_d0);
    putText(surface, left_xor_col + xor_w, geom.body_row + 1, "════>", bitStyle(in_d0));

    drawLfsrBody(surface, geom.xs, geom.body_row, after, before, fb, "s");
    drawClkLabels(surface, geom.xs, geom.body_row + 3);

    if (snap) |s| {
        const text = std.fmt.allocPrint(arena, "clock {d}/{d}   in c{d}={d}   fb={d}   S={s}", .{
            if (clock_index == 0) @as(usize, 0) else s.clock,
            code.n,
            s.in_index,
            s.in_bit,
            s.fb,
            tryFormatBits(arena, after),
        }) catch return;
        putText(surface, col, geom.body_row + 5, text, normal);
    } else {
        putText(surface, col, geom.body_row + 5, "clock 0/15   registers cleared   waiting for first bit", muted_style);
    }

    drawReceivedStrip(surface, col, geom.body_row + 6, received, if (snap) |s| s.in_index else null, clock_index == 0);

    if (meggitt) {
        const pat = tryFormatBits(arena, code.MEGGITT_PATTERN);
        const box_style = if (match) error_style else muted_style;
        // Park the comparator to the right of the shared body, not over the FFs.
        const box_col = col + body_origin_from_col + bodySpan() + 3;
        if (box_col + 22 < surface.size.width) {
            putText(surface, box_col, geom.body_row - 1, "┌────────────────────┐", box_style);
            putText(surface, box_col, geom.body_row, if (match) "│ MATCH x^14 CORRECT │" else "│ s == pattern ?     │", if (match) changed_style else muted_style);
            const pat_line = std.fmt.allocPrint(arena, "│ pattern {s}        │", .{pat}) catch return;
            putText(surface, box_col, geom.body_row + 1, pat_line, box_style);
            putText(surface, box_col, geom.body_row + 2, "└────────────────────┘", box_style);
        }
    }
}

const SharedGeom = struct {
    origin: u16,
    xs: [code.parity_len]u16,
    last_ff: u16,
    loop_left: u16,
    rail_row: u16,
    body_row: u16,
};

fn sharedGeom(col: u16, row: u16) SharedGeom {
    const origin = col + body_origin_from_col;
    const xs = ffPositions(origin);
    return .{
        .origin = origin,
        .xs = xs,
        .last_ff = xs[code.parity_len - 1],
        .loop_left = origin - 2,
        .rail_row = row,
        .body_row = row + 3,
    };
}

fn drawFeedbackRail(surface: vxfw.Surface, left: u16, right: u16, row: u16, fb: code.Bit) void {
    putText(surface, left, row, "┌", bitStyle(fb));
    drawHLine(surface, left + 1, right - 1, row, "─", bitStyle(fb));
    putText(surface, right, row, "┐", bitStyle(fb));
    putText(surface, left + 14, row, if (fb == 1) " fb = 1 " else " fb = 0 ", if (fb == 1) warning_style else muted_style);
    putText(surface, left, row + 1, "│", bitStyle(fb));
    putText(surface, right, row + 1, "│", bitStyle(fb));
}

pub fn drawEncoderLog(
    surface: vxfw.Surface,
    arena: std.mem.Allocator,
    col: u16,
    row: u16,
    snaps: []const code.EncoderSnapshot,
    clock_index: usize,
    max_rows: u16,
) void {
    putText(surface, col, row, "clk in fb r0 r1 r2 r3 out gate", section_style);
    if (clock_index == 0 or max_rows == 0) return;
    const shown = @min(@as(usize, max_rows), clock_index);
    const start = clock_index - shown;
    var line: u16 = 1;
    var i = start;
    while (i < clock_index) : (i += 1) {
        const s = snaps[i];
        const text = std.fmt.allocPrint(arena, " {d:2}  {d}  {d}  {d}  {d}  {d}  {d}  {d}  {s}", .{
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
    arena: std.mem.Allocator,
    col: u16,
    row: u16,
    snaps: []const code.SyndromeSnapshot,
    clock_index: usize,
    max_rows: u16,
) void {
    putText(surface, col, row, "clk in@ in fb s0 s1 s2 s3", section_style);
    if (clock_index == 0 or max_rows == 0) return;
    const shown = @min(@as(usize, max_rows), clock_index);
    const start = clock_index - shown;
    var line: u16 = 1;
    var i = start;
    while (i < clock_index) : (i += 1) {
        const s = snaps[i];
        const text = std.fmt.allocPrint(arena, " {d:2} c{d:<2} {d}  {d}  {d}  {d}  {d}  {d}", .{
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
    arena: std.mem.Allocator,
    col: u16,
    row: u16,
    snaps: []const code.MeggittSnapshot,
    clock_index: usize,
    max_rows: u16,
) void {
    putText(surface, col, row, "clk look bit match s0..s3", section_style);
    if (clock_index == 0 or max_rows == 0) return;
    const shown = @min(@as(usize, max_rows), clock_index);
    const start = clock_index - shown;
    var line: u16 = 1;
    var i = start;
    while (i < clock_index) : (i += 1) {
        const s = snaps[i];
        const text = std.fmt.allocPrint(arena, " {d:2} c{d:<2}  {d}  {s}   {d}{d}{d}{d}", .{
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

fn digit(bit: code.Bit) []const u8 {
    return if (bit == 0) "0" else "1";
}

fn asciiDigit(n: u8) []const u8 {
    return switch (n) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        else => "?",
    };
}

fn tryFormatBits(arena: std.mem.Allocator, bits: anytype) []const u8 {
    var buf: [16]u8 = undefined;
    const slice = code.formatBits(bits, buf[0..bits.len]);
    return arena.dupe(u8, slice) catch "????";
}

fn ffPositions(origin: u16) [code.parity_len]u16 {
    var xs: [code.parity_len]u16 = undefined;
    xs[0] = origin;
    var i: usize = 1;
    while (i < code.parity_len) : (i += 1) {
        const gap: u16 = if (code.G[i] == 1) tap_gap else plain_gap;
        xs[i] = xs[i - 1] + ff_w + gap;
    }
    return xs;
}

fn drawHLine(surface: vxfw.Surface, left: u16, right: u16, row: u16, ch: []const u8, style: vaxis.Style) void {
    var x = left;
    while (x <= right) : (x += 1) {
        putText(surface, x, row, ch, style);
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
        drawFlipFlop(surface, xs[i], row, prefix, @intCast(i), after[i], after[i] != before[i]);
        if (i + 1 < code.parity_len) {
            const from = xs[i] + ff_w;
            const to = xs[i + 1];
            if (code.G[i + 1] == 1) {
                putText(surface, from, row + 1, "════>", bitStyle(after[i]));
                drawXorBox(surface, from + 5, row, after[i] ^ fb);
                // Tap label and drop from feedback rail.
                putText(surface, from + 4, row - 1, "g3", muted_style);
                putText(surface, from + 7, row - 2, "│", bitStyle(fb));
                putText(surface, from + 7, row - 1, "v", bitStyle(fb));
                putText(surface, from + 5 + xor_w, row + 1, "════>", bitStyle(after[i] ^ fb));
            } else {
                var x = from;
                while (x + 1 < to) : (x += 1) {
                    putText(surface, x, row + 1, "═", bitStyle(after[i]));
                }
                putText(surface, to - 1, row + 1, ">", bitStyle(after[i]));
            }
        }
    }
}

fn drawFlipFlop(
    surface: vxfw.Surface,
    col: u16,
    row: u16,
    prefix: []const u8,
    index: u8,
    value: code.Bit,
    changed: bool,
) void {
    // Only the trim changes color; reverse-fill on the whole box caused blotches
    // around the label and was visually aggressive.
    const border = if (changed) ff_changed_style else ff_style;
    putText(surface, col, row, "┏━━━━━━━━━━━┓", border);

    putText(surface, col, row + 1, "┃", border);
    putText(surface, col + 1, row + 1, "  ", normal);
    putText(surface, col + 3, row + 1, prefix, normal);
    putText(surface, col + 3 + @as(u16, @intCast(prefix.len)), row + 1, asciiDigit(index), normal);
    putText(surface, col + 6, row + 1, " [", normal);
    surface.writeCell(col + 8, row + 1, .{
        .char = .{ .grapheme = digit(value), .width = 1 },
        .style = if (value == 1) warning_style else normal,
    });
    putText(surface, col + 9, row + 1, "]  ", normal);
    putText(surface, col + 12, row + 1, "┃", border);

    putText(surface, col, row + 2, "┗━━━━━━━━━━━┛", border);
}

fn drawXorBox(surface: vxfw.Surface, col: u16, row: u16, out: code.Bit) void {
    const used = if (out == 1) warning_style else xor_style;
    putText(surface, col, row, "╭───╮", used);
    putText(surface, col, row + 1, "│XOR│", used);
    putText(surface, col, row + 2, "╰───╯", used);
}

/// XOR with a top stem (┴) so feedback can rise from the gate into the rail above.
fn drawXorBoxTopOut(surface: vxfw.Surface, col: u16, row: u16, out: code.Bit) void {
    const used = if (out == 1) warning_style else xor_style;
    putText(surface, col, row, "╭─┴─╮", used);
    putText(surface, col, row + 1, "│XOR│", used);
    putText(surface, col, row + 2, "╰───╯", used);
}

fn drawClkLabels(surface: vxfw.Surface, xs: [code.parity_len]u16, row: u16) void {
    for (xs) |x| {
        putText(surface, x + 3, row, "D ^CLK", muted_style);
    }
}

fn drawEncoderStatus(
    surface: vxfw.Surface,
    arena: std.mem.Allocator,
    col: u16,
    row: u16,
    snap: ?code.EncoderSnapshot,
    clock_index: usize,
    message: code.Message,
    gate: bool,
    fb: code.Bit,
    in_bit: code.Bit,
) void {
    const text = std.fmt.allocPrint(arena, "clock {d}/15   gate:{s}   in={d}   fb={d}   out={d}", .{
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
            .char = .{ .grapheme = digit(message[idx]), .width = 1 },
            .style = if (done) muted_style else warning_style,
        });
        qcol += 2;
    }
}

fn drawInputLabel(
    surface: vxfw.Surface,
    arena: std.mem.Allocator,
    col: u16,
    row: u16,
    snap: ?code.EncoderSnapshot,
) void {
    if (snap) |s| {
        if (s.gate) {
            const idx = code.k - s.clock;
            const text = std.fmt.allocPrint(arena, " m{d}={d}", .{ idx, s.in_bit }) catch return;
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
            .char = .{ .grapheme = digit(received[idx]), .width = 1 },
            .style = if (!idle and current == idx) active_style else normal,
        });
        x += 2;
    }
}
