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

# Focus targets while configuring a stage (before Enter runs it).
FOCUS_FILE = "file"
FOCUS_WAVELET = "wavelet"
FOCUS_LEVEL = "level"
FOCUS_TECHNIQUE = "technique"
FOCUS_T = "threshold"


def _fmt_ms(ns: int) -> str:
    return f"{ns / 1_000_000:.3f} ms"


def _fmt_snr(snr: float) -> str:
    if np.isinf(snr):
        return "infinite"
    return f"{snr:.3f} dB"


def _mark(selected: bool, active_focus: bool, label: str) -> str:
    cursor = ">" if active_focus else " "
    bullet = "*" if selected else " "
    style_open = "[reverse bold]" if active_focus and selected else ("[bold]" if selected else "")
    style_close = "[/]" if style_open else ""
    return f" {cursor}{bullet} {style_open}{label}{style_close}"


class MetricsBar(Static):
    """Bottom performance metrics line."""

    def show(self, timings: codec.PipelineTimings | None, status: str = "") -> None:
        if timings is None:
            self.update(f"[dim]timings: —[/]  {status}")
            return
        parts = [
            f"load {_fmt_ms(timings.load_ns)}",
            f"dwt {_fmt_ms(timings.dwt_ns)}",
            f"thresh {_fmt_ms(timings.threshold_ns)}",
            f"enc {_fmt_ms(timings.quantize_encode_ns)}",
            f"write {_fmt_ms(timings.write_ns)}",
            f"decode {_fmt_ms(timings.decode_ns)}",
            f"idwt {_fmt_ms(timings.idwt_ns)}",
            f"wav {_fmt_ms(timings.write_wav_ns)}",
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
    """Staged encode / decode / playback demonstration with interactive choices."""

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
        width: 42;
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
        Binding("enter", "advance", "Run/Next", show=True),
        Binding("space", "advance", "Run/Next", show=False),
        Binding("up", "move_up", "Up", show=False),
        Binding("down", "move_down", "Down", show=False),
        Binding("k", "move_up", "Up", show=False),
        Binding("j", "move_down", "Down", show=False),
        Binding("left", "nudge_left", "Nudge-", show=False),
        Binding("right", "nudge_right", "Nudge+", show=False),
        Binding("minus", "nudge_left", "Nudge-", show=False),
        Binding("plus", "nudge_right", "Nudge+", show=False),
        Binding("=", "nudge_right", "Nudge+", show=False),
        # priority=True so we override Screen's default tab → focus_next.
        Binding("tab", "cycle_focus", "Focus", show=True, priority=True),
        Binding("shift+tab", "cycle_focus_back", "Focus", show=False, priority=True),
        Binding("o", "play_original", "Play orig", show=True),
        Binding("p", "play_recon", "Play recon", show=True),
        Binding("r", "reset", "Reset", show=True),
        Binding("q", "quit", "Quit", show=True),
    ]

    def __init__(self, wav_path: str | Path | None = None) -> None:
        super().__init__()
        self.demo_dir = Path(__file__).resolve().parent.parent
        self.audio_dir = codec.audio_dir(self.demo_dir)
        self.wav_choices = codec.list_input_wavs(self.audio_dir)
        if not self.wav_choices:
            raise FileNotFoundError(
                f"No WAV files found in {self.audio_dir}. "
                "Add input audio under the audio/ directory."
            )

        initial = Path(wav_path) if wav_path else self.wav_choices[0]
        if not initial.is_file():
            for candidate in (
                self.audio_dir / initial.name,
                self.demo_dir / initial.name,
                initial,
            ):
                if candidate.is_file():
                    initial = candidate
                    break
            else:
                initial = self.wav_choices[0]

        self.wav_index = 0
        for i, path in enumerate(self.wav_choices):
            if path.resolve() == initial.resolve() or path.name == initial.name:
                self.wav_index = i
                break

        self.wavelet_choices = list(codec.AVAILABLE_WAVELETS)
        self.wavelet_index = self.wavelet_choices.index(codec.DEFAULT_WAVELET)
        self.level = codec.DEFAULT_LEVEL
        self.technique_choices = list(codec.ThresholdTechnique)
        self.technique_index = self.technique_choices.index(codec.DEFAULT_TECHNIQUE)
        self.threshold_choices = list(codec.THRESHOLD_PRESETS)
        self.threshold_index = self.threshold_choices.index(codec.DEFAULT_THRESHOLD)

        self.sel_focus = FOCUS_FILE
        self.stage = 0
        self.stage_done = False
        self.info: codec.AudioInfo | None = None
        self.coeffs: list[np.ndarray] | None = None
        self.thresholded: list[np.ndarray] | None = None
        self.encode: codec.EncodeResult | None = None
        self.decode: codec.DecodeResult | None = None
        self.timings = codec.PipelineTimings()
        self._sync_output_paths()

    @property
    def wav_path(self) -> Path:
        return self.wav_choices[self.wav_index]

    @property
    def wavelet(self) -> str:
        return self.wavelet_choices[self.wavelet_index]

    @property
    def technique(self) -> codec.ThresholdTechnique:
        return self.technique_choices[self.technique_index]

    @property
    def threshold(self) -> float:
        return self.threshold_choices[self.threshold_index]

    def _sync_output_paths(self) -> None:
        self.compressed_path = self.wav_path.with_suffix(".wac")
        self.reconstructed_path = self.wav_path.with_name(
            self.wav_path.stem + "_reconstructed.wav"
        )

    def _max_level(self) -> int:
        if self.info is None:
            return max(1, self.level)
        return codec.max_decomposition_level(self.info.samples.shape[0], self.wavelet)

    def _clamp_level(self) -> None:
        self.level = max(1, min(self.level, self._max_level()))

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
        self._update_subtitle()
        self.query_one("#banner", StageBanner).show(0)
        self.query_one("#metrics", MetricsBar).show(self.timings)
        self._render_stage()

    def _update_subtitle(self) -> None:
        self.sub_title = (
            f"{self.wav_path.name}  ·  "
            f"{codec.DEFAULT_TRANSFORM} {self.wavelet} L{self.level}  ·  "
            f"{self.technique.value} T={self.threshold}"
        )

    def _side_panel(self, status: str | None = None) -> str:
        lines = [
            "[bold]Controls[/]",
            "↑↓/jk       move selection",
            "Tab         switch focus",
            "←→ / -+     nudge level/T",
            "Enter/Space run or next",
            "o / p       play orig/recon",
            "r           reset",
            "q           quit",
            "",
            f"[bold]Stage[/] {self.stage + 1}/{len(STAGE_NAMES)}",
            "",
            "[bold]Session[/]",
            f"File   {self.wav_path.name}",
            f"Filter {self.wavelet}",
            f"Level  {self.level}",
            f"Tech   {self.technique.value}",
            f"T      {self.threshold}",
        ]
        if status:
            lines.extend(["", f"[bold]Status[/]\n{status}"])
        return "\n".join(lines)

    def action_reset(self) -> None:
        self.stage = 0
        self.stage_done = False
        self.sel_focus = FOCUS_FILE
        self.info = None
        self.coeffs = None
        self.thresholded = None
        self.encode = None
        self.decode = None
        self.timings = codec.PipelineTimings()
        self._sync_output_paths()
        self._update_subtitle()
        self.query_one("#banner", StageBanner).show(0)
        self.query_one("#metrics", MetricsBar).show(self.timings, "[dim]reset[/]")
        self._render_stage()

    def action_advance(self) -> None:
        if not self.stage_done:
            self._run_stage(self.stage)
            self.stage_done = True
            self._set_focus_for_stage(self.stage)
        elif self.stage < len(STAGE_NAMES) - 1:
            self.stage += 1
            self.stage_done = False
            self._set_focus_for_stage(self.stage)
            # Encode / Decode / Playback auto-run on entry (no further config).
            if self.stage >= 3:
                self._run_stage(self.stage)
                self.stage_done = True
        else:
            return
        self._update_subtitle()
        self.query_one("#banner", StageBanner).show(self.stage)
        self.query_one("#metrics", MetricsBar).show(self.timings)
        self._render_stage()

    def _set_focus_for_stage(self, stage: int) -> None:
        if stage == 0:
            self.sel_focus = FOCUS_FILE
        elif stage == 1:
            self.sel_focus = FOCUS_WAVELET
        elif stage == 2:
            self.sel_focus = FOCUS_TECHNIQUE
        else:
            self.sel_focus = FOCUS_FILE

    def action_cycle_focus(self) -> None:
        if self.stage_done:
            return
        if self.stage == 1:
            self.sel_focus = FOCUS_LEVEL if self.sel_focus == FOCUS_WAVELET else FOCUS_WAVELET
        elif self.stage == 2:
            self.sel_focus = FOCUS_T if self.sel_focus == FOCUS_TECHNIQUE else FOCUS_TECHNIQUE
        self._render_stage()

    def action_cycle_focus_back(self) -> None:
        self.action_cycle_focus()

    def action_move_up(self) -> None:
        self._move_selection(-1)

    def action_move_down(self) -> None:
        self._move_selection(1)

    def action_nudge_left(self) -> None:
        self._nudge(-1)

    def action_nudge_right(self) -> None:
        self._nudge(1)

    def _move_selection(self, delta: int) -> None:
        if self.stage_done and self.stage < 3:
            # Allow re-picking only before the stage has been run; after run, wait for next.
            return
        if self.stage == 0 and self.sel_focus == FOCUS_FILE:
            self.wav_index = (self.wav_index + delta) % len(self.wav_choices)
            self._sync_output_paths()
        elif self.stage == 1 and self.sel_focus == FOCUS_WAVELET:
            self.wavelet_index = (self.wavelet_index + delta) % len(self.wavelet_choices)
            self._clamp_level()
        elif self.stage == 1 and self.sel_focus == FOCUS_LEVEL:
            self.level = max(1, min(self._max_level(), self.level + delta))
        elif self.stage == 2 and self.sel_focus == FOCUS_TECHNIQUE:
            self.technique_index = (
                self.technique_index + delta
            ) % len(self.technique_choices)
        elif self.stage == 2 and self.sel_focus == FOCUS_T:
            self.threshold_index = (
                self.threshold_index + delta
            ) % len(self.threshold_choices)
        else:
            return
        self._update_subtitle()
        self._render_stage()

    def _nudge(self, delta: int) -> None:
        if self.stage_done:
            return
        if self.stage == 1:
            self.sel_focus = FOCUS_LEVEL
            self.level = max(1, min(self._max_level(), self.level + delta))
        elif self.stage == 2:
            self.sel_focus = FOCUS_T
            self.threshold_index = (
                self.threshold_index + delta
            ) % len(self.threshold_choices)
        else:
            return
        self._update_subtitle()
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
            self._sync_output_paths()
            self.info, self.timings.load_ns = timed(
                lambda: codec.load_audio(self.wav_path)
            )
            self._clamp_level()
        elif stage == 1:
            assert self.info is not None
            self._clamp_level()
            level = self.level
            wavelet = self.wavelet
            self.coeffs, self.timings.dwt_ns = timed(
                lambda: codec.decompose(
                    self.info.samples,
                    wavelet=wavelet,
                    level=level,
                    mode=codec.DEFAULT_MODE,
                )
            )
            self.level = len(self.coeffs) - 1
        elif stage == 2:
            assert self.coeffs is not None and self.info is not None
            technique = self.technique
            threshold = self.threshold
            self.thresholded, self.timings.threshold_ns = timed(
                lambda: codec.apply_threshold(
                    self.coeffs,
                    threshold=threshold,
                    technique=technique,
                )
            )
        elif stage == 3:
            assert self.thresholded is not None and self.info is not None
            wavelet = self.wavelet
            mode = codec.DEFAULT_MODE

            def _encode() -> codec.EncodeResult:
                flat = codec.flatten_coeffs(self.thresholded)
                y_thr = codec.reconstruct(
                    self.thresholded,
                    wavelet,
                    mode,
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
                    wavelet=wavelet,
                    level=len(self.thresholded) - 1,
                    mode=mode,
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
            return

    def _render_stage(self) -> None:
        log = self.query_one("#panel", RichLog)
        log.clear()
        self.query_one("#side", Static).update(self._side_panel())

        if self.stage == 0 and not self.stage_done:
            log.write("[bold cyan]Stage 1 — Input audio[/]")
            log.write(
                f"Select a WAV from [bold]{self.audio_dir.name}/[/], "
                "then press [bold]Enter[/] to load."
            )
            log.write("")
            for i, path in enumerate(self.wav_choices):
                log.write(
                    _mark(
                        i == self.wav_index,
                        self.sel_focus == FOCUS_FILE,
                        path.name,
                    )
                )
            log.write("")
            log.write(
                "Pipeline: DWT → threshold → fixed-point quantize → "
                "24-bit records → .wac → decode → inverse DWT."
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
            log.write("Press [bold]Enter[/] for DWT filter/level selection.")
            return

        if self.stage == 1 and not self.stage_done:
            max_level = self._max_level()
            log.write("[bold cyan]Stage 2 — Discrete wavelet transform (DWT)[/]")
            log.write("Choose filter and level, then [bold]Enter[/] to run wavedec.")
            log.write(f"Focus: [bold]{self.sel_focus}[/]  (Tab to switch)")
            log.write("")
            log.write("[bold]Filter[/]")
            for i, name in enumerate(self.wavelet_choices):
                log.write(
                    _mark(
                        i == self.wavelet_index,
                        self.sel_focus == FOCUS_WAVELET,
                        f"{name}  —  {codec.wavelet_description(name)}",
                    )
                )
            log.write("")
            log.write("[bold]Level[/]")
            log.write(
                _mark(
                    True,
                    self.sel_focus == FOCUS_LEVEL,
                    f"{self.level}  (max {max_level} for this signal/filter)",
                )
            )
            log.write("Use ←→ or -+ to change level.")
            return

        if self.stage == 1 and self.coeffs is not None:
            sizes = [c.size for c in self.coeffs]
            log.write("[bold cyan]Stage 2 — Discrete wavelet transform (DWT)[/]")
            log.write("")
            log.write("Kind:           multilevel DWT")
            log.write(f"Transform:      {codec.wavelet_description(self.wavelet)}")
            log.write(f"Wavelet:        {self.wavelet}")
            log.write(f"Level:          {len(self.coeffs) - 1}")
            log.write(f"Extension:      {codec.DEFAULT_MODE}")
            log.write(f"Coeff vector:   {sum(sizes):,} coefficients")
            log.write(f"Subband sizes:  {sizes}")
            log.write("")
            log.write(
                "Implemented with PyWavelets wavedec/waverec (Mallat algorithm). "
                "Ordering: [cA_L, cD_L, cD_L-1, …, cD_1]."
            )
            log.write("Press [bold]Enter[/] for threshold technique selection.")
            return

        if self.stage == 2 and not self.stage_done:
            log.write("[bold cyan]Stage 3 — Thresholding[/]")
            log.write("Choose technique and T, then [bold]Enter[/] to apply.")
            log.write(f"Focus: [bold]{self.sel_focus}[/]  (Tab to switch)")
            log.write("")
            log.write("[bold]Technique[/]")
            for i, tech in enumerate(self.technique_choices):
                log.write(
                    _mark(
                        i == self.technique_index,
                        self.sel_focus == FOCUS_TECHNIQUE,
                        f"{tech.value}  —  {tech.label}",
                    )
                )
            log.write("")
            log.write("[bold]Threshold T[/]")
            for i, value in enumerate(self.threshold_choices):
                log.write(
                    _mark(
                        i == self.threshold_index,
                        self.sel_focus == FOCUS_T,
                        f"{value}",
                    )
                )
            return

        if self.stage == 2 and self.thresholded is not None and self.info is not None:
            flat = codec.flatten_coeffs(self.thresholded)
            y_thr = codec.reconstruct(
                self.thresholded,
                self.wavelet,
                codec.DEFAULT_MODE,
                self.info.samples.shape[0],
            )
            snr = codec.snr_db(self.info.samples, y_thr)
            log.write("[bold cyan]Stage 3 — Thresholding[/]")
            log.write("")
            log.write(f"Technique:       {self.technique.label} ({self.technique.value})")
            log.write(f"Threshold T:     {self.threshold}")
            if self.technique is codec.ThresholdTechnique.HARD_MATLAB:
                zero, mid = codec.matlab_band_sets(len(self.thresholded) - 1)
                log.write(f"Zeroed details:  {sorted(zero)}")
                log.write(f"Hard mid-bands:  {sorted(mid)}")
            log.write("")
            log.write(f"Zero coefficients: {codec.zero_percentage(flat):.3f}%")
            log.write(f"SNR (float recon): {_fmt_snr(snr)}")
            log.write("")
            log.write("Press [bold]Enter[/] to quantize and encode 24-bit records.")
            return

        if self.stage == 3 and self.encode is not None:
            enc = self.encode
            f = enc.fractional_bits
            log.write("[bold cyan]Stage 4 — Quantize + 24-bit encode[/]")
            log.write("")
            log.write(f"Wavelet/level:     {enc.wavelet} / {enc.level}")
            log.write(f"Technique / T:     {self.technique.value} / {self.threshold}")
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
            log.write(f"Filter / level:   {self.wavelet} / {self.level}")
            log.write(f"Technique / T:    {self.technique.value} / {self.threshold}")
            log.write("")
            log.write(f"Threshold SNR:    {_fmt_snr(enc.snr_threshold_db)}")
            log.write(f"Final SNR:        {_fmt_snr(dec.snr_db)}")
            log.write(f"Payload ratio:    {enc.payload_ratio:.4f} : 1")
            log.write(f"Total ratio:      {enc.total_ratio:.4f} : 1")
            log.write("")
            log.write("Press [bold]o[/] to play original, [bold]p[/] for reconstructed.")
            return

        log.write("Working…")


def run_app(wav_path: str | Path | None = None) -> None:
    AudioCompressionApp(wav_path).run()
