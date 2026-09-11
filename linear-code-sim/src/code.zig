const std = @import("std");

pub const Bit = u1;
pub const Message = [4]Bit;
pub const Codeword = [7]Bit;
pub const Syndrome = [3]Bit;

/// The supplied generator matrix. Message and codeword vectors are row vectors.
pub const G: [4][7]Bit = .{
    .{ 1, 1, 1, 1, 0, 0, 0 },
    .{ 1, 0, 1, 0, 1, 0, 0 },
    .{ 0, 1, 1, 0, 0, 1, 0 },
    .{ 1, 1, 0, 0, 0, 0, 1 },
};

/// H = [I3 | P^T], so G * H^T = 0 over GF(2).
pub const H: [3][7]Bit = .{
    .{ 1, 0, 0, 1, 1, 0, 1 },
    .{ 0, 1, 0, 1, 0, 1, 1 },
    .{ 0, 0, 1, 1, 1, 1, 0 },
};

pub const ParseError = error{
    WrongLength,
    NonBinaryDigit,
};

pub fn parseMessage(text: []const u8) ParseError!Message {
    if (text.len != 4) return error.WrongLength;

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

pub fn encode(message: Message) Codeword {
    var codeword: Codeword = @splat(0);
    for (0..G[0].len) |column| {
        for (0..message.len) |row| {
            codeword[column] ^= message[row] & G[row][column];
        }
    }
    return codeword;
}

/// Flip a zero-based codeword position. Null models a channel with no error.
pub fn transmit(codeword: Codeword, error_index: ?usize) error{InvalidBitPosition}!Codeword {
    var received = codeword;
    if (error_index) |index| {
        if (index >= received.len) return error.InvalidBitPosition;
        received[index] ^= 1;
    }
    return received;
}

pub fn calculateSyndrome(received: Codeword) Syndrome {
    var result: Syndrome = @splat(0);
    for (0..H.len) |row| {
        for (0..received.len) |column| {
            result[row] ^= received[column] & H[row][column];
        }
    }
    return result;
}

/// Match a syndrome to a column of H. The returned position is zero-based.
pub fn locateError(syndrome: Syndrome) ?usize {
    if (std.mem.eql(Bit, &syndrome, &@as(Syndrome, @splat(0)))) return null;

    for (0..H[0].len) |column| {
        var h_column: Syndrome = undefined;
        for (0..H.len) |row| h_column[row] = H[row][column];
        if (std.mem.eql(Bit, &syndrome, &h_column)) return column;
    }
    return null;
}

pub fn correct(received: Codeword, syndrome: Syndrome) Codeword {
    var corrected = received;
    if (locateError(syndrome)) |index| corrected[index] ^= 1;
    return corrected;
}

pub fn recoverMessage(corrected: Codeword) Message {
    return corrected[3..7].*;
}

pub fn writeBits(comptime length: usize, bits: [length]Bit, output: *[length]u8) []const u8 {
    for (bits, 0..) |bit, index| output[index] = if (bit == 0) '0' else '1';
    return output;
}

test "parse only accepts exactly four binary digits" {
    try std.testing.expectEqual(Message{ 1, 0, 1, 1 }, try parseMessage("1011"));
    try std.testing.expectError(error.WrongLength, parseMessage("101"));
    try std.testing.expectError(error.WrongLength, parseMessage("10110"));
    try std.testing.expectError(error.NonBinaryDigit, parseMessage("10x1"));
}

test "generator and parity-check matrices are orthogonal" {
    for (0..G.len) |g_row| {
        for (0..H.len) |h_row| {
            var dot_product: Bit = 0;
            for (0..G[0].len) |column| {
                dot_product ^= G[g_row][column] & H[h_row][column];
            }
            try std.testing.expectEqual(@as(Bit, 0), dot_product);
        }
    }
}

test "all messages survive every supported channel outcome" {
    for (0..16) |value| {
        const message: Message = .{
            @intCast((value >> 3) & 1),
            @intCast((value >> 2) & 1),
            @intCast((value >> 1) & 1),
            @intCast(value & 1),
        };
        const codeword = encode(message);
        try std.testing.expectEqual(message, recoverMessage(codeword));
        try std.testing.expectEqual(Syndrome{ 0, 0, 0 }, calculateSyndrome(codeword));

        const no_error_word = try transmit(codeword, null);
        const no_error_syndrome = calculateSyndrome(no_error_word);
        try std.testing.expectEqual(@as(?usize, null), locateError(no_error_syndrome));
        try std.testing.expectEqual(codeword, correct(no_error_word, no_error_syndrome));

        for (0..7) |error_index| {
            const received = try transmit(codeword, error_index);
            const syndrome = calculateSyndrome(received);
            try std.testing.expectEqual(@as(?usize, error_index), locateError(syndrome));

            const corrected = correct(received, syndrome);
            try std.testing.expectEqual(codeword, corrected);
            try std.testing.expectEqual(message, recoverMessage(corrected));
        }
    }
}

test "transmit rejects an out-of-range bit position" {
    const codeword = encode(.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.InvalidBitPosition, transmit(codeword, 7));
}
