#!/usr/bin/env python3
"""比较保存的引擎 PCM 与独立重采样的音频。需要 numpy 和 scipy。"""

import argparse
import json
from pathlib import Path
import sys

import numpy as np
from scipy import signal
from scipy.io import wavfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("reference", type=Path)
parser.add_argument("directory", type=Path)
parser.add_argument("--check-normalization", action="store_true")
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

if args.check_normalization:
    paths = sorted(args.directory.glob("*-norm-0.f32"))
    if not paths:
        sys.exit("缺少归一化记录，请先创建 capture-normalization 标记并执行真实转录。")
    passed = True
    for path in paths:
        prefix = path.name.removesuffix("-norm-0.f32")
        first = np.fromfile(path, dtype="<f4")
        second = np.fromfile(args.directory / f"{prefix}-norm-1.f32", dtype="<f4")
        cpu = np.fromfile(args.directory / f"{prefix}-cpunorm-0.f32", dtype="<f4")
        finite = bool(np.isfinite(first).all() and np.isfinite(second).all() and np.isfinite(cpu).all())
        repeated_error = float(np.max(np.abs(first - second))) if finite else None
        cpu_error = float(np.max(np.abs(first - cpu))) if finite else None
        valid = finite and repeated_error <= 1e-4 and cpu_error <= 1e-4
        passed = passed and valid
        print(json.dumps({"normalization": prefix, "finite": finite,
                          "repeatMaximumAbsoluteError": repeated_error,
                          "cpuMaximumAbsoluteError": cpu_error, "passed": valid}))
    sys.exit(0 if passed else 1)
