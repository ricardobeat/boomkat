# TinyDuck: Dead-Weight Audit + Optimization Directions

Current `src/` size: **36,958 LOC** (spec target was ~11,400 LOC). This report has two parts: (1) concrete cruft to cut now, verified against the actual codebase, and (2) forward-looking performance ideas for later, researched against 2024–2026 prior art.

---

## Part 1 — What to cut now

### Confirmed broken (fix, don't just clean)

**`just build` is currently broken.** `project.json`'s `tinyduck` and `tinyduck_debug` targets point at `tinyduck_runner/main.c3`, which does not exist:

```
$ just build
Failed to resolve tinyduck_runner/main.c3
error: recipe `build` failed on line 7 with exit code 1
```

Git history shows `cli/main.c3` (`tinyduck_cli` target) was added later as the real runner (`aa1d6b4 feat: add tinyduck_cli runner`), but nobody updated the older `tinyduck`/`tinyduck_debug` targets to match. Fix: point those targets at `cli/main.c3`, or delete them if `tinyduck_cli` fully supersedes them.

`test_vm_runner/test_vm.c3` is untracked (`git status` shows `??`) but is a live, needed file referenced by the `tinyduck_test*` targets — not cruft, just needs `git add`.

### Whole directories that are dead

- **`duktape/` (288 files, full old Duktape C source tree, incl. `duktape/src-separate/`)** — not referenced anywhere in `project.json`. TinyDuck's engine now lives entirely in `src/*.c3`. This is a vestigial copy from before the C3 rewrite. **Delete the whole directory.**
- **`libregexp/` (11 C files)** — same story: the live regex engine is `regexp/` (C3, `tiny_re.c3`), wired into every build target's `sources`. `libregexp/` is the old Duktape C regex backend, unreferenced. **Delete.**

Together these two account for a large chunk of the repo's file count (though not `src/`'s LOC count) and are pure historical baggage from the Duktape-port era, before the "reboot" described in `progress.md`.

### Reachable-from-nowhere internals (real runtime code, but for features that were never wired up to JS)

These are the interesting ones — not comments or stale files, but live logic maintained and GC-rooted every cycle for a global (`Symbol`) that is **never registered**, so no script can ever reach it:

- **`src/heap.c3`**: `symbol_registry_keys` / `symbol_registry_syms` / `symbol_registry_count` / `symbol_registry_cap` (a full growable `Symbol.for`/`Symbol.keyFor` registry), `symbol_proto`, `iterator_proto` (`%IteratorPrototype%`), `iterator_symbol`, `toprimitive_symbol` — all allocated, GC-marked (`heap.c3:1569`), and torn down, for a constructor that's unreachable from script.
- **`src/vm.c3:773-840`**: a full ES6 §7.1.1 `Symbol.toPrimitive` protocol dispatch inside `to_primitive_value()` — checks for a `Symbol.toPrimitive` accessor/data property, invokes it with a `"default"` hint, handles the TypeError-on-object-result case. This runs on the hot path of every `+`/coercion op, for a symbol that can't exist in any live object.
- **`src/hobject.c3:201,1298`**: `exotic_proxyobj` flag — set at line 1298, never read anywhere. Proxy isn't implemented; this bit and its assignment are dead.
- **`src/builtins/core.c3:~930-1010,~907-930`**: builtin name/arity metadata table has entries for `Map`, `Set`, and their methods (`set`/`get`/`has`/`delete`/`clear`/`keys`/`values`/`entries`/`forEach`), and for `Object.defineProperty`, `.create`, `.getPrototypeOf`, `.setPrototypeOf`, `.getOwnPropertyDescriptor`, `.defineProperties`, `.seal`, `.freeze`, `.isSealed`, `.isFrozen`, `.isExtensible`, `.preventExtensions`, `.getOwnPropertyNames` — none of these are registered as real globals/methods in `src/builtins/object.c3`. The table entries are orphaned.
- **`src/builtins/core.c3:~1800`**: `"GeneratorFunction"` in a constructor-name array used to wire up prototypes — generators don't exist, so this name is dead.
- **`src/builtins/core.c3:1`**: module doc comment still says *"Built-in function registry for the Duktape C3 port"* — stale framing from before the reboot.

**Estimated impact**: removing the Symbol registry + toPrimitive protocol + Map/Set table remnants + descriptor table remnants is on the order of a few hundred LOC, but more importantly removes a live GC-root, a hot-path branch in every `ToPrimitive` coercion, and heap fields that are permanently allocated for nothing.

### Judgment calls (real, used features — not obviously dead, but worth a decision)

