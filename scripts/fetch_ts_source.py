#!/usr/bin/env python3
"""Fetch the TypeScript compiler's own source (microsoft/TypeScript v6.0.3).

TypeScript 6.0 is the last compiler written in TypeScript; TypeScript 7 is a
Go rewrite. Its sources exercise far more of the
language than the conformance corpus does (const enums across modules, cycles
between modules, import aliases), so they are a useful stress test for the
engine's type stripping:

    python3 scripts/fetch_ts_source.py
    python3 scripts/fetch_ts_source.py --check

`--check` compiles every fetched module and reports the ones the engine still
rejects. The corpus is gitignored; only this script is committed.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

UA = "boomkat-ts-source-fetch"
VERSION = "6.0.3"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "test", "tscorpus", "typescript-src")
TARBALL = f"https://codeload.github.com/microsoft/TypeScript/tar.gz/refs/tags/v{VERSION}"
DEFAULT_BIN = os.path.join(ROOT, "out", "boomkat")

# The parser, checker, services and command line driver: everything the
# compiler itself is built from.
TREES = ("src/compiler", "src/services", "src/server", "src/tsc",
         "src/jsTyping", "src/typingsInstaller",
         "src/typingsInstallerCore", "src/watchGuard", "src/deprecatedCompat")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.read()


# Names the release the fetched tree came from, so another VERSION refetches.
STAMP = os.path.join(DEST, ".version")


def extract():
    if os.path.isfile(STAMP):
        with open(STAMP, encoding="utf-8") as f:
            if f.read().strip() == VERSION:
                print(f"already fetched: {DEST}")
                return
    if os.path.isdir(DEST):
        print(f"replacing the sources of another release in {DEST}")
        shutil.rmtree(DEST)
    print(f"downloading {TARBALL}")
    data = fetch(TARBALL)
    os.makedirs(DEST, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    try:
        with tarfile.open(path, "r:gz") as tar:
            wanted = [f"TypeScript-{VERSION}/{t}" for t in TREES]
            members = [m for m in tar.getmembers()
                       if any(m.name == w or m.name.startswith(w + "/") for w in wanted)]
            for m in members:
                m.name = m.name.split("/", 1)[1]
            tar.extractall(DEST, members=members, filter="data")
    finally:
        os.unlink(path)
    with open(STAMP, "w", encoding="utf-8") as f:
        f.write(VERSION + "\n")
    print(f"extracted {sum(1 for _ in walk_ts(DEST))} modules into {DEST}")


def walk_ts(base):
    for root, _dirs, files in os.walk(base):
        for f in files:
            if f.endswith(".ts"):
                yield os.path.join(root, f)


def check(bin_path):
    """Compile every fetched module; report the ones the engine rejects."""
    bad = 0
    total = 0
    for path in sorted(walk_ts(DEST)):
        total += 1
        res = subprocess.run([bin_path, path], capture_output=True, text=True, timeout=600)
        out = res.stdout + res.stderr
        if "SyntaxError" in out:
            bad += 1
            line = out.strip().split("\n")[0].replace(DEST + os.sep, "")
            print(f"  {line}")
    print(f"{total - bad}/{total} modules compile")
    return 0 if bad == 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="compile every fetched module")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="engine binary for --check")
    args = ap.parse_args()
    extract()
    if args.check:
        return check(args.bin)
    return 0


if __name__ == "__main__":
    sys.exit(main())
