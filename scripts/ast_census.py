#!/usr/bin/env python3
"""Differential census of the flat-AST parser against the legacy compiler.

Runs `boomkat_debug --parse-only` against test262 metadata. Set AST_LEGACY_BIN
to compare acceptance with a saved compiler. AST_LEGACY_MODE selects its mode.
Metadata mismatches excluded by the suite skip list remain in the tally.
Module files use the Module goal on both paths.
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

from run_test262 import skip_reason

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEBUG_BIN = os.environ.get("AST_DEBUG_BIN", os.path.join(ROOT, "out", "boomkat_debug"))
LEGACY_BIN = os.environ.get("AST_LEGACY_BIN")
LEGACY_MODE = os.environ.get("AST_LEGACY_MODE", "--no-ast-gen")


# Exact corpus cases: broad path rules would hide unrelated parser regressions.
KNOWN_ACCEPTS = {
    **{f"language/comments/hashbang/{name}.js": "hashbang" for name in (
        "line-terminator-carriage-return", "line-terminator-line-separator",
        "line-terminator-paragraph-separator", "module", "not-empty", "use-strict")},
    "language/expressions/class/elements/field-definition-accessor-no-line-terminator.js": "accessor-identifier-asi",
    "language/statements/class/elements/field-definition-accessor-no-line-terminator.js": "accessor-identifier-asi",
    "staging/decorators/accessor-as-identifier.js": "accessor-identifier-asi",
    **{f"language/statements/using/syntax/{name}.js": "using-identifier" for name in (
        "using-declaring-let-split-across-two-lines", "using-for-using-of-of",
        "using-invalid-arraybindingpattern-does-not-break-element-access")},
    "test/ast_functions_control.js": "regexp-in-template",
    "test/ast_patterns.js": "await-pattern-default",
}
KNOWN_REJECTS = {
    "language/import/dup-bound-names.js": "duplicate-import-binding",
    **{f"language/module-code/{name}.js": "module-html-comment" for name in (
        "comment-multi-line-html-close", "comment-single-line-html-close", "comment-single-line-html-open")},
}


def known_difference(path, ast, legacy):
    path = path.replace(os.sep, "/")
    key = path.split("test262/test/", 1)[-1] if "test262/test/" in path else os.path.relpath(path, ROOT)
    if (ast, legacy) == ("accept", "reject"):
        return KNOWN_ACCEPTS.get(key, "")
    if (ast, legacy) == ("reject", "accept"):
        return KNOWN_REJECTS.get(key, "")
    return ""


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
    is_module = path.endswith(".mjs") or "test/modules/" in os.path.relpath(path, ROOT)
    only_strict = False
    expect = None
    meta = metadata(src)
    if meta is not None:
        fl = re.search(r"flags:\s*\[(.*?)\]", meta)
        flags = [x.strip() for x in fl.group(1).split(",")] if fl else []
        if not fl:
            block = re.search(r"^flags:\s*\n((?:[ \t]+-[^\n]*\n)+)", meta, re.M)
            if block:
                flags = re.findall(r"-[ \t]+(\w+)", block.group(1))
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
        legacy_v, legacy_err = run([LEGACY_BIN, LEGACY_MODE, "--check"] + (["-m"] if is_module else []) + [target]) if LEGACY_BIN else (None, "")
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
    stats = {"files": len(files), "ast_ok_expect": 0, "ast_bad_expect": 0, "agree": 0, "disagree": 0, "crash": 0, "known": 0, "expect_skipped": 0}
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
                    reason = known_difference(path, av, lv)
                    if reason:
                        stats["known"] += 1
                    disagree.append((path, av, lv, ae, le))
            if expect is not None:
                if av == expect:
                    stats["ast_ok_expect"] += 1
                else:
                    stats["ast_bad_expect"] += 1
                    expect_bad.append((path, av, expect, ae))
                    if "test262/test/" in path and skip_reason(path):
                        stats["expect_skipped"] += 1
    if a.log:
        with open(a.log, "w") as f:
            for path, av, lv, ae, le in disagree:
                f.write(f"{'AST-KNOWN ' + known_difference(path, av, lv) if known_difference(path, av, lv) else 'DISAGREE'}\t{path}\tast={av}\tlegacy={lv}\t{ae or le}\n")
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
    return int(stats["disagree"] != stats["known"] or bool(crashes) or stats["ast_bad_expect"] != stats["expect_skipped"])


if __name__ == "__main__":
    sys.exit(main())
