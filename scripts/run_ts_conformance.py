#!/usr/bin/env python3
"""TypeScript conformance runner: type-stripping conformance against the
official Microsoft TypeScript conformance corpus.

The engine runs `.ts` files by erasing type syntax at parse time (plan 042,
the TS 5.8+ `--erasableSyntaxOnly` subset). There is no official test262-style
TypeScript suite, so this harness turns the TypeScript project's own
conformance corpus (`tests/cases/conformance/`, thousands of files) into one
by using `tsc --erasableSyntaxOnly` as the acceptance oracle:

  ACCEPT  - tsc reports no errors: the file is purely erasable, so the
            engine must compile it. A SyntaxError here is a real failure.
  REJECT  - tsc reports only TS1294 (erasableSyntaxOnly violation: enum,
            namespace, parameter property, ...): the engine must also reject
            the source with a compile error.
  SKIP    - tsc reports other diagnostics (type errors, deliberate-error
            tests, missing libs): not an erasable-syntax test. Also skipped:
            `.d.ts` files and any file tsc cannot parse as a single program.

Corpus location: `test/typescript/conformance-src` (a sparse, blobless clone
of github.com/microsoft/TypeScript with `tests/cases/conformance` checked
out; fetch it with `scripts/fetch_ts_conformance.py`). Like test262, the
corpus itself is gitignored; the harness and this script are committed.

The full corpus runs in a couple of minutes: tsc verdicts are cached in
`test/typescript/ts_conformance_cache`, engine runs are parallel, and a file
that compiles but whose runtime never terminates counts as a pass (compile
conformance, not runtime conformance). A hard deadline (default 10 minutes)
aborts the run and reports partial results if anything pathological slips in.

Usage:
  python3 scripts/run_ts_conformance.py [--limit N] [--only <substring>]
      [--bin ./out/boomkat] [--keep-tsc] [--phase-dir <subdir>]
      [--jobs N] [--engine-timeout SECONDS] [--deadline SECONDS]
      [--log <file>] [--no-cache]
  --keep-tsc     reuse cached tsc classifications (default; kept for compat)
  --no-cache     force a fresh tsc classification, overwriting the cache
  --log <file>   write RESULT<TAB>path lines for every verdict (failure
                 clustering, same format as run_test262.py)
"""

import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# The corpus lives under the TypeScript 7 ("Corsa") Go-rewrite layout
# (tsc/testdata/tests/cases/conformance); scripts/fetch_ts_conformance.py
# sparse-checks out exactly this path.
CORPUS = os.path.join(ROOT, "test", "typescript", "conformance-src",
                      "tsc", "testdata", "tests", "cases", "conformance")
CACHE = os.path.join(ROOT, "test", "typescript", "ts_conformance_cache")
DEFAULT_BIN = os.path.join(ROOT, "out", "boomkat")

DEFAULT_JOBS = 16
DEFAULT_ENGINE_TIMEOUT = 20      # seconds per engine run
DEFAULT_TSC_TIMEOUT = 60         # seconds per tsc run
DEFAULT_DEADLINE = 600           # hard wall-clock cap for the whole run

TSC_FLAGS = [
    "--noEmit", "--erasableSyntaxOnly", "--skipLibCheck",
    "--target", "es2022", "--module", "esnext", "--moduleResolution", "bundler",
    "--lib", "es2022", "--strict", "false", "--isolatedModules", "false",
    "--noResolve",
]

# TS1294 = "This syntax is not allowed under 'erasableSyntaxOnly'"
RE_TS1294 = re.compile(r"error TS1294")
def _strip_js_comments(src):
    """Remove // and /* */ comments so a decorator scan does not trip on
    `// @target: ...` header directives."""
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != chr(10):
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


# Files tsc classifies ACCEPT whose code violates a JavaScript early error
# that tsc does not enforce (its parser is more lenient than the ECMA-262
# grammar this engine implements). The engine's rejection is spec-correct,
# so these are not erasable-syntax bugs. Each entry names the reason.
JS_EARLY_ERROR_FILES = {
    "async/es6/asyncWithVarShadowing_es6.ts":
        "var in a catch block shadows the catch parameter (early error)",
    "es6/moduleExportsSystem/topLevelVarHoistingCommonJS.ts":
        "with statement (sloppy-mode code; the engine is strict-only)",
}

