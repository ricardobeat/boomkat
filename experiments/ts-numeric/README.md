# Guarded TypeScript numeric-region experiment

The experiment supports safe, bounded numeric specialization, but does not establish a benefit specific to TypeScript annotations. A plain-JavaScript selection policy chooses the same guarded regions and achieves essentially the same timings. Keep this disabled by default; the evidence supports further work on sufficiently long, double-heavy regions rather than general annotation-driven optimization.

Worktree: `/private/tmp/boomkat-ts-specialization`. Branch: `prototype/ts-numeric-specialization`, based on `bb4738ea`. No merge. No Test262 command or suite was run.

## Implementation

`Parser.ts_annotation` retains an exact primitive `number` token on identifier bindings using an existing AST flag byte. No AST column or function-record allocation was added. Unions, arrays, aliases, and return types supply no hint. Only ordinary function/method parameter binding paths retain the hint; typed arrows are deliberately excluded.

The compiler considers functions with 1–8 parameters, at most 32 registers and 96 original instructions, with no rest/default/destructured parameters, argument-object use, closures, eval, with, asynchronous execution, generators, or required runtime environment. A whitelist proves a single straight-line region ending in `RET`. Guarded parameters seed the Number proof; numeric constants, register copies, `+ - * /`, and immediate arithmetic propagate it. Calls, property access, branches, and observable stores reject the whole function. Local parameter writes are safe when they cannot be observed through `arguments` or a closure.

One `NUMERIC_REGION` instruction is prepended. Every parameter is checked for an actual Number (fastint or double) before the body runs. On refusal, execution starts at the original generic bytecode without conversion, writes, or replay. On success, a small interpreter executes the same operations using a 32-element binary64 scratch array and publishes only the return value. The original bytecode is also the numeric-region program, so the body is not cloned. The ordinary switch and threaded VM both support the prefix. `--no-optimize` skips specialization.

The scratch array is intentionally `@noinit`: the compiler proves every read initialized. The original prototype zeroed 256 bytes on every invocation; raw measurements for that version remain in `results-zero-initialized.json`. Scratch storage still adds 256 bytes; the final arm64 handler uses a 352-byte native frame including saved registers and stack protection. Assembly inspection confirms separate arithmetic instructions and intermediate scratch stores, without per-access array bounds checks.

Every arithmetic instruction preserves the original association and a binary64 intermediate boundary. There is no integer narrowing, reassociation, FMA substitution, or general deoptimization. Wrong annotations can return strings, compute BigInts, invoke conversion objects, or throw through the original JS bytecode. The runtime still applies the existing strict/sloppy call behavior.

The selectable modes are:

| Flag value | Selection | Return representation |
| --- | --- | --- |
| `off` (default) | Existing optimized bytecode, including `ADD_FUSED` | Existing behavior |
| `annotations` | Every simple parameter has exact `number` annotation | Double |
| `infer` | Any otherwise eligible numeric-shaped JS function | Double |
| `annotations-compact` | Same annotation selection | Exact integral results may use fastint; preserves negative zero |

`infer` is guarded bytecode-shape speculation, not a claim that untyped JS parameter types can be proved statically. Every enabled mode performs entry checks. The compact-return ablation preserves all intermediate Number rounding and converts only the final exact value within fastint bounds; NaN, infinities, and negative zero remain doubles.

## Runtime measurements

Apple arm64 Darwin 27.0, C3 0.8.5 / LLVM 23.1.3, release `boomkat` target (`O2`, existing relaxed FP configuration, threaded dispatch). These are one-machine focused microbenchmarks, not device or application-level evidence.

Each generated program warms up 20,000 calls, then times five million calls using `Date.now()`. A separate process is used for every trial. Job order is deterministically shuffled. Every run's checksum must agree across all policies, and both the in-program time and process wall time are retained. This makes the main timing 100–800 ms rather than timer-resolution scale. Timings include the caller loop and checksumming, so they intentionally capture effects on callers as well as on the kernel.

`results.json` contains nine repetitions with the pre-change baseline executable and the three initial policies, after removing scratch zeroing. Median milliseconds:

| Kernel | Existing generic | Annotations | JS selection | Original baseline |
| --- | ---: | ---: | ---: | ---: |
| One add, fastint | 104 | 150 | 150 | 108 |
| Four-argument sum, fastint | 147 | 177 | 175 | 149 |
| Four-argument sum, double | 222 | 229 | 229 | 227 |
| Eight operations, integer inputs | 240 | 242 | 241 | 246 |
| Eight operations, double inputs | 273 | 272 | 272 | 279 |
| Twenty operations, integer inputs | 304 | 314 | 312 | 307 |
| Twenty operations, double inputs | 422 | 370 | 369 | 427 |
| Wrong string annotation | 772 | 792 | 784 | 785 |
| One string every sixteen calls | 219 | 248 | 246 | 222 |

The clear positive case is the twenty-operation double kernel: 12.3% less elapsed time against same-binary generic. One fastint add costs 44% more, and the four-argument fastint sum costs 20% more. Near-equal mixed-arithmetic results do not justify a speedup claim. Generic arithmetic is already numeric-aware, and `ADD_FUSED` executes two additions in one threaded handler. The region's own switch dispatch still executes once per original arithmetic instruction; it primarily removes repeated tag/coercion/release/boxing work.

