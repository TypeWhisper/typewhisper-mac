#!/usr/bin/env python3
"""比较保存的引擎 PCM 与独立重采样的音频。需要 numpy 和 scipy。"""

import argparse
import json
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("reference", type=Path)
parser.add_argument("directory", type=Path)
args = parser.parse_args()
rate, reference = wavfile.read(args.reference)
if rate != 16_000 or reference.ndim != 1:
    parser.error("reference 必须为单声道 16 kHz 音频")
reference = reference.astype(np.float64)
for path in sorted(args.directory.glob("*.f32")):
    if not path.with_suffix(".json").exists():
        continue
    samples = np.fromfile(path, dtype="<f4").astype(np.float64)
    correlation = signal.correlate(samples, reference, method="fft")
    lags = signal.correlation_lags(len(samples), len(reference))
    lag = int(lags[np.argmax(correlation)])
    start = max(0, lag)
    ref_start = max(0, -lag)
    size = min(len(samples) - start, len(reference) - ref_start)
    actual = samples[start:start + size]
    expected = reference[ref_start:ref_start + size]
    print(json.dumps({
        "file": path.name, "sampleRate": int(rate), "channels": 1,
        "samples": len(samples), "seconds": len(samples) / rate,
        "rms": float(np.sqrt(np.mean(samples ** 2))),
        "referenceSamples": len(reference),
        "referenceRMS": float(np.sqrt(np.mean(reference ** 2))),
        "crossCorrelationLag": lag,
        "correlation": float(np.corrcoef(actual, expected)[0, 1]),
        "maxAbsoluteError": float(np.max(np.abs(actual - expected))),
    }, ensure_ascii=False))
