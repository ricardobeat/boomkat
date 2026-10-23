# Eval compiler optimization review

2026-10-23, Apple M3, macOS 27, C3 0.8.5. Work and measurements use
`boomkat-gcmem`; starting runtime is `c8f22d0a`, retained runtime is `8cd3bc3f`.

CodeLoad uses indirect eval to compile and initialize Closure and jQuery.
The investigation compared both engines' actual indirect-eval bytecode, not
ES module loading. QuickJS's local source was compiled into a temporary dumper
with `DUMP_BYTECODE=1`; production benchmark binaries were preserved.

| Source | Functions, each engine | Boomkat static ops | QuickJS static ops |
|---|---:|---:|---:|
| Closure | 58 | 1640 | 1794 |
| jQuery | 533 | 25006 | 27579 |

These register and stack VM operations are different units of work, so their
counts do not imply equivalent execution cost. They do show that Boomkat's gap
is not explained by emitting twice as many operations. Native CPU profiles put
11–14% of samples in register liveness and another 6% in jump-target building.
QuickJS resolves variables and labels and computes operand-stack height;
Boomkat performs multiple optimization and register-liveness passes.

Retained changes:

- `cc943d86`: derive liveness inputs in place. A changed output already schedules
  propagation; remove redundant input comparisons, copies, and two working sets.
- `06a3b78d`: size temporary tables by emitted instruction count. Bytecode buffer
  capacity starts at 512 even for tiny functions, and the optimizer initialized
  its liveness records for those unused slots.
- `8cd3bc3f`: share jump-target and try-region maps across passes that preserve
  control flow. Rebuild after return threading only when strict tail-call
  analysis needs the result. Inline constant fusion rules so their callbacks
  specialize instead of dispatching indirectly for every instruction.
- `0cb08b85`: add `boomkat_debug --eval` to inspect indirect-eval bytecode.

Each change was measured against the preceding retained binary. Compiler-only
numbers are medians of 15 alternating pairs using the same O3 inspection target;
CodeLoad uses seven alternating pairs of the same production full-ICU target.
No builds or correctness tests ran during these comparisons.

| Change | Closure compile, before → after (µs) | jQuery compile, before → after (µs) | CodeLoad score, before → after | Score gain |
|---|---:|---:|---:|---:|
| In-place liveness | 1116 → 1091 | 15828 → 15479 | 12031 → 12437 | +3.37% |
| Actual instruction counts | 1042 → 1010 | 15058 → 14527 | 11630 → 13050 | +12.21% |
| Shared maps and specialized rules | 975 → 925 | 13549 → 12899 | 14625 → 15273 | +4.43% |

Absolute scores drifted between experiments; compare the paired before/after
values within each row. Their product suggests about 21% cumulative gain, but
a direct combined comparison has not been measured. This does not establish
the requested 50–100% gain or parity with QuickJS.

Timed CodeLoad runs allocate more when faster, so peak RSS grows with their work
volume. These changes reduce compiler scratch storage; the timed-run RSS values
in the raw data are not fixed-work memory comparisons.

Validation of the final source:

- Identical complete function-tree dumps for all 659 local JS fixtures and both
  extracted libraries, including flags, registers, constants and captures.
- 32/32 golden snapshots, including the disabled-optimization check.
- Full test262: 53,264 passes, zero failures, existing 352 exclusions unchanged.
- ASAN + GC_STRESS + GC_VERIFY + pool bypass: 46/46 pass.
- Both NaN-boxed and NONANBOX local suites: 658 scripts, 32 modules, all auxiliary
  groups and 39 private-class fixtures pass.

Disabling optimization was only a diagnostic: Closure eval ran about 67% faster,
but used more memory, and jQuery fails in that debug mode. No optimization was
disabled in the retained production code. Smaller initial compiler capacities
were not retained because that experiment had not been measured.

[Raw alternating samples, binary hashes and validation totals](results.json).
Full disassemblies, profiles and diagnostic sources remain in ignored
`out/eval-optimization/`.

To inspect equivalent input through Boomkat's eval compiler:

```sh
c3c build boomkat_debug
./out/boomkat_debug --eval --dump-code path/to/source.js
./out/boomkat_debug --eval --check -d path/to/source.js
```
