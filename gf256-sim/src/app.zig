const std = @import("std");
const vaxis = @import("vaxis");
const gf = @import("gf256.zig");

const vxfw = vaxis.vxfw;

const View = enum(u3) {
    overview,
    table,
    addition,
    multiplication,
    division,
};

const Operation = enum(u2) {
    addition,
    multiplication,
    division,
};

const Example = struct {
    a: u8,
    b: u8,
    result: u8,
};

const normal: vaxis.Style = .{};
const title_style: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };
const section_style: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true };
const active_style: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true };
const success_style: vaxis.Style = .{ .fg = .{ .index = 2 }, .bold = true };
const warning_style: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
const error_style: vaxis.Style = .{ .fg = .{ .index = 1 }, .bold = true };
const muted_style: vaxis.Style = .{ .dim = true };

pub const Model = struct {
    view: View = .overview,
    table_offset: u8 = 0,
    active_operand: usize = 0,
    inputs: [3][2][2]u8 = .{
        .{ .{ '5', '7' }, .{ '8', '3' } },
        .{ .{ '5', '7' }, .{ '1', '3' } },
        .{ .{ 'e', '0' }, .{ '1', '3' } },
    },
    input_lengths: [3][2]u2 = .{
        .{ 2, 2 },
        .{ 2, 2 },
        .{ 2, 2 },
    },
    histories: [3][8]Example = @splat(@splat(.{ .a = 0, .b = 0, .result = 0 })),
    history_lengths: [3]u4 = @splat(0),
    input_error: bool = false,
    division_by_zero: bool = false,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn setView(self: *Model, view: View) void {
        self.view = view;
        self.input_error = false;
        self.division_by_zero = false;
    }

    fn operation(self: *const Model) ?Operation {
        return switch (self.view) {
            .addition => .addition,
            .multiplication => .multiplication,
            .division => .division,
            else => null,
        };
    }

    fn cycleView(self: *Model, direction: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.view));
        const next = @mod(current + direction, 5);
        self.setView(@enumFromInt(@as(u3, @intCast(next))));
    }

    fn clearCurrentHistory(self: *Model) void {
        const operation_value = self.operation() orelse return;
        self.history_lengths[@intFromEnum(operation_value)] = 0;
    }

    fn calculate(self: *Model) void {
        const operation_value = self.operation() orelse return;
        const op_index = @intFromEnum(operation_value);
        if (self.input_lengths[op_index][0] != 2 or self.input_lengths[op_index][1] != 2) {
            self.input_error = true;
            return;
        }

        const a = parseHexByte(self.inputs[op_index][0]);
        const b = parseHexByte(self.inputs[op_index][1]);
        const result = switch (operation_value) {
            .addition => gf.add(a, b),
            .multiplication => gf.multiply(a, b),
            .division => gf.divide(a, b) catch {
                self.division_by_zero = true;
                self.input_error = false;
                return;
            },
        };

        var length: usize = self.history_lengths[op_index];
        if (length == self.histories[op_index].len) {
            for (1..length) |index| {
                self.histories[op_index][index - 1] = self.histories[op_index][index];
            }
            length -= 1;
        }
        self.histories[op_index][length] = .{ .a = a, .b = b, .result = result };
        self.history_lengths[op_index] = @intCast(length + 1);
        self.input_error = false;
        self.division_by_zero = false;
    }

    fn editOperand(self: *Model, digit: u8) void {
        const operation_value = self.operation() orelse return;
        const op_index = @intFromEnum(operation_value);
        var length: usize = self.input_lengths[op_index][self.active_operand];
        if (length == 2) length = 0;
        self.inputs[op_index][self.active_operand][length] = digit;
        self.input_lengths[op_index][self.active_operand] = @intCast(length + 1);
        self.input_error = false;
        self.division_by_zero = false;
    }

    fn deleteDigit(self: *Model) void {
        const operation_value = self.operation() orelse return;
        const op_index = @intFromEnum(operation_value);
        var length: usize = self.input_lengths[op_index][self.active_operand];
        if (length == 0) return;
        length -= 1;
        self.inputs[op_index][self.active_operand][length] = ' ';
        self.input_lengths[op_index][self.active_operand] = @intCast(length);
        self.input_error = false;
        self.division_by_zero = false;
    }

    fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
            ctx.quit = true;
            return;
        }

        if (key.matches(0x1b, .{})) {
            self.setView(.overview);
        } else if (key.matches(vaxis.Key.f1, .{})) {
            self.setView(.overview);
        } else if (key.matches(vaxis.Key.f2, .{})) {
            self.setView(.table);
        } else if (key.matches(vaxis.Key.f3, .{})) {
            self.setView(.addition);
        } else if (key.matches(vaxis.Key.f4, .{})) {
            self.setView(.multiplication);
        } else if (key.matches(vaxis.Key.f5, .{})) {
            self.setView(.division);
        } else if (key.matches('[', .{}) or key.matches('p', .{})) {
            self.cycleView(-1);
        } else if (key.matches(']', .{}) or key.matches('n', .{})) {
            self.cycleView(1);
        } else if (self.operation() == null and key.matches('1', .{})) {
            self.setView(.overview);
        } else if (self.operation() == null and key.matches('2', .{})) {
            self.setView(.table);
        } else if (self.operation() == null and key.matches('3', .{})) {
            self.setView(.addition);
        } else if (self.operation() == null and key.matches('4', .{})) {
            self.setView(.multiplication);
        } else if (self.operation() == null and key.matches('5', .{})) {
            self.setView(.division);
        } else if (key.matches(vaxis.Key.tab, .{})) {
            if (self.operation() != null) {
                self.active_operand = 1 - self.active_operand;
            } else {
                self.cycleView(1);
            }
        } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            if (self.operation() != null) self.active_operand = 0 else self.cycleView(-1);
        } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            if (self.operation() != null) self.active_operand = 1 else self.cycleView(1);
        } else switch (self.view) {
            .table => self.handleTableKey(key),
            .addition, .multiplication, .division => self.handleCalculatorKey(key),
            .overview => {},
        }
        ctx.consumeAndRedraw();
    }

    fn handleTableKey(self: *Model, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.table_offset -|= 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.table_offset +|= 1;
        } else if (key.matches(vaxis.Key.page_up, .{})) {
            self.table_offset -|= 16;
        } else if (key.matches(vaxis.Key.page_down, .{})) {
            self.table_offset +|= 16;
        } else if (key.matches(vaxis.Key.home, .{})) {
            self.table_offset = 0;
        } else if (key.matches(vaxis.Key.end, .{})) {
            self.table_offset = 255;
        }
    }

    fn handleCalculatorKey(self: *Model, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('=', .{})) {
            self.calculate();
        } else if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.delete, .{})) {
            self.deleteDigit();
        } else if (key.matches('r', .{})) {
            self.clearCurrentHistory();
        } else if (key.matches('x', .{}) or key.matches('X', .{})) {
            self.consumeHexPrefix();
        } else if (hexKey(key)) |digit| {
            self.editOperand(digit);
        } else if (key.codepoint >= 0x20 and key.codepoint <= 0x7e) {
            self.input_error = true;
        }
    }

    fn consumeHexPrefix(self: *Model) void {
        const operation_value = self.operation() orelse return;
        const op_index = @intFromEnum(operation_value);
        const length = self.input_lengths[op_index][self.active_operand];
        if (length == 1 and self.inputs[op_index][self.active_operand][0] == '0') {
            self.inputs[op_index][self.active_operand] = .{ ' ', ' ' };
            self.input_lengths[op_index][self.active_operand] = 0;
            self.input_error = false;
            return;
        }
        self.input_error = true;
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init, .focus_in => try ctx.requestFocus(self.widget()),
            .key_press => |key| self.handleKey(ctx, key),
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        self.draw(surface, ctx);

        if (self.operation()) |operation_value| {
            const op_index = @intFromEnum(operation_value);
            const digit_col: u16 = if (self.active_operand == 0) 7 else 21;
            const length: u16 = self.input_lengths[op_index][self.active_operand];
            if (size.height > 7 and digit_col + length < size.width) {
                surface.cursor = .{ .row = 6, .col = digit_col + length, .shape = .beam };
            }
        }
        return surface;
    }

    fn draw(self: *Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        if (surface.size.width < 42 or surface.size.height < 14) {
            putText(surface, 1, 1, "GF(256) EXPLORER", title_style);
            putText(surface, 1, 3, "Terminal is too small.", error_style);
            putText(surface, 1, 4, "Resize to at least 42 x 14.", normal);
            return;
        }

        putText(surface, centeredColumn(surface.size.width, 16), 0, "GF(256) EXPLORER", title_style);
        drawNavigation(self, surface);

        switch (self.view) {
            .overview => self.drawOverview(surface),
            .table => self.drawTable(surface, ctx),
            .addition => self.drawCalculator(surface, ctx, .addition),
            .multiplication => self.drawCalculator(surface, ctx, .multiplication),
            .division => self.drawCalculator(surface, ctx, .division),
        }
        drawFooter(surface, "p/n or [/] section  Esc overview  F1-F5 jump  q quit");
    }

    fn drawOverview(self: *const Model, surface: vxfw.Surface) void {
        _ = self;
        putText(surface, 2, 4, "FIELD DEFINITION", section_style);
        putText(surface, 2, 6, "GF(256) = GF(2^8)", success_style);
        putText(surface, 2, 7, "p(x) = x^8 + x^4 + x^3 + x^2 + 1", normal);
        putText(surface, 2, 8, "Polynomial: 0x11D   reduction byte: 0x1D", muted_style);
        putText(surface, 2, 10, "The table uses LFSR coefficient order [a0 ... a7]:", section_style);
        putText(surface, 2, 11, "a0 + a1*x + ... + a7*x^7 (constant coefficient first)", normal);
        if (surface.size.height > 18) {
            putText(surface, 2, 13, "Addition", warning_style);
            putText(surface, 16, 13, "coefficient XOR (no carries)", normal);
            putText(surface, 2, 14, "Multiplication", warning_style);
            putText(surface, 16, 14, "carryless polynomial product mod p(x)", normal);
            putText(surface, 2, 15, "Division", warning_style);
            putText(surface, 16, 15, "multiply by the nonzero divisor's inverse", normal);
            putText(surface, 2, 17, "Choose 2 for all 256 elements or 3-5 for calculators.", success_style);
        }
    }

    fn drawTable(self: *const Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        putText(surface, 2, 4, "COMPLETE FIELD-TO-BINARY TABLE", section_style);
        putText(surface, 2, 5, "ENTRY   ELEMENT       LFSR BITS   COEFFICIENT ORDER", muted_style);

        const first_row: u16 = 6;
        const last_row = surface.size.height - 2;
        const available: usize = last_row - first_row;
        var row_index: usize = 0;
        while (row_index < available) : (row_index += 1) {
            const raw = @as(usize, self.table_offset) + row_index;
            if (raw > 255) break;
            const entry: u8 = @intCast(raw);
            const bits = gf.tableBinary(entry);
            const element = if (entry == 0)
                "0"
            else
                std.fmt.allocPrint(ctx.arena, "alpha^{d}", .{entry - 1}) catch return;
            const line = std.fmt.allocPrint(
                ctx.arena,
                "{d: >3}     {s: <11} {s}    [1, x, ..., x^7]",
                .{ entry, element, &bits },
            ) catch return;
            putText(surface, 2, @intCast(first_row + row_index), line, if (entry == self.table_offset) active_style else normal);
        }

        const status = std.fmt.allocPrint(
            ctx.arena,
            "Showing from {d}/255  Up/Down, j/k, PgUp/PgDn, Home/End scroll",
            .{self.table_offset},
        ) catch return;
        putText(surface, 2, surface.size.height - 3, status, warning_style);
    }

    fn drawCalculator(
        self: *const Model,
        surface: vxfw.Surface,
        ctx: vxfw.DrawContext,
        operation_value: Operation,
    ) void {
        const op_index = @intFromEnum(operation_value);
        const symbol: []const u8 = switch (operation_value) {
            .addition => "+",
            .multiplication => "*",
            .division => "/",
        };
        const heading: []const u8 = switch (operation_value) {
            .addition => "GF(256) ADDITION",
            .multiplication => "GF(256) MULTIPLICATION",
            .division => "GF(256) DIVISION",
        };

        putText(surface, 2, 4, heading, section_style);
        putText(surface, 2, 6, "A: 0x", normal);
        drawInput(surface, 7, 6, self.inputs[op_index][0], self.input_lengths[op_index][0], self.active_operand == 0);
        putText(surface, 11, 6, symbol, warning_style);
        putText(surface, 16, 6, "B: 0x", normal);
        drawInput(surface, 21, 6, self.inputs[op_index][1], self.input_lengths[op_index][1], self.active_operand == 1);
        putText(surface, 26, 6, "Enter calculates; Tab selects operand", muted_style);

        if (self.input_error) {
            putText(surface, 2, 8, "Enter exactly two hexadecimal digits (00-FF) per operand.", error_style);
        } else if (self.division_by_zero) {
            putText(surface, 2, 8, "Division rejected: 0 has no multiplicative inverse.", error_style);
        } else {
            putText(surface, 2, 8, "Typing replaces a complete byte; Backspace edits.", muted_style);
        }

        const history_length: usize = self.history_lengths[op_index];
        if (history_length == 0) {
            putText(surface, 2, 10, "No calculations yet. The current inputs are ready to run.", warning_style);
            putText(surface, 2, 12, operationExplanation(operation_value), normal);
            return;
        }

        const latest = self.histories[op_index][history_length - 1];
        const a_bits = gf.binary(latest.a);
        const b_bits = gf.binary(latest.b);
        const result_bits = gf.binary(latest.result);
        const result_line = std.fmt.allocPrint(
            ctx.arena,
            "Result: 0x{X:0>2} {s} 0x{X:0>2} = 0x{X:0>2}  (decimal {d})",
            .{ latest.a, symbol, latest.b, latest.result, latest.result },
        ) catch return;
        putText(surface, 2, 10, result_line, success_style);
        const binary_line = std.fmt.allocPrint(
            ctx.arena,
            "Binary: {s} {s} {s} = {s}",
            .{ &a_bits, symbol, &b_bits, &result_bits },
        ) catch return;
        putText(surface, 2, 11, binary_line, normal);
        drawCheck(surface, ctx, operation_value, latest, 12);

        if (surface.size.height > 18) {
            putText(surface, 2, 14, "RECENT EXAMPLES (oldest to newest)", section_style);
            const maximum_rows: usize = surface.size.height - 17;
            const start = history_length -| maximum_rows;
            var history_index = start;
            var row: u16 = 15;
            while (history_index < history_length and row < surface.size.height - 2) : ({
                history_index += 1;
                row += 1;
            }) {
                const item = self.histories[op_index][history_index];
                const line = std.fmt.allocPrint(
                    ctx.arena,
                    "{d}.  0x{X:0>2} {s} 0x{X:0>2} = 0x{X:0>2}",
                    .{ history_index + 1, item.a, symbol, item.b, item.result },
                ) catch return;
                putText(surface, 4, row, line, if (history_index + 1 == history_length) success_style else normal);
            }
            putText(surface, 43, 14, "r clears this history", muted_style);
        }
    }
};

