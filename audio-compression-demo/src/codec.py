"""Wavelet audio compression with the required 24-bit record format."""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

import numpy as np
import pywt
import soundfile as sf

# Defaults matching the MATLAB sketch (db4 / level 10 / mid-band threshold).
#
# Transform: multilevel Discrete Wavelet Transform (DWT) via Mallat's
# filter bank (PyWavelets wavedec/waverec).
# Family: Daubechies orthogonal wavelets; ``db4`` has 4 vanishing moments.
# See: https://en.wikipedia.org/wiki/Discrete_wavelet_transform
DEFAULT_WAVELET = "db4"
DEFAULT_WAVELET_FAMILY = "Daubechies"
DEFAULT_WAVELET_VANISHING_MOMENTS = 4
DEFAULT_TRANSFORM = "DWT"
DEFAULT_LEVEL = 10
DEFAULT_MODE = "symmetric"
DEFAULT_THRESHOLD = 0.1
DEFAULT_F = 12
DEFAULT_ZERO_DETAIL_LEVELS = frozenset({1, 6, 7, 8, 9, 10})
DEFAULT_THRESHOLD_DETAIL_LEVELS = frozenset({2, 3, 4, 5})

AVAILABLE_WAVELETS = (
    "haar",
    "db2",
    "db4",
    "db8",
    "sym4",
    "coif2",
    "bior2.2",
)
THRESHOLD_PRESETS = (0.05, 0.1, 0.2, 0.5)


class ThresholdTechnique(str, Enum):
    HARD = "hard"
    SOFT = "soft"
    HARD_MATLAB = "hard_matlab"
    SOFT_UNIFORM = "soft_uniform"

    @property
    def label(self) -> str:
        return {
            ThresholdTechnique.HARD: "Hard (all bands)",
            ThresholdTechnique.SOFT: "Soft (all bands)",
            ThresholdTechnique.HARD_MATLAB: "Hard + MATLAB bands",
            ThresholdTechnique.SOFT_UNIFORM: "Soft + keep approx",
        }[self]


DEFAULT_TECHNIQUE = ThresholdTechnique.HARD_MATLAB

TECHNIQUE_BY_ID = {t.value: t for t in ThresholdTechnique}


def wavelet_description(wavelet: str = DEFAULT_WAVELET) -> str:
    """Human-readable transform / family label for the UI and report."""
    name = wavelet.lower()
    if name == "haar" or name == "db1":
        family = "Haar (Daubechies db1)"
        moments = 1
    elif name.startswith("db") and name[2:].isdigit():
        moments = int(name[2:])
        family = f"Daubechies (db{moments})"
    elif name.startswith("sym") and name[3:].isdigit():
        moments = int(name[3:])
        family = f"Symlet (sym{moments})"
    elif name.startswith("coif") and name[4:].isdigit():
        moments = int(name[4:])
        family = f"Coiflet (coif{moments})"
    elif name.startswith("bior"):
        family = f"Biorthogonal ({name})"
        return f"{DEFAULT_TRANSFORM}: {family}"
    else:
        return f"{DEFAULT_TRANSFORM}: {wavelet}"
    return (
        f"{DEFAULT_TRANSFORM}: {family}, {moments} vanishing moment"
        f"{'' if moments == 1 else 's'}"
    )


def max_decomposition_level(n_samples: int, wavelet: str) -> int:
    return max(1, pywt.dwt_max_level(n_samples, pywt.Wavelet(wavelet).dec_len))


def list_input_wavs(directory: str | Path) -> list[Path]:
    """WAV files available for selection (excludes reconstructed outputs)."""
    directory = Path(directory)
    files = sorted(
        p
        for p in directory.glob("*.wav")
        if not p.name.endswith("_reconstructed.wav")
    )
    return files


