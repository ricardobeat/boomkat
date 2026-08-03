#!/usr/bin/env python3
"""Fetch the official TypeScript conformance corpus into
test/typescript/conformance-src as a sparse, blobless clone (only
tests/cases/conformance is checked out), so the conformance runner
(scripts/run_ts_conformance.py) has the official syntax corpus to test
against without vendoring thousands of files into the repo. The clone is
gitignored; the runner caches tsc classifications in
test/typescript/ts_conformance_cache (also gitignored).
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEST = os.path.join(ROOT, "test", "typescript", "conformance-src")
REMOTE = "https://github.com/microsoft/TypeScript.git"

ENV = dict(os.environ)
ENV["GIT_SSH_COMMAND"] = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"


def sh(cmd, **kw):
    print("+", " ".join(cmd))
    return subprocess.run(cmd, env=ENV, **kw)


def main():
    if os.path.isdir(os.path.join(DEST, ".git")):
        print(f"Corpus already present at {DEST}; updating instead.")
        sh(["git", "-C", DEST, "pull", "--depth", "1"])
        sh(["git", "-C", DEST, "sparse-checkout", "set", "tests/cases/conformance"])
        return 0
    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    r = sh(["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse", REMOTE, DEST])
    if r.returncode != 0:
        print("clone failed", file=sys.stderr)
        return 1
    r = sh(["git", "-C", DEST, "sparse-checkout", "set", "tests/cases/conformance"])
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