- **`Function.prototype.call` / `.apply` / `.bind`** (`src/builtins/function.c3`) are fully implemented and wired up, including a dedicated `is_bound` object flag. `tinyduck.md` lists these as an "open question," provisionally "out" (paired with `arguments`). Since `arguments` really is gone, `.call`/`.apply` lose most of their classic use case (forwarding an arguments object), but `.bind` is still commonly useful with spread/rest args. Recommend: keep `.bind`, consider cutting `.call`/`.apply` since spread (`fn(...args)`) covers the common case and dropping them removes another arity-juggling code path.

### The two hard, pervasive cuts still not done

These match what `progress.md` already flags as the last, riskiest phase — confirmed still fully present:

- **Property descriptors** (`writable`/`enumerable`/`configurable` bitfield on every property, `src/hobject.c3:~220+`) — touches ~80 call sites across `env.c3`, `hobject.c3`, `vm.c3`, and nearly every file in `builtins/`. The spec calls for dropping descriptors entirely (own-prop only, no enumerability distinctions), but the bitfield and its checks are still load-bearing throughout. This is a real refactor, not a deletion.
- **Strict/sloppy dual path** (`is_strict` / `ACT_FLAG_STRICT`) — threaded through `compiler/statements.c3`, `compiler/context.c3`, `vm.c3` activation records. The spec wants a single "always strict-ish" path; right now the flag still exists and branches on it. Also a real refactor.

Both are correctly sequenced last in `progress.md` — they're structural, not simple deletions, and should stay planned rather than rushed.

---

## Part 2 — Where this could go performance-wise (2026 ideas)

Research pulled from current prior art in small/embedded engines (QuickJS, Hermes, LuaJIT, JerryScript, wasm3, Elk, Porffor, CPython 3.13+/3.14) — filtered for what's tractable for a solo/small-team ~15K LOC engine, not V8-scale efforts.

### Quick wins (weeks, not months)

- **AOT bytecode embedding (`qjsc`-style).** QuickJS's `qjsc` compiles JS to a C source that embeds pre-parsed bytecode, so the shipped binary skips lexing/parsing entirely and (if `eval` is truly unreachable, which it already mostly is here) can strip the compiler out of the binary altogether. For TinyDuck's embedded/game-config use case, this is a near-direct port: a small tool that runs the existing compiler once, serializes `bytecode.c3`'s structures to a C3 source array, and links that instead of source text. Startup-time win is real (sub-millisecond vs. parse-on-load) and the implementation is "write a serializer," not "write a new compiler."

### Medium effort, real speedup

- **Register-based bytecode, if not already fully committed to stack-based.** Measured results (Lua 5.0's switch) show register VMs execute ~46% fewer instructions than stack-equivalent bytecode for the same program, at the cost of ~26% larger bytecode and slightly more complex decode. Worth checking: `bytecode.c3`'s current model — if it's already register-based (likely, given `tinyduck.md`'s "sliding-window slots" language in `vm.c3` comments), this is already banked; if stack-based, it's a worthwhile but nontrivial VM rewrite.
- **A small (1–4 slot) inline cache for property access**, tailored to the *no-prototype, flat class-table* object model this project already committed to. This is actually a better fit for ICs than a normal prototype-chain engine: with no chain to walk, a monomorphic IC only needs to remember "last class-id + own-prop slot index" per callsite and can skip the hash lookup entirely on hit. JerryScript's `LCache` (hashmap-based property cache for <64KB-RAM devices) is the closest embedded precedent; a class-table model can do simpler — a per-callsite 1-slot cache keyed by class-id, since there's no shape mutation from prototype changes to invalidate against. Estimated 2-3x on property-heavy code for modest (~16 bytes/callsite) memory cost.
- **Threaded/computed-goto dispatch** for the main interpreter loop (if the current `vm.c3` still uses a plain `switch` on opcode). wasm3 and most fast small interpreters use direct-threaded or computed-goto dispatch instead of a big switch; this is usually a localized, mechanical change to the dispatch loop with no architectural implications, and is one of the best effort-to-reward changes available.

### Bigger bets, worth tracking but not rushing

- **Copy-and-patch baseline JIT.** The technique CPython 3.13+ prototyped and Deegen (2024) generalized: pre-compile small C "stencil" functions for each opcode to object code at build time, then at runtime stitch/patch them together with real operand addresses instead of interpreting. No traditional codegen or register allocator needed — closer to "smart macro assembly" than a real JIT. This is the most realistic JIT-tier option for a solo project (LuaJIT Remake/Deegen reports ~179% interpreter speedup from an auto-generated tier), but it adds real build-time tooling complexity (needs a C/LLVM toolchain step) and should wait until the LOC-reduction phase is done and the bytecode format is stable — patching a moving target is wasted work.
- **AOT-to-native for a fully static subset**, à la Porffor: for code paths where types are statically inferable (numbers, fixed-shape classes — which is most of what a flat class-table model naturally encourages), emit native code or WASM directly instead of bytecode. Porffor gets huge binary-size wins doing this but only covers ~39% of real-world JS; TinyDuck's *deliberately restricted* dialect (no dynamic prototypes, no eval, no arguments, no descriptors) is exactly the kind of constrained surface where a static-typing pass would cover much more than 39%. This is genuinely novel territory worth a design spike later — the language cuts already made are what make this more tractable here than in a general JS engine.

