const std = @import("std");

pub const Bit = u1;
pub const n: usize = 15;
pub const k: usize = 11;
pub const parity_len: usize = n - k;

pub const Message = [k]Bit;
pub const Codeword = [n]Bit;
pub const Register = [parity_len]Bit;
pub const Syndrome = Register;

/// g(x) = 1 + x^3 + x^4, stored as [g0, g1, g2, g3, g4].
pub const G = [parity_len + 1]Bit{ 1, 0, 0, 1, 1 };
pub const G_POLY: u16 = polyFromCoeffs(G);

pub const ParseError = error{
    WrongLength,
    NonBinaryDigit,
};

pub const EncoderStep = struct {
    next: Register,
    fb: Bit,
    out: Bit,
    d: Register,
};

pub const SyndromeStep = struct {
    next: Register,
    fb: Bit,
    d: Register,
};

pub const EncoderSnapshot = struct {
    clock: usize = 0,
    in_bit: Bit = 0,
    gate: bool = false,
    fb: Bit = 0,
    out: Bit = 0,
    before: Register = @splat(0),
    after: Register = @splat(0),
    d: Register = @splat(0),
};

pub const SyndromeSnapshot = struct {
    clock: usize = 0,
    in_bit: Bit = 0,
    in_index: usize = 0,
    fb: Bit = 0,
    before: Register = @splat(0),
    after: Register = @splat(0),
    d: Register = @splat(0),
};

pub const ErrorTestRow = struct {
    position: usize,
    syndrome: Syndrome,
    table_pos: ?usize,
    recovered_ok: bool,
};

pub fn parseMessage(text: []const u8) ParseError!Message {
    if (text.len != k) return error.WrongLength;

    var message: Message = undefined;
    for (text, 0..) |character, index| {
        message[index] = switch (character) {
            '0' => 0,
            '1' => 1,
            else => return error.NonBinaryDigit,
        };
    }
    return message;
}

/// Premultiplied encoder clock. Gate on: fb = in XOR r3, output is the message bit.
/// Gate off: fb = 0, output is r3, and the remainder shifts out high bit first.
pub fn encoderStep(reg: Register, in_bit: Bit, gate: bool) EncoderStep {
    const fb: Bit = if (gate) in_bit ^ reg[parity_len - 1] else 0;
    const out: Bit = if (gate) in_bit else reg[parity_len - 1];
    var d: Register = undefined;
    d[0] = fb;
    inline for (1..parity_len) |stage| {
        d[stage] = reg[stage - 1] ^ (G[stage] & fb);
    }
    return .{ .next = d, .fb = fb, .out = out, .d = d };
}

/// Division-circuit clock. Received bits enter at s0; feedback is s3.
pub fn syndromeStep(reg: Register, in_bit: Bit) SyndromeStep {
    const fb = reg[parity_len - 1];
    var d: Register = undefined;
    d[0] = in_bit ^ fb;
    inline for (1..parity_len) |stage| {
        d[stage] = reg[stage - 1] ^ (G[stage] & fb);
    }
    return .{ .next = d, .fb = fb, .d = d };
}

pub fn simulateEncoder(message: Message) struct { snapshots: [n]EncoderSnapshot, codeword: Codeword } {
    var reg: Register = @splat(0);
    var snapshots: [n]EncoderSnapshot = @splat(.{});
    var codeword: Codeword = @splat(0);

    for (0..n) |i| {
        const gate = i < k;
        const in_bit: Bit = if (gate) message[k - 1 - i] else 0;
        const before = reg;
        const step = encoderStep(reg, in_bit, gate);
        const out_index = n - 1 - i;
        codeword[out_index] = step.out;
        snapshots[i] = .{
            .clock = i + 1,
            .in_bit = in_bit,
            .gate = gate,
            .fb = step.fb,
            .out = step.out,
            .before = before,
            .after = step.next,
            .d = step.d,
        };
        reg = step.next;
    }
    return .{ .snapshots = snapshots, .codeword = codeword };
}

pub fn encode(message: Message) Codeword {
    return simulateEncoder(message).codeword;
}

