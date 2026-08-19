#!/usr/bin/env python3
"""Compare compiled bytecode between two builds over the library corpus.

Usage:
    ./scripts/bytecode_diff.py <baseline-binary> [--corpus DIR] [--verbose]

Why this exists
---------------
Capture-analysis and codegen changes can be semantically wrong while every
conformance gate stays green. A change that wrongly decided a variable was not
captured passed test262 at 50002/50002 and 100% of the local suite, and only
surfaced as a runtime TypeError deep inside a minified handlebars bundle.

What localised it was diffing `boomkat_debug -c` output between the two builds
and finding the function where a GETVAR had become a plain register read. This
automates that.

What it reports
---------------
Per file, the change in each opcode's static count, with two rules encoding the
safety asymmetry of capture analysis:

    GETVAR/GETVAR_SLOT going DOWN    fine  - fewer demotions, the optimisation
    GETVAR going UP                  fine  - over-capture costs speed only
    DECLVAR changing AT ALL          ALERT - parameters and declared bindings
                                             must still be materialised into
                                             the environment; a drop here means
                                             a binding lost its env home, which
                                             is how a captured parameter starts
                                             reading a stale register

Over-capturing is always safe. Under-capturing silently miscompiles. So a
DECLVAR delta is treated as a hard failure and a GETVAR delta as information.

Exit status is non-zero if any ALERT fired, so this can gate a commit.
"""

import argparse, pathlib, re, subprocess, sys
from collections import Counter

OPCODE_RE = re.compile(r'^\[\s*\d+\]\s+([A-Z_][A-Z_0-9]*)')

def opcode_counts(binary: str, js: pathlib.Path) -> Counter | None:
    """Static opcode histogram for one file, or None if it will not compile."""
    try:
        p = subprocess.run([binary, "-c", str(js)],
                           capture_output=True, text=True, timeout=180)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if p.returncode != 0 and not p.stdout:
        return None
    c = Counter()
    for line in p.stdout.splitlines():
        m = OPCODE_RE.match(line.strip())
        if m:
            c[m.group(1)] += 1
    return c or None

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline", help="binary to compare against (e.g. a worktree's out/boomkat_debug)")
    ap.add_argument("--current", default="out/boomkat_debug")
    ap.add_argument("--corpus", default="test/libcorpus/_wrapped")
    ap.add_argument("--verbose", action="store_true", help="show every opcode that moved")
    args = ap.parse_args()

    corpus = pathlib.Path(args.corpus)
    if not corpus.is_dir():
        print(f"corpus not found: {corpus}", file=sys.stderr)
        print("(test/libcorpus is gitignored; run from the main checkout)", file=sys.stderr)
        return 2

    files = sorted(f for f in corpus.glob("*.js") if not f.name.endswith("_api.js"))
    if not files:
        print(f"no .js files in {corpus}", file=sys.stderr)
        return 2

    print(f"baseline: {args.baseline}")
    print(f"current:  {args.current}")
    print(f"corpus:   {len(files)} files from {corpus}\n")

    alerts, skipped = [], []
    print(f"{'file':<22} {'DECLVAR':>16} {'GETVAR':>18}")
    print(f"{'-'*22} {'-'*16} {'-'*18}")

    for js in files:
        base = opcode_counts(args.baseline, js)
        cur  = opcode_counts(args.current, js)
        if base is None or cur is None:
            skipped.append(js.name)
            continue

        def delta(op): return cur.get(op, 0) - base.get(op, 0)
        d_decl = delta("DECLVAR")
        d_get  = delta("GETVAR") + delta("GETVAR_SLOT")

        decl_s = f"{base.get('DECLVAR',0)}" if d_decl == 0 else f"{base.get('DECLVAR',0)}->{cur.get('DECLVAR',0)} !!"
        gv_base = base.get("GETVAR",0) + base.get("GETVAR_SLOT",0)
        gv_cur  = cur.get("GETVAR",0) + cur.get("GETVAR_SLOT",0)
        get_s = f"{gv_base}" if d_get == 0 else f"{gv_base}->{gv_cur} ({d_get:+d})"

        print(f"{js.name:<22} {decl_s:>16} {get_s:>18}")

        if d_decl != 0:
            alerts.append(f"{js.name}: DECLVAR moved {d_decl:+d} — a binding changed env materialisation")
        if args.verbose:
            for op in sorted(set(base) | set(cur)):
                if delta(op):
                    print(f"    {op:<24} {base.get(op,0):>7} -> {cur.get(op,0):>7} ({delta(op):+d})")

    print()
    if skipped:
        print(f"skipped (would not compile under one binary): {', '.join(skipped)}\n")

    if alerts:
        print("ALERT — these need explaining before the change ships:")
        for a in alerts:
            print(f"  {a}")
        print("\nA DECLVAR drop is the signature of a captured binding losing its\n"
              "environment slot. Verify with: out/boomkat test/libcorpus/_wrapped/<lib>_api.js")
        return 1

    print("No DECLVAR changes: every binding kept its environment materialisation.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
