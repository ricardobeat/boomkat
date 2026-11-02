# JSC versus Boomkat native loop evidence

Captured 2026-11-02 on macOS ARM64. No benchmark timings collected and no repository files changed.

## Source and reproducibility

The available shell is `/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc`, framework version22625.1.29.11.26 (full metadata in `jsc-runtime-version.json`). System options and shell help are archived. `commands.txt` gives the exact commands.

`navier-exact-kernels.js` contains the original FluidField constructor from `bench/mini/navier-stokes.js`, with only an inspection property exposing the existing functions. The lin_solve/advect bodies are byte-for-byte unchanged; the original bodies, original constructor and SHA256 manifest are archived. The driver uses ordinary JavaScript Arrays, resolution128x128,20iterations, and64 calls to EACH lin_solve branch and advect. This is a deterministic kernel activation driver, not the full mini benchmark state/warmup. Initial array contents and all calls are preserved in the source.

JSC uses its default DFG/FTL thresholds; only concurrent compilation is disabled. DFG then FTL native code is explicitly logged for both kernels, including final FTL replacements. `navier-sample.stderr.log` independently records actual FTL execution of BOTH functions (`lin_solve#DG9A1c:FTL:bc#354` etc and `advect#DVMXnO:FTL:bc#466`). This proves activation, not merely enabled compiler options. Sampling output is used only for tier confirmation.

JSC JIT, JSC `--useJIT=false`, and Boomkat af024 all produce EXACTLY `20296.04261683489`.

The Boomkat comparison is a git archive of committed af024c0de4e094eee5c9bf2ad80bd7b296436c4c with the existing native-code-byte print injection only (`diagnostic-only.patch`). It is an ordinary O2 release build WITHOUT SLJIT_STATS. The independent stats-enabled capture is retained separately and is NOT used for instruction counts. Project configuration matches that exact commit; hashes and binary identity are in `boomkat-snapshot-manifest.json`. Vendor/CLI/project are symlinked as parent requested. The exact same driver and script mode were used in both engines.

## Hot loop comparison

Counts below include the backward branch and count the STATIC contiguous instruction interval. They are NOT dynamic executed-path instruction counts or speed ratios: intervals include branches/side exits and Boomkat sometimes has alternate paths within an interval. JSC unrolling means its lin_solve interval advances FOUR source elements. Total function byte sizes are intentionally not used for comparison.

| Hot interval | JSC FTL offsets | JSC static instructions / source elements | Boomkat af024 offsets | Boomkat static instructions / source elements | C calls in either interval |
|---|---|---:|---|---:|---:|
| lin_solve copy branch |308..496|48 /4|4260..4896|160 /1|0|
| lin_solve iterative branch |812..1264|114 /4|7044..8320|320 /1|0|
| advect inner loop |384..704|81 /1|3792..6136|587 /1|0|

Exact extracted loops are `*.jsc-hot-loop.asm` and `*.boomkat-hot-loop.asm`. Full annotated B3/Air/assembly is retained for JSC, and decoded bytes plus offset assembly for Boomkat are under `boomkat-release-native/`. `hot-loop-comparison.json` records the ranges/counts mechanically.

### Direct observations

* JSC advect loads array butterflies and array lengths at328..356, BEFORE the inner backedge target384. Its inner loop retains seven indexed bounds checks (392,416,564,588,620,644,672), int32 overflow checks, and a NaN check before the double-array store. It does not repeatedly walk the closure/binding metadata to obtain the same values in this loop. Guards are not simply removed wholesale.
* JSC keeps row/column/index arithmetic in integer registers. Its advect clamping-to-int operations use `fjcvtzs` at456 and488. Array address calculation uses scaled register addressing. Width, height, rowSize, array storage and lengths are held outside the per-element body where its proofs permit.
* JSC lin_solve iterative arithmetic carries the freshly stored left-neighbor value in d0 into the next element; it loads x0, right, upper and lower elements, performs native fadd/fmul, guards NaN, stores, and advances. It unrolls four elements while retaining required bounds/overflow checks. Native loop arithmetic does not call C.
* Current Boomkat advect3792..3912 contains the start of a repeated floating-index validation chain: NaN, negative-zero, int32 range, float-to-int, roundtrip equality, and extension checks precede the indexed load. The same pattern recurs for computed indexes. Type proofs and integer representation would remove redundant conversions without removing bounds safety.
* Boomkat advect4352..4596 and4648..4892 contain repeated closure/binding descriptor walks and tagged-value validation inside the scalar loop (see full offset assembly). lin_solve iterative has an analogous chain7920..8156 near its loop condition, followed by boxed numeric decoding. This is native generated code, not an opaque C helper, but still expensive work per element.
* Boomkat copies/reloads live native values through its execution-owned home area around backedges; this is visible as x19-relative loads/stores. JSC uses register-carried induction and arithmetic values more consistently in these captures. Some Boomkat home traffic represents conservative recovery/liveness requirements; changing it requires preserving exact deopt states.

### Practical interpretation (inference from the disassembly)

The remaining Navier gap is not explained by ordinary C calls in the numeric inner loops: both engines already emit the arithmetic natively. The strongest next architecture work is stable integer/range facts across loop PHIs, typed numeric array element representation, binding/capture dependency hoisting with invalidation and alias proofs, and removal of unnecessary backedge home traffic with exact recovery retained. JSC unrolling is visible, but it should not obscure the larger redundant conversion/metadata work already present per scalar element. This report does not establish runtime proportions or recommend deleting guards without proofs.

The older parent 7e2 capture came from the FULL Navier mini, not this exact driver. Its advect inner interval happens to match3792..6136; its lin_solve iterative span differs from this driver. The same-source af024 capture above is the controlled comparison.

## Supplemental own-field / Array dispatch

`boxed-field-array.js` is a clearly labeled representative kernel, NOT an original benchmark body. It indexes an ordinary Array of objects and reads numeric own fields value/scale. DFG then FTL are present; separate sampling explicitly records `fieldArrayDispatch#ElJpJD:FTL:bc#40`. JIT and interpreter checksums both270663680.

`fieldArrayDispatch.ftl.arm64.asm` shows the array storage/length loaded at136..140 before the unrolled loop; bounds checks and per-row structure guards remain. Row numeric properties load directly from inline own-field offsets+0x10/+0x18 (232,248 etc), with numeric representation checks. No generic property callback/helper is called on the successful hot path. Slow exits remain for unexpected array holes, structures, or values. This is relevant to the dictionary/property-helper lane, but this capture alone does not show Boomkat's corresponding representation.

## Official debugger option references

The installed binary's actual `--options` output is the source of truth for this runtime. Official WebKit references for the method:

* [JavaScriptCore crash investigation](https://webkit.org/blog/6411/javascriptcore-csi-a-crash-site-investigation-story/) documents DFG/FTL disassembly diagnostics and disabling concurrent JIT for deterministic investigation.
* [WebKit OptionsList.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/OptionsList.h) defines the native disassembly options.
* [WebKit jsc.cpp](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/jsc.cpp) defines shell diagnostics and tier intrinsics. This report uses actual sampling tier records rather than modifying original kernel bodies to call those intrinsics.
