#!/usr/bin/env python3
"""Run the VDOM workload in alternating Boomkat and QuickJS pairs."""

import argparse
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TIMING = re.compile(r"^vdom_churn: total=(\d+)ms worst_frame=(\d+)ms$", re.MULTILINE)


def positive_int(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def run(binary, flags, source):
    start = time.perf_counter()
    result = subprocess.run(
        [str(binary), *flags, str(source)], capture_output=True, text=True, timeout=120
    )
    elapsed = time.perf_counter() - start
    if result.returncode:
        raise RuntimeError(f"{binary} exited {result.returncode}:\n{result.stderr}\n{result.stdout}")
    timing = TIMING.search(result.stdout)
    if timing is None:
        raise RuntimeError(f"{binary} did not print VDOM frame timing:\n{result.stdout}")
    checksum = TIMING.sub("vdom_churn: <timing>", result.stdout)
    return elapsed, int(timing[2]), checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=positive_int, default=3)
    parser.add_argument("--frames", type=positive_int, default=300)
    parser.add_argument("--components", type=positive_int, default=150)
    parser.add_argument("--list-size", type=positive_int, default=80)
    args = parser.parse_args()

    boomkat = ROOT / "out/boomkat"
    quickjs = ROOT / "out/qjs"
    for binary in (boomkat, quickjs):
        if not binary.is_file():
            parser.error(f"{binary} is missing; build the engine first")

    prefix = (
        f"var VDOM_FRAMES_OVERRIDE={args.frames}; "
        f"var VDOM_COMPONENTS_OVERRIDE={args.components}; "
        f"var VDOM_LIST_SIZE_OVERRIDE={args.list_size}; "
        "var VDOM_TIMING_OVERRIDE=true;\n"
    )
    with tempfile.TemporaryDirectory(prefix="boomkat-vdom-") as directory:
        source = Path(directory) / "vdom.js"
        source.write_text(prefix + (ROOT / "benchmarks/vdom_test.js").read_text())
        engines = (("Boomkat", boomkat, ("--script",)), ("QuickJS", quickjs, ()))
        times = {name: [] for name, _, _ in engines}
        worst_frames = {name: [] for name, _, _ in engines}
        expected = None
        for pair in range(-1, args.runs):
            order = engines if pair % 2 == 0 else engines[::-1]
            for name, binary, flags in order:
                elapsed, worst, checksum = run(binary, flags, source)
                if expected is None:
                    expected = checksum
                elif checksum != expected:
                    raise RuntimeError(f"{name} output differs from the other VDOM runs")
                if pair >= 0:
                    times[name].append(elapsed)
                    worst_frames[name].append(worst)

    bk = statistics.median(times["Boomkat"])
    qjs = statistics.median(times["QuickJS"])
    print(f"VDOM: {args.frames} frames, {args.components} components, {args.list_size} items/list")
    print(f"Wall time, median of {args.runs} alternating runs (includes startup and compilation):")
    print(f"  Boomkat {bk:.3f}s  QuickJS {qjs:.3f}s  ratio {bk / qjs:.2f}x")
    print("Worst frame, median of each run's maximum:")
    print(
        f"  Boomkat {statistics.median(worst_frames['Boomkat']):g}ms  "
        f"QuickJS {statistics.median(worst_frames['QuickJS']):g}ms"
    )


if __name__ == "__main__":
    main()