fn drawNavigation(self: *const Model, surface: vxfw.Surface) void {
    const labels = [_][]const u8{ "1 Overview", "2 Table", "3 Add", "4 Multiply", "5 Divide" };
    var col: u16 = 2;
    for (labels, 0..) |label, index| {
        if (col >= surface.size.width) break;
        putText(surface, col, 2, label, if (index == @intFromEnum(self.view)) active_style else normal);
        col += @intCast(label.len + 2);
    }
}

fn drawInput(surface: vxfw.Surface, col: u16, row: u16, input: [2]u8, length: u2, active: bool) void {
    for (0..2) |index| {
        surface.writeCell(col + @as(u16, @intCast(index)), row, .{
            .char = .{ .grapheme = if (index < length) input[index .. index + 1] else "_" },
            .style = if (active) active_style else normal,
        });
    }
}

fn drawCheck(
    surface: vxfw.Surface,
    ctx: vxfw.DrawContext,
    operation_value: Operation,
    example: Example,
    row: u16,
) void {
    const check = switch (operation_value) {
        .addition => std.fmt.allocPrint(
            ctx.arena,
            "Check: bitwise XOR gives 0x{X:0>2}; coefficients add modulo 2.",
            .{example.result},
        ) catch return,
        .multiplication => if (example.b == 0)
            std.fmt.allocPrint(
                ctx.arena,
                "Check: every polynomial multiplied by zero is zero; result = 0x{X:0>2}.",
                .{example.result},
            ) catch return
        else
            std.fmt.allocPrint(
                ctx.arena,
                "Check: carryless product reduced modulo 0x11D; result / 0x{X:0>2} = 0x{X:0>2}.",
                .{ example.b, gf.divide(example.result, example.b) catch 0 },
            ) catch return,
        .division => blk: {
            const reciprocal = gf.inverse(example.b) catch return;
            break :blk std.fmt.allocPrint(
                ctx.arena,
                "Check: inverse(0x{X:0>2}) = 0x{X:0>2}; 0x{X:0>2} * 0x{X:0>2} = 0x{X:0>2}.",
                .{ example.b, reciprocal, example.result, example.b, gf.multiply(example.result, example.b) },
            ) catch return;
        },
    };
    putText(surface, 2, row, check, warning_style);
}

