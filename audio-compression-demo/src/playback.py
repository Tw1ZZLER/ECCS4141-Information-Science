"""Audio playback helpers with PortAudio and external-player fallbacks."""

from __future__ import annotations

import ctypes
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf


def _try_load_portaudio() -> bool:
    """Best-effort preload of libportaudio for sounddevice on Nix."""
    candidates: list[str] = []
    env = os.environ.get("PORTAUDIO_LIB") or os.environ.get("LIBPORTAUDIO")
    if env:
        candidates.append(env)

    ld = os.environ.get("LD_LIBRARY_PATH", "")
    for part in ld.split(":"):
        if not part:
            continue
        candidates.append(str(Path(part) / "libportaudio.so"))
        candidates.append(str(Path(part) / "libportaudio.so.2"))

    # Common sonames if the dynamic linker can already see them.
    candidates.extend(
        [
            "libportaudio.so.2",
            "libportaudio.so",
            "portaudio",
        ]
    )

    for name in candidates:
        try:
            ctypes.CDLL(name)
            return True
        except OSError:
            continue
    return False


def _play_sounddevice(samples: np.ndarray, sample_rate: int) -> None:
    _try_load_portaudio()
    import sounddevice as sd

    clipped = np.clip(samples, -1.0, 1.0).astype(np.float32)
    sd.play(clipped, sample_rate, blocking=True)


def _external_players() -> list[list[str]]:
    """Return command templates; `{path}` is substituted with the WAV path."""
    commands: list[list[str]] = []
    # PipeWire / Pulse / ALSA / ffmpeg / mpv — prefer non-GUI blocking tools.
    for binary, args in (
        ("pw-play", ["{path}"]),
        ("paplay", ["{path}"]),
        ("aplay", ["{path}"]),
        ("ffplay", ["-nodisp", "-autoexit", "-loglevel", "quiet", "{path}"]),
        ("mpv", ["--no-video", "--really-quiet", "{path}"]),
    ):
        path = shutil.which(binary)
        if path:
            commands.append([path, *args])
    return commands


def _play_external(samples: np.ndarray, sample_rate: int) -> str:
    players = _external_players()
    if not players:
        raise RuntimeError(
            "No PortAudio library and no external player "
            "(pw-play, paplay, aplay, ffplay, or mpv) found"
        )

    clipped = np.clip(samples, -1.0, 1.0)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        sf.write(str(tmp_path), clipped, sample_rate, subtype="PCM_16")
        errors: list[str] = []
        for cmd in players:
            rendered = [tmp_path.as_posix() if part == "{path}" else part for part in cmd]
            try:
                subprocess.run(rendered, check=True)
                return Path(rendered[0]).name
            except (OSError, subprocess.CalledProcessError) as exc:
                errors.append(f"{rendered[0]}: {exc}")
        raise RuntimeError("; ".join(errors))
    finally:
        tmp_path.unlink(missing_ok=True)


def play_audio(samples: np.ndarray, sample_rate: int) -> str:
    """Play mono/stereo float samples. Returns the backend name used."""
    try:
        _play_sounddevice(samples, sample_rate)
        return "sounddevice/PortAudio"
    except Exception as sounddevice_exc:  # noqa: BLE001
        try:
            backend = _play_external(samples, sample_rate)
            return backend
        except Exception as external_exc:  # noqa: BLE001
            raise RuntimeError(
                f"PortAudio unavailable ({sounddevice_exc}); "
                f"external player failed ({external_exc})"
            ) from external_exc
