# Experimental current-frame SSA regions

This branch preserves work in progress based on `68d7c01e`. It is not enabled in the standard targets and has not passed broad correctness or workload validation. The validated engine change remains on `rat` at `68d7c01e`.

The prototype adds exact pre-instruction recovery after heap stores, compiler-derived recovery liveness, watched numeric globals, ABI-aware register allocation, native baseline continuations, distinct fresh-frame entries, and bounded acyclic regions at nonzero loop headers with pure short-circuit selector inlining. Generic calls and backward-branch polls stay in the baseline tier.

Build the measured region configuration:

```sh
c3c build boomkat --macos-min-version 27.0 \
  -D SLJIT_READ_REFRESH -D SLJIT_ARRAY_NAMED_READ \
  -D SLJIT_EFFECT_REGION -D SLJIT_EFFECT_WIDE_SCRATCH \
  -D SLJIT_EFFECT_FRESH_ENTRY -D SLJIT_EFFECT_BLOCK_REGIONS
```

Focused smoke tests passed for Richards, committed-store/late-getter recovery and string formals. Statistics proved scheduler region activation. Three matched long-run pairs measured Richards 1756 -> 1619 ms against the preceding prefix prototype; DeltaBlue was neutral. This is experimental evidence, not a full-suite result or a 5-10x gain.

Before promotion: audit external-edge post-state and branch writes, all snapshot/alias cases, string ownership, GC root publication and old/young/marking barriers, method/global mutations and cross-realm behavior, epoch-patch/free ownership, and incoming native links. Mutable global snapshots after earlier writes need a guaranteed binding-owner dependency or effect-aware reload; registration failure must not leave a stale entry-only snapshot. The prototype has not been validated for all of those cases.

Some earlier isolated comparisons omitted two enabled main-build features. Those DeltaBlue comparisons are invalid and are retained only as debugging history. The later matched binaries used the main project configuration explicitly.

Reproducible experimental patches and timing records live under plan 113 on `plans/archive`, in `profiled-iteration-2026-10-29/`. Other experiments (memory CSE, shared store checks, store-read fusion and standalone global watching) are archived separately and are not silently included here.
