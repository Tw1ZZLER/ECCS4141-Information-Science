# GF(256) Explorer

An interactive Zig/Vaxis terminal program for the GF(256) in-class activity. It defines the field, displays every byte representation, and provides addition, multiplication, and division calculators that retain multiple examples.

## Run

The project requires Zig 0.16.0 and pins Vaxis 0.6.0.

```sh
zig --command zig build run
```

Other verification commands:

```sh
zig --command zig build
zig --command zig build test
zig --command sh -c 'zig fmt --check build.zig src/*.zig'
```

The installed executable is `zig-out/bin/gf256-sim`.

## Controls

- `p` / `n` or `[` / `]`: previous or next section from any screen.
- `Esc`: return to the overview from any screen.
- `F1`–`F5`: jump directly to Overview, Table, Add, Multiply, or Divide.
- `1`–`5`: jump to a section from the overview or table; on a calculator these remain available as hexadecimal input.
- Table: `Up`/`Down` or `j`/`k` scroll one element; `PgUp`/`PgDn` scroll 16; `Home`/`End` jump to either end.
- Calculators: enter two hexadecimal digits for each byte. An optional `0x` prefix is accepted. `Tab` or `Left`/`Right` selects A or B, `Backspace` edits, and `Enter` or `=` calculates.
- `r`: clear the current calculator's history.
- `q` or `Ctrl-C`: quit.

Typing a hex digit over a complete two-digit operand starts a replacement byte. The calculators retain the eight most recent successful calculations for each operation. Division by zero is rejected.

## Field definition and representation

The field is

```text
GF(256) = GF(2)[x] / (p(x))
p(x) = x^8 + x^4 + x^3 + x^2 + 1
```

The irreducible polynomial is `0x11D`. When a multiplication shift produces an `x^8` term, the implementation XORs the low reduction byte `0x1D`, because

```text
x^8 = x^4 + x^3 + x^2 + 1  (mod p(x)).
```

The arithmetic calculators use the usual numeric byte notation, where
`a7a6a5a4a3a2a1a0` represents

```text
a7*x^7 + a6*x^6 + a5*x^5 + a4*x^4
  + a3*x^3 + a2*x^2 + a1*x + a0.
```

For example, `0x53 = 01010011` represents `x^6 + x^4 + x + 1`.

The field table follows the classroom LFSR convention instead: its bits are
shown left-to-right as `[a0, a1, ..., a7]`, so the constant coefficient comes
first. Thus `alpha^0 = 1` is displayed as `10000000`.

## Complete 256-element table

Section 2 generates the 256 field entries by advancing a linear feedback shift
register built from `p(x)`. Entry 0 is the all-zero state. Entry `n` for
`1 <= n <= 255` is `alpha^(n-1)`.

```text
ENTRY   ELEMENT       LFSR BITS
  0     0             00000000
  1     alpha^0       10000000
  2     alpha^1       01000000
  8     alpha^7       00000001
  9     alpha^8       10111000
 ...       ...           ...
255     alpha^254     (final nonzero state)
```

The register shifts right. When the outgoing rightmost bit is 1, it XORs the
feedback mask `10111000`, which places the polynomial's `1`, `x^2`, `x^3`, and
`x^4` coefficients in the table's constant-first order. The primitive
polynomial makes the register visit every nonzero 8-bit state exactly once
before repeating. Scrolling from `Home` through `End` exposes all 256 entries.

## Addition examples

Addition is coefficient-wise modulo 2, which is exactly bitwise XOR. There are no integer carries.

```text
0x57 + 0x83 = 0xD4    01010111 XOR 10000011 = 11010100
0xA6 + 0x3D = 0x9B    10100110 XOR 00111101 = 10011011
0xFF + 0x0F = 0xF0    11111111 XOR 00001111 = 11110000
```

Check: `0x57 XOR 0x83` is `0xD4`, so the first result agrees with polynomial coefficient addition in GF(2).

## Multiplication examples

Multiplication is a carryless polynomial product reduced modulo `0x11D`; it is not ordinary byte multiplication.

```text
0x57 * 0x13 = 0xE0
0x80 * 0x02 = 0x1D
0x53 * 0xCA = 0x8F
0xAE * 0x07 = 0x6D
```

Check: `0x80` represents `x^7`. Multiplying by `0x02` produces `x^8`, which reduces to `x^4 + x^3 + x^2 + 1`, or binary `00011101 = 0x1D`. This directly demonstrates the assigned polynomial reduction.

## Division examples

For nonzero `b`, division uses `a / b = a * b^-1`. The implementation obtains the inverse as `b^254`, since every nonzero element satisfies `b^255 = 1`.

```text
0xE0 / 0x13 = 0x57    inverse(0x13) = 0x58
0x01 / 0x02 = 0x8E    inverse(0x02) = 0x8E
0xD4 / 0x83 = 0x8C    inverse(0x83) = 0x1D
0xAE / 0x07 = 0x83    inverse(0x07) = 0xBA
```

Check: the first multiplication example gives `0x57 * 0x13 = 0xE0`, so reversing it gives `0xE0 / 0x13 = 0x57`. Also, `0x02 * 0x8E = 0x01`, confirming that `0x8E` is the multiplicative inverse of `0x02`.

## Implementation notes and what we learned

The program keeps field arithmetic in `src/gf256.zig`, separate from the Vaxis model and rendering in `src/app.zig`. Zig's `u8` type naturally represents all 256 field elements, while explicit XOR, shifts, and overflow-safe byte operations make the distinction between polynomial arithmetic and ordinary integer arithmetic visible. Error unions model undefined operations: division by zero and the inverse of zero are explicit errors rather than special values.

The main lesson is that the same eight bits can represent either an integer or a polynomial. The storage is identical, but the selected operations determine the mathematics: XOR replaces carried addition, multiplication requires polynomial reduction, and division requires a field inverse.