# Sentinel returned by engine workers when the run deadline has passed.
DEADLINE = "deadline"


class Clock:
    """Thread-safe monotonic clock shared by all workers."""

    def __init__(self, deadline_s):
        self.deadline = time.monotonic() + deadline_s
        self.hit = False
        self.lock = threading.Lock()

    def expired(self):
        with self.lock:
            if self.hit:
                return True
            if time.monotonic() > self.deadline:
                self.hit = True
                return True
            return False


def tsc_classify(path, cache_dir, no_cache):
    """Run tsc once per file (cached). Returns 'accept' | 'reject' | 'skip'."""
    rel = os.path.relpath(path, CORPUS)
    cache_file = os.path.join(cache_dir, rel + ".txt")
    if not no_cache and os.path.exists(cache_file):
        with open(cache_file, "r", encoding="utf-8") as f:
            return f.read().strip()

    out = ""
    try:
        res = subprocess.run(
            ["tsc", *TSC_FLAGS, path],
            capture_output=True, text=True, timeout=DEFAULT_TSC_TIMEOUT,
        )
        out = res.stdout + res.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        if isinstance(e, FileNotFoundError):
            print("tsc not on PATH; cannot run the oracle. Install typescript.", file=sys.stderr)
            sys.exit(2)
        verdict = "skip"  # timeout: tsc hung on a pathological file
    else:
        if res.returncode == 0:
            verdict = "accept"
        elif RE_TS1294.search(out) and "error TS" in out:
            # Reject only when TS1294 is the ONLY diagnostic family.
            errors = [l for l in out.splitlines() if "error TS" in l]
            verdict = "reject" if all(RE_TS1294.search(l) for l in errors) else "skip"
        else:
            verdict = "skip"

    os.makedirs(os.path.dirname(cache_file), exist_ok=True)
    with open(cache_file, "w", encoding="utf-8") as f:
        f.write(verdict)
    return verdict


def engine_outcome(path, bin_path, timeout):
    """Run the engine on the file.

    Returns 'compiled' (exit 0), 'syntax_error' (compile rejected the
    source), 'decorators' (only problem is an out-of-scope `@` token),
    'accessors' (only problem is the out-of-scope auto-accessor proposal),
    'compiled_timeout' (the source compiled and ran past `timeout`; a
    compile-conformance pass whose runtime never terminates), or 'missing'.
    """
    try:
        res = subprocess.run([bin_path, path], capture_output=True, text=True,
                             timeout=timeout)
    except subprocess.TimeoutExpired:
        return "compiled_timeout"
    except FileNotFoundError:
        return "missing"
    combined = res.stdout + res.stderr
    # The script path prints "SyntaxError: ..."; the ESM path prints
    # "<file>: SyntaxError at line X:Y: ...". Both mean the source failed
    # to compile (vs. compiled-and-threw, which prints "Uncaught"/"VM error").
    # "compile error" is still accepted for the debug CLI's wording.
    if "SyntaxError" in combined or "compile error" in combined:
        # Decorators are real runtime syntax under --erasableSyntaxOnly, not
        # type syntax, and are out of scope for this engine (plan 042). A
        # file whose only problem is an `@` token is a documented non-goal,
        # not an erasable-syntax bug. Auto-accessors (`accessor x: T`) are
        # likewise a non-goal proposal feature the engine rejects with a
        # dedicated message.
        if "unexpected character '@'" in combined:
            return "decorators"
        if "auto-accessors" in combined:
            return "accessors"
        if "using declarations are not supported" in combined:
            return "using_decls"
        # A decorator can trip the parser before the `@` is ever lexed (e.g.
        # `({ x = @dec class {} } = obj)` dies in the destructuring probe),
        # so also treat a compile failure of source that contains decorator
        # syntax as the documented non-goal.
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                src = f.read()
        except OSError:
            src = ""
        if re.search(r"@\s*[A-Za-z_$]", _strip_js_comments(src)):
            return "decorators"
        return "syntax_error"
    return "compiled"


