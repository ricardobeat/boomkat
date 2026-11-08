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

## Follow-up profile and rejected experiments

The same two-second jQuery profile after shared lines (`shared-lines-profile.txt`)
attributes only 9 of 1,478 samples (0.6%) to line-table building. Liveness is now
the largest individual leaf at 105 samples (7.1%). Lexing, AST construction,
resolution and early checks remain distributed across many functions. Sampling
counts are approximate, not precise attribution of total benchmark runtime.

Two subsequent experiments used `3804a297` as their source baseline and the
same saved shared-lines binary as their timing baseline:

| Experiment | Pairs | CodeLoad before / after | Closure ms before / after | jQuery ms before / after |
|---|---:|---:|---:|---:|
| Copy fallthrough liveness instead of clear + union | 7 | 31,110 / 31,258 | 335 / 338 | 667 / 665 |
| Reuse deferred-body early-error validation | 5 | 32,098 / 31,744 | 315 / 312 | 618 / 618 |

Both were reverted: neither establishes a useful improvement. Their raw
samples and binary hashes are in `liveness-copy-results.json` and
`validated-body-results.json`. Compare only paired rows within each experiment;
the absolute scores drift across batches.

The first changed `moveelim_compute_liveness` to initialize the scratch output
with `copy_from` when a fallthrough successor exists, clearing only otherwise.
The second added an internal `validated_body` argument to `index_begin`, set
only by `materialize_function_body`. It skipped `Early.init/run/conflicts` on
immutable source already validated by the original eval, while preserving
parsing and resolution. Focused checks passed for eager rejection of invalid
uncalled bodies, strictness, regexp syntax and captures,
but the absent speedup did not justify retaining the shortcut or broadening
its validation. All production early-error checks remain in place.

The next substantial frontend investigation should measure the initial full
AST/resolution work separately from body materialization. These experiments
do not justify a general lazy-parser rewrite yet. For liveness, collect sweep
counts and bitset sizes before choosing between a worklist or block-level
analysis; removing one word traversal was insufficient here.

## Frontend phase split

`FRONTEND_STATS` times `index_begin` split on `ParseOptions.function_body`,
whole `materialize_function_body`, and `CompilerContext.finish`, and counts
liveness calls, sweeps, instruction visits and bitset words.
`test/benchmarks/codeload-source-metadata/phase_isolation.py` runs the
equal-work drivers against `out/boomkat_relexstats` (RELEX_STATS +
FRONTEND_STATS, no TRACE_VM, so eval deferral stays on) and reports medians.
Three runs per case:

| Counter | 100 jQuery loads | 1,000 Closure loads |
|---|---:|---:|
| total elapsed | 595 ms | 296 ms |
| initial full-unit frontend | 296.1 ms (49.8%) | 173.4 ms (58.6%) |
| materialization, frontend only | 34.9 ms | 15.4 ms |
| materialization, including emit and finish | 69.2 ms (11.6%) | 37.4 ms (12.7%) |
| finish, all functions | 105.3 ms (17.7%) | 41.2 ms (13.9%) |
| materializations | 4,100 (41/load) | 2,000 (2/load) |
| lexed bytes, initial / materialize | 9.38 MB / 0.79 MB | 9.50 MB / 0.78 MB |
| liveness calls / sweeps | 19,890 / 46,797 | 11,090 / 25,197 |
| liveness visits / word traversals | 3.55M / 7.11M | 1.98M / 2.89M |
| largest bitset | 7 words | 2 words |

The initial full-unit parse, resolution and validation dominates, not body
materialization: only 41 of jQuery's ordinary bodies are ever called, and they
re-lex 0.79 MB against 9.38 MB for the initial pass. The larger lever is the
initial frontend. Liveness runs about 2.3 times per finished function, 92% of
calls have a one-word (<= 32 register) set, and 31% carry a back edge, so a
block-level or worklist rewrite cannot help much; fewer calls or fewer sweeps
could. Note `relex_source` counts each lexer's full slice, so the per-kind
`src=` figures double-count units that create both an outer and an inner
lexer; compare `lexed` bytes across kinds instead.

## Retained frontend changes

Measured with `test/benchmarks/eval-lazy/measure.py`, five alternating pairs,
production `boomkat-full-icu`. Compare only paired rows within a batch: absolute
scores drift between batches, so the cumulative line gives a range.