### Not worth it at this scale

Sea-of-nodes IR, full SSA-based optimizing JIT, V8-style polymorphic (4-way) inline caches, and hidden-class transition graphs are all explicitly the kind of "needs a team" complexity that contradicts the project's own thesis. Skip them; the flat class-table model already gets most of hidden-classes' benefit for free by construction.

### C3-specific leverage (language/stdlib features worth exploiting)

Verified directly against the installed `c3c 0.8.1` compiler (not just docs) — both `@jump` and `@pool` compile cleanly, and neither is currently used anywhere in `src/`, so both are genuine untapped opportunities rather than already-banked wins:

- **`switch (...) @jump { ... }`** compiles the switch as a computed-goto jump table instead of cascading comparisons — confirmed to compile against `c3c 0.8.1`. Confirmed: `vm.c3:2026` is `switch (op) {` — a plain switch, not yet using `@jump`. Adding the attribute there is a one-line, same-semantics change that removes branch-misprediction cost on every bytecode fetch. This is the single highest ratio of impact to effort in this whole report.
- **Compile-time metaprogramming (`$eval`, `$foreach`, compile-time reflection over enum `.values`)** can generate the opcode dispatch table, the builtin name/arity table (Part 1's dead-weight table, if kept for live builtins), and per-opcode format metadata at compile time instead of hand-maintained runtime switch statements — directly shrinking both LOC and a class of copy-paste bugs (like the dead `GeneratorFunction`/`Map`/descriptor entries found above, which exist *because* the table is hand-maintained and has drifted from what's actually registered). Iterating `Opcode.values` at compile time to emit a read-only metadata table also makes the enum/table-drift bug class structurally impossible.
- **`@pool() { ... }` scoped arena allocation** (`std::core::mem`) — confirmed to parse/compile against `c3c 0.8.1` (needs `mem::tmalloc`, not `mem::temp_alloc`, for the temp allocator call). This is a natural fit for a mark-sweep GC's allocation pattern: wrap per-VM-tick or per-compile-pass allocation in a pool block and batch-free at scope exit, rather than tracking everything through the general mark-sweep heap. Best candidate: AST/parse-time allocations in `compiler/*.c3`, which are fully transient once bytecode is emitted.
- **`@inline`** is already used 25+ times in `src/` per the research pass — the opportunity here is auditing hot per-opcode helpers (register access, `strict_eq`, `toint32`-style coercions) for consistency rather than introducing something new.
- **Optional/fault types (`?`/`!`) instead of Duktape's longjmp-based error handling** — TinyDuck already uses this pattern (`TVal?` return types, `faultdef`-style errors visible in `vm.c3`). This is a genuine structural win already banked over Duktape's C error model: no setjmp/longjmp bookkeeping, errors are ordinary typed control flow. It plausibly explains why `src/` has no bulk equivalent to Duktape's `duk_error_augment.c`/`duk_error_longjmp.c`. No further action needed here — already the right design.
- **SIMD (`std::simd` / vector types)** is speculative for this project — plausible for string scanning (UTF-8 validation, `String.prototype.includes`/`indexOf`) but not likely to matter until the engine is otherwise fast; low priority.
- **Small-binary/cross-compilation story** matters concretely here since `riscv_crt/` already exists in the tree — `strip-unused` and `Oz` are already used in `project.json`'s targets, which is the right lever; AOT bytecode embedding (this section's first "quick win") compounds well with that goal since it also lets a build that never calls `eval` drop the compiler from the binary.
- **No `@tailcall`/`@must_tail` attribute exists in C3** — tail-call behavior is left entirely to LLVM's backend optimizer. Not a blocker (the design spec already drops TCO as a language feature), just worth knowing this isn't a lever available for the interpreter's own C3 call chains either.

---

## Suggested next step

The dead-weight items in Part 1 are safe, mechanical deletions (mostly "delete unreferenced things") except for the broken build target, which should be fixed first since it blocks `just build` entirely. The two pervasive refactors (descriptors, strict/sloppy) should stay sequenced last, per the existing `progress.md` plan. Part 2 is exploratory — recommend banking the "quick wins" (AOT bytecode embed, threaded dispatch, class-table-tailored IC) after the LOC-reduction phases finish, and treating copy-and-patch JIT / static-subset AOT as a later design spike once the bytecode format has stopped changing.