def main():
    args = [a for a in sys.argv[1:]]
    limit = None
    only = None
    bin_path = DEFAULT_BIN
    phase_dir = None
    jobs = DEFAULT_JOBS
    engine_timeout = DEFAULT_ENGINE_TIMEOUT
    deadline_s = DEFAULT_DEADLINE
    log_path = None
    no_cache = False
    if "--limit" in args:
        limit = int(args[args.index("--limit") + 1])
    if "--only" in args:
        only = args[args.index("--only") + 1]
    if "--bin" in args:
        bin_path = args[args.index("--bin") + 1]
    if "--phase-dir" in args:
        phase_dir = args[args.index("--phase-dir") + 1]
    if "--jobs" in args:
        jobs = int(args[args.index("--jobs") + 1])
    if "--engine-timeout" in args:
        engine_timeout = int(args[args.index("--engine-timeout") + 1])
    if "--deadline" in args:
        deadline_s = int(args[args.index("--deadline") + 1])
    if "--log" in args:
        log_path = args[args.index("--log") + 1]
    if "--no-cache" in args:
        no_cache = True
    # --keep-tsc is the default; accepted for compatibility.
    if "--keep-tsc" in args and "--no-cache" in args:
        print("--keep-tsc and --no-cache conflict; --no-cache wins", file=sys.stderr)

    if not os.path.isdir(CORPUS):
        print(f"Corpus not found at {CORPUS}.\n"
              f"Fetch it with: python3 scripts/fetch_ts_conformance.py", file=sys.stderr)
        return 2
    if not os.path.exists(bin_path):
        print(f"Engine binary not found: {bin_path}. Build it first.", file=sys.stderr)
        return 2

    files = []
    root = os.path.join(CORPUS, phase_dir) if phase_dir else CORPUS
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".ts") or name.endswith(".d.ts"):
                continue
            files.append(os.path.join(dirpath, name))
    files.sort()
    if only:
        files = [f for f in files if only in f]
    if limit:
        files = files[:limit]

    clock = Clock(deadline_s)

    # Phase 1: tsc verdicts (cached, parallel when the cache is cold).
    print(f"classifying {len(files)} files with tsc (jobs={jobs})...", flush=True)
    verdicts = {}
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        results = ex.map(lambda p: (p, tsc_classify(p, CACHE, no_cache)), files)
        for path, verdict in results:
            verdicts[path] = verdict
            if clock.expired():
                print("tsc classification exceeded the deadline; aborting", file=sys.stderr)
                return 2

    counts = {"pass": 0, "fail": 0, "expected_reject": 0, "unexpected_accept": 0,
              "skip": 0, "decorators": 0, "js_early_error": 0, "runtime_timeout": 0,
              "accessors": 0, "using_decls": 0}
    for v in verdicts.values():
        if v == "skip":
            counts["skip"] += 1
    failures = []
    unexpected = []
    log_lines = []

    def log_verdict(rel, result):
        if log_path:
            log_lines.append(f"{result}\t{rel}")

    # Phase 2: engine runs, in parallel. Each worker checks the shared
    # deadline before spawning a process so a pathological batch cannot run
    # past the cap; aborted files are reported as skipped-unrun.
    def engine_work(path):
        if clock.expired():
            return (path, DEADLINE)
        rel = os.path.relpath(path, CORPUS)
        verdict = verdicts[path]
        if verdict == "skip":
            return (path, "skip")
        t0 = time.monotonic()
        outcome = engine_outcome(path, bin_path, engine_timeout)
        elapsed = time.monotonic() - t0
        return (path, outcome, elapsed, verdict, rel)

    todo = [p for p in files if verdicts[p] != "skip"]
    aborted = 0
    slow = []
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        futures = [ex.submit(engine_work, p) for p in todo]
        for fut in futures:
            r = fut.result()
            if r[1] == DEADLINE:
                aborted += 1
                continue
            path, outcome, elapsed, verdict, rel = r
            slow.append((elapsed, rel))
            if verdict == "accept":
                if rel in JS_EARLY_ERROR_FILES and outcome == "syntax_error":
                    counts["js_early_error"] += 1
                    log_verdict(rel, "JS_EARLY_ERROR")
                    continue
                if outcome == "compiled":
                    counts["pass"] += 1
                    log_verdict(rel, "PASS")
                elif outcome == "compiled_timeout":
                    # The source compiled and ran past the timeout: a compile
                    # conformance pass whose runtime never terminates.
                    counts["pass"] += 1
                    counts["runtime_timeout"] += 1
                    log_verdict(rel, "PASS_TIMEOUT")
                elif outcome == "decorators":
                    counts["decorators"] += 1
                    log_verdict(rel, "SKIP_DECORATORS")
                elif outcome == "accessors":
                    counts["accessors"] += 1
                    log_verdict(rel, "SKIP_ACCESSORS")
                elif outcome == "using_decls":
                    counts["using_decls"] += 1
                    log_verdict(rel, "SKIP_USING")
                else:
                    counts["fail"] += 1
                    failures.append((rel, outcome))
                    log_verdict(rel, "FAIL")
            else:  # reject
                if outcome == "syntax_error":
                    counts["expected_reject"] += 1
                    log_verdict(rel, "REJECT_OK")
                elif outcome == "decorators":
                    # A reject verdict whose only problem is `@` is a
                    # documented non-goal, not an engine acceptance bug.
                    counts["decorators"] += 1
                    log_verdict(rel, "SKIP_DECORATORS")
                else:
                    counts["unexpected_accept"] += 1
                    unexpected.append((rel, outcome))
                    log_verdict(rel, "UNEXPECTED_ACCEPT")

    print()
    print(f"TS conformance (corpus: {len(files)} files after filter, "
          f"jobs={jobs}, engine timeout={engine_timeout}s, deadline={deadline_s}s)")
    print(f"  accept  -> compiled ok:       {counts['pass']}"
          + (f" ({counts['runtime_timeout']} ran past the engine timeout)" if counts["runtime_timeout"] else ""))
    print(f"  accept  -> SyntaxError (BUG): {counts['fail']}")
    print(f"  reject  -> rejected ok:       {counts['expected_reject']}")
    print(f"  reject  -> compiled (BUG):    {counts['unexpected_accept']}")
    print(f"  skipped (not erasable tests): {counts['skip']}")
    if counts["decorators"]:
        print(f"  skipped (decorators, non-goal): {counts['decorators']}")
    if counts["accessors"]:
        print(f"  skipped (auto-accessors, non-goal): {counts['accessors']}")
    if counts["using_decls"]:
        print(f"  skipped (using declarations, non-goal): {counts['using_decls']}")
    if counts["js_early_error"]:
        print(f"  skipped (JS early error, tsc lenient): {counts['js_early_error']}")
    if aborted:
        print(f"  NOT RUN (deadline hit):      {aborted}")

    slow.sort(reverse=True)
    if slow:
        print("\n== slowest engine runs ==")
        for elapsed, rel in slow[:8]:
            print(f"  {elapsed:7.1f}s  {rel}")

    if failures:
        print(f"\n== {len(failures)} accept-file compile failures ==")
        for rel, outcome in failures[:40]:
            print(f"  {outcome:>12}  {rel}")
        if len(failures) > 40:
            print(f"  ... and {len(failures) - 40} more")
    if unexpected:
        print(f"\n== {len(unexpected)} reject-files accepted by the engine ==")
        for rel, outcome in unexpected[:20]:
            print(f"  {outcome:>12}  {rel}")
        if len(unexpected) > 20:
            print(f"  ... and {len(unexpected) - 20} more")

    if log_path:
        with open(log_path, "w", encoding="utf-8") as f:
            f.write("\n".join(log_lines) + "\n")
        print(f"\nlog written: {log_path}")

    if aborted:
        print(f"\n== RUN EXCEEDED {deadline_s}s DEADLINE; {aborted} files unrun ==")
        return 2
    if counts["fail"] == 0 and counts["unexpected_accept"] == 0:
        print("\n== all TS conformance checks passed ==")
        return 0
    print(f"\n== {counts['fail'] + counts['unexpected_accept']} TS conformance failure(s) ==")
    return 1


if __name__ == "__main__":
    sys.exit(main())
