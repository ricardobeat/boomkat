# TINY core-builtin and runtime cleanup prototype

Worktree: `/tmp/boomkat-tiny-llvm-size`, branch `tiny-llvm-size`.
The main checkout is untouched. This prototype keeps generators, for-of,
private fields, strict module execution, async functions, Date and JSON.
Legacy builtin APIs remain; this pass targets the selected newer APIs and
execution paths unavailable to strict-only, loader-free profiles.

## Size

macOS ARM64, C3 0.8.4 / LLVM 23.1.1. External LLVM 23.1.3 regenerates
the separate-module objects for the unwind experiment. Executables are
dead-stripped and native-symbol-stripped.

| Configuration | Reference bytes | Core-profile bytes | Saved |
| --- | ---: | ---: | ---: |
| Existing TINY optimization settings | 784,080 | **734,176** | 49,904 |
| Separate modules | 718,352 | 668,432 | 49,920 |
| Separate modules, suppressed native unwind | 652,224 | **602,304** | 49,920 |
| Normal executable | 2,556,744 | **2,556,744** | 0 |

The smallest tested executable remains 102,304 bytes above 500,000 bytes.
The ordinary TINY code section shrinks from 612,396 to 565,048 bytes
(47,348 bytes). An intermediate catalog-only build removed 35,200 code
bytes; runtime cleanup accounts for roughly another 12 KB. File deltas
are affected by Mach-O segment alignment and signing metadata.

## Profile boundary

`CORE_BUILTINS_ONLY` selects one catalog capability, `EXTENDED_BUILTINS`,
for both the TINY generator and runner. The enum keeps stable ordinals;
unselected public handlers and their exclusive internal callbacks have
null pointers. Registration omits those methods. The capability header
uses bit 2048 to identify this smaller catalog and reject mismatched images.

The excluded API list is checked in `test/bytecode/core_builtins.js`:

- Array.fromAsync; flat/flatMap, findLast/findLastIndex, toReversed,
  toSorted, toSpliced, with and at.
- Promise.any, allSettled, withResolvers and try. Promise.all/race,
  resolve/reject, then/catch/finally and async functions remain.
- Object.groupBy, fromEntries, getOwnPropertyDescriptors and hasOwn.
- String.replaceAll, matchAll, isWellFormed, toWellFormed, padStart,
  padEnd and at.
- Math.sumPrecise, Error.isError, JSON.rawJSON and JSON.isRawJSON.

`Opcode.is_enabled()` centralizes opcode availability. Image validation
rejects unavailable instructions, and constant guards remove their execution
families. Strict-only profiles exclude DELVAR, WITH_START, WITH_END, WITHGET,
WITHBASE and WTWR. Profiles without module loading exclude DYN_IMPORT,
DYN_IMPORT_DEFER, DYN_IMPORT_SOURCE and IMPORT_META. Source parsing and the
loader are already excluded from TINY; this removes residual VM handling.

`EnvRecord.is_with()` folds false in strict-only builds and expands to the
existing flag read in normal builds. Environment lookup, calls and captures
share the predicate. The full profile folds all new opcode guards away.
SLIM retains its builtin catalog and benefits from strict-only cleanup.

The builtin-sharing experiments are recorded in the separate audit. No generator/iterator backend removal is included.

## Validation

- 136 bytecode checks across ordinary, separate-module and no-unwind variants.
  Includes absent registrations, retained async/Date/JSON/generators/private
  fields/for-of, capability mismatch and ten forged excluded opcodes.
- 18 normal/SLIM profile checks.
- Normal local suite: 586 scripts, 28 ESM fixtures and all subordinate suites
  passed; the configured async stress test remains skipped.
- Normal Rosetta: 42 passed, zero failures.
- Differential local-fixture sweep: 313 matching zero-exit executions,
  92 files rejected by the compiler, 179 rejected by the reduced runtime,
  and two explained output differences. `test_long_string_keys.js` skips
  three conditional checks for absent APIs; `builtin_as_callback.js` reports
  flatMap/toSorted unavailable, alongside its existing unsupported-feature
  failures. Zero-exit does not imply every fixture's printed assertions pass.

The differential sweep uses bytecode from the core compiler. It clears only
the new catalog bit in a copy for the reference runner, so both execute the
same instructions. Production readers retain exact capability matching.

## Performance

Fifteen shuffled process runs per benchmark, compilation excluded, startup
included. Outputs match. Ratios are against each build's reference; values
above 1 mean more elapsed time.

| Benchmark | Core TINY | Core TINY, size-tuned | Normal |
| --- | ---: | ---: | ---: |
| Loop | 1.000x | 1.204x | 1.015x |
| Function calls | 1.037x | 2.410x | 1.003x |
| Property lookup | 0.993x | 1.436x | 0.981x |
| Prototype IC | 1.007x | 2.057x | 0.991x |
| Arrays | 1.021x | 1.447x | 1.012x |

Normal's size is unchanged and these measurements show no material slowdown.
TINY's existing optimization settings preserve approximately its measured
speed; the separate-module size experiment remains a substantial tradeoff.
Raw samples are in `tiny-core-timings.json`; reproduce with
`scripts/time_core_profile.py` using the isolated reference builds.

## Reproduction and artifacts

`just build-tiny` builds the ordinary 734 KB prototype from this branch.
`just test-tiny` exercises the profile and image checks.

The external LLVM experiment needs a separate-module export:

```
mkdir -p out/build/core-separate-ir out/core-separate-ir out/core-ir-separate
c3c build boomkat_tiny --build-dir out/build/core-separate-ir \
  --output-dir out/core-separate-ir --single-module=no --show-backtrace=no \
  --macos-min-version 27.0 --keep-obj --emit-llvm \
  --llvm-out out/core-ir-separate --print-linking \
  -z -Wl,-exported_symbols_list,scripts/no_exports.exp -z -Wl,-dead_strip \
  > out/core-separate-ir/build.log 2>&1
python3 scripts/probe_tiny_llvm.py control --split --core
python3 scripts/probe_tiny_llvm.py no-unwind --split --core --no-compact-unwind
```

The 602 KB runner is at
`out/no-unwind-core-separate-no-compact/boomkat_tiny`; the matching generator
is at `out/core-compiler/boomkat_tiny_compile`. Both use the smaller catalog.
Native unwind suppression has the host-unwinding limitations described in
`tiny-llvm-size.md`; JavaScript exceptions retain their engine-managed paths.
