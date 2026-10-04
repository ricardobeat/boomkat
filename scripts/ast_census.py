#!/usr/bin/env python3
"""Differential census of the flat-AST parser against the legacy compiler.

For each script file, runs `boomkat_debug --parse-only` (flat AST) and
`boomkat_debug -c` (legacy fused compile) and compares accept / reject.
Module files (`.mjs`, test262 `flags: [module]`) only run the AST parser.
For test262 files the metadata gives the expected verdict
(`negative: phase: parse` rejects), and `onlyStrict` tests parse with a
"use strict" prefix.

Usage: ast_census.py [--jobs N] [--log FILE] [--show N] <dir-or-file>...
Prints the disagreements between the two parsers, then a summary.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEBUG_BIN = os.path.join(ROOT, "out", "boomkat_debug")


def metadata(src):
    m = re.search(r"/\*---(.*?)---\*/", src, re.S)
    if not m:
        return None
    return m.group(1)


def classify(path):
    """Returns (is_module, only_strict, expect) where expect is None or 'accept'/'reject'."""
    with open(path, "rb") as f:
        raw = f.read()
    try:
        src = raw.decode("utf-8")
    except UnicodeDecodeError:
        src = raw.decode("latin-1")
    is_module = path.endswith(".mjs")
    only_strict = False
    expect = None
    meta = metadata(src)
    if meta is not None:
        fl = re.search(r"flags:\s*\[(.*?)\]", meta)
        flags = [x.strip() for x in fl.group(1).split(",")] if fl else []
        is_module = is_module or "module" in flags
        only_strict = "onlyStrict" in flags
        neg = re.search(r"negative:\s*\n(?:\s+\w+:.*\n)*?\s+phase:\s*(\w+)", meta)
        expect = "reject" if (neg and neg.group(1) == "parse") else "accept"
        if "raw" in flags:
            only_strict = False
    return is_module, only_strict, expect, raw


def run(args, timeout=20):
    try:
        r = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    err = r.stderr.decode("utf-8", "replace").strip()
    if r.returncode == 0:
        return "accept", ""
    if "SyntaxError" in err:
        return "reject", err
    return "crash", err[:200]


def check(path):
    is_module, only_strict, expect, raw = classify(path)
    target = path
    tmp = None
    if only_strict:
        fd, tmp = tempfile.mkstemp(suffix=".js")
        with os.fdopen(fd, "wb") as f:
            f.write(b'"use strict";\n' + raw)
        target = tmp
    try:
        ast_args = [DEBUG_BIN, "--parse-only"] + (["-m"] if is_module else []) + [target]
        ast_v, ast_err = run(ast_args)
        legacy_v, legacy_err = (None, "")
        if not is_module:
            legacy_v, legacy_err = run([DEBUG_BIN, "-c", target])
        return path, is_module, expect, ast_v, ast_err, legacy_v, legacy_err
    finally:
        if tmp:
            os.unlink(tmp)


def gather(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for d, dirs, files in os.walk(p):
                dirs.sort()
                for f in sorted(files):
                    if f.endswith((".js", ".mjs")) and "_FIXTURE" not in f:
                        out.append(os.path.join(d, f))
        else:
            out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--log")
    ap.add_argument("--show", type=int, default=40)
    a = ap.parse_args()

    files = gather(a.paths)
    stats = {"files": len(files), "ast_ok_expect": 0, "ast_bad_expect": 0, "agree": 0, "disagree": 0, "crash": 0}
    disagree = []
    expect_bad = []
    crashes = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for path, is_module, expect, av, ae, lv, le in ex.map(check, files):
            if av in ("crash", "timeout"):
                stats["crash"] += 1
                crashes.append((path, av, ae))
            if lv is not None:
                if av == lv:
                    stats["agree"] += 1
                else:
                    stats["disagree"] += 1
                    disagree.append((path, av, lv, ae, le))
            if expect is not None:
                if av == expect:
                    stats["ast_ok_expect"] += 1
                else:
                    stats["ast_bad_expect"] += 1
                    expect_bad.append((path, av, expect, ae))
    if a.log:
        with open(a.log, "w") as f:
            for path, av, lv, ae, le in disagree:
                f.write(f"DISAGREE\t{path}\tast={av}\tlegacy={lv}\t{ae or le}\n")
            for path, av, ex_, ae in expect_bad:
                f.write(f"EXPECT\t{path}\tast={av}\texpected={ex_}\t{ae}\n")
            for path, av, ae in crashes:
                f.write(f"CRASH\t{path}\t{av}\t{ae}\n")
    for path, av, lv, ae, le in disagree[: a.show]:
        print(f"DISAGREE {os.path.relpath(path, ROOT)} ast={av} legacy={lv}  {ae or le}")
    for path, av, ex_, ae in expect_bad[: a.show]:
        print(f"EXPECT   {os.path.relpath(path, ROOT)} ast={av} expected={ex_}  {ae}")
    for path, av, ae in crashes[: a.show]:
        print(f"CRASH    {os.path.relpath(path, ROOT)} {av} {ae}")
    print(stats)
    return 1 if (disagree or crashes) else 0


if __name__ == "__main__":
    sys.exit(main())