fn operationExplanation(operation_value: Operation) []const u8 {
    return switch (operation_value) {
        .addition => "Addition is XOR: coefficients add modulo 2 without carries.",
        .multiplication => "Multiply polynomials without carries, then reduce modulo 0x11D.",
        .division => "For nonzero B, A / B = A * B^-1 where B^-1 = B^254.",
    };
}

fn hexKey(key: vaxis.Key) ?u8 {
    if (key.codepoint >= '0' and key.codepoint <= '9') return @intCast(key.codepoint);
    if (key.codepoint >= 'a' and key.codepoint <= 'f') return @intCast(key.codepoint);
    if (key.codepoint >= 'A' and key.codepoint <= 'F') return @intCast(key.codepoint + 32);
    return null;
}

fn parseHexByte(digits: [2]u8) u8 {
    return hexValue(digits[0]) * 16 + hexValue(digits[1]);
}

fn hexValue(digit: u8) u8 {
    return if (digit <= '9') digit - '0' else digit - 'a' + 10;
}

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

fn drawFooter(surface: vxfw.Surface, text: []const u8) void {
    if (surface.size.height < 2) return;
    putText(surface, 1, surface.size.height - 1, text, muted_style);
}

fn centeredColumn(width: u16, text_width: u16) u16 {
    return if (width > text_width) (width - text_width) / 2 else 0;
}

