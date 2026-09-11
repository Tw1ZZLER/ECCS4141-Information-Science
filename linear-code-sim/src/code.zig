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
