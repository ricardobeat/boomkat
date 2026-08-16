#!/usr/bin/env python3
"""Fetch unmodified TypeScript library sources into test/tscorpus (gitignored)
and check that they RUN under this engine's ts_mode, using node's native type
stripping as the oracle: the driver under each library must produce identical
stdout under `node` and `out/duktape_c3`.

    python3 scripts/verify_ts_libraries.py              # fetch (if needed) + sweep
    python3 scripts/verify_ts_libraries.py --fetch-only  # just populate the cache
    python3 scripts/verify_ts_libraries.py --no-fetch    # sweep only, skip network

Companion to scripts/verify_libraries.py (plan 070's compiled-bundle sweep):
that one loads prebuilt JS bundles; this one executes the .ts sources real
projects ship, with driver scripts in scripts/ts_runtime_checks/ asserting
observable behavior (store updates, proxy notifications, diff output).

Two sources are single self-contained files (microdiff, zustand vanilla).
valtio imports 'proxy-compare', so that dependency is vendored beside it and
the import specifier rewritten to the local file; the rewrite is recorded in
the table below so the transform stays auditable.
"""
import argparse
import difflib
import os
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(ROOT, "test", "tscorpus")
ENGINE = os.path.join(ROOT, "out", "duktape_c3")
CHECKS_DIR = os.path.join(HERE, "ts_runtime_checks")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"

# name -> (source files as (dest_name, url) pairs, post-fetch (find, replace) rewrites)
LIBS = {
    "microdiff": {
        "files": {"microdiff.ts": "https://cdn.jsdelivr.net/gh/AsyncBanana/microdiff@v1.4.0/index.ts"},
        "rewrites": [],
    },
    "zustand": {
        "files": {"zustand_vanilla.ts": "https://cdn.jsdelivr.net/gh/pmndrs/zustand@v5.0.3/src/vanilla.ts"},
        "rewrites": [],
    },
    "valtio": {
        "files": {
            "valtio_vanilla.ts": "https://cdn.jsdelivr.net/gh/pmndrs/valtio@v2.1.3/src/vanilla.ts",
            "proxy_compare.ts": "https://cdn.jsdelivr.net/gh/dai-shi/proxy-compare@v3.0.1/src/index.ts",
        },
        # valtio's source imports the 'proxy-compare' package by bare specifier;
        # rewrite it to the vendored file so no package resolution is involved.
        "rewrites": [
            ("valtio_vanilla.ts", "from 'proxy-compare'", "from './proxy_compare.ts'"),
        ],
    },
}


def fetch(name, dest_name, url, force=False):
    dest = os.path.join(CACHE, dest_name)
    if os.path.exists(dest) and os.path.getsize(dest) > 0 and not force:
        return dest
    print(f"fetching {name}/{dest_name} ...")
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


def run(binary, driver_path, cwd):
    try:
        r = subprocess.run([binary, driver_path], cwd=cwd, capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "TIMEOUT"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch-only", action="store_true")
    ap.add_argument("--no-fetch", action="store_true")
    ap.add_argument("--lib", help="only sweep this library")
    args = ap.parse_args()

    if not args.no_fetch:
        for name, spec in LIBS.items():
            for dest_name, url in spec["files"].items():
                fetch(name, dest_name, url)
        for name, spec in LIBS.items():
            for dest_name, find, repl in spec.get("rewrites", []):
                path = os.path.join(CACHE, dest_name)
                if not os.path.exists(path):
                    continue
                with open(path, "r") as f:
                    body = f.read()
                if find in body:
                    with open(path, "w") as f:
                        f.write(body.replace(find, repl))

    if args.fetch_only:
        return 0

    if not shutil.which("node"):
        print("ERROR: node is not on PATH; it is the runtime oracle for this sweep", file=sys.stderr)
        return 1

    libs = {args.lib: LIBS[args.lib]} if args.lib else LIBS
    passed = failed = 0
    for name in libs:
        driver = os.path.join(CHECKS_DIR, f"{name}.ts")
        if not os.path.exists(driver):
            print(f"SKIP: no driver for {name}")
            continue
        missing = [f for f in LIBS[name]["files"] if not os.path.exists(os.path.join(CACHE, f))]
        if missing:
            print(f"SKIP: {name} sources not fetched ({', '.join(missing)})")
            continue
        # Copy the driver beside the fetched sources so its relative imports resolve.
        driver_in_cache = os.path.join(CACHE, f"_driver_{name}.ts")
        with open(driver, "rb") as f:
            body = f.read().decode("utf-8")
        with open(driver_in_cache, "w") as f:
            f.write(body)
        n_rc, n_out, _ = run("node", driver_in_cache, CACHE)
        e_rc, e_out, e_err = run(os.path.abspath(ENGINE), driver_in_cache, CACHE)
        if n_rc != 0:
            print(f"SKIP: node oracle rejected {name} (rc={n_rc})")
            continue
        if e_rc != 0 or e_out != n_out:
            failed += 1
            print(f"FAIL: {name}")
            print(f"  engine rc={e_rc}")
            for line in (e_err or "").splitlines()[:4]:
                print(f"    | {line}")
            if e_out != n_out:
                for line in list(difflib.unified_diff(n_out.splitlines(), e_out.splitlines(), "node", "engine"))[:10]:
                    print(f"    | {line}")
        else:
            passed += 1
            print(f"ok:   {name}")

    print(f"\n{passed} pass, {failed} fail ({passed + failed} total)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
