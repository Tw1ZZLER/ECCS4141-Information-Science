"""Nanosecond timing helpers."""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import TypeVar

T = TypeVar("T")


def elapsed_ns(start_ns: int) -> int:
    return time.perf_counter_ns() - start_ns


def timed(fn: Callable[[], T]) -> tuple[T, int]:
    """Run ``fn`` and return ``(result, elapsed_nanoseconds)``."""
    start = time.perf_counter_ns()
    result = fn()
    return result, time.perf_counter_ns() - start
