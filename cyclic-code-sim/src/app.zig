const std = @import("std");
const vaxis = @import("vaxis");
const code = @import("code.zig");
const ui = @import("circuit.zig");

const vxfw = vaxis.vxfw;

const Stage = enum {
    message,
    encode,
    channel,
    syndrome,
    meggitt,
    result,
    auto_test,
};

const play_ms: u32 = 400;
const full_min_width: u16 = 100;
const full_min_height: u16 = 32;

pub const Model = struct {
    stage: Stage = .message,
    input: [code.k]u8 = @splat(' '),
    input_len: usize = 0,
    input_error: bool = false,
    message: code.Message = @splat(0),
    codeword: code.Codeword = @splat(0),
    error_choice: usize = 0,
    received: code.Codeword = @splat(0),
    syndrome: code.Syndrome = @splat(0),
    corrected: code.Codeword = @splat(0),
    recovered: code.Message = @splat(0),
    encode_snaps: [code.n]code.EncoderSnapshot = @splat(.{}),
    syndrome_snaps: [code.n]code.SyndromeSnapshot = @splat(.{}),
    meggitt_snaps: [code.n]code.MeggittSnapshot = @splat(.{}),
    test_rows: [code.n]code.ErrorTestRow = @splat(.{
        .position = 0,
        .syndrome = @splat(0),
        .meggitt_pos = null,
        .table_pos = null,
        .recovered_ok = false,
    }),
    clock_index: usize = 0,
    playing: bool = false,
    detected_table: ?usize = null,
    detected_meggitt: ?usize = null,
    choice_rows: [16]u16 = @splat(0),
    choice_starts: [16]u16 = @splat(0),
    choice_ends: [16]u16 = @splat(0),
    parse_ns: u64 = 0,
    encode_ns: u64 = 0,
    transmit_ns: u64 = 0,
    syndrome_ns: u64 = 0,
    locate_ns: u64 = 0,
    correct_ns: u64 = 0,
    recover_ns: u64 = 0,

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

    pub fn commitMessage(self: *Model) bool {
        if (self.input_len != self.input.len) {
            self.input_error = true;
            return false;
        }
        self.message = code.parseMessage(self.input[0..]) catch {
            self.input_error = true;
            return false;
        };
        const sim = code.simulateEncoder(self.message);
        self.encode_snaps = sim.snapshots;
        self.codeword = sim.codeword;
        self.clock_index = 0;
        self.playing = false;
        self.stage = .encode;
        self.input_error = false;
        self.test_rows = code.runAllSingleErrors(self.message);
        return true;
    }

    fn beginChannel(self: *Model) void {
        self.playing = false;
        self.clock_index = 0;
        self.stage = .channel;
    }

    fn beginSyndrome(self: *Model, io: std.Io) void {
        const error_index: ?usize = if (self.error_choice == 0) null else self.error_choice - 1;

        const transmit_start = std.Io.Clock.awake.now(io);
        self.received = code.transmit(self.codeword, error_index) catch unreachable;
        self.transmit_ns = elapsedNanoseconds(transmit_start, io);

        const syndrome_start = std.Io.Clock.awake.now(io);
        const syn = code.simulateSyndrome(self.received);
        self.syndrome_snaps = syn.snapshots;
        self.syndrome = syn.syndrome;
        self.syndrome_ns = elapsedNanoseconds(syndrome_start, io);

        const locate_start = std.Io.Clock.awake.now(io);
        self.detected_table = code.locateByTable(self.syndrome);
        const meg = code.simulateMeggitt(self.received, self.syndrome);
        self.meggitt_snaps = meg.snapshots;
        self.detected_meggitt = meg.located;
        self.corrected = meg.corrected;
        self.locate_ns = elapsedNanoseconds(locate_start, io);

        const recover_start = std.Io.Clock.awake.now(io);
        self.recovered = code.recoverMessage(self.corrected);
        self.recover_ns = elapsedNanoseconds(recover_start, io);

        self.clock_index = 0;
        self.playing = false;
        self.stage = .syndrome;
    }

    fn isClocked(self: *const Model) bool {
        return self.stage == .encode or self.stage == .syndrome or self.stage == .meggitt;
    }

    fn stepForward(self: *Model) void {
        if (!self.isClocked()) return;
        if (self.clock_index < code.n) self.clock_index += 1;
        if (self.clock_index == code.n) self.playing = false;
    }

    fn stepBack(self: *Model) void {
        if (!self.isClocked()) return;
        if (self.clock_index > 0) self.clock_index -= 1;
    }

    fn finishClocks(self: *Model) void {
        if (!self.isClocked()) return;
        self.clock_index = code.n;
        self.playing = false;
    }

    fn nextStage(self: *Model, io: std.Io) void {
        switch (self.stage) {
            .message => {
                const parse_start = std.Io.Clock.awake.now(io);
                const ok = self.commitMessage();
                self.parse_ns = elapsedNanoseconds(parse_start, io);
                if (ok) self.encode_ns = self.parse_ns;
            },
            .encode => {
                if (self.clock_index == code.n) self.beginChannel();
            },
            .channel => self.beginSyndrome(io),
            .syndrome => {
                if (self.clock_index == code.n) {
                    self.clock_index = 0;
                    self.playing = false;
                    self.stage = .meggitt;
                }
            },
            .meggitt => {
                if (self.clock_index == code.n) {
                    self.playing = false;
                    self.stage = .result;
                }
            },
            .result => self.stage = .auto_test,
            .auto_test => self.stage = .result,
        }
    }

    fn togglePlay(self: *Model, ctx: *vxfw.EventContext) void {
        if (!self.isClocked()) return;
        self.playing = !self.playing;
        if (self.playing) {
            if (self.clock_index == code.n) self.clock_index = 0;
            ctx.tick(play_ms, self.widget()) catch {};
        }
    }

    fn selectPreviousError(self: *Model) void {
        self.error_choice = if (self.error_choice == 0) 15 else self.error_choice - 1;
    }

    fn selectNextError(self: *Model) void {
        self.error_choice = (self.error_choice + 1) % 16;
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
        if (key.matches('t', .{}) and self.stage != .message) {
            self.playing = false;
            self.stage = if (self.stage == .auto_test) .result else .auto_test;
            if (self.stage == .auto_test and self.clock_index == 0 and self.encode_snaps[0].clock == 0) {
                _ = self.commitMessage();
                self.stage = .auto_test;
            }
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
                    self.nextStage(ctx.io);
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
            .encode, .syndrome, .meggitt => {
                if (key.matches('p', .{})) {
                    self.togglePlay(ctx);
                } else if (key.matches(vaxis.Key.space, .{}) or key.matches('n', .{}) or key.matches(vaxis.Key.right, .{})) {
                    self.playing = false;
                    self.stepForward();
                } else if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.left, .{})) {
                    self.playing = false;
                    self.stepBack();
                } else if (key.matches('f', .{})) {
                    self.finishClocks();
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    self.nextStage(ctx.io);
                }
            },
            .channel => {
                if (key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.up, .{}) or key.matches('h', .{})) {
                    self.selectPreviousError();
                } else if (key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches('l', .{})) {
                    self.selectNextError();
                } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
                    self.nextStage(ctx.io);
                } else if (key.matches('0', .{})) {
                    self.error_choice = 0;
                }
            },
            .result => {
                if (key.matches(vaxis.Key.enter, .{}) or key.matches('t', .{})) {
                    self.stage = .auto_test;
                }
            },
            .auto_test => {
                if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.escape, .{})) {
                    self.stage = .result;
                }
            },
        }
        ctx.consumeAndRedraw();
    }

    fn handleMouse(self: *Model, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) void {
        if (self.stage != .channel or mouse.type != .press or mouse.button != .left) return;
        if (mouse.col < 0 or mouse.row < 0) return;
        const column: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        for (0..self.choice_starts.len) |choice| {
            if (row == self.choice_rows[choice] and column >= self.choice_starts[choice] and column < self.choice_ends[choice]) {
                self.error_choice = choice;
                ctx.consumeAndRedraw();
                return;
            }
        }
    }

    fn handleTick(self: *Model, ctx: *vxfw.EventContext) void {
        if (!self.playing or !self.isClocked()) return;
        self.stepForward();
        if (self.playing and self.clock_index < code.n) {
            ctx.tick(play_ms, self.widget()) catch {};
        }
        ctx.consumeAndRedraw();
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init, .focus_in => try ctx.requestFocus(self.widget()),
            .key_press => |key| self.handleKey(ctx, key),
            .mouse => |mouse| self.handleMouse(ctx, mouse),
            .tick => self.handleTick(ctx),
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.width < full_min_width or size.height < full_min_height) {
            self.drawCompact(surface, ctx);
        } else {
            self.drawFull(surface, ctx);
        }
        if (self.stage == .message and size.height > 5) {
            const cursor_column: u16 = @intCast(@min(12 + self.input_len * 4, @as(usize, size.width -| 1)));
            surface.cursor = .{ .row = 5, .col = cursor_column, .shape = .beam };
        }
        self.drawPerformance(surface, ctx);
        return surface;
    }

    fn drawPerformance(self: *const Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        if (surface.size.height == 0) return;
        const text = switch (self.stage) {
            .message => "Performance: waiting for first calculation",
            .encode => std.fmt.allocPrint(
                ctx.arena,
                "Performance: parse+encode {d} ns",
                .{self.parse_ns},
            ) catch return,
            .channel => std.fmt.allocPrint(
                ctx.arena,
                "Performance: encode snapshots ready | parse {d} ns",
                .{self.parse_ns},
            ) catch return,
            .syndrome, .meggitt => std.fmt.allocPrint(
                ctx.arena,
                "Performance: transmit {d} ns | syndrome {d} ns | locate {d} ns",
                .{ self.transmit_ns, self.syndrome_ns, self.locate_ns },
            ) catch return,
            .result, .auto_test => std.fmt.allocPrint(
                ctx.arena,
                "Performance: recover {d} ns | table lookup {d} ns",
                .{ self.recover_ns, self.locate_ns },
            ) catch return,
        };
        ui.putText(surface, 1, surface.size.height - 1, text, ui.title_style);
    }

    fn drawFull(self: *Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        const width = surface.size.width;
        ui.putText(surface, ui.centeredColumn(width, 44), 0, "(15,11) CYCLIC CODE SHIFT-REGISTER SIM", ui.title_style);
        ui.putText(surface, 2, 1, "Message -> Encoder LFSR -> Codeword -> Channel -> Syndrome LFSR -> Meggitt -> Message", ui.muted_style);
        ui.putText(surface, 2, 2, "g(x) = 1 + x^3 + x^4    c(x) = p(x) + x^4 m(x)    high-order bit c14 sent first", ui.muted_style);

        switch (self.stage) {
            .message => self.drawMessage(surface),
            .encode => self.drawEncode(surface),
            .channel => self.drawChannel(surface, ctx),
            .syndrome => self.drawSyndrome(surface),
            .meggitt => self.drawMeggitt(surface),
            .result => self.drawResult(surface, ctx),
            .auto_test => self.drawAutoTest(surface, ctx),
        }
    }

    fn drawMessage(self: *const Model, surface: vxfw.Surface) void {
        ui.putText(surface, 2, 4, "[1] MESSAGE INPUT  (m0 ... m10, low-order first as typed)", ui.section_style);
        ui.putText(surface, 2, 5, "Message: ", ui.normal);
        for (0..self.input.len) |index| {
            const col: u16 = @intCast(11 + index * 4);
            ui.putText(surface, col, 5, "[", ui.muted_style);
            surface.writeCell(col + 1, 5, .{
                .char = .{ .grapheme = if (self.input[index] == ' ') " " else self.input[index .. index + 1] },
                .style = if (index == self.input_len) ui.active_style else ui.normal,
            });
            ui.putText(surface, col + 2, 5, "]", ui.muted_style);
        }
        ui.putText(surface, 2, 7, "Type eleven binary digits, then press Enter to open the encoder.", ui.normal);
        ui.putText(surface, 2, 8, "The encoder feeds m10 first (premultiplication by x^4), then m9 ... m0.", ui.muted_style);
        if (self.input_error) {
            ui.putText(surface, 2, 10, "Input rejected: enter exactly eleven bits containing only 0 or 1.", ui.error_style);
        }
        ui.drawFooter(surface, "0/1 type  Backspace delete  Enter encode  r reset  q quit");
    }

    fn drawEncode(self: *const Model, surface: vxfw.Surface) void {
        ui.putText(surface, 2, 4, "[2] ENCODER  premultiplied LFSR, gate ON for 11 clocks then parity shifts out", ui.section_style);
        const snap = if (self.clock_index == 0) null else self.encode_snaps[self.clock_index - 1];
        ui.drawEncoderCircuit(surface, 2, 5, snap, self.clock_index, self.message);

        ui.putText(surface, 2, 14, "m =", ui.normal);
        ui.putBits(surface, 6, 14, self.message, null, ui.normal);
        ui.putText(surface, 2, 15, "c =", ui.normal);
        const partial = self.partialCodeword();
        ui.putBits(surface, 6, 15, partial, null, ui.success_style);
        ui.putText(surface, 68, 14, "c = (p0 p1 p2 p3 | m0..m10)", ui.muted_style);

        const log_row: u16 = 17;
        const max_rows = if (surface.size.height > log_row + 3) surface.size.height - log_row - 3 else 0;
        ui.drawEncoderLog(surface, 2, log_row, &self.encode_snaps, self.clock_index, max_rows);
        self.drawClockFooter(surface);
    }

    fn drawChannel(self: *Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        ui.putText(surface, 2, 4, "[3] CHANNEL / ERROR INJECTION", ui.section_style);
        ui.putText(surface, 2, 6, "Transmitted c =", ui.normal);
        ui.putBits(surface, 18, 6, self.codeword, null, ui.success_style);
        ui.putText(surface, 2, 7, "            p0 p1 p2 p3  m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10", ui.muted_style);

        self.drawErrorChoices(surface, 2, 9);

        const preview_index: ?usize = if (self.error_choice == 0) null else self.error_choice - 1;
        const preview = code.transmit(self.codeword, preview_index) catch self.codeword;
        ui.putText(surface, 2, 12, "Received    r =", ui.normal);
        ui.putBits(surface, 18, 12, preview, preview_index, if (preview_index == null) ui.success_style else ui.changed_style);

        const desc = if (preview_index) |index|
            std.fmt.allocPrint(ctx.arena, "Single-bit error at c{d} (coefficient of x^{d}).", .{ index, index }) catch return
        else
            "No error. Received word equals the transmitted codeword.";
        ui.putText(surface, 2, 14, desc, if (preview_index == null) ui.success_style else ui.warning_style);
        ui.putText(surface, 2, 16, "Press Enter to clock the received word into the syndrome register.", ui.normal);
        ui.drawFooter(surface, "Left/Right or h/l select  0=none  click a bit  Enter/Space transmit  r reset  q quit");
    }

    fn drawSyndrome(self: *const Model, surface: vxfw.Surface) void {
        ui.putText(surface, 2, 4, "[4] SYNDROME REGISTER  r14 first, s(x) = r(x) mod g(x)", ui.section_style);
        const snap = if (self.clock_index == 0) null else self.syndrome_snaps[self.clock_index - 1];
        ui.drawSyndromeCircuit(surface, 2, 5, snap, self.clock_index, self.received, false, false);

        if (self.clock_index == code.n) {
            if (code.isZero(self.syndrome)) {
                ui.putText(surface, 2, 14, "NO ERROR  syndrome = 0000", ui.success_style);
            } else {
                var buf: [4]u8 = undefined;
                const bits = code.formatBits(self.syndrome, &buf);
                var line: [40]u8 = undefined;
                const text = std.fmt.bufPrint(&line, "ERROR DETECTED  syndrome = {s}", .{bits}) catch return;
                ui.putText(surface, 2, 14, text, ui.error_style);
            }
        }

        const log_row: u16 = 16;
        const max_rows = if (surface.size.height > log_row + 3) surface.size.height - log_row - 3 else 0;
        ui.drawSyndromeLog(surface, 2, log_row, &self.syndrome_snaps, self.clock_index, max_rows);
        self.drawClockFooter(surface);
    }

    fn drawMeggitt(self: *const Model, surface: vxfw.Surface) void {
        ui.putText(surface, 2, 4, "[5] MEGGITT DECODER  clock S with input 0; fire when S matches x^14 mod g(x)", ui.section_style);
        const match = if (self.clock_index == 0) false else self.meggitt_snaps[self.clock_index - 1].match;
        const view = self.meggittView();
        ui.drawSyndromeCircuit(surface, 2, 5, view, self.clock_index, self.received, true, match);

        ui.putText(surface, 2, 14, "received:", ui.normal);
        ui.putBits(surface, 12, 14, self.received, if (self.error_choice == 0) null else self.error_choice - 1, ui.changed_style);
        if (self.clock_index > 0) {
            const snap = self.meggitt_snaps[self.clock_index - 1];
            ui.putText(surface, 2, 15, "correct :", ui.normal);
            ui.putBits(surface, 12, 15, snap.corrected_so_far, if (snap.match) snap.examine_index else null, ui.success_style);
        }

        const log_row: u16 = 17;
        const max_rows = if (surface.size.height > log_row + 3) surface.size.height - log_row - 3 else 0;
        ui.drawMeggittLog(surface, 2, log_row, &self.meggitt_snaps, self.clock_index, max_rows);
        self.drawClockFooter(surface);
    }

    fn drawResult(self: *const Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        ui.putText(surface, 2, 4, "[6] CORRECTION AND RECOVERY", ui.section_style);

        var syn_buf: [4]u8 = undefined;
        const syn_bits = code.formatBits(self.syndrome, &syn_buf);
        if (code.isZero(self.syndrome)) {
            const text = std.fmt.allocPrint(ctx.arena, "Syndrome {s}  ->  NO ERROR", .{syn_bits}) catch return;
            ui.putText(surface, 2, 6, text, ui.success_style);
        } else {
            const text = std.fmt.allocPrint(ctx.arena, "Syndrome {s}  ->  ERROR DETECTED", .{syn_bits}) catch return;
            ui.putText(surface, 2, 6, text, ui.error_style);
        }

        const table_text = if (self.detected_table) |index|
            std.fmt.allocPrint(ctx.arena, "Lookup table: S matches x^{d} mod g(x)  ->  error at c{d}", .{ index, index }) catch return
        else
            "Lookup table: S = 0000  ->  no error";
        ui.putText(surface, 2, 8, table_text, ui.warning_style);

        const meg_text = if (self.detected_meggitt) |index|
            std.fmt.allocPrint(ctx.arena, "Meggitt decoder: pattern fired while examining c{d}", .{index}) catch return
        else
            "Meggitt decoder: pattern never fired  ->  no correction";
        ui.putText(surface, 2, 9, meg_text, ui.warning_style);

        ui.putText(surface, 2, 11, "Received:  ", ui.normal);
        ui.putBits(surface, 13, 11, self.received, if (self.error_choice == 0) null else self.error_choice - 1, ui.changed_style);
        ui.putText(surface, 2, 12, "Corrected: ", ui.normal);
        ui.putBits(surface, 13, 12, self.corrected, self.detected_meggitt, ui.corrected_style);
        ui.putText(surface, 2, 14, "Recovered m (c4..c14):", ui.normal);
        ui.putBits(surface, 26, 14, self.recovered, null, ui.success_style);

        if (std.mem.eql(code.Bit, &self.recovered, &self.message)) {
            ui.putText(surface, 2, 16, "Recovered message matches the original 11-bit input.", ui.success_style);
        } else {
            ui.putText(surface, 2, 16, "Recovered message does not match. Check the injected error.", ui.error_style);
        }
        ui.putText(surface, 2, 18, "Press t to run the automatic test of all 15 single-bit error locations.", ui.normal);
        ui.drawFooter(surface, "t auto-test  r new message  q quit");
    }

    fn drawAutoTest(self: *const Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        ui.putText(surface, 2, 4, "[7] AUTOMATIC SINGLE-BIT ERROR TEST", ui.section_style);
        ui.putText(surface, 2, 6, "pos   syndrome   table   Meggitt   recovered", ui.section_style);
        for (self.test_rows, 0..) |row, i| {
            var syn_buf: [4]u8 = undefined;
            const syn_bits = code.formatBits(row.syndrome, &syn_buf);
            const table = if (row.table_pos) |p|
                std.fmt.allocPrint(ctx.arena, "c{d}", .{p}) catch "?"
            else
                "none";
            const meg = if (row.meggitt_pos) |p|
                std.fmt.allocPrint(ctx.arena, "c{d}", .{p}) catch "?"
            else
                "none";
            const line = std.fmt.allocPrint(
                ctx.arena,
                " c{d:<2}   {s}      {s:<5}  {s:<5}     {s}",
                .{ row.position, syn_bits, table, meg, if (row.recovered_ok) "ok" else "FAIL" },
            ) catch return;
            const style: vaxis.Style = if (!row.recovered_ok)
                ui.error_style
            else if (self.error_choice > 0 and self.error_choice - 1 == i)
                ui.active_style
            else
                ui.normal;
            ui.putText(surface, 2, @intCast(7 + i), line, style);
        }
        ui.putText(surface, 2, 23, "Each of the 15 injected errors produces a unique syndrome and is corrected.", ui.success_style);
        ui.drawFooter(surface, "Enter/Esc back to result  r new message  q quit");
    }

    fn drawCompact(self: *Model, surface: vxfw.Surface, ctx: vxfw.DrawContext) void {
        ui.putText(surface, 1, 0, "(15,11) CYCLIC SIM  (resize to 100x32 for circuit)", ui.title_style);
        if (surface.size.height < 12 or surface.size.width < 40) {
            ui.putText(surface, 1, 2, "Terminal is too small.", ui.error_style);
            ui.putText(surface, 1, 3, "Resize to at least 54 x 18.", ui.normal);
            ui.drawFooter(surface, "r reset  q quit");
            return;
        }

        switch (self.stage) {
            .message => {
                ui.putText(surface, 1, 2, "Enter 11-bit message:", ui.section_style);
                for (0..self.input.len) |index| {
                    const col: u16 = @intCast(1 + index * 3);
                    surface.writeCell(col, 4, .{
                        .char = .{ .grapheme = if (self.input[index] == ' ') "_" else self.input[index .. index + 1] },
                    });
                }
                if (self.input_error) ui.putText(surface, 1, 6, "Use exactly eleven 0/1 digits.", ui.error_style);
                ui.drawFooter(surface, "0/1 type  Enter encode  q quit");
            },
            .encode => {
                ui.putText(surface, 1, 2, "Encoder LFSR", ui.section_style);
                self.drawCompactRegisters(surface, 1, 4, if (self.clock_index == 0) @splat(0) else self.encode_snaps[self.clock_index - 1].after);
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "clock {d}/15", .{self.clock_index}) catch return;
                ui.putText(surface, 1, 6, text, ui.warning_style);
                ui.putText(surface, 1, 8, "c:", ui.normal);
                ui.putBits(surface, 4, 8, self.partialCodeword(), null, ui.success_style);
                self.drawClockFooter(surface);
            },
            .channel => {
                ui.putText(surface, 1, 2, "c:", ui.normal);
                ui.putBits(surface, 4, 2, self.codeword, null, ui.success_style);
                const err = if (self.error_choice == 0)
                    "none"
                else
                    std.fmt.allocPrint(ctx.arena, "c{d}", .{self.error_choice - 1}) catch "bit";
                ui.putText(surface, 1, 6, "Error:", ui.normal);
                ui.putText(surface, 8, 6, err, ui.warning_style);
                ui.drawFooter(surface, "h/l select  Enter send");
            },
            .syndrome => {
                ui.putText(surface, 1, 2, "Syndrome LFSR", ui.section_style);
                self.drawCompactRegisters(surface, 1, 4, if (self.clock_index == 0) @splat(0) else self.syndrome_snaps[self.clock_index - 1].after);
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "clock {d}/15", .{self.clock_index}) catch return;
                ui.putText(surface, 1, 6, text, ui.warning_style);
                self.drawClockFooter(surface);
            },
            .meggitt => {
                ui.putText(surface, 1, 2, "Meggitt locator", ui.section_style);
                const snap = if (self.clock_index == 0) null else self.meggitt_snaps[self.clock_index - 1];
                self.drawCompactRegisters(surface, 1, 4, if (snap) |s| s.after else @splat(0));
                if (snap) |s| {
                    var buf: [48]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "look c{d} match={s}", .{ s.examine_index, if (s.match) "YES" else "no" }) catch return;
                    ui.putText(surface, 1, 6, text, if (s.match) ui.error_style else ui.normal);
                }
                self.drawClockFooter(surface);
            },
            .result => {
                ui.putText(surface, 1, 2, "S:", ui.normal);
                ui.putBits(surface, 4, 2, self.syndrome, null, ui.warning_style);
                ui.putText(surface, 1, 4, "fixed:", ui.normal);
                ui.putBits(surface, 8, 4, self.corrected, self.detected_meggitt, ui.success_style);
                ui.putText(surface, 1, 8, "m:", ui.normal);
                ui.putBits(surface, 4, 8, self.recovered, null, ui.success_style);
                ui.drawFooter(surface, "t test  r reset  q quit");
            },
            .auto_test => {
                ui.putText(surface, 1, 2, "All-15 error test", ui.section_style);
                var ok: usize = 0;
                for (self.test_rows) |row| {
                    if (row.recovered_ok) ok += 1;
                }
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}/15 recovered", .{ok}) catch return;
                ui.putText(surface, 1, 4, text, if (ok == 15) ui.success_style else ui.error_style);
                ui.drawFooter(surface, "Enter back  q quit");
            },
        }
    }

    fn drawCompactRegisters(self: *const Model, surface: vxfw.Surface, col: u16, row: u16, reg: code.Register) void {
        _ = self;
        ui.putText(surface, col, row, "reg:", ui.normal);
        ui.putBits(surface, col + 5, row, reg, null, ui.warning_style);
    }

    fn drawClockFooter(self: *const Model, surface: vxfw.Surface) void {
        const extra = if (self.clock_index == code.n) "  Enter next stage" else "";
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Space/n/Right clock  Left/Backspace back  p play  f finish{s}  r reset  q quit", .{extra}) catch
            "Space clock  p play  f finish  r reset  q quit";
        ui.drawFooter(surface, text);
    }

    fn drawErrorChoices(self: *Model, surface: vxfw.Surface, start_col: u16, row: u16) void {
        const labels = [_][]const u8{
            "none", "c0", "c1", "c2",  "c3",  "c4",  "c5",  "c6",
            "c7",   "c8", "c9", "c10", "c11", "c12", "c13", "c14",
        };
        var col = start_col;
        var current_row = row;
        for (labels, 0..) |label, choice| {
            if (choice == 8) {
                current_row += 1;
                col = start_col;
            }
            self.choice_rows[choice] = current_row;
            self.choice_starts[choice] = col;
            ui.putText(surface, col, current_row, label, if (choice == self.error_choice) ui.active_style else ui.normal);
            col += @intCast(label.len);
            self.choice_ends[choice] = col;
            col += 2;
        }
    }

    fn partialCodeword(self: *const Model) code.Codeword {
        var word: code.Codeword = @splat(0);
        var i: usize = 0;
        while (i < self.clock_index) : (i += 1) {
            word[code.n - 1 - i] = self.encode_snaps[i].out;
        }
        return word;
    }

    fn meggittView(self: *const Model) ?code.SyndromeSnapshot {
        if (self.clock_index == 0) return null;
        const s = self.meggitt_snaps[self.clock_index - 1];
        return .{
            .clock = s.clock,
            .in_bit = 0,
            .in_index = s.examine_index,
            .fb = s.fb,
            .before = s.before,
            .after = s.after,
            .d = s.after_correct,
        };
    }
};

fn elapsedNanoseconds(start: std.Io.Timestamp, io: std.Io) u64 {
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    return @intCast(@max(elapsed, 0));
}

test "commitMessage encodes eleven bits into 15 encoder snapshots" {
    var model: Model = .{};
    const typed = "10110011101";
    for (typed, 0..) |ch, i| model.input[i] = ch;
    model.input_len = typed.len;
    try std.testing.expect(model.commitMessage());
    try std.testing.expectEqual(Stage.encode, model.stage);
    try std.testing.expectEqual(@as(usize, 0), model.clock_index);
    try std.testing.expectEqual(@as(usize, 15), model.encode_snaps.len);
    try std.testing.expect(model.encode_snaps[0].gate);
}

test "all-15 error table recovers the original message" {
    var model: Model = .{};
    const typed = "11001010111";
    for (typed, 0..) |ch, i| model.input[i] = ch;
    model.input_len = typed.len;
    try std.testing.expect(model.commitMessage());
    for (model.test_rows) |row| {
        try std.testing.expect(row.recovered_ok);
        try std.testing.expectEqual(row.table_pos, row.meggitt_pos);
    }
}