test "calculator accepts replacement bytes with optional 0x prefix" {
    var model: Model = .{};
    model.setView(.addition);

    model.editOperand('0');
    model.consumeHexPrefix();
    model.editOperand('5');
    model.editOperand('7');
    try std.testing.expectEqualStrings("57", &model.inputs[0][0]);

    model.active_operand = 1;
    model.editOperand('8');
    model.editOperand('3');
    model.calculate();

    try std.testing.expectEqual(@as(u4, 1), model.history_lengths[0]);
    try std.testing.expectEqual(@as(u8, 0xd4), model.histories[0][0].result);
    try std.testing.expect(!model.input_error);
}

test "calculator rejects division by zero without recording history" {
    var model: Model = .{};
    model.setView(.division);
    model.inputs[2][1] = .{ '0', '0' };
    model.input_lengths[2][1] = 2;
    model.calculate();

    try std.testing.expect(model.division_by_zero);
    try std.testing.expectEqual(@as(u4, 0), model.history_lengths[2]);
}

test "calculator pages always cycle back to non-input pages" {
    var model: Model = .{};
    model.setView(.addition);
    model.cycleView(1);
    try std.testing.expectEqual(View.multiplication, model.view);
    model.cycleView(1);
    try std.testing.expectEqual(View.division, model.view);
    model.cycleView(1);
    try std.testing.expectEqual(View.overview, model.view);
    model.setView(.addition);
    model.cycleView(-1);
    try std.testing.expectEqual(View.table, model.view);
}
