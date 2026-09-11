# (7,4) Linear Block-Code Simulator

An interactive terminal simulator for a systematic (7,4) linear block code. It follows a four-bit message through the encoder, an optional single-bit channel error, syndrome decoding, correction, and message recovery.

## Run

The project uses Zig 0.16.0 and pins Vaxis 0.6.0 in `build.zig.zon`.

```sh
zig build run
```

The first build needs network access to fetch the pinned Zig dependencies. Later builds use Zig's package cache.

Other useful commands:

```sh
zig build
zig build test
zig fmt --check build.zig src/*.zig
```

The installed executable is `zig-out/bin/linear-code-sim`.

## Controls

- Message screen: type four `0` or `1` digits, `Backspace` to remove one, then `Enter`.
- Channel screen: select `0` for no error or `1`–`7` for a bit position. Arrow keys and `h`/`l` also change the selection; the choices can be clicked with a mouse. Press `Enter` or `Space` to transmit.
- Diagnosis screen: inspect the syndrome and detected position, then press `Enter`, `Space`, or `c` to reveal correction.
- Any screen: `r` starts over; `q` or `Ctrl-C` exits.

After every completed stage, the bottom-left performance line reports each operation's elapsed time in nanoseconds:

- Encoder stage: message parsing and matrix encoding.
- Receiver diagnosis stage: channel transmission/error injection, syndrome calculation, and error lookup.
- Correction stage: bit correction and message recovery.

Measurements use Zig's monotonic `std.Io.Clock.awake` clock. They are single-operation timings and therefore include timer-call overhead; use `zig build run -Doptimize=ReleaseFast` when demonstrating optimized performance.

The UI switches to a compact layout in a small terminal. A terminal of at least 78 columns by 23 rows shows the generator matrix and complete pipeline most clearly.

## Matrix and bit convention

Messages are row vectors `m = [m1 m2 m3 m4]`. All arithmetic is in GF(2), so addition is XOR.

```text
    [1 1 1 1 0 0 0]
G = [1 0 1 0 1 0 0]
    [0 1 1 0 0 1 0]
    [1 1 0 0 0 0 1]
```

The encoder computes `c = mG`. Since `G = [P | I4]`, codeword positions 4–7 contain the original message. Positions are numbered 1–7 from left to right.

The parity-check matrix is derived as `H = [I3 | P^T]`:

```text
    [1 0 0 1 1 0 1]
H = [0 1 0 1 0 1 1]
    [0 0 1 1 1 1 0]
```

At the receiver, `S = rH^T`. Syndrome `000` means no error. For a single-bit error, the syndrome equals the corresponding column of `H`, which identifies the bit to flip.

## Relationship to transmitter and receiver hardware

- **Message register:** the four editable input cells hold `m1`–`m4`.
- **Encoder XOR network:** multiplication by each column of `G` represents the XOR gates that generate one codeword bit.
- **Channel/error switch:** selecting one of seven positions models an inverter in that channel path; selecting no error leaves every line unchanged.
- **Syndrome network:** multiplication by `H^T` represents three parity-check XOR circuits.
- **Error locator:** the syndrome-to-column lookup represents decoder logic that enables one of seven correction lines.
- **Correction XOR gates:** the enabled line flips the detected received bit.
- **Output register:** systematic positions 4–7 provide the recovered four-bit message.

This simulator intentionally supports only no error or one injected error. A (7,4) Hamming code guarantees correction in that scope; it does not guarantee correction of multiple simultaneous errors.

## Suggested demonstration

1. Enter `1011` and show the generated codeword.
2. Select bit 5 and compare transmitted and received rows.
3. Transmit, show the three-bit syndrome, and explain how it matches column 5 of `H`.
4. Reveal correction and verify that the recovered message is `1011`.
5. Reset and repeat with `0` (no error) to show syndrome `000`.
