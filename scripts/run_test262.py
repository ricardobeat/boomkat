#!/usr/bin/env python3
"""
Worker-mode test262 runner.

Spawns N parallel batch_test_vm --worker processes, feeds tests via stdin,
collects PASS/FAIL results, enforces per-test timeouts via SIGKILL+restart.

Default: 3 workers (max 4) to avoid OOM from multiple VM heaps.

IMPORTANT: Always prefer running a single --phase relevant to your change
instead of the full suite. The full suite takes 20+ minutes; a single phase
is usually under a minute. Only run all phases for final validation before
merging.

Usage:
    python3 scripts/run_test262.py --phase 2    # single phase (preferred)
    python3 scripts/run_test262.py              # all phases (full validation only)
    python3 scripts/run_test262.py --workers 8  # override worker count
    python3 scripts/run_test262.py --es5        # ES5-only (skip tests with feature flags)
"""

import argparse
import os
import re
import select
import signal
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
TEST262_DIR = os.path.join(PROJECT_DIR, "test262", "test")
VM_BINARY = os.path.join(PROJECT_DIR, "out", "batch_test_vm")

# Default timeout per test (seconds)
TEST_TIMEOUT = 10

# ---------------------------------------------------------------------------
# Skip list — see test262_relevance_report.md for rationale
# ---------------------------------------------------------------------------

# Directories to skip entirely (relative to test262/test/)
SKIP_DIRS = {
    "annexB",                          # 1,086 — legacy browser quirks
    "intl402",                         # 3,337 — ECMA-402 (separate spec)
    "staging",                         # 1,493 — unstandardized proposals
    "harness",                         # 116   — test harness self-tests
    "built-ins/Temporal",              # 4,603 — Stage 3 proposal
    "built-ins/ShadowRealm",           # 67    — Stage 3 proposal
    "built-ins/DisposableStack",       # 93    — Stage 3
    "built-ins/AsyncDisposableStack",  # 104   — Stage 3
    "built-ins/SuppressedError",       # 22    — Stage 3
    "built-ins/AbstractModuleSource",  # 8     — Stage 3
    "built-ins/SharedArrayBuffer",     # 104   — platform-dependent
    "built-ins/Atomics",               # 390   — platform-dependent
    "built-ins/Proxy",                 # 311   — extreme complexity
    "built-ins/WeakRef",               # 29    — GC-dependent
    "built-ins/FinalizationRegistry",  # 47    — GC-dependent
    "built-ins/BigInt",                # 77    — defer
}

# Feature flags to skip (matched against test metadata `features: [...]`)
UNSUPPORTED_PATTERN = re.compile(
    r"features:\s*\[.*\b(?:"
    # Engine quirks / non-standard
    r"IsHTMLDDA|host-gc-required|cross-realm|tail-call-optimization|"
    r"legacy-regexp|caller|"
    # Annex B property features
    r"__proto__|__getter__|__setter__|"
    # Stage 3 proposals
    r"Temporal|ShadowRealm|decorators|explicit-resource-management|"
    r"source-phase-imports|source-phase-imports-module-source|"
    r"import-defer|export-defer|import-attributes|import-text|import-bytes|"
    r"Atomics\.pause|canonical-tz|immutable-arraybuffer|"
    r"nonextensible-applies-to-private|await-dictionary|error-stack-accessor|"
    r"promise-try|iterator-sequencing|Error\.isError|upsert|array-grouping|"
    r"Math\.sumPrecise|RegExp\.escape|json-parse-with-source|"
    r"regexp-modifiers|regexp-duplicate-named-groups|"
    r"uint8array-base64|Float16Array|resizable-arraybuffer|"
    r"joint-iteration|iterator-helpers|"
    # ES2024+ features (implement later)
    r"Array\.fromAsync|set-methods|promise-with-resolvers|"
    r"symbols-as-weakmap-keys|change-array-by-copy|Atomics\.waitAsync|"
    # Complex features deferred
    r"SharedArrayBuffer|Atomics|Proxy|BigInt|WeakRef|FinalizationRegistry|"
    r"structured-clone|import\.meta|dynamic-import|"
    # Class features not yet implemented
    r"class-methods-private|class-static-methods-private|"
    r"class-fields-private|class-fields-public|"
    r"class-static-fields-private|class-static-fields-public|"
    r"class-static-block|"
    # Other unimplemented ES features
    r"object-rest|optional-chaining|logical-assignment|"
    r")\b"
)

