# Audio Compression Using Wavelet Decomposition

Information Science project: a lossy wavelet audio compressor with the required
24-bit `(zero count, coefficient)` record format, a Textual TUI that walks
encode / decode / playback, and millisecond stage timings.

## Run

```sh
cd audio-compression-demo
nix shell nixpkgs#uv # only for NixOS, install uv elsewhere on other systems
uv sync
uv run python main.py
```

Batch encode/decode without the TUI (writes `.wac` + reconstructed WAV and
prints metrics):

```sh
uv run python main.py --batch king_injustice.wav
uv run python main.py --batch speech_clip.wav --wavelet haar --level 5 \
  --technique soft --threshold 0.2
```

Handout encoder examples:

```sh
uv run python main.py --self-test
```

## Controls

| Key | Action |
|-----|--------|
| `↑` / `↓` or `j` / `k` | Move the active selection list |
| `Tab` | Switch focus (filter↔level, technique↔T) |
| `←` / `→` or `-` / `+` | Nudge level or threshold preset |
| `Enter` / `Space` | Run the current stage, or advance to the next |
| `o` | Play original audio |
| `p` | Play reconstructed audio |
| `r` | Reset pipeline |
| `q` | Quit |

Stages: **Input → DWT → Threshold → Encode → Decode → Playback**.

- **Input** — pick any `*.wav` in the demo folder (except `*_reconstructed.wav`).
- **DWT** — pick filter (`haar`, `db2`, `db4`, `db8`, `sym4`, `coif2`, `bior2.2`) and level.
- **Threshold** — pick technique and `T` (`0.05`, `0.1`, `0.2`, `0.5`).

Threshold techniques:

| Id | Behavior |
|----|----------|
| `hard` | Hard shrink on every band |
| `soft` | Soft shrink (wavelet shrinkage) on every band |
| `hard_matlab` | Zero approx + coarse/finest details; hard-shrink mid bands (default) |
| `soft_uniform` | Keep approximation; soft-shrink all detail bands |

The 24-bit `(count, coeff)` encode format is unchanged; soft thresholding only
changes which floating-point coefficients are retained before quantization.

The bottom bar reports real-time delay of each stage in milliseconds (`load`,
`dwt`, `thresh`, `enc`, `write`, `decode`, `idwt`, `wav`), measured with
`time.perf_counter_ns()` and displayed as ms.

## Input audio

Selectable clips shipped in this folder include `king_injustice.wav`,
`speech_clip.wav` (1.5 s excerpt), and any other `*.wav` you drop in.

Default reported results below use `king_injustice.wav`:

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

Stereo inputs are mixed to mono before compression.

## Wavelet experiment

This demo uses a multilevel **discrete wavelet transform (DWT)** — Mallat’s
filter-bank decomposition via PyWavelets `wavedec` / `waverec`. The TUI can
switch filters and levels; the default report below uses **Daubechies** `db4`.

| Choice | Value | Justification |
|--------|-------|---------------|
| Transform | Multilevel **DWT** | Discrete subband structure for thresholding + the 24-bit codec |
| Default filter | **Daubechies** (`db4`) | Orthogonal compactly supported wavelets; matches the course MATLAB sketch |
| Other filters | `haar`, `db2`, `db8`, `sym4`, `coif2`, `bior2.2` | Explore support length / vanishing moments in the DWT stage |
| Vanishing moments | 4 (`db4`) | Short support with good speech-like energy compaction |
| Default level | 10 (clamped to max) | Deep decomposition for long zero runs with the MATLAB band policy |
| Extension | `symmetric` | Stable inverse with PyWavelets `wavedec` / `waverec` |
| Default technique | `hard_matlab`, `T = 0.1` | Zero approx + details 6…L and 1; hard-threshold mid bands 2–5 |

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
| `king_injustice.wav` | Primary source clip |
| `speech_clip.wav` | Short selectable excerpt |
| `*.wav` | Any additional inputs discovered by the Input stage |
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