def matlab_band_sets(n_levels: int) -> tuple[frozenset[int], frozenset[int]]:
    """Adapt the MATLAB zero / mid-band policy to the actual decomposition depth."""
    zero = {1} | {lvl for lvl in range(6, n_levels + 1)}
    mid = {lvl for lvl in (2, 3, 4, 5) if 1 <= lvl <= n_levels}
    # Levels neither zeroed nor mid keep their coeffs unchanged (none for L<=5 mid-only).
    return frozenset(zero), frozenset(mid)

MAGIC = b"WAC1"
HEADER_FORMAT = "<4sIII16sBBBBI"
# magic, sample_rate, n_samples, n_coeffs, wavelet[16], level, mode_id, F, bit_depth, record_count
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)

MODE_IDS = {
    "symmetric": 0,
    "periodization": 1,
    "reflect": 2,
    "zero": 3,
}
ID_TO_MODE = {v: k for k, v in MODE_IDS.items()}


@dataclass
class AudioInfo:
    path: Path
    samples: np.ndarray
    sample_rate: int
    channels: int
    bit_depth: int
    duration_s: float
    original_sample_bits: int
    file_bytes: int


@dataclass
class EncodeResult:
    coeffs_thresholded: list[np.ndarray]
    flat_thresholded: np.ndarray
    quantized: np.ndarray
    records: np.ndarray  # shape (R, 2) of (count, coeff)
    zero_pct_threshold: float
    zero_pct_quantized: float
    snr_threshold_db: float
    wavelet: str
    level: int
    mode: str
    fractional_bits: int
    n_samples: int
    sample_rate: int
    bit_depth: int
    payload_bits: int
    header_bits: int
    payload_ratio: float
    total_ratio: float
    record_count: int


@dataclass
class DecodeResult:
    quantized: np.ndarray
    samples: np.ndarray
    snr_db: float
    wavelet: str
    level: int
    mode: str
    fractional_bits: int
    sample_rate: int
    n_samples: int
    bit_depth: int
    record_count: int
    coeffs_match_encoded: bool | None = None


@dataclass
class PipelineTimings:
    load_ns: int = 0
    dwt_ns: int = 0
    threshold_ns: int = 0
    quantize_encode_ns: int = 0
    write_ns: int = 0
    decode_ns: int = 0
    idwt_ns: int = 0
    write_wav_ns: int = 0


@dataclass
class PipelineResult:
    info: AudioInfo
    encode: EncodeResult
    decode: DecodeResult
    reconstructed_path: Path
    compressed_path: Path
    timings: PipelineTimings = field(default_factory=PipelineTimings)


def load_audio(path: str | Path) -> AudioInfo:
    path = Path(path)
    info = sf.info(str(path))
    data, sample_rate = sf.read(str(path), always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)
    samples = np.asarray(data, dtype=np.float64)

    subtype = (info.subtype or "").upper()
    if "PCM_16" in subtype or subtype == "PCM_16":
        bit_depth = 16
    elif "PCM_24" in subtype:
        bit_depth = 24
    elif "PCM_32" in subtype or "FLOAT" in subtype:
        bit_depth = 32
    elif "PCM_U8" in subtype or "PCM_8" in subtype:
        bit_depth = 8
    else:
        # soundfile often exposes MPEG-in-WAV oddly; treat float samples as 16-bit PCM reference.
        bit_depth = 16

    n = samples.shape[0]
    return AudioInfo(
        path=path,
        samples=samples,
        sample_rate=int(sample_rate),
        channels=1,
        bit_depth=bit_depth,
        duration_s=n / float(sample_rate),
        original_sample_bits=n * bit_depth,
        file_bytes=path.stat().st_size,
    )


def decompose(
    samples: np.ndarray,
    wavelet: str = DEFAULT_WAVELET,
    level: int = DEFAULT_LEVEL,
    mode: str = DEFAULT_MODE,
) -> list[np.ndarray]:
    max_level = pywt.dwt_max_level(len(samples), pywt.Wavelet(wavelet).dec_len)
    level = min(level, max_level)
    return pywt.wavedec(samples, wavelet, level=level, mode=mode)


