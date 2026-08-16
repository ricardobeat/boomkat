#!/usr/bin/env python3
"""Fetch unmodified TypeScript library sources into test/tscorpus (gitignored)
and validate that they RUN under this engine's ts_mode, using a transpile
oracle: `tsc` strips each .ts to .js (the same binary that is the
ts-conformance corpus's oracle), and the driver must produce identical stdout
when run as .ts (engine ts_mode) and as the stripped .js (plain module). A
divergence isolates a ts_mode erasure bug; no second engine runs the corpus.

    python3 scripts/verify_ts_libraries.py              # fetch (if needed) + sweep
    python3 scripts/verify_ts_libraries.py --fetch-only  # just populate the cache
    python3 scripts/verify_ts_libraries.py --no-fetch    # sweep only, skip network
    python3 scripts/verify_ts_libraries.py --lib valtio  # one library

Sources are fetched UNMODIFIED and laid out so their own import specifiers
resolve as written: valtio's bare 'proxy-compare' import is satisfied by
vendoring that package at node_modules/proxy-compare/index.ts (the engine's
node_modules resolution), and jotai keeps its src/vanilla/ directory shape.
The transpiled mirrors land in test/tscorpus/_transpiled/ with .ts import
specifiers mechanically rewritten to .js in the EMITTED files only.

An engine-side transpiler was tried first (ts.transpileModule via
typescript.js running on this engine, the api-check path) and is blocked by
a pre-existing miscompile: typescript.js's emit pipeline crashes with
"undefined is not a function" (substituteNode resolves undefined in
getPipelinePhase) on inputs as small as `const q = 1; q.foo;`. Reproducible
with --no-optimize and on older binaries; tracked for its own session.
"""
import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(ROOT, "test", "tscorpus")
TRANSPILED = os.path.join(CACHE, "_transpiled")
ENGINE = os.path.join(ROOT, "out", "duktape_c3")
CHECKS_DIR = os.path.join(HERE, "ts_runtime_checks")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"

# name -> driver + the source files it needs, as {dest: url} pairs. Layout is
# the package's own, so intra-package specifiers resolve unmodified.
LIBS = {
    "microdiff": {
        "driver": "microdiff.ts",
        "files": {"microdiff.ts": "https://cdn.jsdelivr.net/gh/AsyncBanana/microdiff@v1.4.0/index.ts"},
    },
    "zustand": {
        "driver": "zustand.ts",
        "files": {"zustand_vanilla.ts": "https://cdn.jsdelivr.net/gh/pmndrs/zustand@v5.0.3/src/vanilla.ts"},
    },
    "valtio": {
        "driver": "valtio.ts",
        "files": {
            "valtio_vanilla.ts": "https://cdn.jsdelivr.net/gh/pmndrs/valtio@v2.1.3/src/vanilla.ts",
            "node_modules/proxy-compare/index.ts": "https://cdn.jsdelivr.net/gh/dai-shi/proxy-compare@v3.0.1/src/index.ts",
        },
    },
    "signalscore": {
        "driver": "signalscore.ts",
        "files": {"signals_core.ts": "https://cdn.jsdelivr.net/gh/preactjs/signals@%40preact%2Fsignals-core%401.14.4/packages/core/src/index.ts"},
    },
    "jotai": {
        "driver": "jotai.ts",
        "files": {
            f"jotai/src/vanilla/{part}": f"https://cdn.jsdelivr.net/gh/pmndrs/jotai@v2.20.2/src/vanilla/{part}"
            for part in ("atom.ts", "store.ts", "typeUtils.ts", "internals.ts")
        },
    },
}


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return True
    print(f"fetching {os.path.relpath(dest, ROOT)} ...")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        data = urllib.request.urlopen(req, timeout=30).read()
    except Exception as e:
        print(f"  FAILED: {e}", file=sys.stderr)
        return False
    if data.lstrip().startswith(b"Couldn't find"):
        print(f"  FAILED: {data[:120]!r}", file=sys.stderr)
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as f:
        f.write(data)
    return True


