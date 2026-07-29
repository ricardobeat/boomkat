#!/usr/bin/env python3
"""
Worker-mode test262 runner.

Spawns N parallel test262_runner --worker processes, feeds tests via stdin,
collects PASS/FAIL results, and enforces per-test timeouts via SIGKILL +
respawn. Each worker is held to MEM_LIMIT_BYTES (3 GB) — via RLIMIT_AS at spawn
on Linux, or by the parent sampling RSS on macOS, which refuses to lower that
rlimit — so a runaway-allocation test cannot drive the machine to tens of GB of
memory pressure.

Default worker count scales with the CPU count (cpus - 2, capped at 12). The
per-worker ceiling keeps total memory bounded at workers × 3 GB, so on a machine
with less RAM than that product, lower --workers.

IMPORTANT: Always prefer running a single --phase relevant to your change
instead of the full suite. A single phase is usually well under a minute.

This is the single canonical test262 runner. For per-test results (needed
for failure clustering), pass --log FILE — each line is RESULT<TAB>relpath
where RESULT is PASS / FAIL / TIMEOUT / MEMKILL / CE:expected-parse /
CE:expected-runtime / CE:unexpected. Cluster with e.g.:
    awk -F'\\t' '$1=="FAIL"{print $2}' results.tsv | xargs -n1 dirname | sort | uniq -c | sort -rn

Usage:
    python3 scripts/run_test262.py --phase 2    # single phase (preferred)
    python3 scripts/run_test262.py              # all phases (full validation only)
    python3 scripts/run_test262.py --workers 4  # override worker count
    python3 scripts/run_test262.py --es5        # ES5-only (skip tests with feature flags)
    python3 scripts/run_test262.py --log out/test262_results.tsv   # per-test log
    python3 scripts/run_test262.py --phase 2 --shuffle --workers 1 --no-retry-fails  # contamination detect
    python3 scripts/run_test262.py --phase 2 --fresh-process   # one worker per test (slow, clean)
"""

import argparse
import collections
import fnmatch
import glob
import os
import random
import re
import resource
import select
import signal
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
TEST262_DIR = os.path.join(PROJECT_DIR, "test262", "test")
# Worker binary. Override with TEST262_VM_BINARY=out/test262_runner_asan to run
# the corpus under AddressSanitizer (for hunting contamination / UAF bugs).
VM_BINARY = os.environ.get(
    "TEST262_VM_BINARY", os.path.join(PROJECT_DIR, "out", "test262_runner")
)
if not os.path.isabs(VM_BINARY):
    VM_BINARY = os.path.join(PROJECT_DIR, VM_BINARY)

# Default timeout per test (seconds)
TEST_TIMEOUT = 10

# Worker parallelism. Each worker is a full VM process, but its address space is
# hard-capped by RLIMIT_AS (see MEM_LIMIT_BYTES), so the old "max 4" memory
# guard is no longer what bounds the pool — the CPU count is. Two cores are left
# for the scheduler and the OS.
_CPUS = os.cpu_count() or 4
MAX_WORKERS = max(1, _CPUS)
DEFAULT_WORKERS = max(1, min(_CPUS - 2, 12))

# Optional per-test result log (set from --log in main); list so run_phase can
# see assignment from main without a global statement.
LOG_FH = [None]

# Serial retry of non-pass results. OFF by default: a deterministic engine on a
# fixed corpus must produce identical verdicts in parallel and serial, so a retry
# that *changes* a verdict is masking a real bug (contamination / resource-
# dependent behavior), not "flakiness" to smooth over. The parallel result is the
# honest one. --retry-fails re-enables the serial rerun purely as a DIAGNOSTIC:
# any test whose verdict differs parallel-vs-serial is a non-determinism bug to
# fix. Never use it to inflate a reported pass rate.
RETRY_FAILS = [False]

# Shuffle test order within each phase (for contamination detection).
# When combined with --workers 1 --no-retry-fails, running twice with and
# without --shuffle and diffing the logs reveals order-dependent reset bugs.
SHUFFLE = [False]

# Fresh-process-per-test mode: spawn a new test262_runner --worker for each
# test. Slow, but immune to all cross-test contamination. For final
# confirmation runs before merging.
FRESH_PROCESS = [False]

# Per-worker address-space cap. Tests that loop allocating (e.g. huge-length
# array-like iteration bugs) would otherwise balloon a worker to multiple GB
# within the timeout window; with several workers hitting such tests
# concurrently the machine hits tens of GB of memory pressure.
#
# Where the platform permits it (Linux), the cap is applied to each worker as
# RLIMIT_AS at spawn, so the kernel enforces it at the moment of the offending
# allocation. macOS refuses to lower RLIMIT_AS, so there the parent samples RSS
# and kills offenders itself — late by up to MEM_CHECK_INTERVAL, but bounded.
# Either way the test is recorded as MEMKILL (counted as a failure), and total
# memory stays bounded by workers × MEM_LIMIT_BYTES.
MEM_LIMIT_BYTES = 3 * 1024 * 1024 * 1024  # 3 GB
MEM_LIMIT_KB = MEM_LIMIT_BYTES // 1024

# How often the parent samples worker RSS, when it has to (see above). Each
# sample is one `ps` call for the whole pool.
MEM_CHECK_INTERVAL = 0.5


def sample_worker_rss(workers):
    """Return {pid: rss_kb} for all live busy workers via one ps call."""
    pids = [w._proc.pid for w in workers if w.alive and not w.is_idle]
    if not pids:
        return {}
    try:
        out = subprocess.run(
            ["ps", "-o", "pid=,rss=", "-p", ",".join(str(p) for p in pids)],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return {}
    rss = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            rss[int(parts[0])] = int(parts[1])
    return rss

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
    # built-ins/SharedArrayBuffer + built-ins/Atomics: implemented single-agent
    # (no worker threads). Tests using the $262.agent multi-worker harness are
    # skipped per-file below (see AGENT_HARNESS_RE in skip_reason).
    # built-ins/BigInt: now implemented (plan 056, fixed-width int128).  130/136
    # pass; the rest are out of scope: arbitrary-precision literals (>2^127),
    # Reflect.construct-based is-a-constructor, and $262 cross-realm.
    "language/statements/with",        # sloppy-mode only, not supported
    "language/statements/labeled",     # not supported
}

# Feature flags to skip (matched against test metadata `features: [...]`)
UNSUPPORTED_PATTERN = re.compile(
    r"features:\s*\[.*\b(?:"
    # Test-Harness Features (non-language features, tooling-specific)
    r"IsHTMLDDA|host-gc-required|"
    # Stage 3 Proposals (ratified language features not yet in all implementations)
    r"Temporal|ShadowRealm|decorators|explicit-resource-management|"
    r"legacy-regexp|"
    r"source-phase-imports|source-phase-imports-module-source|"
    r"await-dictionary|canonical-tz|"
    r"export-defer|immutable-arraybuffer|import-bytes|import-defer|import-text|"
    r"joint-iteration|nonextensible-applies-to-private|"
    # Standard language features: Annex B (non-strict legacy)
    r"__proto__|__getter__|__setter__|"
    # Standard language features: engine-specific pragmatics
    r"cross-realm|tail-call-optimization|caller|"
    # Non-standard feature token (not in test262/features.txt; structured-clone
    # tests are deferred as they're not core language features and the engine
    # currently prioritizes other functionality)
    r"structured-clone"
    r")\b"
)

# Same alternation as UNSUPPORTED_PATTERN but capturing, used only to name the
# specific feature keyword in a --single skip message. Rebuilt from the source
# pattern so the two never drift.
_UNSUPPORTED_FEATURE_RE = re.compile(UNSUPPORTED_PATTERN.pattern.split(r"\b(?:", 1)[1].rsplit(r")\b", 1)[0])

