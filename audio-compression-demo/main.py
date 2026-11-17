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
        default="king_injustice.wav",
        help="uncompressed WAV to compress (default: king_injustice.wav)",
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

    wav_path = Path(args.wav)
    if not wav_path.is_file():
        candidate = root / args.wav
        if candidate.is_file():
            wav_path = candidate
        else:
            print(f"error: WAV not found: {args.wav}", file=sys.stderr)
            return 1

    if args.batch:
        result = codec.run_pipeline(wav_path)
        enc = result.encode
        dec = result.decode
        t = result.timings
        print(f"input:          {result.info.path}")
        print(f"duration:       {result.info.duration_s:.3f}s @ {result.info.sample_rate} Hz")
        print(f"samples:        {result.info.samples.shape[0]}")
        print(f"bit depth:      {result.info.bit_depth}")
        print(f"sample bits:    {result.info.original_sample_bits}")
        print(f"wavelet:        {enc.wavelet} level {enc.level} mode={enc.mode}")
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
        print(
            "timings_ns: "
            f"load={t.load_ns} dwt={t.dwt_ns} thresh={t.threshold_ns} "
            f"enc={t.quantize_encode_ns} write={t.write_ns} "
            f"decode={t.decode_ns} idwt={t.idwt_ns} wav={t.write_wav_ns}"
        )
        return 0 if dec.coeffs_match_encoded else 2

    run_app(wav_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