def run(binary, driver_path, cwd):
    try:
        r = subprocess.run([binary, driver_path], cwd=cwd, capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "TIMEOUT"


SPEC_RE = re.compile(r"((?:\bfrom|\bimport|\bexport)\s*\(?\s*)(['\"])([^'\"]+)\.ts\2")


def strip_with_tsc(rel_files):
    """Run tsc over the given cache-relative files, emitting .js mirrors under
    _transpiled/ that keep the same relative layout. Returns True on success."""
    if shutil.which("tsc") is None:
        print("ERROR: tsc is not on PATH; it is the transpile oracle for this sweep", file=sys.stderr)
        return False
    if os.path.isdir(TRANSPILED):
        shutil.rmtree(TRANSPILED)
    r = subprocess.run(
        ["tsc", "--target", "es2022", "--module", "esnext", "--skipLibCheck",
         "--outDir", TRANSPILED, *rel_files],
        cwd=CACHE, capture_output=True, text=True, timeout=300,
    )
    if not os.path.isdir(TRANSPILED):
        print(f"ERROR: tsc produced no output (rc={r.returncode})")
        for line in r.stderr.splitlines()[:4]:
            print(f"  | {line}")
        return False
    # Type errors do not block emit; only missing files do.
    for rel in rel_files:
        js = os.path.join(TRANSPILED, rel[:-3] + ".js")
        if not os.path.exists(js):
            print(f"ERROR: tsc did not emit {rel}")
            return False
    for root, _dirs, names in os.walk(TRANSPILED):
        for n in names:
            if not n.endswith(".js"):
                continue
            p = os.path.join(root, n)
            with open(p) as f:
                body = f.read()
            # The emitted module keeps .ts specifiers; point them at the
            # transpiled mirrors. Extensionless specifiers resolve via the
            # engine's probe (only .js files exist under _transpiled).
            body = SPEC_RE.sub(lambda m: m.group(1) + m.group(2) + m.group(3) + ".js" + m.group(2), body)
            body = drop_undeclared_export_names(body)
            with open(p, "w") as f:
                f.write(body)
    return True


DECL_RE = re.compile(r"\b(?:function|class|const|let|var)\s+([A-Za-z_$][\w$]*)")
EXPORT_LIST_RE = re.compile(r"export\s*\{([^}]*)\}\s*;", re.M)


def drop_undeclared_export_names(body):
    """The stripper sometimes keeps type-only names in a trailing export list
    (same-file interfaces), which makes the emitted .js an invalid module.
    Drop specifiers that name no declaration in the file."""
    declared = set(DECL_RE.findall(body))

    def fix(m):
        # The emitted list keeps the source's `//` comments, which would glue
        # to the following specifier on a naive comma split and read as part
        # of the declaration name.
        inner = re.sub(r"//[^\n]*", "", m.group(1))
        specs = [s.strip() for s in inner.split(",") if s.strip()]
        kept = [s for s in specs if (s.split(" as ")[0].strip() in declared)]
        return "export { " + ", ".join(kept) + " };" if kept else ""

    return EXPORT_LIST_RE.sub(fix, body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch-only", action="store_true")
    ap.add_argument("--no-fetch", action="store_true")
    ap.add_argument("--lib", help="only sweep this library")
    args = ap.parse_args()

    if not args.no_fetch:
        ok = True
        for name, spec in LIBS.items():
            for dest, url in spec["files"].items():
                ok = fetch(url, os.path.join(CACHE, dest)) and ok
        if not ok:
            return 1
    if args.fetch_only:
        return 0

    names = [args.lib] if args.lib else list(LIBS)
    passed = failed = 0
    for name in names:
        spec = LIBS[name]
        driver = os.path.join(CHECKS_DIR, spec["driver"])
        if not os.path.exists(driver):
            print(f"SKIP: no driver for {name}")
            continue
        missing = [f for f in spec["files"] if not os.path.exists(os.path.join(CACHE, f))]
        if missing:
            print(f"SKIP: {name} sources not fetched ({', '.join(missing)})")
            continue

        # Copy the driver beside the fetched sources so its relative imports resolve.
        driver_cache = os.path.join(CACHE, f"_driver_{name}.ts")
        with open(driver, "rb") as f:
            body = f.read().decode("utf-8")
        with open(driver_cache, "w") as f:
            f.write(body)

        # 1. ts run
        ts_rc, ts_out, ts_err = run(os.path.abspath(ENGINE), driver_cache, CACHE)
        if ts_rc != 0:
            failed += 1
            print(f"FAIL: {name} (ts run rc={ts_rc})")
            for line in (ts_err or "").splitlines()[:4]:
                print(f"  | {line}")
            continue

        # 2. transpiled js run, tsc as the stripper
        rel_files = list(spec["files"].keys()) + [f"_driver_{name}.ts"]
        if not strip_with_tsc(rel_files):
            failed += 1
            print(f"FAIL: {name} (tsc strip step failed)")
            continue
        js_driver = os.path.join(TRANSPILED, f"_driver_{name}.js")
        js_rc, js_out, js_err = run(os.path.abspath(ENGINE), js_driver, TRANSPILED)
        if js_rc != 0 or js_out != ts_out:
            failed += 1
            print(f"FAIL: {name} (ts vs transpiled-js divergence; js rc={js_rc})")
            if js_rc != 0:
                for line in (js_err or "").splitlines()[:4]:
                    print(f"  | {line}")
            if js_out != ts_out:
                for line in list(difflib.unified_diff(ts_out.splitlines(), js_out.splitlines(), "ts", "js"))[:12]:
                    print(f"  | {line}")
            continue
        passed += 1
        print(f"ok:   {name}")

    print(f"\n{passed} pass, {failed} fail ({passed + failed} total)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
