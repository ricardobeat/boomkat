#!/usr/bin/env python3
"""Runs the legacy compiler with --compare-ast over files and tallies AST-COMPARE lines.

Usage: ast_compare.py [--jobs N] [--show N] [--log FILE] <dir-or-file>...
Scripts compile under `-c`; `.mjs`, test262 module files and `test/modules` fixtures add `-m`; `onlyStrict` test262
files get a "use strict" prefix. Each AST-COMPARE line is a disagreement between a legacy scan
and the flat AST's scope index.
"""
import argparse, os, re, subprocess, sys, tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ast_census import classify, gather, DEBUG_BIN, ROOT


known = Counter()


def check(path):
    is_module, only_strict, expect, raw = classify(path)
    is_module = is_module or "test/modules/" in os.path.relpath(path, ROOT)
    if expect == "reject":
        return path, [], False
    target, tmp = path, None
    if only_strict:
        fd, tmp = tempfile.mkstemp(suffix=".js")
        with os.fdopen(fd, "wb") as f:
            f.write(b'"use strict";\n' + raw)
        target = tmp
    try:
        args = [DEBUG_BIN, "--compare-ast", "-c"] + (["-m"] if is_module else []) + [target]
        try:
            r = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
        except subprocess.TimeoutExpired:
            return path, ["TIMEOUT"], True
        out = r.stderr.decode("utf-8", "replace").splitlines()
        known.update((l.split() + ["?", "?"])[1] for l in out if l.startswith("AST-KNOWN"))
        lines = [l for l in out if l.startswith("AST-COMPARE")]
        crashed = r.returncode not in (0, 1)
        return path, lines, crashed
    finally:
        if tmp:
            os.unlink(tmp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--show", type=int, default=30)
    ap.add_argument("--log")
    a = ap.parse_args()
    files = gather(a.paths)
    kinds = Counter()
    bad = []
    crashes = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for path, lines, crashed in ex.map(check, files):
            if crashed:
                crashes.append(path)
            if lines:
                bad.append((path, lines))
                for l in lines:
                    kinds[(l.split() + ["?", "?"])[1]] += 1
    if a.log:
        with open(a.log, "w") as f:
            for path, lines in bad:
                for l in lines:
                    f.write(f"{path}\t{l}\n")
    for path, lines in bad[: a.show]:
        print(os.path.relpath(path, ROOT))
        for l in lines[:3]:
            print("   ", l)
    print({"files": len(files), "with_disagreement": len(bad), "crashes": len(crashes), "by_kind": dict(kinds), "explained": dict(known)})
    return 1 if bad or crashes else 0


if __name__ == "__main__":
    sys.exit(main())
