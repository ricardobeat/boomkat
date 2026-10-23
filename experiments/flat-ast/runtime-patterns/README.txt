Initial runtime pattern prototypes, before rebasing onto current main
==================================================================
One alternating serial pair per unchanged Octane mini input; no warmups.
Baseline is the prior flat-ast-optimizations release binary (13a9a361 code).
Candidate adds compact expression kinds and redundant Int32 coercion removal,
fastint add/subtract + |0 pairs, fastint bit-mask + strict-zero-branch pairs,
and immediate signed/unsigned shift + typed-array access pairs.
The ordinary consumer is retained for switch dispatch and partial fallback.

All 30 benchmark processes passed their embedded checks. See results.json for
component timers, process wall/CPU time, RSS and binary/source hashes; summary.csv
for combined embedded timers. Zlib 8154 -> 7268 ms (-10.9%); Mandreel 1505 -> 1318
ms (-12.4%). Other changes are mixed, up to +3.5% time; geometric mean ratio
0.9917 (~0.8% less time). One sample does not establish statistical confidence.

IMPORTANT: this older baseline lacks main's threaded typed-array handlers.
These gains include introducing typed-array fast paths at fused access sites;
they do not establish an incremental gain over current main. A comparison after
rebasing onto main is required and supersedes these numbers for that purpose.
No per-family attribution or dynamic guard-hit measurements were performed.

Minimal validation: one focused regression in release script/module and debug
unoptimized script/module; canonical bytecode confirms all eight paired opcode
variants are emitted. BigInt/coercion/overflow/IEEE values, numeric typed-array
kinds, bounds, proxy access and observable conversions are exercised. Test262
and broad suites were deliberately deferred. No claim of comprehensive validation.
The fixture is function-scoped: an earlier global-scoped version exposed an
existing unoptimized-script failure also reproduced on bb4738ea, avoided here
so this focused check does not depend on that unrelated preexisting issue.

This is a narrow speed prototype: facts describe expression results, not local
variable flow; arithmetic fast paths accept fastints; bit branches match strict
zero comparisons; shifted accesses require an immediately adjacent consumer.
Postincrement fusion, separated temporary indexes, Number-double arithmetic
pairs, loose-zero comparisons and generic dense-array fusion remain future work.

Reproduce with release builds at the recorded revisions copied to bin/before and
bin/after, then python3 experiments/flat-ast/runtime-patterns/run.py.
Generated binaries are ignored. See the subsequent rebased run for current-main
comparison, build provenance and the exact candidate revision.
