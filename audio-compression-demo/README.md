# Audio Compression Using Wavelet Decomposition

Information Science project: a lossy wavelet audio compressor with the required
24-bit `(zero count, coefficient)` record format, a Textual TUI that walks
encode / decode / playback, and millisecond stage timings.

## Run

```sh
cd audio-compression-demo
nix shell nixpkgs#uv # only for NixOS, install uv elsewhere on other systems
uv sync
uv run python main.py king_injustice.wav
```

Playback tries `sounddevice`/PortAudio first, then falls back to an external
player (`pw-play`, `paplay`, `aplay`, `ffplay`, or `mpv`). On this machine
PipeWire’s `pw-play` is enough; no extra Nix packages are required for that path.

To use PortAudio directly with `sounddevice` on NixOS, enter the optional shell
so `libportaudio` is on `LD_LIBRARY_PATH`:

```sh
nix-shell   # uses shell.nix (uv + portaudio)
uv sync
uv run python main.py king_injustice.wav
```

Batch encode/decode without the TUI (writes `.wac` + reconstructed WAV and
prints metrics):

```sh
uv run python main.py --batch king_injustice.wav
```

Handout encoder examples:

```sh
uv run python main.py --self-test
```

## Controls

| Key | Action |
|-----|--------|
| `Enter` / `Space` | Run current stage or advance to the next |
| `o` | Play original audio |
| `p` | Play reconstructed audio |
| `r` | Reset pipeline |
| `q` | Quit |

Stages: **Input → DWT → Threshold → Encode → Decode → Playback**.

The bottom bar reports real-time delay of each stage in milliseconds (`load`,
`dwt`, `thresh`, `enc`, `write`, `decode`, `idwt`, `wav`), measured with
`time.perf_counter_ns()` and displayed as ms.

## Input audio

| Item | Value |
|------|-------|
| File | `king_injustice.wav` |
| Duration | 4.638 s |
| Sampling rate | 11025 Hz |
| Channels | 1 (mono) |
| Bit depth (ratio reference) | 16 |
| Samples | 51 138 |
| Original sample bits | 51 138 × 16 = **818 208** |
| On-disk size | 14 336 bytes |

Stereo inputs would be mixed to mono before compression; this clip is already
mono and is used as the reference for all SNR and ratio numbers.

## Wavelet experiment

This demo uses a multilevel **discrete wavelet transform (DWT)** — Mallat’s
filter-bank decomposition via PyWavelets `wavedec` / `waverec` — with the
**Daubechies** family wavelet `db4` (4 vanishing moments).

| Choice | Value | Justification |
|--------|-------|---------------|
| Transform | Multilevel **DWT** | Discrete subband structure for thresholding + the 24-bit codec |
| Family | **Daubechies** (`db4`) | Orthogonal compactly supported wavelets; matches the course MATLAB sketch |
| Vanishing moments | 4 (`db4`) | Short support with good speech-like energy compaction |
| Level | 10 | Maximum useful depth for this length; creates many coarse bands that can be zeroed for long runs |
| Extension | `symmetric` | Stable inverse with PyWavelets `wavedec` / `waverec` |
| Hard threshold | `T = 0.1` on detail levels 2–5 | Keeps mid-band structure while clearing small coeffs |
| Zeroed bands | approximation + details 6–10 and detail 1 | Coarse / finest bands contribute little to intelligibility here and become long zero runs |