def _hard_shrink(band: np.ndarray, threshold: float) -> np.ndarray:
    out = band.copy()
    out[np.abs(out) <= threshold] = 0.0
    return out


def _soft_shrink(band: np.ndarray, threshold: float) -> np.ndarray:
    magnitude = np.abs(band)
    shrunk = np.sign(band) * np.maximum(magnitude - threshold, 0.0)
    return shrunk.astype(np.float64, copy=False)


def apply_hard_threshold(
    coeffs: list[np.ndarray],
    threshold: float = DEFAULT_THRESHOLD,
    zero_approx: bool = True,
    zero_detail_levels: frozenset[int] | None = None,
    threshold_detail_levels: frozenset[int] | None = None,
) -> list[np.ndarray]:
    """Hard-threshold wavelet coeffs (MATLAB-band helper). Kept for compatibility."""
    return apply_threshold(
        coeffs,
        threshold=threshold,
        technique=ThresholdTechnique.HARD_MATLAB,
        zero_approx=zero_approx,
        zero_detail_levels=zero_detail_levels,
        threshold_detail_levels=threshold_detail_levels,
    )


def apply_threshold(
    coeffs: list[np.ndarray],
    *,
    threshold: float = DEFAULT_THRESHOLD,
    technique: ThresholdTechnique | str = DEFAULT_TECHNIQUE,
    zero_approx: bool | None = None,
    zero_detail_levels: frozenset[int] | None = None,
    threshold_detail_levels: frozenset[int] | None = None,
) -> list[np.ndarray]:
    """Apply a selectable thresholding technique to wavelet coefficients."""
    if isinstance(technique, str):
        technique = TECHNIQUE_BY_ID[technique]
    n_levels = len(coeffs) - 1

    if technique is ThresholdTechnique.HARD:
        return [_hard_shrink(band, threshold) for band in coeffs]

    if technique is ThresholdTechnique.SOFT:
        return [_soft_shrink(band, threshold) for band in coeffs]

    if technique is ThresholdTechnique.SOFT_UNIFORM:
        out = [coeffs[0].copy()]  # keep approximation
        out.extend(_soft_shrink(band, threshold) for band in coeffs[1:])
        return out

    # HARD_MATLAB (and optional overrides)
    if zero_detail_levels is None or threshold_detail_levels is None:
        auto_zero, auto_mid = matlab_band_sets(n_levels)
        if zero_detail_levels is None:
            zero_detail_levels = auto_zero
        if threshold_detail_levels is None:
            threshold_detail_levels = auto_mid
    if zero_approx is None:
        zero_approx = True

    out: list[np.ndarray] = []
    if zero_approx:
        out.append(np.zeros_like(coeffs[0]))
    else:
        out.append(_hard_shrink(coeffs[0], threshold))

    for i, band in enumerate(coeffs[1:], start=1):
        detail_level = n_levels - i + 1  # coeffs[1] -> coarsest detail = n_levels
        if detail_level in zero_detail_levels:
            out.append(np.zeros_like(band))
        elif detail_level in threshold_detail_levels:
            out.append(_hard_shrink(band, threshold))
        else:
            out.append(band.copy())
    return out


def reconstruct(
    coeffs: list[np.ndarray],
    wavelet: str,
    mode: str,
    n_samples: int,
) -> np.ndarray:
    y = pywt.waverec(coeffs, wavelet, mode=mode)
    y = np.asarray(y, dtype=np.float64)
    if len(y) >= n_samples:
        return y[:n_samples]
    out = np.zeros(n_samples, dtype=np.float64)
    out[: len(y)] = y
    return out


