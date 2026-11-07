# CodeLoad source metadata costs

2026-11-07, macOS ARM64, production `boomkat-full-icu` target with its current
defaults (O2, optsize=small). Baseline: `cd2beb6c`. These are not directly
comparable with the older O3 eval-lazy study.

## Profile and first change: share deferred-body line tables

A two-second native sample of 500 salted jQuery loads attributed 220 of 1,662
samples (13.2%) to `build_line_table`, the largest individual leaf. Register
liveness followed at 91 samples (5.5%). See `baseline-profile.txt`.

Materializing a deferred body reparses a source prefix ending at that body's
closing brace. Previously each materialization scanned that entire prefix to
rebuild line coordinates. The source buffer now retains one line-start table,
created when its first body is deferred. Reparsed ASTs borrow that immutable
table while retaining the buffer. Final source-buffer release frees the table.
Ordinary compilation does not retain an additional table.
Deferred units retain four bytes per source line plus the buffer's slice
descriptor; this trades a small amount of persistent metadata for repeated
source scans. Highly multiline eval source will retain more metadata than
these minified benchmark libraries.

The coordinate regression covers CR, LF, CRLF, U+2028, U+2029, UTF-8 byte
columns, single-line source, sibling/nested materialization, and use after
the originating AST and intervening evals have been released.

Five serial alternating pairs, unchanged javascript-zoo CodeLoad:

| Metric | Baseline median | Shared lines median |
|---|---:|---:|
| CodeLoad score | 28,103 | 30,714 |
| 1,000 Closure loads | 329 ms | 322 ms |
| 100 jQuery loads | 753 ms | 636 ms |
| Closure peak RSS, fixed work | 153.24 MB | 153.16 MB |
| jQuery peak RSS, fixed work | 168.43 MB | 168.02 MB |
| Timed CodeLoad peak RSS | 664.01 MB | 701.97 MB |

CodeLoad improves 9.3%; fixed-work jQuery time falls 15.5%. Closure's small
difference is inconclusive. Timed CodeLoad does more work when faster, so its
RSS is not an equal-work memory comparison. Samples and binary/source hashes
are in `shared-lines-results.json`. No builds or suites ran during timing.

Reproduce with `test/benchmarks/eval-lazy/measure.py`, passing the saved baseline
and candidate binaries, `--bench-dir /path/to/javascript-zoo/bench --pairs 5`
and `--out /tmp/codeload-results.json`.

Validation for shared lines:

- Local suite: 682 scripts, 33 modules, all auxiliary suites pass.
- New coordinate regression and existing `eval_deferred_functions.js` pass
  under the rebuilt ASAN/GC_STRESS/GC_VERIFY/POOL_BYPASS target.
- Full test262: 53,372 pass, eight staging Date stress timeouts, zero compile
  errors; 236 existing exclusions. All eight failures are the
  `staging/sm/Date/dst-offset-caching-*-of-8.js` tests at the default 10-second
  limit. An unchanged baseline running fraction 3 also exceeded that budget
  and was stopped after 101 seconds; the longer-timeout directory diagnostic
  was stopped too. This is not a clean full-suite pass and does not establish
  the eventual verdicts of those eight tests. No exclusions changed.
- A broader GC-stress sweep was stopped in the unrelated 60,000-iteration
  shape-ID stress case; only the focused lifetime checks above are claimed.
