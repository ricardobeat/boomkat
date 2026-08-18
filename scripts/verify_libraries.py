#!/usr/bin/env python3
"""Fetch a corpus of unmodified real-world npm bundles into test/libcorpus
(gitignored -- optional vendoring, not checked in) and check that they load
under this engine, using out/qjs as the pass/fail oracle for each bundle.

    python3 scripts/verify_libraries.py                 # fetch (if needed) + sweep
    python3 scripts/verify_libraries.py --fetch-only     # just populate the cache
    python3 scripts/verify_libraries.py --no-fetch        # sweep only, skip network
    python3 scripts/verify_libraries.py --api-checks       # also run each library's
                                                            # API-behavior driver from
                                                            # scripts/lib_api_checks/,
                                                            # diffed against qjs
    python3 scripts/verify_libraries.py --api-checks lodash  # just one library's checks

Background: plans/070-real-world-battle-testing.md. Each library is prefixed
with a minimal host shim and suffixed with `console.log("LOADED")`, then run
under both `out/boomkat` and `out/qjs`. A library that loads under qjs but
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
ENGINE = os.path.join(ROOT, "out", "boomkat")
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
CJS_SHIM = 'var module = { exports: {} }; var exports = module.exports;\n'
# babel's browser global exposes its whole API through lazy getters installed
# by its own UMD wrapper (get transform(){...}), not through module.exports,
# so its driver reads the plain `Babel` global instead -- see
# scripts/lib_api_checks/babel.js.
NO_CJS_SHIM = {"babel"}
API_CHECKS_DIR = os.path.join(HERE, "lib_api_checks")


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
    print(f"{len(rows) - fails}/{len(rows)} pass under boomkat")
    return 1 if fails else 0


def api_check_one(name, timeout=30):
    """Run one library's behavioral API driver (scripts/lib_api_checks/<name>.js)
    against its cached bundle, diffed against qjs on the identical script.
    Returns (status, detail) where status is PASS / FAIL / SKIP.

    A driver's absence isn't a failure (that's the "optional" in optional
    vendoring): the engine-level regression test for a bug found this way
    lives under test/engine/ and needs no download. A missing bundle is the
    same -- run --fetch-only or drop --no-fetch first.
    """
    driver_path = os.path.join(API_CHECKS_DIR, f"{name}.js")
    if not os.path.exists(driver_path):
        return "SKIP", "no driver"
    src = os.path.join(CACHE, f"{name}.js")
    if not os.path.exists(src):
        return "SKIP", "bundle not cached"

    with open(src, "rb") as f:
        bundle_src = f.read().decode("utf-8", "replace")
    with open(driver_path) as f:
        driver_src = f.read()

    os.makedirs(WRAPPED, exist_ok=True)
    wrapped = os.path.join(WRAPPED, f"{name}_api.js")
    cjs_shim = "" if name in NO_CJS_SHIM else CJS_SHIM
    with open(wrapped, "w") as f:
        f.write(SHIM + cjs_shim + bundle_src + "\n" + driver_src)

    try:
        c3 = subprocess.run([ENGINE, wrapped], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "FAIL", "(timeout)"

    if not os.path.exists(QJS):
        ok = c3.returncode == 0 and "threw" in c3.stdout and "0 threw" in c3.stdout
        return ("PASS" if ok else "FAIL"), (c3.stdout.strip().splitlines()[-1] if c3.stdout.strip() else "(no output)")

    try:
        qjs = subprocess.run([QJS, wrapped], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        qjs = None

    c3_last = c3.stdout.strip().splitlines()[-1] if c3.stdout.strip() else "(no output)"
    if qjs is not None and qjs.stdout.strip() == c3.stdout.strip():
        return "PASS", c3_last
    qjs_last = (qjs.stdout.strip().splitlines()[-1] if qjs and qjs.stdout.strip() else "(no output/timeout)")
    return "FAIL", f"ours=[{c3_last}] qjs=[{qjs_last}]"


def api_checks(names):
    available = [n for n in names if os.path.exists(os.path.join(API_CHECKS_DIR, f"{n}.js"))]
    if not available:
        print("no API-check drivers found for the requested librar" +
              ("y" if len(names) == 1 else "ies"))
        return 0

    print()
    print(f"{'library':<14} {'result':<8} detail")
    print(f"{'-------':<14} {'------':<8} ------")
    fails = 0
    ran = 0
    for name in available:
        status, detail = api_check_one(name)
        if status == "SKIP":
            continue
        ran += 1
        print(f"{name:<14} {status:<8} {detail[:100]}")
        if status != "PASS":
            fails += 1
    if ran == 0:
        print("(nothing to run -- bundles not cached; try without --no-fetch)")
        return 0
    print()
    print(f"{ran - fails}/{ran} API-check drivers match qjs")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch-only", action="store_true", help="populate the cache, don't sweep")
    ap.add_argument("--no-fetch", action="store_true", help="sweep the cache as-is, no network")
    ap.add_argument("--force", action="store_true", help="re-fetch even if cached")
    ap.add_argument("--api-checks", action="store_true", help="also run each library's API-behavior driver, diffed against qjs")
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

    if args.api_checks:
        rc = api_checks(names) or rc

    return rc


if __name__ == "__main__":
    sys.exit(main())
