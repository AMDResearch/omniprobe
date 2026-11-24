"""Locate the rocprof-trace-decoder marker API (Python package and samples).

The SQTT tools here decode thread traces with rocprof-trace-decoder's marker
API (ROCm/rocm-systems#13867). counter_fit.py reuses the decoder's marker
samples (marker_common, address_trace), which the decoder installs under
<prefix>/share/rocprof-trace-decoder/samples, next to its Python package in
<prefix>/lib/pythonX.Y/site-packages.

Search order for <prefix>:
  1. ROCPROF_TRACE_DECODER_SAMPLES: the samples directory itself;
  2. ROCPROF_TRACE_DECODER_LIB: the decoder library (<prefix>/lib/...so);
  3. ROCM_PATH, then /opt/rocm.
"""

from __future__ import annotations

import glob
import os
import sys
from pathlib import Path

SAMPLES_SUBDIR = Path("share") / "rocprof-trace-decoder" / "samples"


def _prefixes() -> list[Path]:
    prefixes = []
    lib = os.environ.get("ROCPROF_TRACE_DECODER_LIB")
    if lib:
        prefixes.append(Path(lib).resolve().parent.parent)
    for root in (os.environ.get("ROCM_PATH"), "/opt/rocm"):
        if root:
            prefixes.append(Path(root))
    return prefixes


def samples_dir() -> Path | None:
    explicit = os.environ.get("ROCPROF_TRACE_DECODER_SAMPLES")
    if explicit and (Path(explicit) / "markers" / "marker_common.py").is_file():
        return Path(explicit)
    for prefix in _prefixes():
        candidate = prefix / SAMPLES_SUBDIR
        if (candidate / "markers" / "marker_common.py").is_file():
            return candidate
    return None


def add_decoder_paths() -> None:
    """Make `rocprof_trace_decoder`, `marker_common` and `address_trace` importable."""
    samples = samples_dir()
    if samples is None:
        raise SystemExit(
            "omniprobe: SQTT analysis needs rocprof-trace-decoder with the marker API "
            "(ROCm/rocm-systems#13867) and its samples. Set ROCPROF_TRACE_DECODER_SAMPLES to "
            "<prefix>/share/rocprof-trace-decoder/samples, or ROCPROF_TRACE_DECODER_LIB to the "
            "decoder library of that install."
        )
    for path in (samples / "markers", samples):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))
    try:
        import rocprof_trace_decoder  # noqa: F401
    except ImportError:
        prefix = samples.parent.parent.parent
        for site in sorted(glob.glob(str(prefix / "lib*" / "python3*" / "site-packages"))):
            if site not in sys.path:
                sys.path.insert(0, site)
