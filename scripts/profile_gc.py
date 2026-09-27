#!/usr/bin/env python3
"""Profile collection phases with the boomkat_gcprofile target."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PHASE = re.compile(
    r"# GC_PHASE kind=(\w+) phase=(\w+) count=(\d+) "
    r"total_ms=([\d.]+) max_ms=([\d.]+) over_4ms=(\d+)"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "out/boomkat_gcprofile")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    binary = args.binary.resolve()
    workloads = {
        "scene_10000": ("bench_scene_churn.js",
                        "var SCENE_NODES_OVERRIDE=10000;\n"),
        "scene_100000_long": ("bench_scene_churn.js",
                             "var SCENE_NODES_OVERRIDE=100000; var SCENE_FRAMES_OVERRIDE=3000;\n"),
        "scene_300000_long": ("bench_scene_churn.js",
                             "var SCENE_NODES_OVERRIDE=300000; var SCENE_FRAMES_OVERRIDE=3000;\n"),
        "vdom_heavy": ("vdom_test.js",
                       "var VDOM_FRAMES_OVERRIDE=300; var VDOM_COMPONENTS_OVERRIDE=150; "
                       "var VDOM_LIST_SIZE_OVERRIDE=80; var VDOM_TIMING_OVERRIDE=true;\n"),
        "large_container": ("bench_gc_large_container.js", ""),
        "native_reentry": ("bench_gc_native_reentry.js", ""),
    }
    results = {}
    with tempfile.TemporaryDirectory(prefix="boomkat-gc-profile-") as directory:
        for name, (source, prefix) in workloads.items():
            path = Path(directory) / (name + ".js")
            path.write_text(prefix + (ROOT / "benchmarks" / source).read_text())
            runs = []
            for iteration in range(args.runs + 1):
                started = time.monotonic()
                # The profiling target uses the debug CLI, whose default is Script.
                process = subprocess.run([str(binary), str(path)], capture_output=True,
                                         text=True, check=True, timeout=120)
                elapsed = time.monotonic() - started
                phases = {
                    f"{kind}/{phase}": {
                        "count": int(count), "total_ms": float(total),
                        "max_ms": float(maximum), "over_4ms": int(over),
                    }
                    for kind, phase, count, total, maximum, over
                    in PHASE.findall(process.stderr)
                }
                if not phases:
                    raise RuntimeError("No GC phase records: build boomkat_gcprofile first")
                if iteration:
                    runs.append({"wall_seconds": elapsed, "phases": phases,
                                 "stdout": process.stdout, "stderr": process.stderr})
            summary = {
                key: {
                    "median_total_ms": statistics.median(r["phases"].get(key, {}).get("total_ms", 0) for r in runs),
                    "max_ms": max(r["phases"].get(key, {}).get("max_ms", 0) for r in runs),
                    "over_4ms": sum(r["phases"].get(key, {}).get("over_4ms", 0) for r in runs),
                } for key in sorted(set.union(*(set(r["phases"]) for r in runs)))
            }
            results[name] = {"runs": runs, "summary": summary}
            pauses = {key: value["max_ms"] for key, value in summary.items()
                      if key.endswith(("/slice", "/collection_pause", "/lazy_sweep_pause",
                                       "/blocking_collection", "/root_publication",
                                       "/string_table_maintenance"))}
            print(name, "pause maxima ms:", pauses, flush=True)
            args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