pub fn transmit(codeword: Codeword, error_index: ?usize) error{InvalidBitPosition}!Codeword {
    var received = codeword;
    if (error_index) |index| {
        if (index >= received.len) return error.InvalidBitPosition;
        received[index] ^= 1;
    }
    return received;
}

pub fn simulateSyndrome(received: Codeword) struct { snapshots: [n]SyndromeSnapshot, syndrome: Syndrome } {
    var reg: Register = @splat(0);
    var snapshots: [n]SyndromeSnapshot = @splat(.{});
    for (0..n) |i| {
        const in_index = n - 1 - i;
        const before = reg;
        const step = syndromeStep(reg, received[in_index]);
        snapshots[i] = .{
            .clock = i + 1,
            .in_bit = received[in_index],
            .in_index = in_index,
            .fb = step.fb,
            .before = before,
            .after = step.next,
            .d = step.d,
        };
        reg = step.next;
    }
    return .{ .snapshots = snapshots, .syndrome = reg };
}

pub fn calculateSyndrome(received: Codeword) Syndrome {
    return simulateSyndrome(received).syndrome;
}

pub fn correct(received: Codeword, syndrome: Syndrome) Codeword {
    var corrected = received;
    if (locateByTable(syndrome)) |index| corrected[index] ^= 1;
    return corrected;
}

pub fn recoverMessage(corrected: Codeword) Message {
    return corrected[parity_len..n].*;
}

pub fn syndromeTable() [n]Syndrome {
    var table: [n]Syndrome = undefined;
    for (0..n) |i| {
        table[i] = remainderFromPoly(modG(@as(u16, 1) << @intCast(i)));
    }
    return table;
}

pub fn locateByTable(syndrome: Syndrome) ?usize {
    if (isZero(syndrome)) return null;
    const table = syndromeTable();
    for (table, 0..) |pattern, index| {
        if (std.mem.eql(Bit, &syndrome, &pattern)) return index;
    }
    return null;
}

pub fn runAllSingleErrors(message: Message) [n]ErrorTestRow {
    const codeword = encode(message);
    var rows: [n]ErrorTestRow = undefined;
    for (0..n) |pos| {
        const received = transmit(codeword, pos) catch unreachable;
        const syn = calculateSyndrome(received);
        const table_pos = locateByTable(syn);
        const recovered = recoverMessage(correct(received, syn));
        rows[pos] = .{
            .position = pos,
            .syndrome = syn,
            .table_pos = table_pos,
            .recovered_ok = std.mem.eql(Bit, &recovered, &message),
        };
    }
    return rows;
}

pub fn isZero(reg: Register) bool {
    return std.mem.eql(Bit, &reg, &@as(Register, @splat(0)));
}

pub fn polyFromBits(bits: anytype) u16 {
    var p: u16 = 0;
    for (bits, 0..) |bit, index| {
        if (bit == 1) p |= @as(u16, 1) << @intCast(index);
    }
    return p;
}

pub fn remainderFromPoly(p: u16) Register {
    var reg: Register = @splat(0);
    for (0..parity_len) |i| {
        reg[i] = @intCast((p >> @intCast(i)) & 1);
    }
    return reg;
}

pub fn modG(dividend: u16) u16 {
    var p = dividend;
    var degree: i32 = 15;
    while (degree >= @as(i32, @intCast(parity_len))) : (degree -= 1) {
        if ((p >> @intCast(degree)) & 1 == 1) {
            p ^= G_POLY << @intCast(degree - @as(i32, @intCast(parity_len)));
        }
    }
    return p;
}

fn remainderFromPolyFull(p: u16) Codeword {
    var codeword: Codeword = @splat(0);
    for (0..n) |i| {
        codeword[i] = @intCast((p >> @intCast(i)) & 1);
    }
    return codeword;
}

fn polyFromCoeffs(coeffs: [parity_len + 1]Bit) u16 {
    var p: u16 = 0;
    for (coeffs, 0..) |bit, index| {
        if (bit == 1) p |= @as(u16, 1) << @intCast(index);
    }
    return p;
}

pub fn formatBits(bits: anytype, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= bits.len);
    for (bits, 0..) |bit, index| {
        buf[index] = if (bit == 0) '0' else '1';
    }
    return buf[0..bits.len];
}