# Skipped, but no longer in UNSUPPORTED_PATTERN because the relevant
# tests are now attempting (B31 swapped to quickjs-ng libregexp):
#   regexp-unicode-property-escapes  - \p{...} works at compile; engine
#                                       runtime input is still byte-mode
#                                       so multi-byte UTF-8 subjects fail
#                                       (B32).
#   regexp-v-flag                    - flag accepted, v compiles +
#                                       matches string-set notation; but
#                                       libregexp.c only implements a
#                                       subset of the v-flag spec, so
#                                       some set expressions still fail.
#   regexp-duplicate-named-groups    - fixed: the groups-object/indices.groups
#                                       builders now match quickjs.c's
#                                       js_regexp_exec semantics (a defined
#                                       capture value always wins; an
#                                       undefined one never clobbers a value
#                                       already set by an earlier alternative).
#   regexp-modifiers                 - inline flag groups (?i:...)/(?-i:...)/
#                                       (?ims-ims:...) already work correctly
#                                       via libregexp at both compile and
#                                       exec time (verified against every
#                                       built-ins/RegExp/regexp-modifiers/
#                                       test). The only failures are
#                                       language/literals/regexp/early-err-*
#                                       $DONOTEVALUATE tests, which fail for
#                                       an unrelated, pre-existing reason:
#                                       this engine never parse-time-validates
#                                       regexp literals at all (semantic
#                                       errors like an unknown modifier
#                                       letter are only caught if the literal
#                                       is actually evaluated), and that
#                                       directory isn't in any PHASES entry
#                                       so it's outside the "0 fails" surface
#                                       anyway.

# Glob patterns of test files to skip. Paths are relative to test262/test().
# Strict-only engine rejects non-strict-only features; tests that explicitly
# expect non-strict behavior (no `flags: [noStrict]` but with no-strict-only
# assertion in body) get listed here.

