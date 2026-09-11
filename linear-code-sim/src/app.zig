const std = @import("std");
const vaxis = @import("vaxis");
const code = @import("code.zig");

const vxfw = vaxis.vxfw;

const Stage = enum {
    message,
    channel,
    diagnosis,
    correction,
};

const normal: vaxis.Style = .{};
const title_style: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };
const section_style: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true };
const active_style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true };
const success_style: vaxis.Style = .{ .fg = .{ .index = 2 }, .bold = true };
const warning_style: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
const error_style: vaxis.Style = .{ .fg = .{ .index = 1 }, .bold = true };
const changed_style: vaxis.Style = .{ .fg = .{ .index = 1 }, .reverse = true, .bold = true };
const muted_style: vaxis.Style = .{ .dim = true };

pub const Model = struct {
    stage: Stage = .message,
    input: [4]u8 = .{ ' ', ' ', ' ', ' ' },
    input_len: usize = 0,
    input_error: bool = false,
    message: code.Message = @splat(0),
    codeword: code.Codeword = @splat(0),
    error_choice: usize = 0,
    received: code.Codeword = @splat(0),
    syndrome: code.Syndrome = @splat(0),
    corrected: code.Codeword = @splat(0),
    recovered: code.Message = @splat(0),
    choice_row: i16 = -1,
    choice_starts: [8]u16 = @splat(0),
    choice_ends: [8]u16 = @splat(0),
    parse_ns: u64 = 0,
    encode_ns: u64 = 0,
    transmit_ns: u64 = 0,
    syndrome_ns: u64 = 0,
    locate_ns: u64 = 0,
    correct_ns: u64 = 0,
    recover_ns: u64 = 0,
    detected_error: ?usize = null,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn reset(self: *Model) void {
        self.* = .{};
    }

    fn advance(self: *Model, io: std.Io) void {
        switch (self.stage) {
            .message => {
                if (self.input_len != self.input.len) {
                    self.input_error = true;
                    return;
                }
                const parse_start = std.Io.Clock.awake.now(io);
                self.message = code.parseMessage(self.input[0..]) catch {
                    self.parse_ns = elapsedNanoseconds(parse_start, io);
                    self.input_error = true;
                    return;
                };
                self.parse_ns = elapsedNanoseconds(parse_start, io);

                const encode_start = std.Io.Clock.awake.now(io);
                self.codeword = code.encode(self.message);
                self.encode_ns = elapsedNanoseconds(encode_start, io);
                self.stage = .channel;
                self.input_error = false;
            },
            .channel => {
                const error_index: ?usize = if (self.error_choice == 0) null else self.error_choice - 1;

                const transmit_start = std.Io.Clock.awake.now(io);
                self.received = code.transmit(self.codeword, error_index) catch unreachable;
                self.transmit_ns = elapsedNanoseconds(transmit_start, io);

                const syndrome_start = std.Io.Clock.awake.now(io);
                self.syndrome = code.calculateSyndrome(self.received);
                self.syndrome_ns = elapsedNanoseconds(syndrome_start, io);

                const locate_start = std.Io.Clock.awake.now(io);
                self.detected_error = code.locateError(self.syndrome);
                self.locate_ns = elapsedNanoseconds(locate_start, io);
                self.stage = .diagnosis;
            },
            .diagnosis => {
                const correct_start = std.Io.Clock.awake.now(io);
                self.corrected = code.correct(self.received, self.syndrome);
                self.correct_ns = elapsedNanoseconds(correct_start, io);

                const recover_start = std.Io.Clock.awake.now(io);
                self.recovered = code.recoverMessage(self.corrected);
                self.recover_ns = elapsedNanoseconds(recover_start, io);
                self.stage = .correction;
            },
            .correction => {},
        }
    }

    fn selectPreviousError(self: *Model) void {
        self.error_choice = if (self.error_choice == 0) 7 else self.error_choice - 1;
    }

    fn selectNextError(self: *Model) void {
        self.error_choice = (self.error_choice + 1) % 8;
    }

    fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
            ctx.quit = true;
            return;
        }
        if (key.matches('r', .{})) {
            self.reset();
            ctx.consumeAndRedraw();
            return;
        }

        switch (self.stage) {
            .message => {
                if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.delete, .{})) {
                    if (self.input_len > 0) {
                        self.input_len -= 1;
                        self.input[self.input_len] = ' ';
                    }
                    self.input_error = false;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    self.advance(ctx.io);
                } else if (key.matches('0', .{}) or key.matches('1', .{})) {
                    if (self.input_len < self.input.len) {
                        self.input[self.input_len] = if (key.matches('0', .{})) '0' else '1';
                        self.input_len += 1;
                        self.input_error = false;
                    } else {
                        self.input_error = true;
                    }
                } else if (key.codepoint >= 0x20 and key.codepoint <= 0x7e) {
                    self.input_error = true;
                }
            },
            .channel => {
                if (key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.up, .{}) or key.matches('h', .{})) {
                    self.selectPreviousError();
                } else if (key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches('l', .{})) {
                    self.selectNextError();
                } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
                    self.advance(ctx.io);
                } else {
                    for (0..8) |choice| {
                        const digit: u21 = @intCast('0' + choice);
                        if (key.matches(digit, .{})) {
                            self.error_choice = choice;
                            break;
                        }
                    }
                }
            },
            .diagnosis => {
                if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{}) or key.matches('c', .{})) {
                    self.advance(ctx.io);
                }
            },
            .correction => {},
        }
        ctx.consumeAndRedraw();
    }

    fn handleMouse(self: *Model, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) void {
        if (self.stage != .channel or mouse.type != .press or mouse.button != .left) return;
        if (mouse.row != self.choice_row or mouse.col < 0) return;
        const column: u16 = @intCast(mouse.col);
        for (0..self.choice_starts.len) |choice| {
            if (column >= self.choice_starts[choice] and column < self.choice_ends[choice]) {
                self.error_choice = choice;
                ctx.consumeAndRedraw();
                return;
            }
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init, .focus_in => try ctx.requestFocus(self.widget()),
            .key_press => |key| self.handleKey(ctx, key),
            .mouse => |mouse| self.handleMouse(ctx, mouse),
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.width < 64 or size.height < 23) {
            self.drawCompact(surface, ctx);
        } else {
            self.drawFull(surface, ctx);
        }
        if (self.stage == .message and size.height > 5) {
            const cursor_column: u16 = @intCast(@min(12 + self.input_len * 4, @as(usize, size.width - 1)));
            surface.cursor = .{ .row = 5, .col = cursor_column, .shape = .beam };
        }
        self.drawPerformance(surface, ctx);
        return surface;
    }

    fn drawPerformance(self: *const Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        if (surface.size.height == 0) return;
        const text = switch (self.stage) {
            .message => "Performance: waiting for first calculation",
            .channel => std.fmt.allocPrint(
                ctx.arena,
                "Performance: parse {d} ns | encode {d} ns",
                .{ self.parse_ns, self.encode_ns },
            ) catch return,
            .diagnosis => std.fmt.allocPrint(
                ctx.arena,
                "Performance: transmit {d} ns | syndrome {d} ns | locate {d} ns",
                .{ self.transmit_ns, self.syndrome_ns, self.locate_ns },
            ) catch return,
            .correction => std.fmt.allocPrint(
                ctx.arena,
                "Performance: correct {d} ns | recover {d} ns",
                .{ self.correct_ns, self.recover_ns },
            ) catch return,
        };
        putText(surface, 1, surface.size.height - 1, text, title_style);
    }

    fn drawFull(self: *Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        const width = surface.size.width;
        putText(surface, centeredColumn(width, 38), 0, "(7,4) LINEAR BLOCK-CODE SIMULATOR", title_style);
        putText(surface, 2, 2, "Message -> Encoder -> Codeword -> Channel -> Syndrome -> Correction -> Message", muted_style);

        if (self.stage == .message) {
            putText(surface, 2, 4, "[1] MESSAGE INPUT", section_style);
            putText(surface, 2, 5, "Message: ", normal);
            for (0..self.input.len) |index| {
                const col: u16 = @intCast(11 + index * 4);
                putText(surface, col, 5, "[", muted_style);
                surface.writeCell(col + 1, 5, .{
                    .char = .{ .grapheme = if (self.input[index] == ' ') " " else self.input[index .. index + 1] },
                    .style = if (index == self.input_len) active_style else normal,
                });
                putText(surface, col + 2, 5, "]", muted_style);
            }
            putText(surface, 2, 7, "Type four binary digits, then press Enter.", normal);
            if (self.input_error) {
                putText(surface, 2, 9, "Input rejected: enter exactly four bits containing only 0 or 1.", error_style);
            }
            drawFooter(surface, "0/1 type  Backspace delete  Enter encode  r reset  q quit");
            return;
        }

        putText(surface, 2, 4, "[1] TRANSMITTER / ENCODER", section_style);
        putText(surface, 2, 5, "Message m =", normal);
        putBits(surface, 14, 5, self.message, null, normal);
        putText(surface, 2, 6, "Operation: c = mG (mod 2)", muted_style);
        putText(surface, 2, 7, "Codeword c =", normal);
        putBits(surface, 15, 7, self.codeword, null, success_style);
        if (width >= 78) drawGeneratorMatrix(surface, width - 31, 4);

        putText(surface, 2, 10, "[2] CHANNEL / ERROR INJECTION", section_style);
        drawErrorChoices(self, surface, 2, 11);
        putText(surface, 2, 13, "Transmitted:", normal);
        putBits(surface, 15, 13, self.codeword, null, normal);
        if (self.stage == .channel) {
            putText(surface, 2, 14, "Choose one channel outcome, then transmit.", warning_style);
            drawFooter(surface, "Left/Right or 0-7 select  Enter/Space transmit  r reset  q quit");
            return;
        }

        putText(surface, 2, 14, "Received:   ", normal);
        putBits(
            surface,
            15,
            14,
            self.received,
            if (self.error_choice == 0) null else self.error_choice - 1,
            if (self.error_choice == 0) success_style else changed_style,
        );

        putText(surface, 2, 16, "[3] RECEIVER / SYNDROME DECODER", section_style);
        putText(surface, 2, 17, "S = rH^T =", normal);
        putBits(surface, 14, 17, self.syndrome, null, warning_style);
        if (self.detected_error) |index| {
            const text = std.fmt.allocPrint(ctx.arena, "S matches column {d} of H -> error at bit {d}.", .{ index + 1, index + 1 }) catch return;
            putText(surface, 2, 18, text, error_style);
        } else {
            putText(surface, 2, 18, "S = 000 -> no error detected.", success_style);
        }

        if (self.stage == .diagnosis) {
            putText(surface, 2, 20, "Diagnosis complete. Reveal correction and recovered message.", warning_style);
            drawFooter(surface, "Enter/Space/c correct  r reset  q quit");
            return;
        }

        putText(surface, 2, 19, "Corrected:  ", normal);
        putBits(surface, 15, 19, self.corrected, null, success_style);
        putText(surface, 2, 20, "Recovered m:", normal);
        putBits(surface, 15, 20, self.recovered, null, success_style);
        putText(surface, 35, 20, "positions 4-7", muted_style);
        drawFooter(surface, "Simulation complete  r new message  q quit");
    }

    fn drawCompact(self: *Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        putText(surface, 1, 0, "HAMMING (7,4) SIMULATOR", title_style);
        if (surface.size.height < 10 or surface.size.width < 32) {
            putText(surface, 1, 2, "Terminal is too small.", error_style);
            putText(surface, 1, 3, "Resize to at least 54 x 18.", normal);
            drawFooter(surface, "r reset  q quit");
            return;
        }

        if (self.stage == .message) {
            putText(surface, 1, 3, "Enter 4-bit message:", section_style);
            for (0..self.input.len) |index| {
                const col: u16 = @intCast(2 + index * 4);
                putText(surface, col, 5, "[", normal);
                surface.writeCell(col + 1, 5, .{ .char = .{
                    .grapheme = if (self.input[index] == ' ') " " else self.input[index .. index + 1],
                } });
                putText(surface, col + 2, 5, "]", normal);
            }
            if (self.input_error) putText(surface, 1, 7, "Use exactly four 0/1 digits.", error_style);
            drawFooter(surface, "0/1 type  Enter encode  q quit");
            return;
        }

        putText(surface, 1, 2, "m:", normal);
        putBits(surface, 4, 2, self.message, null, normal);
        putText(surface, 1, 4, "c:", normal);
        putBits(surface, 4, 4, self.codeword, null, success_style);
        putText(surface, 1, 6, "Error:", normal);
        const error_text = if (self.error_choice == 0)
            "none"
        else
            std.fmt.allocPrint(ctx.arena, "bit {d}", .{self.error_choice}) catch "bit";
        putText(surface, 8, 6, error_text, warning_style);

        if (self.stage == .channel) {
            putText(surface, 1, 8, "Select 0-7; Enter transmits.", active_style);
            drawFooter(surface, "0=no error  1-7=bit  Enter send");
            return;
        }
        putText(surface, 1, 8, "r:", normal);
        putBits(surface, 4, 8, self.received, if (self.error_choice == 0) null else self.error_choice - 1, changed_style);
        putText(surface, 1, 10, "S:", normal);
        putBits(surface, 4, 10, self.syndrome, null, warning_style);
        if (self.detected_error) |index| {
            const diagnosis = std.fmt.allocPrint(ctx.arena, "Error located at bit {d}.", .{index + 1}) catch return;
            putText(surface, 1, 12, diagnosis, error_style);
        } else {
            putText(surface, 1, 12, "No error detected.", success_style);
        }
        if (self.stage == .diagnosis) {
            drawFooter(surface, "Enter correct  r reset  q quit");
            return;
        }
        putText(surface, 1, 13, "fixed:", normal);
        putBits(surface, 8, 13, self.corrected, null, success_style);
        putText(surface, 1, 15, "message:", normal);
        putBits(surface, 10, 15, self.recovered, null, success_style);
        drawFooter(surface, "Complete  r reset  q quit");
    }
};

