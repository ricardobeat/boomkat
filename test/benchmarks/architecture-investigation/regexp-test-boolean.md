# Boolean-only `RegExp.prototype.test`

`RegExp.prototype.test` needs only whether `RegExpExec` found a match. The
shared execution helper now has a boolean-result mode for this caller. It still
gets `exec`; the exact intrinsic uses built-in boolean execution, and a
non-callable `exec` keeps the matcher fallback. Input and `lastIndex`
conversions, matcher reload after conversion, and global/sticky `lastIndex`
writes remain in the same path. A custom callable `exec` is called and its
Object-or-Null result is validated before conversion to a Boolean.

## Measurements

One warmup and fifteen interleaved release runs compare the binary before the
change, the candidate and the repo-built `out/qjs`. The standard
`bench_regexp.js` is dominated by other operations: whole-process medians are
103.7 ms before and 103.6 ms after, with QuickJS at 51.0 ms. Its
2,000-iteration literal-test phase rounds to 1 ms before and 0 ms after, and
0 ms in QuickJS.

The focused probe runs 20,000 iterations per phase. The table shows
integer-millisecond phase medians; `regexp-test-boolean-results.json` contains
all samples and binary hashes.

| Phase | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| Literal test, match | 7 | 4 | 4 |
| Capture test, match | 8 | 3 | 4 |
| Literal test, miss | 15 | 15 | 14 |
| Global test, match | 8 | 5 | 5 |
| Sticky test, match | 6 | 3 | 2 |
| Literal `exec` control | 9 | 8 | 4 |
| Capture `exec` control | 10 | 10 | 4 |

Whole-process medians for the focused probe are 66.0 ms before, 52.3 ms for
the candidate and 40.2 ms for QuickJS. The candidate cuts time in each
successful test phase, reaches QuickJS on literal and global tests, and is
1 ms faster on the capture phase. Sticky testing and `exec` controls remain
slower. A GC_PROFILE run of 20,000 successful capture tests reduces total
allocations from 20,902 to 902;
both runs report `CHECK 20000`. [Allocation counts and binary hashes](regexp-test-allocation-results.json)
record the profile.

## Validation

- `just test-local`: 493 scripts, 20 modules, and all syntax/robustness checks
  pass.
- `built-ins/RegExp` test262: 1,867 pass, 12 scope skips, zero failures.
- Fresh ASAN GC-stress runs pass `test/regexp_exec_reentrancy.js` and
  `test/regexp_lastindex_attributes.js`.

The focused tests cover custom `exec`, invalid custom results, re-entrant
matcher recompilation during `lastIndex` conversion, global match and miss
updates, and a non-writable `lastIndex`.
