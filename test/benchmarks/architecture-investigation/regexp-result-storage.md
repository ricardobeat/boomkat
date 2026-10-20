# RegExp match-result storage reservation

`regexp_build_match_result` creates an array whose capture count is already
known. The old path allocated 16 dense slots on the first element, then moved
those slots when the first named property grew the property table. The result
builder now reserves one backing block for the final dense span and named
properties before inserting either. It sizes the named section for `index`,
`input`, `groups`, `length`, optional `indices`, and unmatched numeric captures.
Unmatched captures stay named properties so `n in result` remains true even
though the dense representation uses `undefined` to mark holes.

## Measurements

One warmup and nine alternating release runs compare the binary before the
reservation, the candidate, and the repo-built `out/qjs`. The standard
`bench_regexp.js` whole-process median is 108.3 ms before and 101.1 ms after;
QuickJS is 53.0 ms. The focused probe's whole-process median is 58.5 ms before
and 54.1 ms after; QuickJS is 31.9 ms. The candidate improves both workloads by
about 7%, while remaining 1.9x and 1.7x slower than QuickJS respectively.

The focused probe runs 20,000 iterations in each phase. Phase times are rounded
to integer milliseconds; all samples and binary hashes are in
`regexp-result-storage-results.json`.

| Phase | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| Literal `exec` | 9 | 8 | 5 |
| Capturing `exec` | 10 | 9 | 4 |
| Unmatched capture `exec` | 14 | 13 | 8 |
| Global `exec` pair | 22 | 20 | 12 |

A GC_PROFILE run of the same 80,000 matches reports 200,153 to 100,153
successful pool requests and 32,020,968 to 7,700,968 requested bytes. HObject
allocations stay at 100,905 in both runs, which is why the pool counters are
recorded separately. These are total successful `Heap.pool_alloc` requests and
logical requested sizes for the probe, not RSS or physical pool-page usage.
Both runs report `CHECK 80000`; profile binary hashes and counters are in
`regexp-result-storage-gcprofile-results.json`.

## Validation

- `just test-local`: 494 scripts, 20 modules, and all syntax/robustness checks
  pass.
- `just test262-dir built-ins/RegExp`: 1,867 pass, 12 scope skips, zero
  failures.
- The focused match-result test passes under the GC stress/ASAN build.

`test/regexp_match_result_storage.js` covers unmatched captures, own-property
presence and descriptors, named groups, and `d`-flag indices.