PHASES = [
    {
        "label": "Phase 0-1: Core VM",
        "dirs": [
            "language/asi", "language/block-scope", "language/comments",
            "language/directive-prologue", "language/function-code",
            "language/global-code", "language/identifiers",
            "language/identifier-resolution", "language/keywords",
            "language/line-terminators", "language/literals/boolean",
            "language/literals/null", "language/literals/numeric",
            "language/literals/string", "language/literals/undefined",
            "language/punctuators", "language/reserved-words",
            "language/source-text", "language/statementList",
            "language/types", "language/white-space",
            "language/statements/block", "language/statements/empty",
            "language/statements/expression", "language/statements/if",
            "language/statements/return", "language/statements/variable",
            "language/statements/while", "language/statements/do-while",
            "language/future-reserved-words", "language/arguments-object",
        ],
    },
    {
        "label": "Phase 1: Calling Convention & Closures",
        "dirs": [
            "language/expressions/function", "language/expressions/call",
            "language/expressions/new", "language/rest-parameters",
        ],
    },
    {
        "label": "Phase 2: Basic Operators",
        "dirs": [
            "language/expressions/addition", "language/expressions/subtraction",
            "language/expressions/multiplication", "language/expressions/division",
            "language/expressions/modulus", "language/expressions/exponentiation",
            "language/expressions/bitwise-and", "language/expressions/bitwise-or",
            "language/expressions/bitwise-xor", "language/expressions/bitwise-not",
            "language/expressions/left-shift", "language/expressions/right-shift",
            "language/expressions/unsigned-right-shift",
            "language/expressions/unary-plus", "language/expressions/unary-minus",
            "language/expressions/logical-not", "language/expressions/typeof",
            "language/expressions/equals", "language/expressions/strict-equals",
            "language/expressions/less-than", "language/expressions/greater-than",
            "language/expressions/less-than-or-equal",
            "language/expressions/greater-than-or-equal",
            "language/expressions/conditional", "language/expressions/comma",
            "language/expressions/void", "language/expressions/logical-and",
            "language/expressions/logical-or", "language/expressions/assignment",
            "language/expressions/compound-assignment",
            "language/expressions/postfix-increment",
            "language/expressions/postfix-decrement",
            "language/expressions/prefix-increment",
            "language/expressions/prefix-decrement",
        ],
    },
    {
        "label": "Phase 3: Object System",
        "dirs": [
            "language/expressions/object", "language/expressions/array",
            "language/expressions/member-expression",
            "language/expressions/property-accessors",
            "built-ins/Object", "built-ins/Array", "built-ins/Array/length",
        ],
    },
    {
        "label": "Phase 4: Error Handling & References",
        "dirs": [
            "built-ins/Error", "built-ins/NativeErrors",
            "language/statements/try", "language/statements/throw",
        ],
    },
    {
        "label": "Phase 5: Built-in Constructors",
        "dirs": [
            "built-ins/Boolean", "built-ins/String", "built-ins/Number",
            "built-ins/Object", "built-ins/Array", "built-ins/Function",
        ],
    },
    {
        "label": "Phase 6: Built-in Prototype Methods",
        "dirs": [
            "built-ins/Math", "built-ins/String/prototype",
            "built-ins/Array/prototype", "built-ins/Number/prototype",
            "built-ins/Boolean/prototype", "built-ins/Function/prototype",
        ],
    },
    {
        "label": "Phase 7: Remaining ES5 Features",
        "dirs": [
            "language/statements/switch", "language/statements/with",
            "language/statements/break", "language/statements/continue",
            "language/statements/labeled", "language/expressions/instanceof",
            "language/expressions/in", "language/expressions/delete",
            "language/eval-code", "language/statements/for",
        ],
    },
    {
        "label": "Phase 8: ES5 Built-in Objects",
        "dirs": [
            "built-ins/JSON", "built-ins/Date", "built-ins/RegExp",
            "built-ins/parseInt", "built-ins/parseFloat",
        ],
    },
    {
        "label": "Phase 11: Arrow Functions & Templates",
        "dirs": [
            "language/expressions/arrow-function",
            "language/expressions/template-literal",
            "language/expressions/tagged-template",
        ],
    },
    {
        "label": "Phase 12-13: Destructuring & Spread",
        "dirs": [
            "language/destructuring",
            "language/expressions/spread",
        ],
    },
    {
        "label": "Phase 14: for-of",
        "dirs": [
            "language/statements/for-of",
        ],
    },
    {
        "label": "Phase 15: Classes",
        "dirs": [
            "language/expressions/class",
            "language/statements/class",
            "language/expressions/super",
        ],
    },
    {
        "label": "Phase 17-20: Map/Set/Symbol/Promise/WeakMap/WeakSet",
        "dirs": [
            "built-ins/Map", "built-ins/Set",
            "built-ins/Symbol",
            "built-ins/Promise",
            "built-ins/WeakMap", "built-ins/WeakSet",
        ],
    },
    {
        "label": "Phase 21: Generators",
        "dirs": [
            "language/expressions/yield",
            "language/expressions/generators",
            "language/statements/generators",
        ],
    },
]

