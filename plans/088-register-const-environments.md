# Register-only const bindings

Experiment on 2026-09-20 against an immutable release binary built from
`49d04ee3`. The compiler removes PUTLEX_C for eligible uncaptured bindings
whose names have no runtime environment consumers. Its existing scope pass
then removes lexical pushes and pops when no bindings or depth-dependent
operations remain. Const writes and TDZ checks retain their environment
bindings; eval, with, captures, arrows, generators, and async functions keep
the existing eligibility restrictions.

The name dependency buffer retains all potentially observed bindings when
full. GETBOUND also forces retention because it addresses a depth/name pair
rather than a canonical name constant. Names are tracked across the whole
function, conservatively retaining same-named bindings in separate scopes.

`get_env_name_operand` in bytecode.c3 centralizes environment consumers and
identifies BC, C, and indirect name operands. It includes fused CALL_VAR /
TAILCALL_VAR and PUTVAR_SNAP alongside ordinary variable accesses. The
regression fixture checks that calling a binding before initialization still
throws ReferenceError.

## Environment counts

GC_PROFILE includes environment creation requests split into function,
declarative, and object scopes. Counters are omitted from normal builds.
The existing allocations counter measures HObject allocations, not every
allocator request or allocated string.

| ES6 workload | Baseline declarative environments | Candidate |
|---|---:|---:|
| class | 5 | 3 |
| closure_capture | 2,000,003 | 2,000,003 |
| destructuring | 1,750,009 | 500,003 |
| forof | 20 | 5 |
| let_loop | 200,006 | 200,006 |
| promise | 210,011 | 210,009 |
| spread_rest | 400,006 | 2 |
| template_literal | 1,000,007 | 1 |

Template HObject allocations fall from 1,000,912 to 906, with GC cycles
falling from 977 to 1. Destructuring HObject allocations fall from 6,000,921
to 4,750,915; spread/rest falls from 1,600,917 to 1,200,913.

These counts identify redundant lexical materialization as a shared cost.
They do not establish the cost of call setup, indexed captures, or generic
iterator handling. Closure capture retains two million declarative scope
creations, and rest parameters retain 400,000 function scope creations in
the combined spread/rest benchmark. Those are separate opportunities.

## Timing

Five whole-process runs per engine, rotating baseline/candidate/QuickJS order
on each repetition, with no concurrent builds or validation jobs. Values are
medians from perf_counter timing; every subprocess exit status is checked.
Scripts are unchanged. Their own assertions remain the runtime oracle; this
experiment does not strengthen promise completion checks.

| Workload | Baseline | Candidate | QuickJS | Time reduction |
|---|---:|---:|---:|---:|
| class | 0.9117s | 0.9224s | 0.2777s | -1.2% |
| closure_capture | 0.2344s | 0.2299s | 0.1508s | 1.9% |
| destructuring | 0.9549s | 0.8585s | 0.2373s | 10.1% |
| forof | 0.3097s | 0.3006s | 0.0525s | 2.9% |
| let_loop | 0.1666s | 0.1667s | 0.2183s | -0.1% |
| promise | 0.7213s | 0.7277s | 0.2254s | -0.9% |
| spread_rest | 0.2975s | 0.2688s | 0.1820s | 9.7% |
| template_literal | 0.2390s | 0.1598s | 0.1169s | 33.1% |
| Sum of medians | 3.8351s | 3.6344s | 1.4610s | 5.2% |

The aggregate ratio falls from 2.63× to 2.49× QuickJS.
Changes below 3% are not attributed to this optimization.

Peak RSS is unmeasured: `/usr/bin/time -l` cannot read kern.clockrate under
the sandbox. Allocation counts do not establish a peak-memory reduction.

## Validation

- 42 Rosetta cases and the local suite: 447 plain scripts plus module,
  syntax, error-reporting, robustness, console, Temporal, and TS fixtures.
- 1,796 passing test262 cases across const, let, block, for, for-of, and
  assignment/dstr; no skip-list changes.
- A freshly built ASAN + GC_STRESS binary passes register_const_environments
  and empty_lexical_environments. The new fixture covers const writes,
  TDZ, sloppy delete, eval, with, captures, shadowing, abrupt exits,
  dependency-buffer overflow, and a heap value retained across allocations.
- The focused fixture also passes in Node.

A separate exploratory repro finds an existing correctness issue in both
baseline and candidate: `const x = 1; [x] = [2]` and
`const x = 1; ({x} = {x: 2})` complete without TypeError. This remains a
separate bug; the targeted test262 directory does not expose these cases.

Raw profiles, validation logs, the immutable baseline binaries, and benchmark
samples are in `/tmp/boomkat-env-experiment/`.
