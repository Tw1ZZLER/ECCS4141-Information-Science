#!/usr/bin/env python3
"""Entry point for the audio compression TUI."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Wavelet audio compression demo (Textual TUI)",
    )
    parser.add_argument(
        "wav",
        nargs="?",
        default=None,
        help="initial WAV selection (default: first *.wav in audio/)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run handout encoding examples and exit",
    )
    parser.add_argument(
        "--batch",
        action="store_true",
        help="run encode/decode without the TUI and print metrics",
    )
    parser.add_argument(
        "--wavelet",
        default=None,
        help="batch wavelet filter (default: db4)",
    )
    parser.add_argument(
        "--level",
        type=int,
        default=None,
        help="batch decomposition level (default: 10, clamped to max)",
    )
    parser.add_argument(
        "--technique",
        choices=["hard", "soft", "hard_matlab", "soft_uniform"],
        default=None,
        help="batch thresholding technique (default: hard_matlab)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=None,
        help="batch threshold T (default: 0.1)",
    )
    args = parser.parse_args(argv)

    # Allow running as `uv run python main.py` from the project directory.
    root = Path(__file__).resolve().parent
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))

    from src import codec
    from src.app import run_app

    if args.self_test:
        codec.self_test_handout_examples()
        print("handout encoding examples: OK")
        return 0

    audio_root = codec.audio_dir(root)
    wav_path: Path | None
    if args.wav is None:
        choices = codec.list_input_wavs(audio_root)
        wav_path = None if not args.batch else (choices[0] if choices else None)
    else:
        wav_path = Path(args.wav)
        if not wav_path.is_file():
            for candidate in (audio_root / args.wav, root / args.wav):
                if candidate.is_file():
                    wav_path = candidate
                    break
            else:
                print(f"error: WAV not found: {args.wav}", file=sys.stderr)
                return 1

    if args.batch:
        if wav_path is None or not wav_path.is_file():
            print(
                f"error: WAV required for --batch (looked in {audio_root})",
                file=sys.stderr,
            )
            return 1
        kwargs: dict = {}
        if args.wavelet is not None:
            kwargs["wavelet"] = args.wavelet
        if args.level is not None:
            kwargs["level"] = args.level
        if args.technique is not None:
            kwargs["technique"] = args.technique
        if args.threshold is not None:
            kwargs["threshold"] = args.threshold
        result = codec.run_pipeline(wav_path, **kwargs)
        enc = result.encode
        dec = result.decode
        t = result.timings
        print(f"input:          {result.info.path}")
        print(f"duration:       {result.info.duration_s:.3f}s @ {result.info.sample_rate} Hz")
        print(f"samples:        {result.info.samples.shape[0]}")
        print(f"bit depth:      {result.info.bit_depth}")
        print(f"sample bits:    {result.info.original_sample_bits}")
        print(f"wavelet:        {enc.wavelet} level {enc.level} mode={enc.mode}")
        print(
            f"threshold:      technique="
            f"{args.technique or codec.DEFAULT_TECHNIQUE.value} "
            f"T={args.threshold if args.threshold is not None else codec.DEFAULT_THRESHOLD}"
        )
        print(f"F:              {enc.fractional_bits}")
        print(f"zero% thresh:   {enc.zero_pct_threshold:.4f}")
        print(f"zero% quant:    {enc.zero_pct_quantized:.4f}")
        print(f"SNR thresh:     {enc.snr_threshold_db:.6f} dB")
        print(f"SNR final:      {dec.snr_db:.6f} dB")
        print(f"records R:      {enc.record_count}")
        print(f"payload bits:   {enc.payload_bits}")
        print(f"header bits:    {enc.header_bits}")
        print(f"payload ratio:  {enc.payload_ratio:.6f}")
        print(f"total ratio:    {enc.total_ratio:.6f}")
        print(f"match:          {dec.coeffs_match_encoded}")
        print(f"wrote:          {result.compressed_path}")
        print(f"wrote:          {result.reconstructed_path}")

        def _ms(ns: int) -> str:
            return f"{ns / 1_000_000:.3f}"

        print(
            "timings_ms: "
            f"load={_ms(t.load_ns)} dwt={_ms(t.dwt_ns)} thresh={_ms(t.threshold_ns)} "
            f"enc={_ms(t.quantize_encode_ns)} write={_ms(t.write_ns)} "
            f"decode={_ms(t.decode_ns)} idwt={_ms(t.idwt_ns)} wav={_ms(t.write_wav_ns)}"
        )
        return 0 if dec.coeffs_match_encoded else 2

    run_app(wav_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