Reference: [Discrete wavelet transform (Wikipedia)](https://en.wikipedia.org/wiki/Discrete_wavelet_transform).

Only hard thresholding is used: `|c| ≤ T → 0`, `|c| > T` unchanged. Subband
ordering and sizes are preserved so the inverse DWT does not need the original
coefficient array—only metadata in the `.wac` header.

## Sparsity

| Stage | Zero percentage |
|-------|-----------------|
| After hard thresholding | **86.449%** |
| After quantization (`F = 12`) | **86.449%** |

Quantization did not create additional zeros on this clip (retained coeffs are
well above one LSB at `F = 12`).

## Fixed-point format

| Item | Value |
|------|-------|
| Fractional bits `F` | 12 |
| Quantize | `q = round(c × 2^F)` (`numpy.rint`) |
| Decode | `ĉ = q / 2^F` |
| Resolution | `2^-12 ≈ 2.441 × 10^-4` |
| Representable range | `[−32768/2^12, 32767/2^12] ≈ [−8.000, 7.99976]` |
| Overflow | Saturate (clip) to signed 16-bit before packing |
| Zeros | Values that quantize to 0 join zero runs |

`F = 12` covers the observed coefficient magnitude with headroom while keeping
quantization noise far below the thresholding error on this signal.

## 24-bit encoding

Each record is 24 bits: **8-bit unsigned zero count** + **16-bit signed
two’s-complement coefficient**.

Rules (as specified):

- `(count, coeff)` means `count` zeros, then `coeff` (including when `coeff` is 0).
- Runs longer than 255 zeros use `(255, 0)` (= 256 zeros), then continue.
- Trailing zeros of length `r` use `(r − 1, 0)` for `1 ≤ r ≤ 256`.

Verified examples:

- `[0,0,0,5,0,0,-3,0,0,0,0,7,0,2]` → `(3,5), (2,-3), (4,7), (1,2)`
- 600 zeros then `5` → `(255,0), (255,0), (88,5)`

## Compression results

| Metric | Value |
|--------|-------|
| Records `R` | 7 073 |
| Payload bits | `24R` = **169 752** (21 219 bytes) |
| Header metadata | 40 bytes = **320** bits (magic, rate, lengths, wavelet, level, mode, `F`, bit depth, `R`) |
| Payload compression ratio | `818208 / 169752` ≈ **4.820 : 1** |
| Total ratio (with header) | `818208 / 170072` ≈ **4.811 : 1** |
| Compressed file | `king_injustice.wac` |

Metadata required for reconstruction (and stored in the header): sample rate,
original sample count, coefficient count, wavelet name, decomposition level,
signal-extension mode, fractional bits `F`, reference bit depth, and record
count. The decoder never reads the original coefficient array.

## Quality

| Metric | Value |
|--------|-------|
| SNR after thresholding (float IDWT) | **15.499 dB** |
| SNR after full decode (quantize → `.wac` → IDWT) | **15.499 dB** |
| Quantized sequence check | Exact match encoder ↔ decoder |

Listening notes (headphones recommended):

- The reconstructed clip remains intelligible; speech cadence and emphasis are
  preserved.
- Compared with the original, there is mild muffling and a slight loss of
  brightness from discarding the finest detail band and coarse approximation
  energy.
- Quantization at `F = 12` is not audibly worse than threshold-only
  reconstruction on this material (SNR change is negligible).

## Main challenge

Maximizing zero coefficients is not the same as maximizing compression. The
24-bit record cost means many short zero runs can waste bits; zeroing whole
coarse bands creates long runs that pack efficiently as `(255, 0)` blocks.
The chosen policy trades some SNR for long runs and about a **4.8 : 1** payload
ratio while keeping speech understandable.

## Project layout

| Path | Role |
|------|------|
| `main.py` | CLI / TUI entry |
| `src/codec.py` | DWT, threshold, quantize, 24-bit RLE, `.wac` I/O, SNR |
| `src/app.py` | Textual staged UI + playback |
| `src/timing.py` | `perf_counter_ns` helpers |
| `king_injustice.wav` | Source clip |
| `king_injustice.wac` | Encoded bitstream |
| `king_injustice_reconstructed.wav` | Final decoded audio |
| `audiocompression.m` | MATLAB reference sketch |
| `pyproject.toml` / `uv.lock` | uv-managed dependencies |

## Demonstration checklist

1. `uv run python main.py --self-test` — encoding examples pass.
2. Open the TUI, step through all six stages, confirm metrics on Encode/Decode.
3. Press `o` then `p` to A/B the original and reconstructed audio.
4. Confirm Decode reports an exact quantized-coefficient match and that
   reconstruction used only the `.wac` file.
