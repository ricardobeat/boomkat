#!/usr/bin/env python3
"""Compare the retained scene workloads with QuickJS in alternating pairs."""

import argparse
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TIMING = re.compile(
    r"^scene_churn: nodes=(\d+) frames=(\d+) total=(\d+)ms worst_frame=(\d+)ms$",
    re.MULTILINE,
)
WORKLOADS = ((10_000, 300), (100_000, 3_000))


def positive_int(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def run(binary, flags, source, nodes, frames):
    start = time.perf_counter()
    result = subprocess.run(
        [str(binary), *flags, str(source)], capture_output=True, text=True, timeout=30
    )
    elapsed = time.perf_counter() - start
    if result.returncode or "FAIL" in result.stdout:
        raise RuntimeError(f"{binary} failed:\n{result.stderr}\n{result.stdout}")
    timing = TIMING.search(result.stdout)
    if timing is None or (int(timing[1]), int(timing[2])) != (nodes, frames):
        raise RuntimeError(f"{binary} printed unexpected scene timing:\n{result.stdout}")
    checksum = TIMING.sub("scene_churn: <timing>", result.stdout)
    return elapsed, int(timing[4]), checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=positive_int, default=2)
    args = parser.parse_args()

    boomkat = ROOT / "out/boomkat"
    quickjs = ROOT / "out/qjs"
    for binary in (boomkat, quickjs):
        if not binary.is_file():
            parser.error(f"{binary} is missing; build the engine first")

    engines = (("Boomkat", boomkat, ("--script",)), ("QuickJS", quickjs, ()))
    benchmark = (ROOT / "benchmarks/bench_scene_churn.js").read_text()
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="boomkat-vdom-") as directory:
        for nodes, frames in WORKLOADS:
            source = Path(directory) / f"scene_{nodes}.js"
            source.write_text(
                f"var SCENE_NODES_OVERRIDE={nodes}; var SCENE_FRAMES_OVERRIDE={frames};\n"
                + benchmark
            )
            times = {name: [] for name, _, _ in engines}
            worst_frames = {name: [] for name, _, _ in engines}
            expected = None
            for pair in range(args.runs):
                order = engines if pair % 2 == 0 else engines[::-1]
                for name, binary, flags in order:
                    elapsed, worst, checksum = run(binary, flags, source, nodes, frames)
                    if expected is None:
                        expected = checksum
                    elif checksum != expected:
                        raise RuntimeError(f"{name} output differs from the other scene runs")
                    times[name].append(elapsed)
                    worst_frames[name].append(worst)

            bk = statistics.median(times["Boomkat"])
            qjs = statistics.median(times["QuickJS"])
            print(f"Scene: {nodes:,} nodes, {frames:,} frames")
            print(
                f"  Wall median ({args.runs} runs): Boomkat {bk:.3f}s, "
                f"QuickJS {qjs:.3f}s, ratio {bk / qjs:.2f}x"
            )
            print(
                f"  Worst frame median: Boomkat {statistics.median(worst_frames['Boomkat']):g}ms, "
                f"QuickJS {statistics.median(worst_frames['QuickJS']):g}ms",
                flush=True,
            )
    print(f"Suite wall time: {time.perf_counter() - started:.2f}s")


if __name__ == "__main__":
    main()