| Change | CodeLoad | Closure ms | jQuery ms |
|---|---:|---:|---:|
| `Early` reserved-word bitsets by atom id | +2.3% | −1.9% | −2.1% |
| Compile stack floor cached per unit (with the row above) | +5.1% | −7.9% | −4.8% |
| Retained pair against `fs-baseline`, three batches | +5.1% / +6.9% / +8.5% | −7.9% / −7.3% / −6.5% | −4.8% / −5.3% / −3.3% |

Fixed-work peak RSS is unchanged (Closure 153.3 MB, jQuery 168.1 MB). Timed
CodeLoad peak RSS rises (700 -> 755 MB) because the faster engine performs more
loads.

`Early` now tests reserved words with a `bool[]` indexed by atom id instead of
two linear scans (up to 40 keywords and 9 strict-reserved words) per identifier.
`compile_stack_floor()` resolves the per-thread stack floor once, and the
parser, resolver and early-error passes cache it, dropping a thread-local load
from each per-node recursion guard. The bitsets are sized after `Early.init`
interns every reserved word; atoms interned later (private names) are never
reserved, and a lookup past the end reads false.

Validation: local suite 682 scripts, 33 modules and 39 private-field cases;
golden bytecode 32/32; test262 `language/{reserved-words,future-reserved-words,
keywords,identifiers,literals,eval-code,function-code}` (27, 55, 25, 268, 536,
347, 217 tests) all pass with no unexpected compile errors. A full test262 run
was not performed in this session.

## Post-change profile and the ASCII lexer path

A fresh sample of the retained build (`retained-profile.txt`) ran the jQuery
CodeLoad driver for 220 loads with `sample 1` starting 0.15 s in, giving 823
main-thread samples at a 293.6 MB physical footprint (the shared-lines capture
recorded 314.4 MB, so allocation-heavy leaves stay comparable). Grouping the
top-level entries: compiler codegen and `finish` 29.2%, lexer 18.5%, the
benchmark's own VM and builtins work 18.3%, AST and parser 16.6%, resolver
8.0%, early-error pass 4.4%, allocator 3.4%. The largest leaves are register
liveness 7.5%, `scan_token_raw` 4.9%, `scan_identifier` 4.0%,
`scan_punctuator` 3.6%, `finish` 3.2%, `resolve_refs` 2.9%, `AtomTable.intern`
2.7%, `regexp_literal_error` 2.7% and `Early.node` 2.7%. No single leaf is
large enough to explain the remaining frontend cost.

`scan_token_raw` decided whether a token starts an identifier by decoding a
codepoint and asking the vendored C Unicode tables, and it did that for every
token that was not a number, string or template, so every punctuator paid for
a `read_codepoint` call, a save and restore of the lexer position, line and
column, and a cross-language call. ASCII now decides on the raw byte, and
`is_identifier_start`/`is_identifier_part` mirror the C helper's ASCII branch,
so both calls are reachable only for multi-byte source. Seven alternating
pairs (`lexer-ascii-results.json`):

| Case | Before | After | Change |
|---|---:|---:|---:|
| CodeLoad score | 33,784 | 34,434 | +1.9% |
| 1,000 Closure loads | 294 ms | 288 ms | −2.0% |
| 100 jQuery loads | 593 ms | 586 ms | −1.2% |

Every round moved in the same direction, and fixed-work peak RSS is unchanged
(Closure 153.4 -> 153.2 MB). Validation: local suite including the 33-module
and 39 private-field groups, and test262 `language/identifiers` (268),
`language/literals` (536) and `language/statements` (9,347) all pass with no
unexpected compile errors.

## Rejected experiments

Each was measured with five alternating pairs and reverted.

- Liveness second-flavor skip: run the retarget liveness only when an `LDREG`
  with a live destination survives (`moveelim_needs_retarget`). CodeLoad
  32,085 -> 31,976 (−0.3%), Closure −0.6%, jQuery −0.6%. The pre-scan costs more
  than the skipped pass saves because retarget candidates are common.
- Regexp-literal validation cache keyed by pattern atom: neutral, +0.5% / +0.7%
  / +0.6% at five pairs and +0.2% / −0.3% / +0.3% at seven. It removes redundant
  `lre_compile` calls but does not move the benchmark, so the added per-`Early`
  state was not kept.
- Deferring only bodies under 32 source bytes (compile tiny bodies eagerly):
  CodeLoad 32,203 -> 31,333 (−2.7%), Closure 307 -> 319 ms (+3.9%), jQuery
  −0.6%. Eager bodies cost more than the saved materializations.
- Atom-id threading of codegen name lookups: not attempted. The contained subset
  (one `atoms.find` per declaration, atom compares in `resolve_var`) lands within
  noise; the real win needs names carried as atoms through codegen, a larger
  refactor.
