#!/usr/bin/env python3
"""Fetch a corpus of unmodified real-world npm bundles into test/libcorpus
(gitignored -- optional vendoring, not checked in) and check that they load
under this engine, using out/qjs as the pass/fail oracle for each bundle.

    python3 scripts/verify_libraries.py              # fetch (if needed) + sweep
    python3 scripts/verify_libraries.py --fetch-only  # just populate the cache
    python3 scripts/verify_libraries.py --no-fetch     # sweep only, skip network
    python3 scripts/verify_libraries.py --lodash-api   # also run the lodash
                                                        # API-behavior checks
                                                        # (requires lodash.js
                                                        # to be present)

Background: plans/070-real-world-battle-testing.md. Each library is prefixed
with a minimal host shim and suffixed with `console.log("LOADED")`, then run
under both `out/duktape_c3` and `out/qjs`. A library that loads under qjs but
not under us is a real engine gap, not a bundle problem.
"""
import argparse
import os
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(ROOT, "test", "libcorpus")
WRAPPED = os.path.join(CACHE, "_wrapped")
ENGINE = os.path.join(ROOT, "out", "duktape_c3")
QJS = os.path.join(ROOT, "out", "qjs")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"

# name -> jsDelivr URL. Pinned where a specific version was verified; a bare
# `@latest`-style URL (no version) tracks upstream and may drift.
LIBS = {
    "lodash":      "https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js",
    "underscore":  "https://cdn.jsdelivr.net/npm/underscore@1.13.6/underscore-umd.js",
    "moment":      "https://cdn.jsdelivr.net/npm/moment/min/moment.min.js",
    "marked":      "https://cdn.jsdelivr.net/npm/marked@4.3.0/marked.min.js",
    "handlebars":  "https://cdn.jsdelivr.net/npm/handlebars@4.7.8/dist/handlebars.min.js",
    "immutable":   "https://cdn.jsdelivr.net/npm/immutable/dist/immutable.min.js",
    "acorn":       "https://cdn.jsdelivr.net/npm/acorn/dist/acorn.js",
    "bluebird":    "https://cdn.jsdelivr.net/npm/bluebird@3.7.2/js/browser/bluebird.min.js",
    "decimaljs":   "https://cdn.jsdelivr.net/npm/decimal.js/decimal.min.js",
    "bignumberjs": "https://cdn.jsdelivr.net/npm/bignumber.js/bignumber.min.js",
    "mathjs":      "https://cdn.jsdelivr.net/npm/mathjs/lib/browser/math.js",
    "jszip":       "https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js",
    "papaparse":   "https://cdn.jsdelivr.net/npm/papaparse/papaparse.min.js",
    "cryptojs":    "https://cdn.jsdelivr.net/npm/crypto-js/crypto-js.js",
    "protobufjs":  "https://cdn.jsdelivr.net/npm/protobufjs@7.4.0/dist/protobuf.min.js",
    "chance":      "https://cdn.jsdelivr.net/npm/chance/chance.min.js",
    "he":          "https://cdn.jsdelivr.net/npm/he/he.js",
    "nearley":     "https://cdn.jsdelivr.net/npm/nearley/lib/nearley.js",
    "d3array":     "https://cdn.jsdelivr.net/npm/d3-array/dist/d3-array.min.js",
    "uuid":        "https://cdn.jsdelivr.net/npm/uuid@8.3.2/dist/umd/uuidv4.min.js",
    "typescript":  "https://cdn.jsdelivr.net/npm/typescript@5.4.5/lib/typescript.js",
    "babel":       "https://cdn.jsdelivr.net/npm/@babel/standalone@7.24.7/babel.min.js",
}

SHIM = 'globalThis.window = globalThis.self = globalThis.global = globalThis;\n'
TAIL = '\nconsole.log("LOADED");\n'


def fetch(name, url, force=False):
    dest = os.path.join(CACHE, f"{name}.js")
    if os.path.exists(dest) and os.path.getsize(dest) > 0 and not force:
        return dest
    print(f"fetching {name} ...")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        data = urllib.request.urlopen(req, timeout=30).read()
    except Exception as e:
        print(f"  FAILED: {e}", file=sys.stderr)
        return None
    if data.lstrip().startswith(b"Couldn't find"):
        print(f"  FAILED: {data[:120]!r}", file=sys.stderr)
        return None
    os.makedirs(CACHE, exist_ok=True)
    with open(dest, "wb") as f:
        f.write(data)
    return dest


def wrap(src_path, name):
    os.makedirs(WRAPPED, exist_ok=True)
    dest = os.path.join(WRAPPED, f"{name}.js")
    with open(src_path, "rb") as f:
        body = f.read().decode("utf-8", "replace")
    with open(dest, "w") as f:
        f.write(SHIM + body + TAIL)
    return dest


