# RegExp `lastIndex` fast path

`RegExpBuiltinExec` reads and converts `lastIndex` on every call. For an own
numeric fastint data property, it now reads the current slot directly. Before
writing it resolves the slot and descriptor again, then uses the normal heap
store barrier only when the property is writable. Strings, doubles, objects,
accessors, missing properties, and non-writable writes retain the generic path.
The read slot and descriptor are never held across `ToInteger`, which can run
script and change either the value or its writable flag.

## Measurements

One warmup and nine alternating release runs compare the binary before the
fast path, the candidate, and the repo-built `out/qjs`. `bench_regexp.js`
measures 95.9 ms before and 91.3 ms after; QuickJS measures 50.9 ms. The
largest phase change is `split(re)`, from 18 to 15 ms, with QuickJS at 8 ms.
Whole-process measurements for the focused probe move from 40.3 to 37.1 ms;
QuickJS measures 19.6 ms. The focused probe runs 20,000 non-global execs,
20,000 sticky misses, 2,000 full global scans, and 2,000 RegExp splits.

| Focused phase | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| Non-global `exec` | 7 | 7 | 4 |
| Full global scan | 8 | 8 | 3 |
| Sticky miss | 3 | 3 | 1 |
| RegExp `split` | 18 | 15 | 9 |

The other focused phases do not move at whole-millisecond resolution. The
candidate remains about 1.8x slower than QuickJS in both whole-process probes.
All samples and binary hashes are in `regexp-lastindex-results.json`.

A GC_PROFILE run counts 228,000 direct fast reads and 208,000 direct fast
writes in the focused probe. It reports 88,904 object allocations and 86,153
successful pool requests. The profile binary and output are summarized in
`regexp-lastindex-gcprofile-results.json`.

## Validation

- `just test-local`: 495 scripts, 20 modules, and all syntax/robustness checks
  pass.
- `just test262-dir built-ins/RegExp`: 1,867 pass, 12 scope skips, zero
  failures.
- Both focused RegExp tests pass under the GC stress/ASAN build.

`test/regexp_lastindex_fastpath.js` covers a coercion that makes `lastIndex`
non-writable, string conversion, and negative-index clamping. The existing
RegExp tests cover matcher recompilation during coercion and non-writable
global writes.