# ---------------------------------------------------------------------------
# Skip filter
# ---------------------------------------------------------------------------

UNSUPPORTED_PATTERN = re.compile(
    r"features:\s*\[.*\b(?:"
    r"proxy|BigInt|async|module|"
    r"Reflect|SharedArrayBuffer|Atomics|Intl|"
    r"TypedArray|DataView|Float32Array|Float64Array|Int8Array|Int16Array|"
    r"Int32Array|Uint8Array|Uint16Array|Uint32Array|Uint8ClampedArray|"
    r"FinalizationRegistry|WeakRef|structured-clone|import\.meta|"
    r"dynamic-import|"
    # Class features not yet implemented
    r"class-methods-private|class-static-methods-private|"
    r"class-fields-private|class-fields-public|"
    r"class-static-fields-private|class-static-fields-public|"
    r"class-static-block|"
    # Other unimplemented ES features
    r"object-rest|explicit-resource-management|"
    r"optional-chaining|logical-assignment|resizable-arraybuffer|"
    r"array-grouping|upsert|set-methods|"
    r"symbols-as-weakmap-keys|cross-realm|"
    r"await-dictionary|"
    r")\b"
)


# Match ANY test that declares feature flags — used by --es5 mode to skip
# all post-ES5 tests.  Tests without `features:` are baseline ES5 behavior.
ANY_FEATURES_PATTERN = re.compile(r"^features:\s*\[", re.MULTILINE)


def should_skip(path, es5_only=False):
    """Check if a test should be skipped based on directory or header metadata."""
    # Skip tests in excluded directories
    rel = os.path.relpath(path, TEST262_DIR)
    for skip_dir in SKIP_DIRS:
        if rel.startswith(skip_dir + os.sep) or rel.startswith(skip_dir + "/"):
            return True

    try:
        with open(path) as f:
            header = f.read(2000)
    except OSError:
        return True

    if "$DONOTEVALUATE" in header:
        return True
    if UNSUPPORTED_PATTERN.search(header):
        return True
    if es5_only and ANY_FEATURES_PATTERN.search(header):
        return True
    if re.search(r"flags:\s*\[.*\bnoStrict\b", header):
        return True
    return False


# ---------------------------------------------------------------------------
# Worker management
# ---------------------------------------------------------------------------