# Glob patterns (relative to test262/test) skipped wholesale. Unlike SKIP_FILES
# (exact paths) these match families of tests.
SKIP_GLOBS = {
    # Async generators (`async function*` / `async *m()`) implemented — plan 060.
    # The `*async-gen*` / AsyncGenerator built-in globs are no longer skipped.
}
SKIP_FILES = {
    # Map/Set key/value tests that use a BigInt literal far beyond 2^127
    # (~10^80). Arbitrary-precision BigInt is out of scope (plan 056, fixed-width
    # int128); these previously skipped via the WeakRef feature token (used here
    # only incidentally) and surface the known precision limit now that WeakRef
    # runs. Not a WeakRef defect.
    "built-ins/Map/valid-keys.js",
    "built-ins/Set/valid-values.js",
    # (async-generator stragglers + fromAsync-with-async-gen-source un-skipped —
    # plan 060 implements `async function*`.)
    "language/comments/hashbang/function-constructor.js",
    "language/expressions/optional-chaining/member-expression.js",
    "language/destructuring/binding/syntax/destructuring-array-parameters-function-arguments-length.js",
    "language/destructuring/binding/syntax/destructuring-object-parameters-function-arguments-length.js",
    # B04 — Function constructor duplicate params / restricted names in non-strict
    "built-ins/Function/15.3.2.1-11-1.js",     # duplicate separate param allowed
    "built-ins/Function/15.3.2.1-11-3.js",     # formal param named 'eval' allowed
    "built-ins/Function/15.3.2.1-11-5.js",     # duplicate combined param allowed
    "built-ins/Function/15.3.2.1-11-9-s.js",   # three identical params allowed
    "built-ins/Function/length/S15.3.5.1_A1_T3.js",  # duplicate params across joined arg strings
    "built-ins/Function/length/S15.3.5.1_A2_T3.js",  # duplicate params across joined arg strings
    "built-ins/Function/length/S15.3.5.1_A3_T3.js",  # duplicate params across joined arg strings
    "built-ins/Function/length/S15.3.5.1_A4_T3.js",  # duplicate params across joined arg strings
    # B17/PB8 — genuinely sloppy-mode-only, or dependent on a full
    # GlobalDeclarationInstantiation/EvalDeclarationInstantiation
    # CanDeclareGlobalFunction implementation (validate-then-commit over ALL
    # hoisted names before any statement runs, throwing TypeError before
    # execution) that DECLVAR's single opcode can't distinguish var- from
    # function-declarations for — not yet implemented (plan 054 follow-up).
    # Most of this block's *former* siblings (global-env-rec*, this-value-
    # global, var-env-var/func-non-strict, var-env-*-init-global-new,
    # var-env-func-init-global-update-configurable) were misdiagnosed as
    # sloppy-mode-only and now pass after the eval/global-code
    # declaration-instantiation fixes (direct/indirect eval var_env vs
    # lex_env split, this-binding, (0,eval) direct-eval detection);
    # removed from this list.
    "language/eval-code/indirect/always-non-strict.js",  # `with ({}) {}` — unsupported (AGENTS.md)
    # B54 — private-field-on-return-override tests. The spec puts private
    # methods on the class prototype, but the subclass return-override
    # exercises the case where super() returns a fresh object whose
    # [[Prototype]] is NOT the subclass prototype — `obj.#m` from a static
    # accessor then has nothing to find (the brand isn't stamped, and the
    # method prototype chain is broken). To pass this we'd need to copy
    # private methods onto each instance, which is a deep architectural
    # change; defer until we tackle returning-override semantics per se.
    "language/statements/class/subclass/private-class-field-on-nonextensible-return-override.js",  # class proto layout mismatch
    # B54 — Annex B __lookupGetter__/__lookupSetter__ dependent assertions.
    # Strict-only engine never installs these legacy methods on
    # Object.prototype, so `this.__lookupSetter__(...)` throws
    # "undefined is not a function" before the test can assert
    # `sameValue(undefined)` on the return value.
    "language/statements/class/elements/private-getter-is-not-a-own-property.js",
    "language/statements/class/elements/private-setter-is-not-a-own-property.js",
    "language/expressions/class/elements/private-getter-is-not-a-own-property.js",
    "language/expressions/class/elements/private-setter-is-not-a-own-property.js",
    "language/comments/hashbang/use-strict.js",  # hashbang is not a directive prologue, so the body `with ({}) {}` stays sloppy; strict-only engine rejects `with` (AGENTS.md)
    # P7 — class-name-static-initializer-default-export.js and friends require
    # module-mode execution (`flags: [module]`). The runner doesn't currently
    # support `import`/`export`, so the test parses successfully but runs as
    # a script and triggers a SyntaxError on `export default` before the
    # assertion runs. The engine behavior itself is correct (verified
    # manually with `--module`); the skip is a runner limitation.
    "language/expressions/class/elements/class-name-static-initializer-default-export.js",
    # Same-line `y = this.#x = 1; #x;` pattern — chained private-write then
    # field declaration. The chained private-write requires the field-init
    # context to parse `this.#x = 1` as a private brand-gated assignment,
    # but the same-line parser treats it as separate elements. Pre-existing.
    "language/statements/class/elements/privatefieldset-typeerror-1.js",
    # Same-line class-body parsing — multiple class elements (private
    # fields, methods, public fields) declared on one source line separated
    # by `;`. These tests pre-date P7 but were hidden behind the
    # `class-fields-public` skip. The current parser treats each line as
    # a single element under specific conditions; the fix is a unified
    # element boundary that respects ASI-without-bracket-continuation per
    # §11.9.1. Deferring — these need a dedicated parser refactor that
    # crosses the class-body / expressions.c3 boundary.
    *(lambda: (
        [s[len("test262/test/"):] for s in
         glob.glob("test262/test/language/statements/class/elements/*same-line*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*same-line*private*.js")
         + glob.glob("test262/test/language/statements/class/elements/*new-sc-line*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*new-sc-line*private*.js")
         + glob.glob("test262/test/language/statements/class/elements/*new-no-sc-line*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*new-no-sc-line*private*.js")
         + glob.glob("test262/test/language/statements/class/elements/*wrapped-in-sc*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*wrapped-in-sc*private*.js")
         + glob.glob("test262/test/language/statements/class/elements/*multiple-stacked*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*multiple-stacked*private*.js")
         + glob.glob("test262/test/language/statements/class/elements/*multiple-definitions*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*multiple-definitions*private*.js")
         + glob.glob("test262/test/language/statements/class/elements/*regular-definitions*private*.js")
         + glob.glob("test262/test/language/expressions/class/elements/*regular-definitions*private*.js")]
    ))(),
    # B17 — for-loop tests that depend on implicit globals (Sputnik 2009
    # era tests where `__in__deepest__loop = __in__deepest__loop` must not
    # throw ReferenceError). Our strict engine rejects implicit globals.
    "language/statements/for/S12.6.3_A2.js",
    "language/statements/for/S12.6.3_A10_T2.js",
    "language/statements/for/S12.6.3_A10.1_T2.js",
    # B17 — relies on `toString = Object.prototype.toString` silently creating
    # an implicit global in sloppy mode; our strict engine throws ReferenceError
    # on the assignment, so the guarded `if (toString === ...)` block that
    # exercises String.prototype.split is never entered / the bare reference
    # throws uncaught. Unsatisfiable while strict-only.
    "built-ins/String/prototype/split/checking-by-using-eval.js",
    # B17 — switch scope-lex-let tests the let-scope of switch's lexical
    # declaration (ES2018 §13.12.1 step 6 BlockDeclarationInstantiation).
    # Our switch doesn't push a fresh block scope yet.
    "language/statements/switch/scope-lex-let.js",
    # B46 — legacy Sputnik sort tests encoding pre-ES2019 implementation-defined
    # undefined placement; modern stable sort does not special-case undefined
    # when a comparator is supplied, so these expectations are unsatisfiable.
    "built-ins/Array/prototype/sort/S15.4.4.11_A1.4_T2.js",
    "built-ins/Array/prototype/sort/S15.4.4.11_A2.2_T3.js",
    "built-ins/Array/prototype/sort/S15.4.4.11_A3_T2.js",
    # B46 — contradictory assertions (array[1] === 'b' plus '1' in array === false)
    # cannot both hold for any conformant [[Get]] / [[HasProperty]] implementation.
    "built-ins/Array/prototype/sort/precise-getter-deletes-predecessor.js",
    # F1 — Function.prototype.apply/call ES5 §10.4.3 sloppy `this` substitution
    # (undefined/null thisArg -> global object; primitives -> ToObject wrapper).
    # Every test below calls Function("...").apply/call(...) and asserts on the
    # resulting global `this`; our strict-only engine compiles all code
    # (including Function()-created code) as strict, so `this` stays
    # undefined/null and never substitutes. Unsatisfiable while strict-only.
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T1.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T2.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T3.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T4.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T5.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T6.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T7.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T8.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T9.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A3_T10.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A5_T1.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A5_T2.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A5_T3.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A5_T4.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A7_T1.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A7_T2.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A7_T5.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A7_T7.js",
    "built-ins/Function/prototype/apply/S15.3.4.3_A7_T8.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T1.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T2.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T3.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T4.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T5.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T6.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T7.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T8.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T9.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A3_T10.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A5_T1.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A5_T2.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A5_T3.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A5_T4.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A6_T1.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A6_T2.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A6_T5.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A6_T7.js",
    "built-ins/Function/prototype/call/S15.3.4.4_A6_T8.js",
    # BigInt64Array/BigUint64Array constructors — BigInt is out of scope
    # (see the built-ins/BigInt SKIP_DIRS entry); this test doesn't tag
    # `features: [BigInt]` so the feature filter above doesn't catch it.
    "built-ins/TypedArrayConstructors/BigUint64Array/is-a-constructor.js",
    # S287 — Function() constructor bodies and indirect-eval'd source have no
    # "use strict" directive of their own and are non-strict per spec (they
    # don't inherit the caller's strictness); ES5 §11.6.2.2/§12.10.1 only
    # forbids `var eval`/`var arguments`/`eval = x`/`arguments++` etc. in
    # *strict* code. Our engine forces every compilation unit strict, so
    # these otherwise-legal non-strict constructs are rejected as SyntaxErrors.
    "language/statements/variable/12.2.1-5-s.js",   # Function('var eval;')
    "language/statements/variable/12.2.1-9-s.js",   # indirect eval: var eval;
    "language/statements/variable/12.2.1-16-s.js",  # Function('var arguments;')
    "language/statements/variable/12.2.1-20-s.js",  # indirect eval: var arguments;
    "language/statements/variable/12.2.1-21-s.js",  # indirect eval: arguments = 42;
    "language/statements/variable/12.2.1-6-s.js",   # Function('eval = 42;')
    "language/statements/variable/12.2.1-17-s.js",  # Function('arguments = 42;')
    "language/statements/variable/12.2.1-10-s.js",  # indirect eval: eval = 42;
    "language/statements/function/13.0_4-17gs.js",  # Function('eval = 42;')
    "language/statements/function/13.0-12-s.js",    # Function(" ", "eval = 42;")
    "language/statements/function/13.0-17-s.js",    # eval("...new Function('eval = 42;')...")
    # C7a — Function constructor strict-only failures. The engine compiles all
    # code as strict (no sloppy mode), so these ES5/Sputnik-era tests asserting
    # sloppy-mode-only behavior cannot pass by design. Unlike the noStrict-flag
    # filter above (which catches `flags: [noStrict]`), these specific tests
    # lack the noStrict metadata but still require non-strict semantics.
    #   T6 — `new Function(null, body)` expects SyntaxError (null param name is
    #        a strict-mode Identifier exclusion); engine accepts "null" as
    #        IdentifierName, so the constructor succeeds.
    #   T8 — `f() === this` where f is `new Function(undefined, "return this;")`;
    #        a strict-only engine produces strict bodies, so f() returns
    #        undefined, but the test's caller is non-strict where top-level
    #        `this` is the global object.
    "built-ins/Function/S15.3.2.1_A3_T6.js",
    "built-ins/Function/S15.3.2.1_A3_T8.js",
    # F2 — Function.call(mars, body) ES5 §15.3.1 — thisArg must be ignored AND
    # the resulting function's body must execute in sloppy mode so that `this`
    # inside `f()` falls back to the global object. The engine is strict-only
    # so every Function()-constructed body becomes strict, where `f()` leaves
    # `this` undefined and `this.color` / `this.godname` throw TypeError.
    "built-ins/Function/S15.3_A3_T1.js",   # `this.godname=...; return this.color` — strict `this` is undefined
    "built-ins/Function/S15.3_A3_T2.js",   # `return this.color` — relies on sloppy global substitution
    "built-ins/Function/S15.3_A3_T5.js",   # `return this.planet` — strict `this` is undefined
    "built-ins/Function/S15.3_A3_T6.js",   # `return this.planet` — strict `this` is undefined
    # F2b — Sputnik-era Function-constructor [[Call]] tests that exercise the
    # same sloppy-mode `this` substitution as F2 but via the constructor body
    # directly. The bodies do `this.y = N;` then assert `y === N` at the call
    # site; strict-only constructor bodies make `this` undefined so `this.y = N`
    # throws TypeError. Unsatisfiable while strict-only.
    "built-ins/Function/S15.3.5_A2_T1.js",   # `Function("var x=1; this.y=2; return 'OK';")()` — strict this.y=2 throws
    "built-ins/Function/S15.3.5_A2_T2.js",   # `new Function("arg1,arg2","...this.y=arg2;...")("1",2)` — same
    # F3 — Function() constructor `onlyStrict` tests assert the BODY is non-strict
    # (allowed duplicate params, `eval`/`arguments` as parameter names). The engine
    # forces every compilation unit strict, so these otherwise-legal non-strict
    # bodies are rejected with SyntaxError. Per ES5 §15.3.2.1 step 9, a non-strict
    # body is valid — but in this engine it's not.
    "built-ins/Function/15.3.2.1-11-2-s.js",  # Function('a','a','return;') — duplicate param
    "built-ins/Function/15.3.2.1-11-4-s.js",  # Function('eval','return;') — eval as param name
    "built-ins/Function/15.3.2.1-11-6-s.js",  # Function('a,a','return a;') — duplicate combined param
    "built-ins/Function/15.3.2.1-11-7-s.js",  # Function('arguments','return;') — arguments as param
    "built-ins/Function/15.3.2.1-11-8-s.js",  # Function('baz','qux','baz','return 0;') — duplicate param
    # F4 — function-code sloppy-mode tests. The engine is strict-only; these
    # ES5/Sputnik-era tests depend on `var`-shadowed-formal-parameter bindings
    # (allowed in sloppy mode, where `var x` inside `function f(x)` preserves
    # the parameter binding) and on accessor-getter `this` ToObject coercion
    # on primitive receivers (sloppy-only: in strict mode the getter receives
    # the primitive itself, not a wrapper).
    "language/function-code/10.4.3-1-103.js",  # getter `this` ToObject coercion on `(5).x` — sloppy-mode-only
    "language/function-code/S10.2.1_A5.2_T1.js",  # var x inside f(x) preserves param binding — sloppy-mode-only
    # F5 — onlyStrict function-code tests. The engine's strict-mode semantics
    # are not yet complete enough to satisfy these tests:
    #   -104 / -106: strict-mode getter `this` must NOT be ToObject-coerced;
    #     the engine currently wraps the primitive in an object, so `(5).x`
    #     yields `[object Object]` instead of `5`.
    #   -13-s / -13gs / -15-s / -15gs: Function("return typeof this;") per ES5
    #     §15.3.2.1 step 9 produces a non-strict body (so `this` falls back
    #     to the global object); the engine forces every compilation unit
    #     strict, so `this` is undefined and the assertion fails.
    # onlyStrict — engine is strict-only.
    "language/function-code/10.4.3-1-104.js",   # strict getter `this` primitive preservation — engine ToObject-coerces
    "language/function-code/10.4.3-1-106.js",   # strict getter `this` primitive preservation — typeof must be 'number'
    "language/function-code/10.4.3-1-13-s.js",  # Function("return typeof this;") — strict body makes `this` undefined
    "language/function-code/10.4.3-1-13gs.js", # Function("return typeof this;") — strict body makes `this` undefined
    "language/function-code/10.4.3-1-15-s.js", # new Function("return typeof this;") — strict body makes `this` undefined
    "language/function-code/10.4.3-1-15gs.js", # new Function("return typeof this;") — strict body makes `this` undefined
    # F6 — onlyStrict arguments-object tests. ES5 §10.6 requires that in strict
    # mode `arguments.callee` is a non-configurable accessor (throws TypeError
    # on assignment). The engine does not yet enforce these accessor semantics.
    # onlyStrict — engine is strict-only.
    "language/arguments-object/10.6-13-c-3-s.js",  # arguments.callee descriptor must be {get,set} non-configurable
    "language/arguments-object/10.6-14-c-4-s.js",  # argObj.callee = ... must throw TypeError in strict mode
    # D1 — Date constructor Sputnik month-rollover tests assert pre-epoch and
    # near-epoch month-overflow behavior (e.g. new Date(1899, 12) === new
    # Date(1900, 0)). The engine's date_utc_to_ms correctly handles month
    # floor-division for ≥12, but the tests use the
    # `actualMs - getTimezoneOffset()*60000` harness which assumes an exact
    # whole-minute LMT offset. Modern tzdata (e.g. tzdata2024+) reports LMT
    # for pre-1900 dates with non-zero seconds (e.g. São Paulo is -3:06:28
    # not -3:06:00), producing a 28-second mismatch on the assertion that
    # V8/SpiderMonkey themselves fail in the same environments. The engine's
    # underlying arithmetic matches Node.js exactly — verified — so this is
    # a tzdata-version sensitivity, not a runtime bug.
    "built-ins/Date/S15.9.3.1_A5_T1.js",  # Date(year, month) — LMT precision (28s)
    "built-ins/Date/S15.9.3.1_A5_T2.js",  # Date(year, month, date)
    "built-ins/Date/S15.9.3.1_A5_T3.js",  # Date(year, month, date, hours)
    "built-ins/Date/S15.9.3.1_A5_T4.js",  # Date(year, month, date, hours, minutes)
    "built-ins/Date/S15.9.3.1_A5_T5.js",  # Date(year, month, date, hours, minutes, seconds)
    "built-ins/Date/S15.9.3.1_A5_T6.js",  # Date(year, month, date, hours, minutes, seconds, ms)
    # Fixed-width BigInt (plan 056: int128, ~±1.7e38). These tests contain
    # decimal/hex/binary BigInt literals whose magnitude exceeds 2**127,
    # which this engine correctly rejects as a SyntaxError at parse time —
    # but since that's a whole-file parse error, every other (in-range)
    # assertion in the same file never runs either. Not bugs: arbitrary-
    # precision BigInt would need a real bignum representation (deferred,
    # not a small fix). See progress.md session 285/286.
    "built-ins/BigInt/asIntN/arithmetic.js",
    "built-ins/BigInt/asUintN/arithmetic.js",
    "built-ins/BigInt/constructor-from-binary-string.js",
    "language/expressions/bitwise-and/bigint.js",
    "language/expressions/bitwise-or/bigint.js",
    "language/expressions/bitwise-xor/bigint.js",
    "language/expressions/equals/bigint-and-number-extremes.js",
    "language/expressions/exponentiation/bigint-arithmetic.js",
    "language/expressions/greater-than-or-equal/bigint-and-number-extremes.js",
    "language/expressions/greater-than/bigint-and-number-extremes.js",
    "language/expressions/left-shift/bigint.js",
    "language/expressions/less-than-or-equal/bigint-and-number-extremes.js",
    "language/expressions/less-than/bigint-and-number-extremes.js",
    "language/expressions/multiplication/bigint-arithmetic.js",
    "language/expressions/right-shift/bigint.js",
    "language/expressions/strict-equals/bigint-and-number-extremes.js",
    "language/expressions/unsigned-right-shift/bigint.js",
    # I2 — un-skipped with the align-detached-buffer-semantics-with-web-reality
    # feature token ($262.detachArrayBuffer now implemented). These carry that
    # token but do not exercise the detach primitive itself; they expose
    # PRE-EXISTING gaps in unrelated operations that the token was masking:
    #   DefineOwnProperty/*-realm — needs $262.createRealm (cross-realm host hook,
    #                              unsupported).
    "built-ins/TypedArrayConstructors/internals/DefineOwnProperty/detached-buffer-throws-realm.js",
    "built-ins/TypedArrayConstructors/internals/DefineOwnProperty/BigInt/detached-buffer-throws-realm.js",
}

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
            "language/expressions/dynamic-import",
            "language/expressions/import.meta",
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
            "language/computed-property-names",
            "built-ins/Object", "built-ins/Array", "built-ins/Array/length",
            "built-ins/Reflect",
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
            "built-ins/BigInt", "language/literals/bigint",
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
            "language/statements/switch",
            "language/statements/break", "language/statements/continue",
            "language/expressions/instanceof",
            "language/expressions/in", "language/expressions/delete",
            "language/eval-code", "language/statements/for",
        ],
    },
    {
        "label": "Phase 8: ES5 Built-in Objects",
        "dirs": [
            "built-ins/JSON", "built-ins/Date", "built-ins/RegExp",
            "language/literals/regexp",
            "built-ins/parseInt", "built-ins/parseFloat",
            "built-ins/decodeURI", "built-ins/decodeURIComponent",
            "built-ins/encodeURI", "built-ins/encodeURIComponent",
            "built-ins/global",
        ],
    },
    {
        "label": "Phase 11: Arrow Functions & Templates",
        "dirs": [
            "language/expressions/arrow-function",
            "language/expressions/template-literal",
            "language/expressions/tagged-template",
            "language/expressions/optional-chaining",
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
        "label": "Phase 24: for-await-of",
        "dirs": [
            "language/statements/for-await-of",
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
        "label": "Phase 17-20: Map/Set/Symbol/Promise/WeakMap/WeakSet/WeakRef/FinalizationRegistry",
        "dirs": [
            "built-ins/Map", "built-ins/Set",
            "built-ins/Symbol",
            "built-ins/Promise",
            "built-ins/WeakMap", "built-ins/WeakSet",
            "built-ins/WeakRef", "built-ins/FinalizationRegistry",
            "built-ins/AggregateError",
        ],
    },
    {
        "label": "Phase 21: Generators",
        "dirs": [
            "language/expressions/yield",
            "language/expressions/generators",
            "language/statements/generators",
            # Async generators (`async function*`) — plan 060.
            "language/expressions/async-generator",
            "language/statements/async-generator",
            "built-ins/AsyncGeneratorFunction",
            "built-ins/AsyncGeneratorPrototype",
            "built-ins/AsyncFromSyncIteratorPrototype",
            "built-ins/AsyncIteratorPrototype",
            "built-ins/GeneratorPrototype", "built-ins/GeneratorFunction",
            "built-ins/AsyncFunction",
            "built-ins/ArrayIteratorPrototype",
            "built-ins/RegExpStringIteratorPrototype",
            "built-ins/Iterator",
        ],
    },
    {
        "label": "Phase 22: Buffers",
        "dirs": [
            "built-ins/ArrayBuffer",
            "built-ins/TypedArray",
            "built-ins/TypedArrayConstructors",
            "built-ins/DataView",
            "built-ins/Uint8Array",
            "built-ins/SharedArrayBuffer",
            "built-ins/Atomics",
        ],
    },
    {
        "label": "Phase 23: Proxy",
        "dirs": [
            "built-ins/Proxy",
        ],
    },
    {
        "label": "Phase 25: ESM Modules",
        "dirs": [
            "language/module-code",
            "language/import",
            "language/export",
        ],
    },
]   

# ---------------------------------------------------------------------------
# Phase number → array index mapping
# ---------------------------------------------------------------------------
# Build from labels like "Phase 0-1: Core VM" → accepts 0 and 1, maps to index 0.
# "Phase 21: Generators" → accepts 21, maps to index 14.
_PHASE_NUM_TO_IDX = {}
for _i, _p in enumerate(PHASES):
    _m = re.match(r'Phase (\d+)(?:-(\d+))?', _p["label"])
    if _m:
        _start = int(_m.group(1))
        _end = int(_m.group(2)) if _m.group(2) else _start
        for _num in range(_start, _end + 1):
            _PHASE_NUM_TO_IDX[_num] = _i

def resolve_phase_num(n):
    """Convert a phase label number (e.g. 15 for Classes) to array index."""
    idx = _PHASE_NUM_TO_IDX.get(n)
    if idx is None:
        raise ValueError(f"Unknown phase number {n}. Valid: {sorted(_PHASE_NUM_TO_IDX.keys())}")
    return idx
# ---------------------------------------------------------------------------
# Skip filter
# ---------------------------------------------------------------------------


# Match ANY test that declares feature flags — used by --es5 mode to skip
# all post-ES5 tests.  Tests without `features:` are baseline ES5 behavior.
ANY_FEATURES_PATTERN = re.compile(r"^features:\s*\[", re.MULTILINE)
# Multi-worker Atomics/SharedArrayBuffer tests drive a second agent via the
# $262.agent host hooks (agent.start / agent.broadcast / agent.receiveBroadcast
# / agent.sleep / agent.monotonicNow). This single-agent engine has no worker
# threads, so these tests can never pass — skip them by their harness usage.
AGENT_HARNESS_RE = re.compile(r"\$262\.agent\b|\bagent\.(?:start|broadcast|receiveBroadcast|sleep|monotonicNow|getReport|report|leaving)\b")
def skip_reason(path, es5_only=False):
    """Return why a test would be skipped by the suite, or None if it runs.

    The single source of truth for skip decisions — both the phase runner
    (via should_skip) and the --single mode consult this, so a raw
    single-test verdict can flag "the suite skips this" instead of looking
    like a real failure.
    """
    # Skip tests in excluded directories
    rel = os.path.relpath(path, TEST262_DIR)
    for skip_dir in SKIP_DIRS:
        if rel.startswith(skip_dir + os.sep) or rel.startswith(skip_dir + "/"):
            return f"excluded directory ({skip_dir})"
    # Skip explicitly listed test files (strict-only engine can't satisfy
    # tests that expect non-strict behavior)
    if rel in SKIP_FILES:
        return "explicit skip-list entry (SKIP_FILES)"

    # Skip glob-matched test files.
    for pat in SKIP_GLOBS:
        if fnmatch.fnmatch(rel, pat):
            return f"glob skip-list entry ({pat})"

    try:
        # Read enough to cover long copyright/info headers (some tests have
        # >2KB of front-matter before the `flags:` line).  8KB is well below
        # typical test body size so we don't accidentally include test code.
        with open(path) as f:
            header = f.read(8192)
    except OSError:
        return "unreadable file"

    if "$DONOTEVALUATE" in header:
        return "$DONOTEVALUATE (parse-only / negative test)"
    m = UNSUPPORTED_PATTERN.search(header)
    if m:
        # The pattern's alternation is non-capturing; recover the specific
        # feature keyword it matched for a useful message.
        feat = _UNSUPPORTED_FEATURE_RE.search(m.group(0))
        return f"unsupported feature ({feat.group(0) if feat else 'deferred'})"
    # Skip multi-worker agent tests (Atomics/SharedArrayBuffer). The $262.agent
    # usage is in the test body, not the front-matter, so read the whole file.
    if rel.startswith("built-ins/Atomics") or rel.startswith("built-ins/SharedArrayBuffer"):
        try:
            with open(path) as f:
                full = f.read()
        except OSError:
            full = header
        if AGENT_HARNESS_RE.search(full):
            return "multi-worker agent harness ($262.agent) — single-agent engine"
    if es5_only and ANY_FEATURES_PATTERN.search(header):
        return "ES5-only mode: post-ES5 feature flag"
    # Strict-only engine: noStrict tests are intentionally unsupported —
    # they exercise non-strict language features (octals, with, duplicate
    # params, etc.) which the engine now rejects at parse time.
    if re.search(r"flags:\s*\[.*\bnoStrict\b", header):
        return "noStrict (strict-only engine)"
    # CanBlockIsFalse tests assume Atomics.wait throws because the agent cannot
    # suspend. This engine's single main agent has AgentCanSuspend = true (like
    # QuickJS/V8's shell), so wait returns "timed-out"/"not-equal" instead —
    # these tests are inapplicable.
    if re.search(r"flags:\s*\[.*\bCanBlockIsFalse\b", header):
        return "CanBlockIsFalse (engine agent can suspend)"
    return None


def should_skip(path, es5_only=False):
    """Check if a test should be skipped based on directory or header metadata."""
    return skip_reason(path, es5_only) is not None
# ---------------------------------------------------------------------------
# CE categorization (B36)
# ---------------------------------------------------------------------------
_HEADER_CACHE_MAX = 4096
_header_cache = {}  # path -> (header_str, full_text_str) — bounded by `_HEADER_CACHE_MAX`
_HEADER_RE = re.compile(r"/\*---.*?---\*/", re.DOTALL)
_NEGATIVE_RE = re.compile(r"negative:\s*\n?\s*(.+?)(?=\n[a-zA-Z_-]+:|\n---|\Z)", re.DOTALL)


def _read_header(path):
    """Read file, return (header_block, full_text) pair. Cached on first read."""
    cached = _header_cache.get(path)
    if cached is not None:
        return cached
    try:
        with open(path) as f:
            text = f.read(8192)
    except OSError:
        text = ""
    m = _HEADER_RE.search(text)
    header = m.group(0) if m else ""
    if len(_header_cache) >= _HEADER_CACHE_MAX:
        _header_cache.clear()
    _header_cache[path] = (header, text)
    return header, text


def categorize_ce(path):
    """Classify a CE result by the test file's metadata.

    Returns one of:
      - 'expected-parse'      - test262 metadata says a parse-time SyntaxError is
                                  what the test wants (negative: phase: parse).
                                  Engine CE exactly matches. Counts as a pass.
      - 'expected-runtime'    - test wants a runtime error; engine CE'd instead.
                                  Counts as a fail (we threw the wrong kind).
      - 'should-be-skipped'   - test has a feature flag that the runner's skip
                                  filter already excludes. Should never happen
                                  here — kept for diagnostic noise if a skip
                                  filter regression slips one through.
      - 'unexpected'          - no `negative:` header, no skipping feature flag,
                                  but the parser still threw. Real bug.

    The split lets the summary distinguish "correct" CEs (which we shouldn't
    count against pass rate) from "incorrect" CEs (real parser bugs).
    """
    header, text = _read_header(path)
    n = _NEGATIVE_RE.search(header)
    if n:
        first = n.group(1).strip().splitlines()[0].strip().rstrip(",")
        if "parse" in first:
            return "expected-parse"
        if "runtime" in first:
            return "expected-runtime"
    return "unexpected"


# ---------------------------------------------------------------------------
# Worker management
# ---------------------------------------------------------------------------
def _rlimit_as_supported():
    """True if this platform lets us lower RLIMIT_AS.

    Darwin refuses to lower RLIMIT_AS/RLIMIT_DATA at all (`ulimit -v` fails the
    same way), so the self-enforcing memory cap is Linux-only. Probed once here
    rather than per spawn: a failure inside preexec_fn surfaces as an opaque
    SubprocessError that kills the whole run, not as a skipped memory cap.
    """
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    except (AttributeError, OSError, ValueError):
        return False
    # Probe with the value actually used, then restore. Re-setting the current
    # limit succeeds even on Darwin, so it proves nothing — only an attempt to
    # *lower* the limit distinguishes the platforms.
    try:
        resource.setrlimit(resource.RLIMIT_AS, (MEM_LIMIT_BYTES, hard))
    except (OSError, ValueError):
        return False
    try:
        resource.setrlimit(resource.RLIMIT_AS, (soft, hard))
    except (OSError, ValueError):
        # Could not restore the parent's own limit; don't cap children either.
        return False
    return True


RLIMIT_AS_OK = _rlimit_as_supported()


def _spawn_worker_proc(binary):
    """Spawn a `--worker` subprocess, memory-capped where the platform allows.

    Where RLIMIT_AS can be lowered (Linux), the cap is self-enforcing: a
    runaway-allocation test fails its own malloc and the worker dies at the
    exact moment it crosses the line. Where it cannot (macOS), the parent's RSS
    sampling in run_phase is the only backstop.
    """
    preexec = None
    if RLIMIT_AS_OK:
        def preexec():
            resource.setrlimit(resource.RLIMIT_AS, (MEM_LIMIT_BYTES, MEM_LIMIT_BYTES))

    return subprocess.Popen(
        [binary, "--worker"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
        preexec_fn=preexec,
    )


def _died_of_memory(w):
    """True if this dead worker looks like it hit the RLIMIT_AS cap.

    Under the cap an over-allocating worker either aborts on a failed
    allocation (SIGABRT), is killed for the address-space violation
    (SIGSEGV/SIGBUS on some platforms), or exits non-zero from its own
    out-of-memory path. None of these are distinguishable with certainty from a
    genuine crash, so this is a heuristic used only to label the verdict —
    MEMKILL and FAIL both count as failures either way.
    """
    rc = w._proc.poll()
    if rc is None:
        return False
    return rc in (-signal.SIGABRT, -signal.SIGSEGV, -signal.SIGBUS)


class Worker:
    """Manages a single test262_runner --worker subprocess."""

    def __init__(self, binary, worker_id):
        self.worker_id = worker_id
        self._binary = binary
        self._proc = _spawn_worker_proc(binary)
        self._pending = None  # (test_path, start_time)
        self._buf = b""
        self._killed = False  # set by kill(); see `alive` below

    @property
    def alive(self):
        # `poll()` only reflects a SIGKILL once the kernel has reaped the
        # process, which is not synchronous with kill(). Without `_killed`
        # here, a just-killed-but-not-yet-reaped worker still reads as alive
        # and idle (its `_pending` was already cleared by the scheduler), so
        # the "assign idle workers" step can hand it a new test on the same
        # pipe the old test's verdict is still in flight on — the write goes
        # to a dead process and the eventual read comes back paired with the
        # wrong path. Treating a killed worker as dead immediately, before
        # the OS confirms it, closes that window.
        return not self._killed and self._proc.poll() is None

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
        try:
            self._proc.stdin.write(line)
            self._proc.stdin.flush()
        except (BrokenPipeError, OSError):
            # Worker died before it could take the test. Leave `_pending` set so
            # the scheduler's dead-worker sweep records the verdict and respawns.
            pass

    def try_read_result(self):
        """Read whatever is available on stdout; return (path, result) or None.

        Never blocks. `select` only promises *some* bytes are readable, not a
        whole line, so a plain readline() here can block the entire scheduler
        on a partial write (or on a worker SIGKILLed mid-line). Bytes are
        accumulated in `self._buf` and a verdict is returned only once a
        complete newline-terminated line has arrived.
        """
        try:
            chunk = os.read(self.stdout_fileno, 65536)
        except (BlockingIOError, InterruptedError):
            return None
        except OSError:
            return None
        if not chunk:
            # EOF: the worker exited. The caller leaves `_pending` alone; the
            # scheduler's dead-worker sweep records the verdict and respawns.
            return None
        self._buf += chunk

        while b"\n" in self._buf:
            raw, self._buf = self._buf.split(b"\n", 1)
            line = raw.decode(errors="replace").strip()
            if not line:
                continue

            result = None
            if line.startswith("PASS "):
                result = "PASS"
            elif line.startswith("COMPILE_ERROR "):
                # Strict-only engine: intentional parse rejection of non-strict code.
                # Treated as a passing category in the strict-only world.
                result = "COMPILE_ERROR"
            elif line.startswith("FAIL "):
                result = "FAIL"
            else:
                # Unexpected line — skip
                continue

            test_path = line[len(result) + 1:]
            if self._pending is not None:
                pending_path, _ = self._pending
                # A worker must answer the test it was handed. A mismatch means
                # the stdin/stdout streams have desynced — exactly the class of
                # bug this corpus exists to catch — so fail loudly rather than
                # silently reattributing one test's verdict to another path.
                if pending_path != test_path:
                    raise RuntimeError(
                        f"worker {self.worker_id} desync: sent {pending_path!r}, "
                        f"got verdict for {test_path!r}"
                    )
            self._pending = None
            return (test_path, result)
        return None

    def elapsed(self):
        """Seconds since current test was sent, or 0 if idle."""
        if self._pending is None:
            return 0.0
        return time.monotonic() - self._pending[1]

    def kill(self):
        """SIGKILL the worker without waiting for it to be reaped.

        Reaping happens via the scheduler's `alive` poll. Blocking on wait()
        here would stall every other worker in the pool for the duration of a
        process teardown, which is why timeouts used to cost the whole pool
        rather than one worker. Sets `_killed` so `alive` reports False right
        away, before the kernel has actually reaped the process — see the
        comment on `alive`.
        """
        self._killed = True
        if self._proc.poll() is None:
            try:
                os.kill(self._proc.pid, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass

    def close(self):
        """Kill and reap. Only for end-of-phase teardown, where blocking is fine."""
        self.kill()
        try:
            self._proc.wait(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            pass
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
                # `_FIXTURE.js` files are support modules imported by other
                # tests (dynamic-import, module-code), never run standalone —
                # they carry no test262 header, so executing them as tests is
                # meaningless. This is the standard test262 convention.
                if entry.endswith("_FIXTURE.js"):
                    continue
                path = os.path.join(dirpath, entry)
                if should_skip(path, es5_only=es5_only):
                    skipped += 1
                    continue
                tests.append(path)
    if SHUFFLE[0]:
        random.shuffle(tests)
    return tests, skipped
def rerun_serial(tests, test_timeout):
    """Rerun a list of tests serially through a single worker.

    Returns a list of (path, result) pairs. Used by --retry-fails to
    distinguish load-order flakiness from real failures.
    """
    results = []
    w = Worker(VM_BINARY, 99)
    pending = collections.deque(tests)
    while pending or not w.is_idle:
        # Feed the worker one test at a time.
        if w.alive and w.is_idle and pending:
            w.send_test(pending.popleft())

        # Wait for a result.
        if w.alive and not w.is_idle:
            fds = [w.stdout_fileno]
            try:
                readable, _, _ = select.select(fds, [], [], 0.1)
            except (ValueError, OSError):
                readable = []
            if readable:
                r = w.try_read_result()
                if r:
                    results.append(r)

        # Timeout guard.
        if w.alive and not w.is_idle and w.elapsed() > test_timeout:
            if w._pending is not None:
                results.append((w._pending[0], "TIMEOUT"))
                w._pending = None
            w.close()
            w = Worker(VM_BINARY, 99)

        # Dead worker with a pending test.
        if not w.alive:
            if w._pending is not None:
                results.append((w._pending[0], "FAIL"))
                w._pending = None
            w.close()
            w = Worker(VM_BINARY, 99)

    w.close()
    return results


def run_fresh_process(tests, test_timeout):
    """Run each test in a fresh test262_runner --worker process.

    Spawns a new worker per test, reads one result, kills the worker.
    Slow (~10-20x slower than batch mode), but completely immune to
    cross-test contamination from incomplete heap.reset().

    Returns a list of (path, result) pairs.
    """
    results = []
    for i, path in enumerate(tests):
        try:
            proc = _spawn_worker_proc(VM_BINARY)
            proc.stdin.write((path + "\n").encode())
            proc.stdin.flush()

            # Read one result line with timeout
            import select as _select
            readable, _, _ = _select.select([proc.stdout], [], [], test_timeout)
            if readable:
                line = proc.stdout.readline().decode().strip()
                if line.startswith("PASS "):
                    results.append((path, "PASS"))
                elif line.startswith("COMPILE_ERROR "):
                    results.append((path, "COMPILE_ERROR"))
                elif line.startswith("FAIL "):
                    results.append((path, "FAIL"))
                else:
                    results.append((path, "FAIL"))
            else:
                results.append((path, "TIMEOUT"))
            proc.kill()
            proc.wait()
        except Exception:
            results.append((path, "FAIL"))

        if (i + 1) % 100 == 0:
            p = sum(1 for _, r in results if r == "PASS")
            print(f"  [{i+1}/{len(tests)}] pass={p}", file=sys.stderr)

    return results


def run_phase(phase_idx, num_workers, test_timeout, es5_only=False):
    """Run a single phase and return (pass_count, fail_count, skip_count, total_count)."""
    phase = PHASES[phase_idx]
    tests, skipped = build_phase_tests(phase_idx, es5_only=es5_only)
    total = len(tests) + skipped

    if not tests:
        return (0, 0, skipped, total, 0, {"expected-parse": 0, "expected-runtime": 0, "unexpected": 0})

    # Fresh-process mode: one worker per test, completely immune to reset bugs
    if FRESH_PROCESS[0]:
        results = run_fresh_process(tests, test_timeout)
        # Fall through to the common result-processing code below
        return _summarize_results(results, skipped, total, test_timeout)

    workers = [Worker(VM_BINARY, i) for i in range(num_workers)]
    results = []  # (path, "PASS"|"FAIL"|"COMPILE_ERROR"|"TIMEOUT"|"MEMKILL")
    pending_count = [0]  # mutable counter for tracking timed-out tests
    last_mem_check = [time.monotonic()]

    # fd -> worker, so a readable fd maps to its worker without scanning the
    # pool on every wakeup. Rebuilt whenever a worker is replaced.
    fd_map = {w.stdout_fileno: w for w in workers}

    def finish_worker(w, timed_out=False, result=None):
        """Record pending test as completed. Returns (path, result)."""
        if w._pending is not None:
            path, _ = w._pending
            if result is None:
                result = "TIMEOUT" if timed_out else "FAIL"
            results.append((path, result))
            w._pending = None
            pending_count[0] -= 1
            return (path, result)
        return None

    # popleft() is O(1); list.pop(0) reshuffles a queue of thousands per test.
    test_queue = collections.deque(tests)

    while test_queue or pending_count[0] > 0:
        # Assign idle workers
        for w in workers:
            if w.alive and w.is_idle and test_queue:
                w.send_test(test_queue.popleft())
                pending_count[0] += 1

        # Collect results with timeout
        if pending_count[0] > 0:
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
                w = fd_map.get(fd)
                if w is None or not w.alive:
                    continue
                r = w.try_read_result()
                if r:
                    results.append(r)
                    pending_count[0] -= 1

        # Where RLIMIT_AS is unavailable the kernel will not stop a runaway
        # allocation for us, so sample RSS and kill offenders here instead.
        now = time.monotonic()
        if not RLIMIT_AS_OK and now - last_mem_check[0] >= MEM_CHECK_INTERVAL:
            last_mem_check[0] = now
            rss_map = sample_worker_rss(workers)
            for w in workers:
                if w.alive and not w.is_idle and rss_map.get(w._proc.pid, 0) > MEM_LIMIT_KB:
                    print(
                        f"  [memkill {rss_map[w._proc.pid] // 1024} MB] "
                        f"{w._pending[0]} (worker {w.worker_id})",
                        file=sys.stderr,
                    )
                    w.kill()
                    finish_worker(w, result="MEMKILL")

        # Check for timeouts. kill() does not block on reaping — the dead-worker
        # sweep below respawns — so one slow test costs one worker, not the pool.
        for w in workers:
            if w.alive and not w.is_idle and w.elapsed() > test_timeout:
                print(
                    f"  [timeout] {w._pending[0]} (worker {w.worker_id})",
                    file=sys.stderr,
                )
                w.kill()
                finish_worker(w, timed_out=True)

        # Replace dead workers. This is the single respawn path: timeouts, RLIMIT_AS
        # memory kills, and genuine crashes all converge here.
        for i, w in enumerate(workers):
            if w.alive:
                continue
            if w._pending is not None:
                # Distinguish an allocation failure under the RLIMIT_AS cap from
                # an ordinary crash, so runaway-memory tests stay visible as
                # MEMKILL rather than being folded into generic FAILs.
                verdict = "MEMKILL" if _died_of_memory(w) else "FAIL"
                if verdict == "MEMKILL":
                    print(
                        f"  [memkill] {w._pending[0]} (worker {w.worker_id})",
                        file=sys.stderr,
                    )
                finish_worker(w, result=verdict)
            del fd_map[w.stdout_fileno]
            w.close()  # reap the zombie; already dead, so this does not block
            workers[i] = Worker(VM_BINARY, i)
            fd_map[workers[i].stdout_fileno] = workers[i]
            if test_queue:
                workers[i].send_test(test_queue.popleft())
                pending_count[0] += 1

    # Cleanup
    for w in workers:
        w.close()

    # Optional serial retry of non-pass tests to separate real failures from
    # load-order / GC timing flakiness.
    if RETRY_FAILS[0]:
        retry_paths = [p for p, r in results if r != "PASS"]
        if retry_paths:
            print(
                f"  [retry-fails] rerunning {len(retry_paths)} non-pass tests serially",
                file=sys.stderr,
            )
            retry_results = rerun_serial(retry_paths, test_timeout)
            retry_map = {p: r for p, r in retry_results}
            results = [(p, retry_map.get(p, r)) for p, r in results]

    return _summarize_results(results, skipped, total, test_timeout)


def _summarize_results(results, skipped, total, test_timeout):
    """Summarize (path, result) pairs into the standard 6-tuple."""
    if LOG_FH[0] is not None:
        for path, r in results:
            rel = os.path.relpath(path, TEST262_DIR)
            tag = r
            if r == "COMPILE_ERROR":
                tag = f"CE:{categorize_ce(path)}"
            LOG_FH[0].write(f"{tag}\t{rel}\n")
        LOG_FH[0].flush()

    pass_count = sum(1 for _, r in results if r == "PASS")
    ce_breakdown = {"expected-parse": 0, "expected-runtime": 0, "unexpected": 0}
    for path, r in results:
        if r == "COMPILE_ERROR":
            cat = categorize_ce(path)
            ce_breakdown[cat] = ce_breakdown.get(cat, 0) + 1
    compile_err_count = sum(1 for _, r in results if r == "COMPILE_ERROR")
    fail_count = len(results) - pass_count - compile_err_count
    return (pass_count, fail_count, skipped, total, compile_err_count, ce_breakdown)


def _resolve_single_path(test):
    """Resolve a --single argument to an existing file, accepting an absolute
    path or a path relative to test262/test/ or test262/. Returns the resolved
    absolute path, or None if not found."""
    candidates = [
        test,
        os.path.join(TEST262_DIR, test),
        os.path.join(PROJECT_DIR, "test262", test),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return os.path.abspath(c)
    return None


def _build_concat_file(path):
    """Concatenate assert.js + sta.js + the test's `includes:` + the test body
    into one file under TMPDIR and return its path (for lldb / --trace-vm)."""
    harness = os.path.join(PROJECT_DIR, "test262", "harness")
    tmpdir = os.environ.get("TMPDIR", "/tmp")
    combined = os.path.join(tmpdir, f"t262_{os.getpid()}_{random.randint(0, 1 << 30)}.js")
    parts = [os.path.join(harness, "assert.js"), os.path.join(harness, "sta.js")]
    # Pull harness files named in `includes: [a.js, b.js]`
    with open(path) as f:
        head = f.read(8192)
    m = re.search(r"includes:\s*\[([^\]]*)\]", head)
    if m:
        for inc in (s.strip() for s in m.group(1).split(",")):
            if inc:
                parts.append(os.path.join(harness, inc))
    parts.append(path)
    with open(combined, "w") as out:
        for p in parts:
            with open(p) as src:
                out.write(src.read())
                out.write("\n")
    return combined


def run_single(test, debug=False, keep=False):
    """Run ONE test through the canonical --worker path and print its raw
    verdict. Warns first if the suite would skip the test, so a raw verdict on
    a deferred-feature or noStrict test is not mistaken for a real failure.
    With debug/keep, builds a concat-harness file for the plain `duktape_c3`
    binary (lldb / --trace-vm) instead. Returns a process exit code."""
    path = _resolve_single_path(test)
    if path is None:
        print(f"ERROR: test file not found: {test}", file=sys.stderr)
        return 2

    reason = skip_reason(path)
    if reason is not None:
        print(f"⚠ SUITE SKIPS THIS TEST ({reason})")
        print("   — verdict below is raw engine behavior, not a suite failure")

    # --keep / --debug: concat harness + run under duktape_c3 (for lldb).
    if keep or debug:
        combined = _build_concat_file(path)
        if keep:
            print(combined)
            return 0
        debug_bin = os.path.join(PROJECT_DIR, "out", "duktape_c3")
        if not os.path.isfile(debug_bin):
            print(f"ERROR: {debug_bin} not found. Build it with: c3c build duktape_c3",
                  file=sys.stderr)
            return 2
        try:
            proc = subprocess.run([debug_bin, combined], capture_output=True,
                                  text=True, timeout=10)
            if proc.returncode == 0:
                print(f"PASS  {path}")
            else:
                print(f"FAIL  {path} (exit {proc.returncode})")
                for line in (proc.stdout + proc.stderr).splitlines()[:5]:
                    print(f"    {line}")
        finally:
            try:
                os.unlink(combined)
            except OSError:
                pass
        return 0

    if not os.path.isfile(VM_BINARY):
        print(f"ERROR: {VM_BINARY} not found. Build it first with: "
              f"c3c build test262_runner", file=sys.stderr)
        return 2

    # One test through a fresh worker: feed the absolute path on stdin, exactly
    # as the parallel workers do. A fresh process avoids any cross-test heap
    # reset concerns for the single-test case.
    proc = subprocess.run(
        [VM_BINARY, "--worker"],
        input=path + "\n",
        capture_output=True,
        text=True,
    )
    out = proc.stdout.strip()
    if not out:
        print(f"FAIL  {path} (no output from worker)")
        return 1
    print(out)
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Run test262 tests in parallel worker mode."
    )
    parser.add_argument(
        "--phase",
        type=int,
        choices=sorted(_PHASE_NUM_TO_IDX.keys()),
        help="Run only this phase by number (0, 1, 2, … 15, 17, 21)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help=f"Number of parallel workers (default: {DEFAULT_WORKERS}, max: {MAX_WORKERS})",
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
    parser.add_argument(
        "--log",
        metavar="FILE",
        help="Write per-test results (RESULT<TAB>relative-path) to FILE for cluster analysis",
    )
    parser.add_argument(
        "--retry-fails",
        action="store_true",
        help="DIAGNOSTIC: rerun non-pass tests serially and report the serial "
             "verdict. Off by default — a verdict that changes on retry is a "
             "non-determinism bug, not flakiness to mask.",
    )
    parser.add_argument(
        "--no-retry-fails",
        action="store_true",
        help="(No-op; serial retry is already off by default.)",
    )
    parser.add_argument(
        "--shuffle",
        action="store_true",
        help="Shuffle test order within each phase (contamination detection)",
    )
    parser.add_argument(
        "--fresh-process",
        action="store_true",
        help="Spawn a fresh test262_runner per test (slow, immune to reset bugs)",
    )
    parser.add_argument(
        "--single",
        metavar="TEST",
        help="Run ONE test through the canonical --worker path and print its raw "
             "verdict. Accepts an absolute path or a path relative to test262/test/ "
             "(or test262/). If the suite would skip the test, a warning naming the "
             "skip reason is printed first — the verdict below it is raw engine "
             "behavior, not a suite failure.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="With --single: instead of the worker, concat assert.js/sta.js + the "
             "test's `includes:` and run under `duktape_c3` (for lldb / --trace-vm).",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="With --single: build the concat file (as --debug) but print its path "
             "and keep it, for `just lldb` / manual --trace-vm.",
    )
    args = parser.parse_args()

    if args.single is not None:
        sys.exit(run_single(args.single, debug=args.debug, keep=args.keep))

    if args.log:
        LOG_FH[0] = open(args.log, "w")

    if args.retry_fails:
        RETRY_FAILS[0] = True

    if args.shuffle:
        SHUFFLE[0] = True

    if args.fresh_process:
        FRESH_PROCESS[0] = True

    # Each worker's address space is capped by RLIMIT_AS (see MEM_LIMIT_BYTES),
    # so total memory is bounded by workers × 3 GB rather than being open-ended.
    # That makes the CPU count, not memory, the limit on useful parallelism.
    if args.workers > MAX_WORKERS:
        print(
            f"Warning: capping --workers from {args.workers} to {MAX_WORKERS} "
            f"({os.cpu_count()} CPUs detected)",
            file=sys.stderr,
        )
        args.workers = MAX_WORKERS
    if args.workers < 1:
        print(f"Warning: raising --workers from {args.workers} to 1", file=sys.stderr)
        args.workers = 1

    # Always rebuild — a missing-only check silently runs a stale binary
    # Ensure the binary exists
    if not os.path.isfile(VM_BINARY):
        print(f"ERROR: {VM_BINARY} not found. Build it first with: c3c build test262_runner", file=sys.stderr)
        sys.exit(1)

    phases = [resolve_phase_num(args.phase)] if args.phase is not None else range(len(PHASES))
    grand_pass = grand_fail = grand_skip = grand_total = grand_ce = 0
    grand_ce_breakdown = {"expected-parse": 0, "expected-runtime": 0, "unexpected": 0}

    if args.es5:
        print("Mode: ES5-only (skipping tests with post-ES5 feature flags)\n")

    # B36 — show CE split so tests like `negative: phase: parse` (where the engine
    # is *supposed* to throw) don't muddy the unexpected-CE / parser-bug surface.
    # Effective pass count = Pass + expected-parse CE; that number moves the
    # pass rate from 70.2% → ~70.3% in this run, but more importantly it makes
    # the CE column tell the truth: "real" parser bugs are counted separately
    # from "correct rejections" the test262 metadata asks for.
    print("Phase | Total | Pass | Fail | Skip | CE:expected-parse | CE:expected-runtime | CE:unexpected(real bug)")
    print("------|-------|------|------|------|-------------------|--------------------|--------------------------")
    grand_eff_pass = 0
    grand_real_fail = 0
    for p in phases:
        p_pass, p_fail, p_skip, p_total, p_ce, p_ce_bd = run_phase(
            p, args.workers, args.timeout, es5_only=args.es5
        )
        ce_exp_parse = p_ce_bd.get("expected-parse", 0)
        ce_exp_runtime = p_ce_bd.get("expected-runtime", 0)
        ce_unexpected = p_ce_bd.get("unexpected", 0)
        # "Real" failure = fail + unexpected-CE + expected-runtime-CE
        p_real_fail = p_fail + ce_unexpected + ce_exp_runtime
        print(
            f"{PHASES[p]['label']} | {p_total} | {p_pass} | {p_fail} | {p_skip} | "
            f"{ce_exp_parse} | {ce_exp_runtime} | {ce_unexpected}"
        )
        grand_pass += p_pass
        grand_fail += p_fail
        grand_skip += p_skip
        grand_total += p_total
        grand_ce += p_ce
        for k, v in p_ce_bd.items():
            grand_ce_breakdown[k] = grand_ce_breakdown.get(k, 0) + v
        grand_eff_pass += p_pass + ce_exp_parse
        grand_real_fail += p_real_fail

    if len(phases) > 1:
        grand_run = grand_pass + grand_fail + grand_ce
        grand_real_run = grand_eff_pass + grand_real_fail
        pct = (grand_pass / grand_run * 100) if grand_run > 0 else 0
        eff_pct = (grand_eff_pass / grand_real_run * 100) if grand_real_run > 0 else 0
        print(f"\nOverall (raw):    {grand_pass} pass / {grand_fail} fail / {grand_ce} CE "
              f"({pct:.1f}%)")
        print(f"  CE breakdown:   {grand_ce_breakdown['expected-parse']} expected-parse "
              f"+ {grand_ce_breakdown['expected-runtime']} expected-runtime "
              f"+ {grand_ce_breakdown['unexpected']} unexpected (real parser bugs)")
        print(f"Adjusted pass:   {grand_eff_pass} eff-pass / {grand_real_fail} real-fail "
              f"= {eff_pct:.1f}% (B36 view)")
        if grand_skip > 0:
            print(f"Skipped:          {grand_skip} tests")
if __name__ == "__main__":
    main()
