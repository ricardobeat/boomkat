# Mandatory regexp literal rejection, 2026-10-31

Rat `c74029b2` improves the engine's regexp wrapper, not the JIT. For patterns without an existing literal prefix, a conservative scanner identifies a mandatory ASCII substring outside groups, classes and top-level alternatives. A missing substring rejects the input before backtracking. A present substring never advances the match start and the original libregexp bytecode decides the result. Case-insensitive and Unicode-set patterns, top-level alternation, unfamiliar escapes, and quantified braces are declined; ordinary Unicode mode is supported. The scanner drops a literal character before `?`, `*`, or `+`, and requires at least three bytes. The existing prefix path is unchanged.

## Evidence from executed work

An earlier full-suite CPU sample spent 408 of 762 self samples in `lre_exec`. Sampled per-pattern timing of the current RegExp mini identified `(^|[^\\])"\\\/Qngr\((-?[0-9]+)\)\\\/"` as the largest contributor: 9.4 ms across one-in-sixteen sampled invocations, out of 3,120 total calls. The diagnostic regexp bytecode (`bk-regex-bytecode.txt`) shows the unanchored split/any/goto search followed by a branch and eight mandatory character opcodes. The new analysis finds those eight literal bytes and can reject before that search. Instrumented execution of the prototype checked 34,800 eligible requests and rejected 27,520. The final single-pass analysis selected the identical literals for this workload, verified by comparing the diagnostic output. These counts are diagnostics, not timing results.

`bk-regex-js-bytecode.txt` records the JS bytecode and `bk-regex-wrapper-disasm-final.txt` captures the actual ARM64 wrapper: the generated C code calls `memmem` for the new filter and reaches `lre_exec` only when the filter permits it. Diagnostic timing and disassembly instrumentation were never used for the performance measurements.

## Performance

Seven alternating exact-build mini pairs measured RegExp **339→225 ms median (-33.6%)**. A 15-mini five-pair screen of the earlier two-pass prototype gave RegExp 338→225 ms and other workloads between -0.6% and +1.4% elapsed time. The final single-pass scanner selected the same literals, but that broader mini screen is not presented as an exact-final-binary measurement.

Three alternating original full-Octane pairs of the exact final release binary all passed validation. Aggregate control scores were **6369, 6402, 6400** and candidate scores **6562, 6539, 6552**; medians **6400→6552 (+2.38%)**. RegExp control scores were **769, 770, 766** and candidate scores **1135, 1130, 1135**; medians **769→1135 (+47.6%)**. Each full result, including latency, is in `bk-regex-final-full.json` and the raw output files.

| Score | Control median | Candidate median |
|---|---:|---:|
| Richards | 4709 | 4699 |
| DeltaBlue | 3398 | 3398 |
| Crypto | 4677 | 4659 |
| RayTrace | 3105 | 3105 |
| EarleyBoyer | 3070 | 3103 |
| RegExp | 769 | 1135 |
| Splay | 8679 | 8565 |
| SplayLatency | 21810 | 21890 |
| NavierStokes | 7214 | 7257 |
| PdfJS | 6328 | 6449 |
| Mandreel | 2186 | 2191 |
| MandreelLatency | 25051 | 25051 |
| Gameboy | 13131 | 13144 |
| CodeLoad | 28823 | 28783 |
| Box2D | 6979 | 7021 |
| zlib | 3387 | 3392 |
| Typescript | 21736 | 21696 |
| Score (version 9) | 6400 | 6552 |

There is a real tradeoff: a synthetic construction-only loop creating one million regexps had a seven-pair median **655→705 ms (+7.6%)**. The earlier two-pass version took 666→722 ms (+8.4%); a single-pass scan reduced that overhead. Full Octane CodeLoad medians were 28823→28783 (-0.14%), which does not establish a general compilation regression or its absence. The 64-bit `ReCompiled` struct grows from 48 to 64 bytes per compiled regexp. `/usr/bin/time -l` was unable to report peak RSS because `sysctl kern.clockrate` was denied; GC pauses and independent compilation CPU attribution were not measured.

## Correctness

The local regression covers alternatives, optional and quantified literals, escaped punctuation, unsupported escapes, lookbehind, case-insensitive matching, sticky and global lastIndex, Unicode/surrogates and match indices. A 51,000-result generated pattern/input matrix matches the preceding release build and Node exactly; the exact final ARM64 ASan and x86-64 binaries also match it. Both control and final candidate pass all **1,879** selected `built-ins/RegExp`, **240** `language/literals/regexp`, and **1,073** `built-ins/String/prototype` Test262 cases with identical verdicts. The exact build passes ARM64 and x86-64 JIT embedding. Interpreter/JIT differential suites match for local (both status 1, existing feature-limited baseline), Rosetta and modules (both status 0). `clang -Wall -Wextra` reports no warnings for the wrapper.

The active goal is not complete: 6552 is still below 50,000. JIT cyclic SSA, effectful calls, code quality and coverage remain open, as do other runtime bottlenecks.