fn putText(surface: vxfw.Surface, start_col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= surface.size.height) return;
    var col = start_col;
    for (text, 0..) |_, index| {
        if (col >= surface.size.width) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = text[index .. index + 1], .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

fn putBits(
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

fn drawGeneratorMatrix(surface: vxfw.Surface, col: u16, row: u16) void {
    putText(surface, col, row, "G = [1 1 1 1 0 0 0]", muted_style);
    putText(surface, col + 4, row + 1, "[1 0 1 0 1 0 0]", muted_style);
    putText(surface, col + 4, row + 2, "[0 1 1 0 0 1 0]", muted_style);
    putText(surface, col + 4, row + 3, "[1 1 0 0 0 0 1]", muted_style);
}

fn drawErrorChoices(self: *Model, surface: vxfw.Surface, start_col: u16, row: u16) void {
    const labels = [_][]const u8{ "No error", "Bit 1", "Bit 2", "Bit 3", "Bit 4", "Bit 5", "Bit 6", "Bit 7" };
    var col = start_col;
    self.choice_row = @intCast(row);
    for (labels, 0..) |label, choice| {
        self.choice_starts[choice] = col;
        putText(surface, col, row, label, if (choice == self.error_choice) active_style else normal);
        col += @intCast(label.len);
        self.choice_ends[choice] = col;
        col += 2;
    }
}

fn drawFooter(surface: vxfw.Surface, text: []const u8) void {
    if (surface.size.height < 2) return;
    putText(surface, 1, surface.size.height - 2, text, muted_style);
}

fn centeredColumn(width: u16, text_width: u16) u16 {
    return if (width > text_width) (width - text_width) / 2 else 0;
}

fn elapsedNanoseconds(start: std.Io.Timestamp, io: std.Io) u64 {
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    return @intCast(@max(elapsed, 0));
}
