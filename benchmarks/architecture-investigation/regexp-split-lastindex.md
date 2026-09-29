# `RegExp.prototype[@@split]` lastIndex accesses

The `@@split` loop sets the splitter's `lastIndex` before each attempted
position and reads it after a match. Those accesses now reuse the guarded
RegExp helpers: direct slot reads and barriered writes apply only to a writable
own numeric `lastIndex` on a genuine RegExp. Custom species splitters,
object-valued indices, accessors, and read-only writes keep the generic paths.
Each lookup stays at its original point in the loop because custom `exec` can
change the value or descriptor.

## Measurements

One warmup and nine alternating release runs compare the binary with the
`RegExpBuiltinExec` fast path alone, the candidate, and the repo-built
`out/qjs`. In `bench_regexp.js`, whole-process medians move from 95.8 to 93.0
ms; QuickJS is 52.8 ms. The `split(re)` phase moves from 15 to 13 ms, with
QuickJS at 8 ms.

The focused probe splits equal-length inputs with sparse, dense, and absent
delimiters, 1,200 times each. Whole-process medians are 25.0 ms before, 22.1 ms
after, and 13.9 ms in QuickJS.

| Split phase | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| Sparse delimiter | 5 | 4 | 3 |
| Dense delimiter | 11 | 10 | 6 |
| Absent delimiter | 5 | 4 | 3 |

Times are integer-millisecond medians; all samples and binary hashes are in
`regexp-split-lastindex-results.json`.

GC_PROFILE counts rise from 230,400 to 268,800 fast reads and from 230,400 to
460,800 fast writes in the focused probe. The extra writes match the per-
position loop; the extra reads match successful matches. Object and pool
allocation totals stay the same. Both profile runs report `CHECK 3600`; their
hashes and counters are in `regexp-split-lastindex-gcprofile-results.json`.

## Validation

- `just test-local`: 495 scripts, 20 modules, and all syntax/robustness checks
  pass.
- `just test262-dir built-ins/RegExp`: 1,867 pass, 12 scope skips, zero
  failures.
- Both focused RegExp tests pass under the GC stress/ASAN build.

The full RegExp test262 directory covers species splitters, custom `exec`,
empty matches, Unicode, and split limits alongside the focused lastIndex
conversion checks.