def run_one(binary, path, timeout=30):
    try:
        p = subprocess.run([binary, path], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "(timeout)"
    out = (p.stdout or "") + (p.stderr or "")
    ok = any(line.strip() == "LOADED" for line in out.splitlines())
    err = "" if ok else (out.strip().splitlines()[-1][:80] if out.strip() else f"(exit {p.returncode}, no output)")
    return ok, err


def sweep(names):
    if not os.path.exists(ENGINE):
        print(f"missing {ENGINE} -- run `just build` first", file=sys.stderr)
        return 1
    have_qjs = os.path.exists(QJS)
    if not have_qjs:
        print("warning: out/qjs not found, skipping the differential oracle column", file=sys.stderr)

    rows = []
    for name in names:
        src = os.path.join(CACHE, f"{name}.js")
        if not os.path.exists(src):
            rows.append((name, "MISSING", "", ""))
            continue
        wrapped = wrap(src, name)
        c3_ok, c3_err = run_one(ENGINE, wrapped)
        qjs_ok, _ = run_one(QJS, wrapped) if have_qjs else (None, "")
        rows.append((name, "PASS" if c3_ok else "FAIL",
                     ("PASS" if qjs_ok else "FAIL") if have_qjs else "?", c3_err))

    print(f"{'library':<14} {'c3':<8} {'qjs':<8} error")
    print(f"{'-------':<14} {'--':<8} {'---':<8} -----")
    fails = 0
    for name, c3, qjs, err in rows:
        print(f"{name:<14} {c3:<8} {qjs:<8} {err}")
        if c3 != "PASS":
            fails += 1
    print()
    print(f"{len(rows) - fails}/{len(rows)} pass under duktape_c3")
    return 1 if fails else 0


def lodash_api_checks():
    """Run behavioral checks of lodash's actual API surface (not just load),
    comparing our engine's output against qjs on the same wrapped bundle plus
    a driver script. Requires test/libcorpus/lodash.js to be present -- this
    step is skipped, not failed, if it isn't (that's the "optional" in
    optional vendoring: the engine-level regression for the bug lodash found
    lives in test/engine/test_hoist_var_block_no_semicolon.js and needs no
    download).
    """
    src = os.path.join(CACHE, "lodash.js")
    if not os.path.exists(src):
        print("test/libcorpus/lodash.js not present -- skipping API checks "
              "(run with --fetch-only or without --no-fetch first)")
        return 0

    driver_path = os.path.join(HERE, "lodash_api_checks.js")
    wrapped = os.path.join(WRAPPED, "lodash_api_checks.js")
    os.makedirs(WRAPPED, exist_ok=True)
    with open(src, "rb") as f:
        lodash_src = f.read().decode("utf-8", "replace")
    with open(driver_path) as f:
        driver_src = f.read()
    with open(wrapped, "w") as f:
        f.write(SHIM + lodash_src + "\n" + driver_src)

    c3 = subprocess.run([ENGINE, wrapped], capture_output=True, text=True, timeout=30)
    print(c3.stdout, end="")
    if c3.stderr.strip():
        print(c3.stderr, file=sys.stderr, end="")

    if os.path.exists(QJS):
        qjs = subprocess.run([QJS, wrapped], capture_output=True, text=True, timeout=30)
        if qjs.stdout.strip() != c3.stdout.strip():
            print("MISMATCH vs qjs oracle:")
            print("  qjs:", qjs.stdout.strip().splitlines()[-1] if qjs.stdout.strip() else "(no output)")
            print("  c3: ", c3.stdout.strip().splitlines()[-1] if c3.stdout.strip() else "(no output)")
            return 1

    return 0 if c3.returncode == 0 and "FAILED" not in c3.stdout else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch-only", action="store_true", help="populate the cache, don't sweep")
    ap.add_argument("--no-fetch", action="store_true", help="sweep the cache as-is, no network")
    ap.add_argument("--force", action="store_true", help="re-fetch even if cached")
    ap.add_argument("--lodash-api", action="store_true", help="also run lodash API-behavior checks")
    ap.add_argument("names", nargs="*", help="only these libraries (default: all)")
    args = ap.parse_args()

    names = args.names or list(LIBS.keys())
    unknown = [n for n in names if n not in LIBS]
    if unknown:
        print(f"unknown librar{'y' if len(unknown)==1 else 'ies'}: {', '.join(unknown)}", file=sys.stderr)
        return 2

    if not args.no_fetch:
        for name in names:
            fetch(name, LIBS[name], force=args.force)

    if args.fetch_only:
        return 0

    rc = sweep(names)

    if args.lodash_api:
        rc = lodash_api_checks() or rc

    return rc


if __name__ == "__main__":
    sys.exit(main())
