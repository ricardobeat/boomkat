# Verbatim Rosetta Code suite

Unmodified JavaScript samples from [rosettacode.org](https://rosettacode.org),
run as-is to exercise the engine with third-party code we did not write.

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

## Constraints on which samples work

Not every task has a usable sample. Skip ones that:

- **need I/O or data files** — several use `require('fs')` and `unixdict.txt`
- **are nondeterministic** — anything calling `Math.random()` without a seed
- **target the browser** — `document.write`, DOM access
- **rely on `console.log` format specifiers** — `console.log("%d", x)` is a Node
  extension; this engine prints the format string literally

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