def snr_db(original: np.ndarray, reconstructed: np.ndarray) -> float:
    err = original - reconstructed
    power = float(np.sum(original**2))
    noise = float(np.sum(err**2))
    if noise == 0.0:
        return float("inf")
    if power == 0.0:
        return float("-inf")
    return 10.0 * np.log10(power / noise)


def zero_percentage(arr: np.ndarray) -> float:
    if arr.size == 0:
        return 0.0
    return 100.0 * float(np.count_nonzero(arr == 0)) / float(arr.size)


def flatten_coeffs(coeffs: list[np.ndarray]) -> np.ndarray:
    return np.concatenate([c.ravel() for c in coeffs]).astype(np.float64, copy=False)


def unflatten_coeffs(flat: np.ndarray, shapes: list[tuple[int, ...]]) -> list[np.ndarray]:
    out: list[np.ndarray] = []
    offset = 0
    for shape in shapes:
        n = int(np.prod(shape))
        out.append(flat[offset : offset + n].reshape(shape))
        offset += n
    if offset != flat.size:
        raise ValueError(f"coefficient length mismatch: used {offset}, have {flat.size}")
    return out


def quantize_coeffs(flat: np.ndarray, fractional_bits: int = DEFAULT_F) -> np.ndarray:
    scale = float(1 << fractional_bits)
    q = np.rint(flat * scale).astype(np.int64)
    q = np.clip(q, -32768, 32767).astype(np.int16)
    return q


def dequantize_coeffs(quantized: np.ndarray, fractional_bits: int = DEFAULT_F) -> np.ndarray:
    return quantized.astype(np.float64) / float(1 << fractional_bits)


def encode_records(quantized: np.ndarray) -> np.ndarray:
    """Encode integer coefficients into (count, coeff) records.

    Each pair means ``count`` zeros followed by ``coeff`` (including when the
    coefficient is zero). Runs longer than 255 zeros use ``(255, 0)`` (= 256
    zeros). Trailing zeros of length ``r`` use ``(r - 1, 0)``.
    """
    q = np.asarray(quantized, dtype=np.int16).ravel()
    records: list[tuple[int, int]] = []
    i = 0
    n = q.size

    while i < n:
        zeros = 0
        while i < n and q[i] == 0:
            zeros += 1
            i += 1

        if i >= n:
            while zeros > 256:
                records.append((255, 0))
                zeros -= 256
            if zeros > 0:
                records.append((zeros - 1, 0))
            break

        coeff = int(q[i])
        i += 1
        while zeros > 255:
            records.append((255, 0))
            zeros -= 256
        records.append((zeros, coeff))

    if not records:
        records.append((0, 0))

    return np.asarray(records, dtype=np.int16)


def decode_records(records: np.ndarray, n_coeffs: int) -> np.ndarray:
    """Expand (count, coeff) records into an integer coefficient array of length n_coeffs."""
    out = np.empty(n_coeffs, dtype=np.int16)
    pos = 0
    for count, coeff in records:
        count_i = int(count) & 0xFF
        coeff_i = int(np.int16(coeff))
        need = count_i + 1
        if pos + need > n_coeffs:
            raise ValueError("decoded coefficients exceed expected length")
        if count_i:
            out[pos : pos + count_i] = 0
        out[pos + count_i] = coeff_i
        pos += need

    if pos != n_coeffs:
        raise ValueError(f"decoded length {pos} != expected {n_coeffs}")
    return out


def pack_records(records: np.ndarray) -> bytes:
    """Pack each (count, coeff) into 24 bits: 8-bit unsigned count + 16-bit signed coeff."""
    buf = bytearray()
    for count, coeff in records:
        c = int(count) & 0xFF
        # Store as unsigned 16-bit two's complement bits.
        q = int(np.int16(coeff)) & 0xFFFF
        buf.append(c)
        buf.append(q & 0xFF)
        buf.append((q >> 8) & 0xFF)
    return bytes(buf)


