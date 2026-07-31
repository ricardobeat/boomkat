# Verbatim Rosetta Code suite

41 unmodified JavaScript samples from [rosettacode.org](https://rosettacode.org),
run as-is to exercise the engine with third-party code we did not write.
28 are driven by assertions, 13 by comparing their printed output.

## Layout

| File | Role |
|---|---|
| `<name>.js` | The sample, **byte-identical to the wiki**. Never edit. |
| `<name>.check.js` | Assertions. Imports the sample and states expectations. |
| `<name>.expected` | For samples whose behavior is what they print: expected stdout. |
| `_harness.js` | Shared `assert` / `assertEq` / `assertImported` / `report`. |

Each sample carries a two-line provenance header naming its task and the index
of the JavaScript block it came from.

## Running

    just rosetta            # or: bash test/rosetta-verbatim/run.sh ./out/duktape_c3
    just rosetta-check      # re-fetch from the wiki and diff against local copies

`rosetta-check` is how you confirm a sample has not been quietly edited (and
that the wiki has not changed underneath us). It makes one network request per
sample, so it is slow; it is not part of the normal test run.

## Adding a task

    python3 scripts/fetch_rosetta.py --task Sorting_algorithms/Heapsort --idx 0 \
        --out test/rosetta-verbatim/heapsort.js

Then write `heapsort.check.js`. Use `--idx` to pick a different JavaScript block
when the first one is unsuitable.

## Validation

Expected outputs are cross-checked against QuickJS (`qjs`), not just recorded
from our own engine -- a `.expected` generated only from our output would pass
even if the engine were wrong. All 14 output files and all 27 assertion files
agree with QuickJS.

Every sample is also mutation-tested: a fault injected into it must make its
check fail. That pass has already caught three real coverage holes (a `gcd`
branch no input reached, a `sieve` boundary at `limit == 2`, and a `stack`
check that could not observe the pushed values).

## Constraints on which samples work

Roughly half the tasks the old suite cited have no usable JavaScript sample.
Skip ones that:

- **need I/O or data files** — several use `require('fs')` and `unixdict.txt`
- **are nondeterministic** — `Math.random()`, or output that depends on the
  current time or the local timezone (`date_manipulation`)
- **target the browser** — `document.write` anywhere in the block makes the
  whole module fail to load, even when the function above it is clean
  (the insertion/shell sort samples are lost this way)
- **are not self-contained** — many blocks reference identifiers defined in a
  different block on the same page (`matrix_multiply` needs `Matrix`,
  `sudoku` needs `reduceGrid`)
- **are value-returning IIFEs** — they expose no binding to import and print
  nothing to compare (`alphabet`, `matrix_transpose`, `temperature`)
- **use non-standard syntax** — `hamming` uses SpiderMonkey's legacy
  `yield`-in-a-plain-function and `[for each (x in y)]` array comprehensions
- **rely on `console.log` doing more than stringify** — format specifiers
  (`console.log("%d", x)`) and object inspection (`console.log({a: 1})` prints
  `[object Object]`) are Node behaviors this engine does not implement

## Engine gaps found while building this suite

Neither is worked around here; the affected samples were excluded instead.

- `Date.prototype.toLocaleString` ignores its options bag and `timeZone`,
  returning a default date string in local time (ECMA-402 gap). This is why
  the `Date_format` task has no sample here.
- `console.log` does not inspect objects.

## Note on the import mechanism

`<name>.check.js` runs through the ESM pipeline (`--module`) so it can import the
sample. Two engine behaviors matter here:

- Top-level `var`/`function` bindings are importable **without** an `export`
  statement. Real ESM requires explicit exports; this is a permissive deviation,
  and it is what lets an unmodified sample be imported at all.
- An unresolvable import name yields `undefined` rather than failing to link, so
  a renamed sample function would silently assert against `undefined` and pass.
  Every check file calls `assertImported(...)` first to turn that into a loud
  failure.

The second is a genuine conformance gap (ES2015 §15.2.1.16.3 `ResolveExport`
should make it an early SyntaxError) and is worth fixing independently.