An always-double return changes subsequent caller arithmetic from fastint to double even when the Number value is integral. That is an important limitation of the initial region implementation. The final-return compaction ablation is recorded separately in `results-compact.json`: seven randomized repetitions in the final executable. One-add fastint timings are generic 104 / double region 153 / compact region 149 ms; the four-argument fastint sum is 146 / 178 / 170 ms. Compaction recovers only a small part of the loss. The boundary checks, conversion, and region interpreter still cost more than the existing short fastint path. The twenty-operation double kernel remains clearly favorable at 422 / 372 / 373 ms (about 12% lower elapsed time). Compaction adds work to fractional-result cases: the eight-operation integer-input kernel is 240 / 241 / 250 ms. These measurements do not isolate a cycle count for each cost, but do rule out the return tag as the sole cause of the short-function regressions.

## Compile and size costs

`compile_cost.py` generates 3,000 four-parameter/eight-operation TS functions and compiles without executing or disassembling during timing. Nine randomized repetitions measure the debug CLI's compile-stage clock and child maximum RSS. Instruction counts are obtained separately.

Final measurements were 23,377 µs median generic versus 23,505 µs annotation selection and 23,348 µs JS selection; the timing ranges overlap. This provides no evidence of a meaningful compile-time regression or improvement. The corpus grows from 36,001 to 39,001 instructions: exactly four bytes per selected function, or 12 KB total. Maximum RSS was approximately 12.4 MB in every policy; process-level RSS cannot reliably resolve that 12 KB difference.

The parser uses a spare existing flag bit, and CompiledFunction gains no fields or extra constant pool. The compiler uses a 32-boolean proof scratch array and one candidate boolean in its transient compiler context. Prepending temporarily holds both the original instruction allocation and the new allocation, then frees the old buffer. Source-map PCs shift by one; no extra persistent source-map entry is required. The final native `__text` section grows by 2,216 bytes (about 0.14%); the executable grows by 224 bytes (2,187,000 → 2,187,224) because existing segment padding absorbs most changes. Complete Mach-O section measurements are in `binary-size.json`.

## Validation and reproduction

Focused fixtures exercise 225 numeric input pairs plus negative zero, NaN, infinities, fastint and safe-integer boundaries, association, multiply/add intermediate rounding, immediate arithmetic, missing parameters, wrong strings, BigInts and mixed BigInt errors, Symbols, coercion order and exceptions, parameter writes, unions/default/rest exclusions, strict methods, sloppy duplicate parameters, and mapped arguments. The numeric fixture is run as both a classic script and a module. The existing local TypeScript corpus, including its TypeScript compiler oracle, passes. Existing `threaded_numeric_ops.js`, `strictness_does_not_leak.js`, and `arguments_register.js` pass under JS selection. Both the switch-only debug VM and the alternate NONANBOX representation were checked. The NO_TYPESCRIPT slim target also builds and executes an inferred numeric JS function successfully.

```sh
just build boomkat
c3c build boomkat_debug --macos-min-version 27.0
./out/boomkat --numeric-specialization=annotations --script experiments/ts-numeric/regression.ts
./out/boomkat --numeric-specialization=annotations experiments/ts-numeric/regression.ts
./out/boomkat --numeric-specialization=annotations-compact --script experiments/ts-numeric/regression.ts
./out/boomkat --numeric-specialization=annotations-compact --script experiments/ts-numeric/sloppy.ts
./out/boomkat_debug --numeric-specialization=annotations --no-optimize experiments/ts-numeric/regression.ts
./out/boomkat_debug --numeric-specialization=annotations -c experiments/ts-numeric/sample.ts
bash experiments/ts-numeric/validate.sh
python3 experiments/ts-numeric/bench.py --runs 9 --iterations 5000000
python3 experiments/ts-numeric/bench.py --compact --runs 7 --iterations 5000000 --output results-compact.json
python3 experiments/ts-numeric/compile_cost.py
```

The benchmark generator writes only to ignored `generated/`. The optional `--baseline PATH` uses a separately retained executable from `bb4738ea`; baseline binaries are not checked in. NONANBOX validation used `c3c -D NONANBOX build boomkat --build-dir out/build/boomkat_nonanbox --macos-min-version 27.0`, saved that executable, and restored the normal release executable afterward.

## Recommendation and limits

Keep the pass opt-in and do not generalize from this result to native typed code. The experiment has no checked object layouts, typed arrays, loops, effectful numeric regions, cross-function proofs, or full TypeScript checking. Static Hermes/MakeCode/asm.js-style assumptions are not silently imported: ordinary JavaScript values always retain an ordinary fallback.

A longer double-heavy region is feasible with small bytecode and compile-memory costs. Annotations provide a simple selection hint, not an additional runtime proof or a demonstrated speed advantage over guarded JS selection. VM tracing/profiling observes the region prefix and return rather than every virtual arithmetic step inside the successful region. A production candidate would need a profitability threshold, an explicit policy for fastint representation at region boundaries, representative low-powered-device workloads, and profiling before deciding whether further dispatch/boxing changes are worth their code and stack costs.
