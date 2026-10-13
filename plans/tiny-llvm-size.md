# TINY LLVM size experiments

Branch: `tiny-llvm-size`, based on `embedded-bytecode-runtime` at `75bd9d5d`.
Worktree: `/tmp/boomkat-tiny-llvm-size`. Production source and profile defaults
are unchanged. All output and build directories persist under `out/`.

Host: macOS ARM64. C3 0.8.4 embeds LLVM 23.1.1; the external LLVM tools are
23.1.3. Measurements use native dead stripping and final `xcrun strip`.
External LLVM's separate-module control reproduces the C3 binary's file size
and 534,764-byte code section, so that is the controlled comparison for
unwind and outlining probes.

## Results

| Configuration | Executable bytes | Machine-code bytes |
| --- | ---: | ---: |
| TINY baseline | 784,080 | 612,396 |
| Explicit function merging enabled | 784,080 | 612,396 |
| Function merging disabled | 784,128 | 616,456 |
| Separate C3 modules | 718,352 | 534,764 |
| External LLVM control, separate modules | 718,352 | 534,764 |
| Separate modules, C3 unwind attributes removed | 668,736 | 538,676 |
| Above, compact unwind output also disabled | **652,224** | 538,676 |
| Separate modules, forced machine outlining | 718,352 | 534,764 |
| Separate modules, two additional outlining passes | 718,832 | 531,652 |
| Separate modules, machine outlining disabled | 781,872 | 608,392 |

The smallest reproducibly named `boomkat_tiny` artifact saves 131,856 bytes
(16.8%) from baseline and remains 152,224 bytes above 500,000. An earlier link
under the filename `no-compact` is 652,216 bytes: the eight-byte difference
is link/signing metadata, with identical section sizes. Additional outlining
plus unwind suppression produced 652,680 bytes under that earlier filename,
so it did not improve file size.

Function merging is already enabled by the C3 O2 preset. Explicitly enabling
it changes nothing. Machine outlining is also active for minsize functions:
disabling it adds 73,628 machine-code bytes to the separate-module control.
Additional passes reduce code by 3,112 bytes but grow the file by 480 bytes;
segment alignment and link metadata matter at these sizes.

C3 adds `uwtable(sync)` to functions and an `uwtable` module flag even when
backtraces are disabled. The probe removes the attributes and clears the
module flag before code generation. Apple linker `-no_compact_unwind`
suppresses the remaining compact table. C objects are held constant; 88
bytes of `.eh_frame` remain. The code section grows by 3,912 bytes when
unwind information changes outlining decisions. Native stack unwinding and
profiling are reduced; JavaScript exceptions use engine-managed catchers.
This is an experimental executable configuration, not a general embedding
ABI guarantee for hosts that unwind through engine frames.

## Validation

- Separate modules and explicit merging: 71 bytecode checks passed.
- Five LLVM variants and two unwind-suppressed links: 216 checks passed.
- Outlining-disabled, three whole-module pipeline probes, merging-disabled:
  158 checks passed.
- Final 652,224-byte artifact: 42 checks passed.
- Local-fixture differential sweep on the equivalent 652,216-byte link:
  319 passing baseline programs produced identical results; 92 source files
  could not compile for TINY and 175 failed on baseline. No differences or
  timeouts. These exclusions do not count as passes.

The checks cover retained async/generators, Date, JSON, strict module behavior,
exceptions, classes, closures, wide calls, GC and corrupt-image rejection.
ASAN was not needed for these code-generation-only experiments.

## Performance

Fifteen shuffled process runs per benchmark, after compiler jobs finished;
ratios are median elapsed time divided by current TINY. Startup is included.
Benchmark stdout matches across configurations. These are local microbenchmarks,
not a prediction for every application.

| Benchmark | Separate modules | Separate + no unwind |
| --- | ---: | ---: |
| Loop | 1.33x | 1.21x |
| Function calls | 2.54x | 2.23x |
| Property lookup | 1.56x | 1.37x |
| Prototype IC | 2.09x | 1.89x |
| Arrays | 1.52x | 1.43x |

The smallest configuration trades meaningful runtime speed for size.
The timing script is `scripts/time_tiny_llvm.py`; raw samples are stored in
`out/timings/results-idle.json` and copied beside this report.

## Reproduction

Run from this worktree. Each C3 invocation needs pre-created parent output
and build directories. Use this common argument set:

```
--show-backtrace=no --macos-min-version 27.0
-z -Wl,-exported_symbols_list,scripts/no_exports.exp -z -Wl,-dead_strip
```

Build `boomkat_tiny` into `out/separate` with `--single-module=no`; build into
`out/merge` with `--merge-functions=yes` and into `out/merge-off` with
`--merge-functions=no`. Strip the resulting executables.

For the LLVM probes, build with `--single-module=no --keep-obj --emit-llvm
--llvm-out out/ir-separate --output-dir out/separate-ir
--build-dir out/build/separate-ir --print-linking`, saving combined output
to `out/separate-ir/build.log`. `--emit-llvm` also enables expensive compiler
verification. The full single-module export was stopped after six minutes;
the separate-module export completed.

```
python3 scripts/probe_tiny_llvm.py control --split
python3 scripts/probe_tiny_llvm.py no-unwind --split
python3 scripts/probe_tiny_llvm.py no-unwind --split --no-compact-unwind
python3 scripts/probe_tiny_llvm.py outline --split
python3 scripts/probe_tiny_llvm.py outline-rerun --split
python3 scripts/probe_tiny_llvm.py no-outline --split
python3 scripts/probe_tiny_llvm.py combined --split
```

Results and section breakdowns are saved in each variant's `result.json`.
The runner uses persistent directories and contains no recursive deletion.

## Secondary whole-module IR pipeline

An independent pipeline exports IR with `--optsize=none --optlevel=none`,
adds `minsize optsize` to the C3 function attributes, then runs LLVM 23.1.3
`opt -passes='default<O2>' --enable-merge-functions --vectorize-loops
--vectorize-slp`. This LLVM version rejects `default<Oz>` and explicitly
directs callers to O2 plus minsize attributes. `llc -O2` then generates
objects, using the original C objects and link command.

Its control is 784,096 bytes with 619,660 machine-code bytes, so it differs
from the production pipeline and must not be used for an exact baseline
comparison. Within this pipeline, unwind suppression yields 734,480 bytes;
extra outlining yields 784,640 bytes. All passed bytecode checks. The primary
separate-module experiment above uses actual optimized C3 IR instead.

## Builtin sharing

See [the separate audit](tiny-builtin-sharing/report.md). Measured code savings
are 2,040 bytes for eight Date
setters, 688 for Array find methods and 544 for string padding. They were
tested independently; adding the savings is not established. The four
Promise combinator bodies span only 7,596 bytes in the linked TINY baseline,
which bounds the potential benefit of sharing their common driver.