def unpack_records(payload: bytes, record_count: int) -> np.ndarray:
    if len(payload) != record_count * 3:
        raise ValueError(
            f"payload size {len(payload)} does not match record_count {record_count}"
        )
    records = np.empty((record_count, 2), dtype=np.int16)
    for i in range(record_count):
        base = i * 3
        count = payload[base]
        lo = payload[base + 1]
        hi = payload[base + 2]
        q = lo | (hi << 8)
        if q >= 0x8000:
            q -= 0x10000
        records[i, 0] = count
        records[i, 1] = q
    return records


def write_wac(
    path: str | Path,
    *,
    sample_rate: int,
    n_samples: int,
    n_coeffs: int,
    wavelet: str,
    level: int,
    mode: str,
    fractional_bits: int,
    bit_depth: int,
    records: np.ndarray,
) -> int:
    """Write compressed file; returns total file size in bytes."""
    path = Path(path)
    if mode not in MODE_IDS:
        raise ValueError(f"unsupported mode {mode!r}")
    wavelet_bytes = wavelet.encode("ascii")[:16].ljust(16, b"\0")
    record_count = int(records.shape[0])
    header = struct.pack(
        HEADER_FORMAT,
        MAGIC,
        int(sample_rate),
        int(n_samples),
        int(n_coeffs),
        wavelet_bytes,
        int(level),
        MODE_IDS[mode],
        int(fractional_bits),
        int(bit_depth),
        record_count,
    )
    payload = pack_records(records)
    data = header + payload
    path.write_bytes(data)
    return len(data)


def read_wac(path: str | Path) -> tuple[dict, np.ndarray]:
    path = Path(path)
    raw = path.read_bytes()
    if len(raw) < HEADER_SIZE:
        raise ValueError("file too small to be a WAC container")
    (
        magic,
        sample_rate,
        n_samples,
        n_coeffs,
        wavelet_bytes,
        level,
        mode_id,
        fractional_bits,
        bit_depth,
        record_count,
    ) = struct.unpack(HEADER_FORMAT, raw[:HEADER_SIZE])
    if magic != MAGIC:
        raise ValueError(f"bad magic {magic!r}")
    if mode_id not in ID_TO_MODE:
        raise ValueError(f"unknown mode id {mode_id}")
    wavelet = wavelet_bytes.split(b"\0", 1)[0].decode("ascii")
    records = unpack_records(raw[HEADER_SIZE:], record_count)
    meta = {
        "sample_rate": sample_rate,
        "n_samples": n_samples,
        "n_coeffs": n_coeffs,
        "wavelet": wavelet,
        "level": level,
        "mode": ID_TO_MODE[mode_id],
        "fractional_bits": fractional_bits,
        "bit_depth": bit_depth,
        "record_count": record_count,
        "header_bytes": HEADER_SIZE,
        "payload_bytes": record_count * 3,
    }
    return meta, records


def encode_audio(
    info: AudioInfo,
    *,
    wavelet: str = DEFAULT_WAVELET,
    level: int = DEFAULT_LEVEL,
    mode: str = DEFAULT_MODE,
    threshold: float = DEFAULT_THRESHOLD,
    technique: ThresholdTechnique | str = DEFAULT_TECHNIQUE,
    fractional_bits: int = DEFAULT_F,
) -> EncodeResult:
    coeffs = decompose(info.samples, wavelet=wavelet, level=level, mode=mode)
    level = len(coeffs) - 1
    thresholded = apply_threshold(
        coeffs, threshold=threshold, technique=technique
    )
    flat_thr = flatten_coeffs(thresholded)
    y_thr = reconstruct(thresholded, wavelet, mode, info.samples.shape[0])
    snr_thr = snr_db(info.samples, y_thr)

    quantized = quantize_coeffs(flat_thr, fractional_bits=fractional_bits)
    records = encode_records(quantized)

    payload_bits = int(records.shape[0]) * 24
    header_bits = HEADER_SIZE * 8
    orig_bits = info.original_sample_bits
    payload_ratio = (orig_bits / payload_bits) if payload_bits else float("inf")
    total_bits = payload_bits + header_bits
    total_ratio = (orig_bits / total_bits) if total_bits else float("inf")

    return EncodeResult(
        coeffs_thresholded=thresholded,
        flat_thresholded=flat_thr,
        quantized=quantized,
        records=records,
        zero_pct_threshold=zero_percentage(flat_thr),
        zero_pct_quantized=zero_percentage(quantized),
        snr_threshold_db=snr_thr,
        wavelet=wavelet,
        level=level,
        mode=mode,
        fractional_bits=fractional_bits,
        n_samples=info.samples.shape[0],
        sample_rate=info.sample_rate,
        bit_depth=info.bit_depth,
        payload_bits=payload_bits,
        header_bits=header_bits,
        payload_ratio=payload_ratio,
        total_ratio=total_ratio,
        record_count=int(records.shape[0]),
    )


