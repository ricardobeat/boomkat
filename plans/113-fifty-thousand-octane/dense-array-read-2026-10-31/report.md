# Dense-array read lowering, 2026-10-31

Rat `2a063511` changes the function-tier dense read to load the value once with a scaled indexed memory operand. The previous ARM64 sequence shifted and added the index, loaded the value for the hole check, then loaded it again for the result. The new sequence loads once, extracts the hole tag from the value and keeps the same value for the guarded destination store. Writes keep the existing address, ownership and GC-barrier path. Both inline and external element storage retain their existing bounds and hole guards.

The actual probe bytecode is GETPROP followed by RET. Diagnostic ARM64 disassembly is `bk-array-control.asm` and `bk-array-exact.asm`. At the dense-read point the four instructions `lsl; add; ldr; ...; ldr` become one scaled `ldr`; three instructions disappear from the successful path. The complete two-bytecode diagnostic body changes 4448 to 4432 bytes including cold paths. Addresses, instrumentation and process-specific code sizes are not release measurements. The measured workload logged 29,999,999 direct native returns from `readIndex`, so this is an executed path, not merely emitted code.

Seven alternating pairs of the exact release builds on the focused 30-million-call probe gave median 1250→1251 ms (control 1333/1250/1252/1250/1250/1250/1250; candidate 1362/1356/1250/1250/1250/1251/1251). This is neutral and does not establish a speedup. An earlier combined fallback prototype measured 1251→1235 ms; that fallback was removed and its timing is not attributed to the retained build. The exact mini medians were Gameboy 276→275 ms, Mandreel 556→559 ms, PdfJS 360→361 ms and TypeScript 1230→1230 ms, each five alternating pairs.

Three alternating original full-Octane pairs passed all assertions. Control scores were 6374/6405/6312, candidate 6334/6395/6362; medians are 6374→6362 (-0.19%). Full individual median scores follow. PdfJS fluctuated substantially: paired control→candidate scores 7404→5468, 5916→6548, 6618→5944. Therefore the PdfJS median must not be taken as a reliable causal estimate, and no broad gain is claimed. Full-run diagnostic native bytes for the first pair were 2,368,360→2,372,604; different warmup and admission decisions prevent interpreting that difference as per-function growth. Compilation CPU, peak memory and GC pause costs were not independently measured.

| Score | Control median | Candidate median |
|---|---:|---:|
| Richards | 4660 | 4681 |
| DeltaBlue | 3395 | 3385 |
| Crypto | 4681 | 4694 |
| RayTrace | 3123 | 3123 |
| EarleyBoyer | 3108 | 3106 |
| RegExp | 776 | 767 |
| Splay | 8467 | 8483 |
| SplayLatency | 21352 | 22130 |
| NavierStokes | 7250 | 7250 |
| PdfJS | 6618 | 5944 |
| Mandreel | 2188 | 2183 |
| MandreelLatency | 24679 | 24926 |
| Gameboy | 13166 | 13131 |
| CodeLoad | 28481 | 28388 |
| Box2D | 6911 | 7135 |
| zlib | 3383 | 3360 |
| Typescript | 21837 | 21484 |
| Score (version 9) | 6374 | 6362 |

The focused fixture exercises negative and oversized indices, holes with prototype data, non-arrays, inline and external array storage, and string/object values. 55 JIT fixtures agree across interpreter/JIT/stress. Exact-build ARM64 and x86-64 JIT embedding pass; an x86-64 release runner and ARM64 optimized ASan runner pass the new fixture. The interpreter/JIT differential suite matches for local (both status 1, existing feature-limited baseline), Rosetta and modules (both status 0). Raw results, bytecode, full per-run output, build hashes and disassembly are retained here. Full Octane remains around 6.3K, well below the 50K objective.
