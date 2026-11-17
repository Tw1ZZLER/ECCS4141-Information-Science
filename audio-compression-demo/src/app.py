"""Textual TUI for wavelet audio compression stages."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import Footer, Header, RichLog, Static

from . import codec
from .timing import timed

STAGE_NAMES = (
    "Input",
    "DWT",
    "Threshold",
    "Encode",
    "Decode",
    "Playback",
)


def _fmt_ns(ns: int) -> str:
    return f"{ns:,} ns"


def _fmt_snr(snr: float) -> str:
    if np.isinf(snr):
        return "infinite"
    return f"{snr:.3f} dB"


class MetricsBar(Static):
    """Bottom performance metrics line."""

    def show(self, timings: codec.PipelineTimings | None, status: str = "") -> None:
        if timings is None:
            self.update(f"[dim]timings: —[/]  {status}")
            return
        parts = [
            f"load {_fmt_ns(timings.load_ns)}",
            f"dwt {_fmt_ns(timings.dwt_ns)}",
            f"thresh {_fmt_ns(timings.threshold_ns)}",
            f"enc {_fmt_ns(timings.quantize_encode_ns)}",
            f"write {_fmt_ns(timings.write_ns)}",
            f"decode {_fmt_ns(timings.decode_ns)}",
            f"idwt {_fmt_ns(timings.idwt_ns)}",
            f"wav {_fmt_ns(timings.write_wav_ns)}",
        ]
        self.update(
            "[bold cyan]perf[/]  "
            + "  ".join(parts)
            + (f"  {status}" if status else "")
        )


class StageBanner(Static):
    def show(self, index: int) -> None:
        chips = []
        for i, name in enumerate(STAGE_NAMES):
            if i == index:
                chips.append(f"[reverse bold]{i + 1}:{name}[/]")
            elif i < index:
                chips.append(f"[green]{i + 1}:{name}[/]")
            else:
                chips.append(f"[dim]{i + 1}:{name}[/]")
        self.update("  ".join(chips))


class AudioCompressionApp(App[None]):
    """Staged encode / decode / playback demonstration."""

    CSS = """
    Screen {
        layout: vertical;
    }
    #banner {
        height: 1;
        padding: 0 1;
        background: $boost;
    }
    #body {
        height: 1fr;
        padding: 0 1;
    }
    #panel {
        height: 1fr;
        border: solid $accent;
        padding: 1 2;
    }
    #side {
        width: 40;
        border: solid $surface;
        padding: 1;
    }
    #metrics {
        height: 3;
        padding: 0 1;
        background: $panel;
        color: $text;
    }
    """

    BINDINGS = [
        Binding("enter", "advance", "Next", show=True),
        Binding("space", "advance", "Next", show=False),
        Binding("o", "play_original", "Play orig", show=True),
        Binding("p", "play_recon", "Play recon", show=True),
        Binding("r", "reset", "Reset", show=True),
        Binding("q", "quit", "Quit", show=True),
    ]

    def __init__(self, wav_path: str | Path) -> None:
        super().__init__()
        self.wav_path = Path(wav_path)
        self.stage = 0
        self.stage_done = False
        self.info: codec.AudioInfo | None = None
        self.coeffs: list[np.ndarray] | None = None
        self.thresholded: list[np.ndarray] | None = None
        self.encode: codec.EncodeResult | None = None
        self.decode: codec.DecodeResult | None = None
        self.timings = codec.PipelineTimings()
        self.compressed_path = self.wav_path.with_suffix(".wac")
        self.reconstructed_path = self.wav_path.with_name(
            self.wav_path.stem + "_reconstructed.wav"
        )

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        yield StageBanner(id="banner")
        with Horizontal(id="body"):
            yield RichLog(id="panel", highlight=True, markup=True, wrap=True)
            yield Static(id="side")
        yield MetricsBar(id="metrics")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "Audio Compression Demo"
        self.sub_title = (
            f"{self.wav_path.name}  ·  "
            f"{codec.DEFAULT_TRANSFORM} {codec.DEFAULT_WAVELET} "
            f"(Daubechies, not Haar / not CWT)"
        )
        self.query_one("#banner", StageBanner).show(0)
        self.query_one("#metrics", MetricsBar).show(self.timings)
        self._render_stage()

    def _side_panel(self, status: str | None = None) -> str:
        lines = [
            "[bold]Controls[/]",
            "Enter/Space  next stage",
            "o            play original",
            "p            play reconstructed",
            "r            reset",
            "q            quit",
            "",
            f"[bold]Stage[/] {self.stage + 1}/{len(STAGE_NAMES)}",
            f"[bold]File[/]  {self.wav_path.name}",
            "",
            "[bold]Transform[/]",
            f"{codec.DEFAULT_TRANSFORM} (discrete)",
            "Family  Daubechies",
            f"Wavelet {codec.DEFAULT_WAVELET} "
            f"({codec.DEFAULT_WAVELET_VANISHING_MOMENTS} vanishing moments)",
            "Not Haar (haar/db1)",
            "Not CWT / complex DWT",
        ]
        if status:
            lines.extend(["", f"[bold]Status[/]\n{status}"])
        return "\n".join(lines)

    def action_reset(self) -> None:
        self.stage = 0
        self.stage_done = False
        self.info = None
        self.coeffs = None
        self.thresholded = None
        self.encode = None
        self.decode = None
        self.timings = codec.PipelineTimings()
        self.query_one("#banner", StageBanner).show(0)
        self.query_one("#metrics", MetricsBar).show(self.timings, "[dim]reset[/]")
        self._render_stage()

    def action_advance(self) -> None:
        if not self.stage_done:
            self._run_stage(self.stage)
            self.stage_done = True
        elif self.stage < len(STAGE_NAMES) - 1:
            self.stage += 1
            self._run_stage(self.stage)
            self.stage_done = True
        else:
            return
        self.query_one("#banner", StageBanner).show(self.stage)
        self.query_one("#metrics", MetricsBar).show(self.timings)
        self._render_stage()

    def action_play_original(self) -> None:
        if self.info is None:
            self._notify_side("Load the input stage first (Enter).")
            return
        self._play(self.info.samples, self.info.sample_rate, "original")

    def action_play_recon(self) -> None:
        if self.decode is None:
            self._notify_side("Decode first (advance to Decode).")
            return
        self._play(self.decode.samples, self.decode.sample_rate, "reconstructed")

    @work(exclusive=True, thread=True)
    def _play(self, samples: np.ndarray, sample_rate: int, label: str) -> None:
        try:
            from .playback import play_audio

            backend = play_audio(samples, sample_rate)
            self.call_from_thread(
                self._notify_side,
                f"Finished playback ({label}) via {backend}.",
            )
        except Exception as exc:  # noqa: BLE001 — surface audio backend errors in UI
            self.call_from_thread(self._notify_side, f"Playback error: {exc}")

    def _notify_side(self, message: str) -> None:
        self.query_one("#side", Static).update(self._side_panel(message))

    def _run_stage(self, stage: int) -> None:
        if stage == 0:
            self.info, self.timings.load_ns = timed(lambda: codec.load_audio(self.wav_path))
        elif stage == 1:
            assert self.info is not None
            self.coeffs, self.timings.dwt_ns = timed(
                lambda: codec.decompose(self.info.samples)
            )
        elif stage == 2:
            assert self.coeffs is not None and self.info is not None
            self.thresholded, self.timings.threshold_ns = timed(
                lambda: codec.apply_hard_threshold(self.coeffs)
            )
        elif stage == 3:
            assert self.thresholded is not None and self.info is not None

            def _encode() -> codec.EncodeResult:
                flat = codec.flatten_coeffs(self.thresholded)
                y_thr = codec.reconstruct(
                    self.thresholded,
                    codec.DEFAULT_WAVELET,
                    codec.DEFAULT_MODE,
                    self.info.samples.shape[0],
                )
                snr_thr = codec.snr_db(self.info.samples, y_thr)
                quantized = codec.quantize_coeffs(flat, fractional_bits=codec.DEFAULT_F)
                records = codec.encode_records(quantized)
                payload_bits = int(records.shape[0]) * 24
                header_bits = codec.HEADER_SIZE * 8
                orig_bits = self.info.original_sample_bits
                return codec.EncodeResult(
                    coeffs_thresholded=self.thresholded,
                    flat_thresholded=flat,
                    quantized=quantized,
                    records=records,
                    zero_pct_threshold=codec.zero_percentage(flat),
                    zero_pct_quantized=codec.zero_percentage(quantized),
                    snr_threshold_db=snr_thr,
                    wavelet=codec.DEFAULT_WAVELET,
                    level=len(self.thresholded) - 1,
                    mode=codec.DEFAULT_MODE,
                    fractional_bits=codec.DEFAULT_F,
                    n_samples=self.info.samples.shape[0],
                    sample_rate=self.info.sample_rate,
                    bit_depth=self.info.bit_depth,
                    payload_bits=payload_bits,
                    header_bits=header_bits,
                    payload_ratio=(orig_bits / payload_bits) if payload_bits else float("inf"),
                    total_ratio=(orig_bits / (payload_bits + header_bits))
                    if payload_bits
                    else float("inf"),
                    record_count=int(records.shape[0]),
                )

            self.encode, self.timings.quantize_encode_ns = timed(_encode)

            def _write() -> int:
                assert self.encode is not None
                return codec.write_wac(
                    self.compressed_path,
                    sample_rate=self.encode.sample_rate,
                    n_samples=self.encode.n_samples,
                    n_coeffs=self.encode.quantized.size,
                    wavelet=self.encode.wavelet,
                    level=self.encode.level,
                    mode=self.encode.mode,
                    fractional_bits=self.encode.fractional_bits,
                    bit_depth=self.encode.bit_depth,
                    records=self.encode.records,
                )

            _, self.timings.write_ns = timed(_write)
        elif stage == 4:
            assert self.encode is not None and self.info is not None

            def _decode_payload() -> tuple[dict, np.ndarray]:
                return codec.read_wac(self.compressed_path)

            meta_records, self.timings.decode_ns = timed(_decode_payload)
            meta, records = meta_records
            quantized = codec.decode_records(records, meta["n_coeffs"])
            match = bool(np.array_equal(quantized, self.encode.quantized))

            def _idwt() -> np.ndarray:
                flat = codec.dequantize_coeffs(
                    quantized, fractional_bits=meta["fractional_bits"]
                )
                shapes = [
                    c.shape
                    for c in codec.decompose(
                        np.zeros(meta["n_samples"]),
                        wavelet=meta["wavelet"],
                        level=meta["level"],
                        mode=meta["mode"],
                    )
                ]
                coeffs_r = codec.unflatten_coeffs(flat, shapes)
                return codec.reconstruct(
                    coeffs_r, meta["wavelet"], meta["mode"], meta["n_samples"]
                )

            samples, self.timings.idwt_ns = timed(_idwt)
            snr = codec.snr_db(self.info.samples, samples)

            def _write_wav() -> None:
                codec.write_wav(self.reconstructed_path, samples, meta["sample_rate"])

            _, self.timings.write_wav_ns = timed(_write_wav)

            self.decode = codec.DecodeResult(
                quantized=quantized,
                samples=samples,
                snr_db=snr,
                wavelet=meta["wavelet"],
                level=meta["level"],
                mode=meta["mode"],
                fractional_bits=meta["fractional_bits"],
                sample_rate=meta["sample_rate"],
                n_samples=meta["n_samples"],
                bit_depth=meta["bit_depth"],
                record_count=meta["record_count"],
                coeffs_match_encoded=match,
            )
        elif stage == 5:
            # Playback stage: no extra compute.
            return

    def _render_stage(self) -> None:
        log = self.query_one("#panel", RichLog)
        log.clear()
        self.query_one("#side", Static).update(self._side_panel())

        if self.stage == 0 and not self.stage_done:
            log.write("[bold cyan]Stage 1 — Input audio[/]")
            log.write("")
            log.write(f"Source: {self.wav_path}")
            log.write("Press [bold]Enter[/] to load the WAV and measure I/O time.")
            log.write("")
            log.write(f"[bold]Transform[/]  {codec.wavelet_description()}")
            log.write(
                "PyWavelets multilevel [bold]DWT[/] (Mallat filter bank), "
                f"family [bold]{codec.DEFAULT_WAVELET_FAMILY}[/], "
                f"code [bold]{codec.DEFAULT_WAVELET}[/]."
            )
            log.write(
                "Haar wavelets are [bold]not[/] used (Haar ≡ db1). "
                "This is [bold]not[/] a continuous wavelet transform (CWT)."
            )
            log.write("")
            log.write(
                "Pipeline: DWT → hard threshold → fixed-point quantize → "
                "24-bit (count, coeff) records → .wac → decode → inverse DWT."
            )
            return

        if self.stage == 0 and self.info is not None:
            info = self.info
            log.write("[bold cyan]Stage 1 — Input audio[/]")
            log.write("")
            log.write(f"Path:           {info.path}")
            log.write(f"Duration:       {info.duration_s:.3f} s")
            log.write(f"Sample rate:    {info.sample_rate} Hz")
            log.write(f"Channels:       {info.channels} (mono reference)")
            log.write(f"Bit depth:      {info.bit_depth} (reference for ratios)")
            log.write(f"Samples:        {info.samples.shape[0]:,}")
            log.write(f"Sample bits:    {info.original_sample_bits:,}")
            log.write(f"File size:      {info.file_bytes:,} bytes")
            log.write(f"Peak |x|:       {float(np.max(np.abs(info.samples))):.4f}")
            log.write("")
            log.write(f"Transform:      {codec.wavelet_description()}")
            return

        if self.stage == 1 and self.coeffs is not None:
            sizes = [c.size for c in self.coeffs]
            log.write("[bold cyan]Stage 2 — Discrete wavelet transform (DWT)[/]")
            log.write("")
            log.write(f"Kind:           multilevel DWT (not CWT)")
            log.write(f"Family:         {codec.DEFAULT_WAVELET_FAMILY} orthogonal")
            log.write(
                f"Wavelet:        {codec.DEFAULT_WAVELET} "
                f"({codec.DEFAULT_WAVELET_VANISHING_MOMENTS} vanishing moments)"
            )
            log.write("Not used:       Haar (haar / db1), CWT, complex DWT")
            log.write(f"Level:          {len(self.coeffs) - 1}")
            log.write(f"Extension:      {codec.DEFAULT_MODE}")
            log.write(f"Coeff vector:   {sum(sizes):,} coefficients")
            log.write(f"Subband sizes:  {sizes}")
            log.write("")
            log.write(
                "Implemented with PyWavelets wavedec/waverec (Mallat algorithm). "
                "Ordering: [cA_L, cD_L, cD_L-1, …, cD_1]."
            )
            log.write(
                "Ref: https://en.wikipedia.org/wiki/Discrete_wavelet_transform"
            )
            return

        if self.stage == 2 and self.thresholded is not None and self.info is not None:
            flat = codec.flatten_coeffs(self.thresholded)
            y_thr = codec.reconstruct(
                self.thresholded,
                codec.DEFAULT_WAVELET,
                codec.DEFAULT_MODE,
                self.info.samples.shape[0],
            )
            snr = codec.snr_db(self.info.samples, y_thr)
            log.write("[bold cyan]Stage 3 — Hard thresholding[/]")
            log.write("")
            log.write("Policy (MATLAB-inspired):")
            log.write("  • zero approximation band")
            log.write("  • zero detail levels 6–10 and level 1")
            log.write("  • hard-threshold levels 2–5 at T = 0.1")
            log.write("")
            log.write(f"Zero coefficients: {codec.zero_percentage(flat):.3f}%")
            log.write(f"SNR (float recon): {_fmt_snr(snr)}")
            log.write("")
            log.write(
                "Coarse bands and finest detail are discarded to create long zero "
                "runs; mid bands keep perceptually important structure."
            )
            return

        if self.stage == 3 and self.encode is not None:
            enc = self.encode
            f = enc.fractional_bits
            log.write("[bold cyan]Stage 4 — Quantize + 24-bit encode[/]")
            log.write("")
            log.write(f"Fractional bits F: {f}")
            log.write(f"Resolution:        2^-F = {2 ** (-f)}")
            log.write(
                f"Representable:     [{(-32768) / (1 << f):.6f}, {32767 / (1 << f):.6f}]"
            )
            log.write("Rounding:          round half away via numpy rint")
            log.write("Overflow:          saturate to int16 range")
            log.write("")
            log.write(f"Zeros after quant: {enc.zero_pct_quantized:.3f}%")
            log.write(f"SNR after thresh:  {_fmt_snr(enc.snr_threshold_db)}")
            log.write(f"Records R:         {enc.record_count:,}")
            log.write(
                f"Payload:           {enc.payload_bits:,} bits "
                f"({enc.payload_bits // 8:,} bytes)"
            )
            log.write(
                f"Header:            {enc.header_bits} bits ({enc.header_bits // 8} bytes)"
            )
            log.write(f"Payload ratio:     {enc.payload_ratio:.4f} : 1")
            log.write(f"Total ratio:       {enc.total_ratio:.4f} : 1")
            log.write(f"Wrote:             {self.compressed_path.name}")
            return

        if self.stage == 4 and self.decode is not None and self.encode is not None:
            dec = self.decode
            log.write("[bold cyan]Stage 5 — Decode + inverse DWT[/]")
            log.write("")
            log.write(
                "Quantized match:  "
                + ("[green]exact[/]" if dec.coeffs_match_encoded else "[red]MISMATCH[/]")
            )
            log.write(f"Records read:     {dec.record_count:,}")
            log.write(f"Transform:        {codec.wavelet_description(dec.wavelet)}")
            log.write(f"Wavelet/level:    {dec.wavelet} / {dec.level}")
            log.write(f"Final SNR:        {_fmt_snr(dec.snr_db)}")
            log.write(f"Reconstructed:    {self.reconstructed_path.name}")
            log.write("")
            log.write("Decoder used only .wac metadata + records (no original coeffs).")
            return

        if self.stage == 5 and self.decode is not None and self.encode is not None:
            enc = self.encode
            dec = self.decode
            log.write("[bold cyan]Stage 6 — Playback[/]")
            log.write("")
            log.write(f"Original:         {self.wav_path.name}")
            log.write(f"Reconstructed:    {self.reconstructed_path.name}")
            log.write(f"Compressed:       {self.compressed_path.name}")
            log.write("")
            log.write(f"Threshold SNR:    {_fmt_snr(enc.snr_threshold_db)}")
            log.write(f"Final SNR:        {_fmt_snr(dec.snr_db)}")
            log.write(f"Payload ratio:    {enc.payload_ratio:.4f} : 1")
            log.write(f"Total ratio:      {enc.total_ratio:.4f} : 1")
            log.write("")
            log.write("Press [bold]o[/] to play original, [bold]p[/] for reconstructed.")
            return

        log.write("Working…")


def run_app(wav_path: str | Path) -> None:
    AudioCompressionApp(wav_path).run()
