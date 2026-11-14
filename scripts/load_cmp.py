#!/usr/bin/env python3
"""Compare load-only cost across engines.

Each library is wrapped in `if (false) { ... }`, so an engine reads, parses and
compiles it without running any of it. Times are best-of-N wall clock; "net"
subtracts the same engine's time on an empty file.

    python3 scripts/load_cmp.py [-n RUNS] [--bin NAME=PATH ...] [files...]
"""
import argparse, os, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
DEFAULT_FILES = ["lodash", "mathjs", "babel", "typescript"]


def engines(extra):
    found = {"boomkat": [os.path.join(ROOT, "out", "boomkat"), "--script"]}
    for spec in extra:
        name, path = spec.split("=", 1)
        found[name] = [path, "--script"]
    qjs, node = shutil.which("qjs"), shutil.which("node")
    if qjs: found["quickjs"] = [qjs, "--script"]
    jsc = shutil.which("jsc") or (JSC if os.path.exists(JSC) else None)
    if jsc: found["jsc"] = [jsc]
    if node: found["node"] = [node]
    return found


def timed(argv, path):
    start = time.perf_counter()
    run = subprocess.run(argv + [path], capture_output=True, timeout=300)
    elapsed = time.perf_counter() - start
    if run.returncode != 0:
        sys.exit(f"rc={run.returncode} {argv} {path}: {run.stderr[:200]!r}")
    return elapsed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", type=int, default=5, help="timed runs per engine and file")
    ap.add_argument("--bin", action="append", default=[], metavar="NAME=PATH",
                    help="another boomkat binary to compare")
    ap.add_argument("files", nargs="*", help="scripts to wrap (default: a libcorpus selection)")
    args = ap.parse_args()
    files = args.files or [os.path.join(ROOT, "test", "libcorpus", f"{n}.js") for n in DEFAULT_FILES]
    table = engines(args.bin)
    with tempfile.TemporaryDirectory() as tmp:
        empty = os.path.join(tmp, "empty.js")
        open(empty, "w").close()
        for src in files:
            wrapped = os.path.join(tmp, os.path.basename(src))
            with open(src, "rb") as f, open(wrapped, "wb") as out:
                out.write(b"if (false) {\n" + f.read() + b"\n}\n")
            best = dict.fromkeys(table, float("inf"))
            base = dict.fromkeys(table, float("inf"))
            for i in range(args.n + 1):  # the first round only warms the caches
                for name, argv in table.items():
                    load, idle = timed(argv, wrapped), timed(argv, empty)
                    if i:
                        best[name] = min(best[name], load)
                        base[name] = min(base[name], idle)
            cells = [f"{n} {1000 * best[n]:7.1f} ms (net {1000 * (best[n] - base[n]):6.1f})" for n in table]
            print(f"{os.path.basename(src):15} " + " | ".join(cells))


if __name__ == "__main__":
    main()