test "generator polynomial bits match 1 + x^3 + x^4" {
    try std.testing.expectEqual(@as(u16, 0b11001), G_POLY);
}

test "parseMessage accepts only 11 binary digits" {
    try std.testing.expectError(error.WrongLength, parseMessage("1011"));
    try std.testing.expectError(error.NonBinaryDigit, parseMessage("1011001110a"));
    const message = try parseMessage("10110011101");
    try std.testing.expectEqual(@as(Bit, 1), message[0]);
    try std.testing.expectEqual(@as(Bit, 1), message[10]);
}

test "shift-register encoder matches polynomial division for all messages" {
    for (0..(@as(usize, 1) << k)) |raw| {
        var message: Message = undefined;
        for (0..k) |i| {
            message[i] = @intCast((raw >> @intCast(i)) & 1);
        }
        const hardware = encode(message);
        const algebraic = remainderFromPolyFull(polyFromBits(message) << @intCast(parity_len) ^ modG(polyFromBits(message) << @intCast(parity_len)));
        try std.testing.expectEqualSlices(Bit, &algebraic, &hardware);
        try std.testing.expectEqual(@as(u16, 0), modG(polyFromBits(hardware)));
        try std.testing.expectEqualSlices(Bit, &message, &recoverMessage(hardware));
    }
}

test "zero syndrome for a valid codeword" {
    const message = try parseMessage("11001010111");
    const codeword = encode(message);
    const syn = calculateSyndrome(codeword);
    try std.testing.expect(isZero(syn));
    try std.testing.expectEqual(@as(?usize, null), locateByTable(syn));
    try std.testing.expectEqualSlices(Bit, &message, &recoverMessage(correct(codeword, syn)));
}

test "every single-bit error is located by the lookup table" {
    const message = try parseMessage("10110011101");
    const rows = runAllSingleErrors(message);
    for (rows, 0..) |row, pos| {
        try std.testing.expectEqual(pos, row.position);
        try std.testing.expect(row.recovered_ok);
        try std.testing.expectEqual(@as(?usize, pos), row.table_pos);
        try std.testing.expect(!isZero(row.syndrome));
        try std.testing.expectEqualSlices(Bit, &syndromeTable()[pos], &row.syndrome);
    }
}

test "syndrome register equals r(x) mod g(x)" {
    const message = try parseMessage("01101100101");
    const codeword = encode(message);
    for (0..n) |pos| {
        const received = try transmit(codeword, pos);
        const syn = calculateSyndrome(received);
        const algebraic = remainderFromPoly(modG(polyFromBits(received)));
        try std.testing.expectEqualSlices(Bit, &algebraic, &syn);
    }
}

test "encoder snapshots produce the systematic layout" {
    const message = try parseMessage("10000000000");
    const sim = simulateEncoder(message);
    try std.testing.expectEqualSlices(Bit, &message, sim.codeword[parity_len..n]);
    try std.testing.expectEqual(@as(usize, 15), sim.snapshots.len);
    try std.testing.expect(sim.snapshots[0].gate);
    try std.testing.expectEqual(@as(Bit, 0), sim.snapshots[0].in_bit);
    try std.testing.expectEqual(@as(Bit, 1), sim.snapshots[k - 1].in_bit);
    try std.testing.expect(!sim.snapshots[k].gate);
}

test "handout cases: no error and errors at beginning, middle, and end" {
    const message = try parseMessage("10110011101");
    const codeword = encode(message);

    const clean = try transmit(codeword, null);
    try std.testing.expect(isZero(calculateSyndrome(clean)));
    try std.testing.expectEqual(@as(?usize, null), locateByTable(calculateSyndrome(clean)));
    try std.testing.expectEqualSlices(Bit, &message, &recoverMessage(clean));

    for ([_]usize{ 0, 7, 14 }) |pos| {
        const received = try transmit(codeword, pos);
        const syn = calculateSyndrome(received);
        try std.testing.expect(!isZero(syn));
        try std.testing.expectEqual(@as(?usize, pos), locateByTable(syn));
        try std.testing.expectEqualSlices(Bit, &message, &recoverMessage(correct(received, syn)));
    }
}
