# SSA latch recovery without artificial loop phis

Rat `34f224e0`, control `9da6427e`, macOS ARM64. This separates a latch
recovery use from loop-carried state; it does not implement cyclic function
SSA or achieve the 50K full-Octane target.

Previously the loop budget check happened after parallel phi copies and its
exit snapshot contained phi homes. Therefore a branch operand overwritten at
fallthrough had to acquire a loop-carried phi solely so the interpreter could
replay that branch on a budget exit. The candidate checks the budget before
copying, and snapshots post-body phi inputs plus the original branch operands.
The ordinary no-exit path then performs phi copies. The separate truthiness
fallback after copies retains its existing published predicate. Every converted
phi input is held live until the latch: all inputs are consumed concurrently,
so a later conversion must not reuse an earlier input's home.

## Bytecode and native code

For `jitNativeStep`, `LDREG r4=r2` at pc 9 feeds `JMP_LT r4,r3` at pc 10;
`GETTHISC r4` immediately overwrites r4 at pc 11. Control graph diagnostics
show slot 4 `livein=0 exitlive=1 phi=3`; candidate shows `livein=0 exitlive=0
phi=-1`. The candidate still materializes r4 from the pre-copy frame on a
budget exit. `native-step-bytecode.txt` and `native-*-phi.txt` show this.

Matched SLJIT_STATS builds with diagnostic-only code extraction produced
1036→1012 bytes, 259→253 static ARM64 instructions and 64→61 static
loads/stores; conditional branches remain 31. Ranges include cold exits. In the
control hot latch, the incremented r2 is boxed into a tagged value and moved
into the r4 phi before the budget comparison. The candidate compares budget
first and copies only actual loop-carried values; r4 boxing moves into the cold
recovery stub. Raw emitted bytes, `clang -arch arm64`/`otool -tvV`
disassemblies, and instrumentation patches are included. Machine-code hashes
from independently instrumented builds matched their respective captures.

Not every range shrinks. Navier–Stokes `lin_solve` pc 47–65 remains 5736 bytes
and 1434 instructions, with static loads/stores 329→335. Its `project` pc
86–110 grows 7812→7960 bytes, 1953→1990 instructions and 509→523 static
loads/stores, reflecting a larger cold recovery snapshot. These are static
counts including cold code, not dynamic CPU attribution.

## Measurements

Five alternating minis (control→candidate median ms): Navier–Stokes 190→189,
Mandreel 555→557, Gameboy 276→275, PdfJS 359→358, Crypto 164→164,
TypeScript 1235→1225. Five 100-iteration Navier–Stokes pairs: 2032→2028 ms.
A warmed 20,000-call native-drive probe: 258→258 ms; diagnostic runs show both
execute the same 82527 SSA-loop iterations. These are neutral/noisy screens,
not claims of speedup. Sources and raw samples are included.

A compilation-heavy probe installing 249 functions/75 loops has 8→8 ms median
across seven pairs. Its generated code is 945180→946668 bytes; five `wait4`
peak-RSS samples have medians 8110080→8126464 bytes. This short probe cannot
resolve small CPU or memory changes.

One alternating original full-Octane pair passed all checks and yielded
6233→6370, with Box2D 4836→6945 and PdfJS 7370→6548. The different native
admission was 174 functions/101 loops/2376732 bytes versus 174/100/2375036.
One pair with large opposing workload swings does not establish an aggregate
improvement; the full score is nowhere near 50K. Full results and hashes are
included and should not be compared across unrelated timing windows.

## Validation

54 jit*/sljit* fixtures agree in interpreter, JIT and stress modes. The new
boxed-pressure fixture runs an SSA loop with eight exit-only values (39 hits,
812 iterations). ARM64 and x64 embedding checks pass, as do x64 and ASan runs
of the boxed and high-register fixtures and ASan native-call coverage. The
local/Rosetta/modules differential matches; local status 1 is the existing
feature-limited baseline, while the other two return 0. Diagnostic allocation
checks found no simultaneous phi-input home collisions in the sampled boxed
and Navier workloads; the lifetime extension expresses the required invariant,
not a claim that those samples exposed an existing miscompile.

General cyclic function CFG/SSA, recovery through effects and calls, precise
WIDE/aliased-region liveness, code-budget economics and the 50K score remain
open. The full-frame snapshot prototype was neutral on minis but generated a
larger `project` range; the retained sparse snapshot reduced that growth.
