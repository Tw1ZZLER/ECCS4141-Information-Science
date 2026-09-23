const std = @import("std");

/// p(x) = x^8 + x^4 + x^3 + x^2 + 1.
pub const modulus: u9 = 0x11d;
pub const reduction_byte: u8 = 0x1d;

pub const DivisionError = error{DivisionByZero};
pub const InverseError = error{ZeroHasNoInverse};

/// Addition in characteristic two is coefficient-wise XOR.
pub fn add(a: u8, b: u8) u8 {
    return a ^ b;
}

/// Carryless polynomial multiplication reduced modulo p(x).
pub fn multiply(a: u8, b: u8) u8 {
    var multiplicand = a;
    var multiplier = b;
    var product: u8 = 0;

    for (0..8) |_| {
        if (multiplier & 1 != 0) product ^= multiplicand;
        const carry = multiplicand & 0x80 != 0;
        multiplicand <<= 1;
        if (carry) multiplicand ^= reduction_byte;
        multiplier >>= 1;
    }
    return product;
}

pub fn power(base_value: u8, exponent_value: u16) u8 {
    var base = base_value;
    var exponent = exponent_value;
    var result: u8 = 1;

    while (exponent != 0) : (exponent >>= 1) {
        if (exponent & 1 != 0) result = multiply(result, base);
        base = multiply(base, base);
    }
    return result;
}

/// Every nonzero element a satisfies a^255 = 1, hence a^-1 = a^254.
pub fn inverse(value: u8) InverseError!u8 {
    if (value == 0) return error.ZeroHasNoInverse;
    return power(value, 254);
}

pub fn divide(numerator: u8, denominator: u8) DivisionError!u8 {
    if (denominator == 0) return error.DivisionByZero;
    return multiply(numerator, inverse(denominator) catch unreachable);
}

pub fn binary(value: u8) [8]u8 {
    var result: [8]u8 = undefined;
    for (0..8) |index| {
        const shift: u3 = @intCast(7 - index);
        result[index] = if ((value >> shift) & 1 == 0) '0' else '1';
    }
    return result;
}

test "assigned polynomial constants" {
    try std.testing.expectEqual(@as(u9, 0x11d), modulus);
    try std.testing.expectEqual(@as(u8, 0x1d), reduction_byte);
}

test "addition is XOR" {
    try std.testing.expectEqual(@as(u8, 0xd4), add(0x57, 0x83));
    try std.testing.expectEqual(@as(u8, 0), add(0xa6, 0xa6));
}

test "multiplication reduces with x8 equals x4 plus x3 plus x2 plus 1" {
    try std.testing.expectEqual(@as(u8, 0x1d), multiply(0x80, 0x02));
    try std.testing.expectEqual(@as(u8, 0xe0), multiply(0x57, 0x13));
    try std.testing.expectEqual(@as(u8, 0x8f), multiply(0x53, 0xca));
    try std.testing.expectEqual(@as(u8, 0x6d), multiply(0xae, 0x07));
}

test "zero and multiplicative identity" {
    for (0..256) |raw| {
        const value: u8 = @intCast(raw);
        try std.testing.expectEqual(@as(u8, 0), multiply(value, 0));
        try std.testing.expectEqual(value, multiply(value, 1));
    }
}

test "all nonzero elements have multiplicative inverses" {
    for (1..256) |raw| {
        const value: u8 = @intCast(raw);
        const reciprocal = try inverse(value);
        try std.testing.expectEqual(@as(u8, 1), multiply(value, reciprocal));
        try std.testing.expectEqual(value, try divide(value, 1));
    }
    try std.testing.expectError(error.ZeroHasNoInverse, inverse(0));
    try std.testing.expectError(error.DivisionByZero, divide(0x53, 0));
}

test "division round trip and distributivity" {
    const values = [_]u8{ 0x00, 0x01, 0x02, 0x13, 0x57, 0x80, 0xa6, 0xff };
    for (values) |a| {
        for (values) |b| {
            if (b != 0) try std.testing.expectEqual(a, try divide(multiply(a, b), b));
            for (values) |c| {
                try std.testing.expectEqual(
                    multiply(a, add(b, c)),
                    add(multiply(a, b), multiply(a, c)),
                );
            }
        }
    }
}

test "documented division examples" {
    try std.testing.expectEqual(@as(u8, 0x57), try divide(0xe0, 0x13));
    try std.testing.expectEqual(@as(u8, 0x8e), try divide(0x01, 0x02));
    try std.testing.expectEqual(@as(u8, 0x8c), try divide(0xd4, 0x83));
    try std.testing.expectEqual(@as(u8, 0x83), try divide(0xae, 0x07));
}

test "binary formatting is fixed width" {
    try std.testing.expectEqualStrings("00000000", &binary(0));
    try std.testing.expectEqualStrings("01010011", &binary(0x53));
    try std.testing.expectEqualStrings("11111111", &binary(0xff));
}