def decode_wac(
    path: str | Path,
    *,
    original: np.ndarray | None = None,
    expected_quantized: np.ndarray | None = None,
) -> DecodeResult:
    meta, records = read_wac(path)
    quantized = decode_records(records, meta["n_coeffs"])
    match = None
    if expected_quantized is not None:
        match = bool(np.array_equal(quantized, expected_quantized))

    flat = dequantize_coeffs(quantized, fractional_bits=meta["fractional_bits"])
    # Rebuild coefficient shapes via a dummy decompose of correct length.
    shapes = [
        c.shape
        for c in decompose(
            np.zeros(meta["n_samples"]),
            wavelet=meta["wavelet"],
            level=meta["level"],
            mode=meta["mode"],
        )
    ]
    coeffs = unflatten_coeffs(flat, shapes)
    samples = reconstruct(coeffs, meta["wavelet"], meta["mode"], meta["n_samples"])
    snr = snr_db(original, samples) if original is not None else float("nan")

    return DecodeResult(
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


def write_wav(path: str | Path, samples: np.ndarray, sample_rate: int) -> None:
    clipped = np.clip(samples, -1.0, 1.0)
    sf.write(str(path), clipped, sample_rate, subtype="PCM_16")


def run_pipeline(
    wav_path: str | Path,
    *,
    compressed_path: str | Path | None = None,
    reconstructed_path: str | Path | None = None,
    wavelet: str = DEFAULT_WAVELET,
    level: int = DEFAULT_LEVEL,
    mode: str = DEFAULT_MODE,
    threshold: float = DEFAULT_THRESHOLD,
    technique: ThresholdTechnique | str = DEFAULT_TECHNIQUE,
    fractional_bits: int = DEFAULT_F,
) -> PipelineResult:
    from .timing import timed

    wav_path = Path(wav_path)
    compressed_path = Path(compressed_path) if compressed_path else wav_path.with_suffix(".wac")
    reconstructed_path = (
        Path(reconstructed_path)
        if reconstructed_path
        else wav_path.with_name(wav_path.stem + "_reconstructed.wav")
    )
    if isinstance(technique, str):
        technique = TECHNIQUE_BY_ID[technique]

    timings = PipelineTimings()
    info, timings.load_ns = timed(lambda: load_audio(wav_path))

    # Split encode timings more finely for the TUI footer.
    coeffs, timings.dwt_ns = timed(
        lambda: decompose(info.samples, wavelet=wavelet, level=level, mode=mode)
    )
    used_wavelet = wavelet
    used_level = len(coeffs) - 1
    thresholded, timings.threshold_ns = timed(
        lambda: apply_threshold(
            coeffs, threshold=threshold, technique=technique
        )
    )

    def _quantize_encode() -> EncodeResult:
        flat_thr = flatten_coeffs(thresholded)
        y_thr = reconstruct(thresholded, used_wavelet, mode, info.samples.shape[0])
        snr_thr = snr_db(info.samples, y_thr)
        quantized = quantize_coeffs(flat_thr, fractional_bits=fractional_bits)
        records = encode_records(quantized)
        payload_bits = int(records.shape[0]) * 24
        header_bits = HEADER_SIZE * 8
        orig_bits = info.original_sample_bits
        return EncodeResult(
            coeffs_thresholded=thresholded,
            flat_thresholded=flat_thr,
            quantized=quantized,
            records=records,
            zero_pct_threshold=zero_percentage(flat_thr),
            zero_pct_quantized=zero_percentage(quantized),
            snr_threshold_db=snr_thr,
            wavelet=used_wavelet,
            level=used_level,
            mode=mode,
            fractional_bits=fractional_bits,
            n_samples=info.samples.shape[0],
            sample_rate=info.sample_rate,
            bit_depth=info.bit_depth,
            payload_bits=payload_bits,
            header_bits=header_bits,
            payload_ratio=(orig_bits / payload_bits) if payload_bits else float("inf"),
            total_ratio=(orig_bits / (payload_bits + header_bits))
            if payload_bits
            else float("inf"),
            record_count=int(records.shape[0]),
        )

    encode, timings.quantize_encode_ns = timed(_quantize_encode)

    def _write() -> int:
        return write_wac(
            compressed_path,
            sample_rate=encode.sample_rate,
            n_samples=encode.n_samples,
            n_coeffs=encode.quantized.size,
            wavelet=encode.wavelet,
            level=encode.level,
            mode=encode.mode,
            fractional_bits=encode.fractional_bits,
            bit_depth=encode.bit_depth,
            records=encode.records,
        )

    _, timings.write_ns = timed(_write)

    meta_and_records, timings.decode_ns = timed(lambda: read_wac(compressed_path))
    meta, records = meta_and_records
    quantized = decode_records(records, meta["n_coeffs"])
    match = bool(np.array_equal(quantized, encode.quantized))

    def _idwt() -> np.ndarray:
        flat = dequantize_coeffs(quantized, fractional_bits=meta["fractional_bits"])
        shapes = [c.shape for c in decompose(
            np.zeros(meta["n_samples"]),
            wavelet=meta["wavelet"],
            level=meta["level"],
            mode=meta["mode"],
        )]
        coeffs_r = unflatten_coeffs(flat, shapes)
        return reconstruct(coeffs_r, meta["wavelet"], meta["mode"], meta["n_samples"])

    samples, timings.idwt_ns = timed(_idwt)
    snr = snr_db(info.samples, samples)

    def _write_wav() -> None:
        write_wav(reconstructed_path, samples, meta["sample_rate"])

    _, timings.write_wav_ns = timed(_write_wav)

    decode = DecodeResult(
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

    return PipelineResult(
        info=info,
        encode=encode,
        decode=decode,
        reconstructed_path=reconstructed_path,
        compressed_path=compressed_path,
        timings=timings,
    )


def self_test_handout_examples() -> None:
    """Verify the handout encoding examples."""
    example = np.array([0, 0, 0, 5, 0, 0, -3, 0, 0, 0, 0, 7, 0, 2], dtype=np.int16)
    records = encode_records(example)
    expected = np.array([[3, 5], [2, -3], [4, 7], [1, 2]], dtype=np.int16)
    assert np.array_equal(records, expected), records
    decoded = decode_records(records, example.size)
    assert np.array_equal(decoded, example), decoded

    long_zeros = np.zeros(601, dtype=np.int16)
    long_zeros[-1] = 5
    records2 = encode_records(long_zeros)
    expected2 = np.array([[255, 0], [255, 0], [88, 5]], dtype=np.int16)
    assert np.array_equal(records2, expected2), records2
    decoded2 = decode_records(records2, long_zeros.size)
    assert np.array_equal(decoded2, long_zeros), decoded2
