#!/usr/bin/env python3
"""
Golden-bytecode test runner.

Runs `out/boomkat_debug -c` on every `.js` file in test/golden_bytecode/
and diffs the disassembly against the checked-in `.expected` file of the
same name. This is the contract that keeps compiler-peephole fusions
(ADDI/SUBI, INC_VAR, GETPROPC, JMP_N*, copy-propagation, ...) honest across
refactors: if a compiler change makes a fusion silently stop firing, the
resulting disasm no longer contains the fused opcode and the golden diff
fails LOUDLY, instead of only showing up as an unexplained benchmark
regression.

Each golden is a pair:
    test/golden_bytecode/<name>.js         source snippet
    test/golden_bytecode/<name>.expected   `boomkat_debug -c` stdout, verbatim

Usage:
    python3 scripts/run_golden_bytecode.py                 # run + diff all goldens
    python3 scripts/run_golden_bytecode.py --update         # regenerate .expected files
    python3 scripts/run_golden_bytecode.py --check-noop     # also assert --no-optimize
                                                              output contains none of the
                                                              fused opcodes (equivalence
                                                              check: fusions must be a
                                                              pure no-op when disabled)
    python3 scripts/run_golden_bytecode.py fib_subi          # run a single golden by name

Requires `out/boomkat_debug` to be built with TRACE_VM (the `boomkat_debug`
target already carries this feature — see `just build-trace` / `make out/boomkat_debug`).
"""

import argparse
import difflib
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLDEN_DIR = os.path.join(REPO_ROOT, "test", "golden_bytecode")
DEBUG_BIN = os.path.join(REPO_ROOT, "out", "boomkat_debug")

# Opcodes introduced only by optional compiler passes. INC_VAR and DEC_VAR
# also implement ordinary by-name updates, so they remain valid with passes off.
FUSED_OPCODES = ("ADDI", "SUBI", "ADD_FUSED", "INC_LT", "GETPROPC",
                  "JMP_NLT", "JMP_NLE", "JMP_NGT", "JMP_NGE", "JMP_NEQ", "JMP_NNE",
                  "NEWOBJ_SHAPE", "INIT_SLOT", "SPREAD_PROJECTION")


def discover_goldens(names=None):
    goldens = []
    for fname in sorted(os.listdir(GOLDEN_DIR)):
        if not fname.endswith(".js"):
            continue
        name = fname[:-3]
        if names and name not in names:
            continue
        goldens.append(name)
    return goldens


def run_disasm(js_path, extra_args=()):
    proc = subprocess.run(
        [DEBUG_BIN, "-c", *extra_args, js_path],
        capture_output=True, text=True, timeout=30,
    )
    return "\n".join(line.rstrip() for line in proc.stdout.splitlines()) + "\n", proc.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", help="run only these golden names (default: all)")
    parser.add_argument("--update", action="store_true", help="regenerate .expected files from current output")
    parser.add_argument("--check-noop", action="store_true",
                         help="also verify --no-optimize output contains none of the fused opcodes")
    args = parser.parse_args()

    if not os.path.isfile(DEBUG_BIN):
        print(f"error: {DEBUG_BIN} not found — build it first (`c3c build boomkat_debug` or `just build-trace`)",
              file=sys.stderr)
        return 1

    goldens = discover_goldens(set(args.names) if args.names else None)
    if not goldens:
        print("error: no golden .js files found" if not args.names else
              f"error: no goldens matched {args.names}", file=sys.stderr)
        return 1

    failures = []
    for name in goldens:
        js_path = os.path.join(GOLDEN_DIR, f"{name}.js")
        expected_path = os.path.join(GOLDEN_DIR, f"{name}.expected")

        actual, rc = run_disasm(js_path)
        if rc != 0:
            print(f"FAIL {name}: boomkat_debug exited {rc}")
            failures.append(name)
            continue

        if args.update:
            with open(expected_path, "w") as f:
                f.write(actual)
            print(f"UPDATED {name}")
            continue

        if not os.path.isfile(expected_path):
            print(f"FAIL {name}: no .expected file (run with --update to create it)")
            failures.append(name)
            continue

        with open(expected_path) as f:
            expected = "\n".join(line.rstrip() for line in f.read().splitlines()) + "\n"

        if actual != expected:
            print(f"FAIL {name}: disasm mismatch")
            diff = difflib.unified_diff(
                expected.splitlines(keepends=True),
                actual.splitlines(keepends=True),
                fromfile=f"{name}.expected", tofile=f"{name} (actual)",
            )
            sys.stdout.writelines(diff)
            failures.append(name)
            continue

        if args.check_noop:
            noop_actual, noop_rc = run_disasm(js_path, extra_args=("--no-optimize",))
            if noop_rc != 0:
                print(f"FAIL {name}: --no-optimize exited {noop_rc}")
                failures.append(name)
                continue
            noop_opcodes = set(re.findall(r"^\[\s*\d+\]\s+([A-Z_0-9]+)",
                                          noop_actual, re.MULTILINE))
            leaked = sorted(noop_opcodes & set(FUSED_OPCODES))
            if leaked:
                print(f"FAIL {name}: --no-optimize output still contains fused opcode(s): {leaked}")
                failures.append(name)
                continue

        print(f"PASS {name}")

    if args.update:
        return 0

    total = len(goldens)
    ok = total - len(failures)
    print(f"\n{ok}/{total} golden bytecode tests passed")
    if failures:
        print(f"FAILED: {', '.join(failures)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
