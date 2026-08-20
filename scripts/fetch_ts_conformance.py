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
# The conformance corpus moved when microsoft/TypeScript's default branch became
# the TypeScript 7 ("Corsa") Go rewrite: it now lives under
# tsc/testdata/tests/cases/conformance (was tests/cases/conformance on 5.x).
CORPUS_PATH = "tsc/testdata/tests/cases/conformance"

ENV = dict(os.environ)
ENV["GIT_SSH_COMMAND"] = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"


def sh(cmd, **kw):
    print("+", " ".join(cmd))
    return subprocess.run(cmd, env=ENV, **kw)


def main():
    if os.path.isdir(os.path.join(DEST, ".git")):
        print(f"Corpus already present at {DEST}; updating instead.")
        # Fetch the remote default branch and hard-reset onto it rather than
        # running `pull`. The TypeScript 7 rewrite is not a fast-forward from an
        # older classic-layout clone, so a plain pull aborts and leaves the
        # corpus path unpopulated. Reset makes the update work from any state.
        sh(["git", "-C", DEST, "fetch", "--depth", "1", "origin", "HEAD"])
        sh(["git", "-C", DEST, "sparse-checkout", "set", CORPUS_PATH])
        sh(["git", "-C", DEST, "reset", "--hard", "FETCH_HEAD"])
        return 0
    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    r = sh(["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse", REMOTE, DEST])
    if r.returncode != 0:
        print("clone failed", file=sys.stderr)
        return 1
    r = sh(["git", "-C", DEST, "sparse-checkout", "set", CORPUS_PATH])
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