class Worker:
    """Manages a single batch_test_vm --worker subprocess."""

    def __init__(self, binary, worker_id):
        self.worker_id = worker_id
        self._proc = subprocess.Popen(
            [binary, "--worker"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        self._pending = None  # (test_path, start_time)
        self._buf = b""

    @property
    def alive(self):
        return self._proc.poll() is None

    @property
    def is_idle(self):
        return self._pending is None

    @property
    def stdout_fileno(self):
        return self._proc.stdout.fileno()

    def send_test(self, test_path):
        """Send a test path to the worker."""
        if self._pending is not None:
            raise RuntimeError("Worker already has a pending test")
        self._pending = (test_path, time.monotonic())
        line = (test_path + "\n").encode()
        self._proc.stdin.write(line)
        self._proc.stdin.flush()

    def try_read_result(self):
        """Try to read a PASS/FAIL line from stdout. Returns (test_path, result) or None."""
        while True:
            chunk = self._proc.stdout.readline()
            if not chunk:
                return None
            line = chunk.decode().strip()
            if not line:
                continue

            result = None
            if line.startswith("PASS "):
                result = "PASS"
            elif line.startswith("FAIL "):
                result = "FAIL"
            else:
                # Unexpected line — skip
                continue

            test_path = line[len(result) + 1:]
            if self._pending is not None:
                pending_path, _ = self._pending
                # Sanity check: should match what we sent
                if pending_path != test_path:
                    test_path = pending_path
            self._pending = None
            return (test_path, result)

    def elapsed(self):
        """Seconds since current test was sent, or 0 if idle."""
        if self._pending is None:
            return 0.0
        return time.monotonic() - self._pending[1]

    def kill(self):
        """Kill this worker process."""
        if self._proc.poll() is None:
            os.kill(self._proc.pid, signal.SIGKILL)
            self._proc.wait()

    def restart(self, binary):
        """Kill and restart the worker."""
        self.kill()
        self._proc = subprocess.Popen(
            [binary, "--worker"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        self._pending = None
        self._buf = b""


# ---------------------------------------------------------------------------
# Test262 runner
# ---------------------------------------------------------------------------


def build_phase_tests(phase_idx, es5_only=False):
    """Collect test files for a phase, applying skip filter. Recurses into subdirs."""
    phase = PHASES[phase_idx]
    tests = []
    skipped = 0
    for rel_dir in phase["dirs"]:
        full = os.path.join(TEST262_DIR, rel_dir)
        if not os.path.isdir(full):
            continue
        for dirpath, _dirnames, filenames in os.walk(full):
            for entry in filenames:
                if not entry.endswith(".js"):
                    continue
                path = os.path.join(dirpath, entry)
                if should_skip(path, es5_only=es5_only):
                    skipped += 1
                    continue
                tests.append(path)
    return tests, skipped


def run_phase(phase_idx, num_workers, test_timeout, es5_only=False):
    """Run a single phase and return (pass_count, fail_count, skip_count, total_count)."""
    phase = PHASES[phase_idx]
    tests, skipped = build_phase_tests(phase_idx, es5_only=es5_only)
    total = len(tests) + skipped

    if not tests:
        return (0, 0, skipped, total)

    workers = [Worker(VM_BINARY, i) for i in range(num_workers)]
    results = []  # (path, "PASS"|"FAIL")
    pending_count = [0]  # mutable counter for tracking timed-out tests

    def finish_worker(w, timed_out=False):
        """Record pending test as completed. Returns (path, result)."""
        if w._pending is not None:
            path, _ = w._pending
            result = "FAIL" if timed_out else "FAIL"
            results.append((path, result))
            w._pending = None
            pending_count[0] -= 1
            return (path, result)
        return None

    # Feed all tests round-robin
    test_queue = list(tests)
    next_worker = 0

    while test_queue or pending_count[0] > 0:
        # Assign idle workers
        for w in workers:
            if w.alive and w.is_idle and test_queue:
                t = test_queue.pop(0)
                w.send_test(t)
                pending_count[0] += 1

        # Collect results with timeout
        if pending_count[0] > 0:
            # Build fd list for select
            fds = [w.stdout_fileno for w in workers if w.alive and not w.is_idle]
            if fds:
                try:
                    readable, _, _ = select.select(fds, [], [], 0.1)
                except (ValueError, OSError):
                    # File descriptor closed under us
                    readable = []
            else:
                readable = []

            for fd in readable:
                # Find worker with this fd
                for w in workers:
                    if w.alive and w.stdout_fileno == fd:
                        r = w.try_read_result()
                        if r:
                            results.append(r)
                            pending_count[0] -= 1
                        break

        # Check for timeouts
        now = time.monotonic()
        for w in workers:
            if w.alive and not w.is_idle and w.elapsed() > test_timeout:
                print(
                    f"  [timeout] {w._pending[0]} (worker {w.worker_id})",
                    file=sys.stderr,
                )
                w.kill()
                finish_worker(w, timed_out=True)
                w.restart(VM_BINARY)

        # Replace dead workers
        for i, w in enumerate(workers):
            if not w.alive:
                if w._pending is not None:
                    finish_worker(w)
                workers[i] = Worker(VM_BINARY, i)
                # Re-assign a pending test if any left
                if test_queue:
                    t = test_queue.pop(0)
                    workers[i].send_test(t)
                    pending_count[0] += 1

    # Cleanup
    for w in workers:
        w.kill()

    pass_count = sum(1 for _, r in results if r == "PASS")
    fail_count = len(results) - pass_count
    return (pass_count, fail_count, skipped, total)


def main():
    parser = argparse.ArgumentParser(
        description="Run test262 tests in parallel worker mode."
    )
    parser.add_argument(
        "--phase",
        type=int,
        choices=range(len(PHASES)),
        help="Run only this phase (0-8)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=3,
        help="Number of parallel workers (default: 3, max: 4)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=TEST_TIMEOUT,
        help=f"Per-test timeout in seconds (default: {TEST_TIMEOUT})",
    )
    parser.add_argument(
        "--es5",
        action="store_true",
        help="ES5-only mode: skip all tests with feature flags (post-ES5 features)",
    )
    args = parser.parse_args()

    # Cap workers to avoid OOM — each worker is a full VM process with its own heap
    if args.workers > 4:
        print(f"Warning: capping --workers from {args.workers} to 4 (memory limit)", file=sys.stderr)
        args.workers = 4

    # Build if needed
    if not os.path.isfile(VM_BINARY):
        print("Building batch_test_vm...", file=sys.stderr)
        rc = subprocess.call(
            ["c3c", "build", "batch_test_vm"],
            cwd=PROJECT_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if rc != 0:
            print("Build failed.", file=sys.stderr)
            sys.exit(1)

    phases = [args.phase] if args.phase is not None else range(len(PHASES))
    grand_pass = grand_fail = grand_skip = grand_total = 0

    if args.es5:
        print("Mode: ES5-only (skipping tests with post-ES5 feature flags)\n")

    print("Phase | Total | Pass | Fail | Skip")
    print("------|-------|------|------|-----")
    for p in phases:
        p_pass, p_fail, p_skip, p_total = run_phase(
            p, args.workers, args.timeout, es5_only=args.es5
        )
        print(
            f"{PHASES[p]['label']} | {p_total} | {p_pass} | {p_fail} | {p_skip}"
        )
        grand_pass += p_pass
        grand_fail += p_fail
        grand_skip += p_skip
        grand_total += p_total

    if len(phases) > 1:
        grand_run = grand_pass + grand_fail
        pct = (grand_pass / grand_run * 100) if grand_run > 0 else 0
        print(f"\nOverall: {grand_pass} pass / {grand_fail} fail ({pct:.1f}%)")
        if grand_skip > 0:
            print(f"Skipped: {grand_skip} tests")


if __name__ == "__main__":
    main()
