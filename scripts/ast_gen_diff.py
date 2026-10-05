#!/usr/bin/env python3
"""Compare canonical function dumps against the compiler in AST_LEGACY_BIN.

Defaults to test/*.js. Directories expand recursively; --sample N --seed S selects
a deterministic sample. --log saves complete diffs, including source lines,
register counts, constants and captures. Exits nonzero on any difference or timeout.
"""
import argparse
from collections import Counter
from contextlib import nullcontext
from concurrent.futures import ThreadPoolExecutor
import difflib
import glob
import hashlib
import os
import random
import re
import subprocess
import tempfile

from ast_census import classify, gather, DEBUG_BIN, LEGACY_BIN, LEGACY_MODE, ROOT

DUMP_DIR = None


def check(path):
    module, strict, _, raw = classify(path)
    module = module or "test/modules/" in os.path.relpath(path, ROOT)
    with tempfile.TemporaryDirectory(prefix="ast-gen-diff-") as tmp:
        target = path
        if strict:
            target = os.path.join(tmp, "strict.js")
            with open(target, "wb") as source:
                source.write(b'"use strict";\n' + raw)
        results = []
        for binary, mode in ((LEGACY_BIN, LEGACY_MODE), (DEBUG_BIN, "--trace-ast-gen")):
            args = [binary, mode, "--dump-code"] + (["-m"] if module else []) + [target]
            try:
                result = subprocess.run(args, capture_output=True, timeout=30)
            except subprocess.TimeoutExpired:
                return path, "error", 0, Counter(), f"TIMEOUT {path}: {binary}\n"
            results.append(result)
    legacy, ast = results
    trace = ast.stderr.decode("utf-8", "replace").splitlines()
    generated = sum(line.startswith("AST-GEN function ") for line in trace)
    skips = Counter(line.removeprefix("AST-GEN-SKIP ") for line in trace if line.startswith("AST-GEN-SKIP "))
    if legacy.returncode == 0:
        skips.update("program: " + line.removeprefix("AST-GEN-FALLBACK ") for line in trace if line.startswith("AST-GEN-FALLBACK "))
    old = legacy.stdout.decode("utf-8", "replace")
    new = ast.stdout.decode("utf-8", "replace")
    old_err = "".join(line + "\n" for line in legacy.stderr.decode("utf-8", "replace").splitlines() if not line.startswith("AST-GEN"))
    new_err = "".join(line + "\n" for line in trace if not line.startswith("AST-GEN"))
    status = "same"
    if legacy.returncode not in (0, 1) or ast.returncode not in (0, 1):
        status = "error"
    elif (old, old_err, legacy.returncode) != (new, new_err, ast.returncode):
        status = "lines" if (re.sub(r" L\d+ ", " L ", old), old_err, legacy.returncode) == (
            re.sub(r" L\d+ ", " L ", new), new_err, ast.returncode
        ) else "diff"
    diff = ""
    if status != "same":
        diff = f"{path}: legacy exit={legacy.returncode}, AST exit={ast.returncode}\n"
        old_lines, new_lines = (old + old_err).splitlines(True), (new + new_err).splitlines(True)
        if status == "lines":
            diff += "".join("-" + old + "+" + new for old, new in zip(old_lines, new_lines) if old != new)
        elif max(len(old_lines), len(new_lines)) > 5000:
            # SequenceMatcher is quadratic on large, repetitive disassemblies.
            # Preserve both complete dumps for review without aligning those lines.
            if DUMP_DIR:
                name = hashlib.sha256(os.fsencode(path)).hexdigest()[:16]
                for suffix, contents in (("legacy", old + old_err), ("ast", new + new_err)):
                    saved = os.path.join(DUMP_DIR, name + "." + suffix)
                    with open(saved, "w") as dump: dump.write(contents)
                    diff += saved + "\n"
            else:
                diff += "large dump differs; use --log to save both versions\n"
        else:
            diff += "".join(difflib.unified_diff(old_lines, new_lines, fromfile="legacy", tofile="AST"))
    return path, status, generated, skips, diff


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--sample", type=int)
    parser.add_argument("--seed", type=int, default=101)
    parser.add_argument("--log")
    parser.add_argument("--show", type=int, default=10)
    args = parser.parse_args()
    if not LEGACY_BIN:
        parser.error("set AST_LEGACY_BIN to a saved comparison compiler")
    global DUMP_DIR
    if args.log:
        DUMP_DIR = args.log + ".dumps"
        os.makedirs(DUMP_DIR, exist_ok=True)
    files = sorted(set(gather(args.paths or glob.glob(os.path.join(ROOT, "test", "*.js")))))
    if args.sample is not None:
        files = random.Random(args.seed).sample(files, min(args.sample, len(files)))
    stats, skips = Counter(), Counter()
    generated, differences = 0, 0
    with (open(args.log, "w") if args.log else nullcontext(None)) as log, ThreadPoolExecutor(args.jobs) as workers:
        for path, status, count, reasons, diff in workers.map(check, files):
            stats[status] += 1
            generated += count
            skips.update(reasons)
            if status != "same":
                if differences < args.show:
                    print(status.upper(), path)
                differences += 1
                if log is not None: log.write(diff)
    print(f"files={len(files)} identical={stats['same']} lines_only={stats['lines']} "
          f"diff={stats['diff']} errors={stats['error']} generated_functions={generated}")
    for reason, count in skips.most_common(args.show):
        print(f"SKIP {count:6d} {reason}")
    return int(len(files) == 0 or differences != 0)


if __name__ == "__main__":
    raise SystemExit(main())
