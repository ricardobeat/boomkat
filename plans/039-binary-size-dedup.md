# Plan 039 — Binary Size: Dead Code Removal + Deduplication

## Background

Release binary (`boomkat`, `O3` + `panic-msg: false` + `debug-info: none`, see
`082f193`) is 1.12MB vs QuickJS ~1.1MB and original C Duktape ~400KB. `__text`
(actual code) is the overwhelming majority of the binary — not debug symbols,
not unicode tables. A 5-way parallel audit of all ~64K lines of `src/` found
the gap is driven by copy-pasted near-identical implementations, not excessive
`@inline` (confirmed clean, zero misuse found) or dead weight from build flags.

Estimated **4,000-5,500 duplicated lines** across the codebase, plausibly
150-300KB of the 1.12MB binary.

## Phase 1 — Dead code removal + disassembler gate (this session)

Zero/low risk, first priority. Includes the disassembler compile-time gate
(previously Phase 1.5) since it's equally safe and quick.

Confirmed unreferenced via grep across `src/`. Delete outright.

- [x] `src/jit.c3:13-15` `jit_peephole_optimize` — empty body (null check only, no-op) — commit `60a3a24`
- [x] `src/builtins/function.c3:512-525` `bound_get_data` — unreferenced stub, confirmed dead by two independent audit runs — commit `fcec976`
- [x] `src/heap.c3:773-813` `Heap.transition_shape` — unused O(N) variant, superseded — commit `5c897a1`
- [x] `src/heap.c3:2593-2602` `Heap.free_header_list` — no callers, admitted stub — commit `713ccbd`
- [x] `src/heap.c3:758-764` `hash_key_ptr` — no callers — commit `d7ca077`
- [x] `src/hstring.c3:617` `bytes_eq` — no callers — commit `cade844`
- [x] `src/module.c3:150-189` `default_module_normalize` — no callers, logic reimplemented inline in `call_resolve_name` — commit `e4920da`
- [x] `src/env.c3:398-411` `env_check_const` — no callers — commit `7abd2a9`
- [x] `src/env.c3:295-318` `env_put_lex` — no callers — commit `7f310c4`
- [ ] **DEFERRED** `src/bytecode.c3:1055-1262` disassembler (`OPCODE_NAMES`, `disassemble`, `write_*`) — NOT pure dead code. Investigation found it backs real CLI features in `benchmarks/boomkat.c3` (`-c`/`--compile-only`, `--format json`, `-t`/`--trace-vm`), not just the trace path. Gating it out of the release build removes user-facing CLI functionality — a product decision, not a mechanical cleanup. Needs a follow-up plan: likely a new build target (e.g. `boomkat_debug` with `-D TRACE_VM`) that keeps these flags working, with `$if($feature(TRACE_VM))` gating in `bytecode.c3`/`vm_trace.c3`/`benchmarks/boomkat.c3`. Skipped for now per user decision.

For each: grep-confirm zero call sites immediately before deleting (line numbers
may have drifted since the audit). Build + run `just bench-fast 2` after each
batch to confirm no regression. Run local test suite (not full test262 — see
memory: avoid full test262 runs) after the full phase.

## Phase 1, item 10 — Disassembler compile-time gate (DEFERRED, see above)

`src/bytecode.c3:1055-1262` — 119-entry `OPCODE_NAMES` table + `disassemble`/
`write_*` functions are gated only by a *runtime* trace flag (sole caller
`src/vm/vm_trace.c3:47`), not compile-time. Wrap in `$if($feature(TRACE_VM))`
(or reuse `ENV_STRICT`-style feature flag) so release builds strip several KB
of `.rodata`/`.text`. Needs a new build target or feature flag for whoever
wants `--trace-vm` — check how `vm_trace.c3` is invoked before deciding the
gating mechanism.

## Phase 2 — Deduplication (separate sessions, ranked by impact)

Each item below is a candidate for its own session/PR — do not batch them,
since each touches a different correctness-sensitive area and needs its own
verification pass (local tests + targeted bench-fast, not full test262).

1. **Map/Set/WeakMap/WeakSet quadruplication** (~1,500-2,000 lines) — `src/builtins/{map,set,weakmap,weakset}.c3`.
   `check_X()`, `X_find_key/value()`, constructors (`builtin_map`/`builtin_set`/`builtin_weakmap`/`builtin_weakset`),
   `.set/.add/.get/.has/.delete`, `register_X_constructor()` each implemented 4x nearly identically.
   Target: one generic `coll_find()`, `coll_check()`, `coll_populate_from_iterable()`,
   `register_coll_constructor()` parameterized by map-vs-set / weak-vs-strong.
   Route constructor registration through existing `src/builtins/core.c3:register_named_value`
   instead of hand-rolling. Use `src/builtins/typedarray.c3` (`builtin_typed_array_shared`)
   as the template — it's already well-factored across 9 array types.
   **Highest risk item** — weak-ref semantics (WeakMap/WeakSet GC interaction) must be preserved exactly.
   - [x] `check_X()` unified into `check_collection_class()` — commit `4402b9a`
   - [x] `X_find_key/value()` unified into `find_in_array_part()` — commit `b5cef04`
   - [x] Constructors (`builtin_map`/`builtin_set`/`builtin_weakmap`/`builtin_weakset`) unified into
     `coll_construct()` in `core.c3`, parameterized by adder name, `is_pair`, and
     `allow_array_fallback` (the true axis of the Map/Set-vs-WeakMap/WeakSet fallback divergence —
     WeakMap/WeakSet throw "iterable argument is not iterable" instead of falling back to
     array-like iteration, matching V8/SpiderMonkey). Net -476 lines. Also fixed a latent UB bug
     found during verification: `get_prop_proto(...)!!` force-unwrapped a legitimate
     `PROP_NOT_FOUND` fault as valid TVal data in unsafe/O3 builds, causing a prior successful
     construction's stale stack bytes to be misread as a callable `@@iterator` on a later
     non-iterable argument. Fixed with explicit `try`/`set_undefined` handling. — commit `02de73b`
   - [x] `.set/.add/.delete` method bodies unified into `coll_set_entry()`/`coll_add_value()`/
     `coll_delete()` in `core.c3`, parameterized by object-key/value validation
     (WeakMap/WeakSet require it, Map/Set don't) and delete strategy (Map/Set tombstone to
     preserve iteration semantics; WeakMap/WeakSet compact since they're not iterable).
     `.get`/`.has` were left as-is (already one-liners around `X_find_key/value`, not worth
     a further indirection). Net -46 lines. — commit `b80474d`
   - [ ] `register_X_constructor()` functions — **DEFERRED**. Each type registers a different
     method list (Map: set/get/has/delete/clear/keys/values/entries/forEach/size/@@iterator;
     WeakMap: set/get/has/delete only; no behavioral divergence, just boilerplate volume).
     A generic driver is possible but would need a per-type (name, builtin_index) table plus
     special-casing for the accessor (size) and @@iterator/@@toStringTag setup — mechanical,
     low-risk, but lower value than remaining Phase 2 items (#2-#11). Skip for now.

2. **Error-throw boilerplate**, 60-70+ call sites (~700+ lines) across nearly every builtin file
   and `vm_calls.c3`/`vm_property.c3`. Same `alloc_object(ERROR) → set prototype → intern
   message → put_prop → throw` pattern everywhere.
   Target: `builtin_throw(ctx, proto, msg)` for builtins, `throw_type_error_fmt(vm, ds, msg)`
   for VM opcode handlers. Mechanical, low risk, highest call-site count.
   - [x] `builtin_throw()`/`builtin_throw_no_result_change()` added to `core.c3` — commit `fa1e5e4`
   - [x] Builtins side done: ~200 call sites converted across array.c3, date.c3, error.c3,
     function.c3, global.c3, number.c3, object.c3 (39 sites, largest), promise.c3, regexp.c3,
     set.c3, string.c3, symbol.c3. Only static string-literal messages converted — sites building
     messages dynamically (string::tformat, snprintf into a runtime buffer) were left untouched.
     Net -890 lines. Dispatched as 8 parallel haiku agents (one file or small file-group each),
     independently re-verified (full diff review, rebuild, full local test suite, bench-fast,
     targeted functional tests per file) before a single combined commit. — commit `8d5d034`
   - [ ] VM side (`src/vm/{vm_calls,vm_property,vm_execute,vm_generators,vm_objects,vm_arith,
     vm_core,vm_coerce,vm_control}.c3`, ~70 sites) — **DEFERRED**, different scope. VM opcode
     handlers use a structurally different pattern (`vm.heap` not `ctx.heap`, `vm_throw_value()`
     not `ctx.should_throw`/`ctx.throw_value`, `heap::BuiltinStr.MESSAGE` constant lookup instead
     of interning "message" each call, `PROP_FLAGS_WEC` not `_WC`). Needs its own
     `vm_throw_type_error(vm, ds, msg)`-style helper designed against that shape, not a reuse of
     the builtins-side helper. Separate follow-up item.

3. **Compiler parameter-parsing triplicated** — `src/compiler/functions.c3`.
   `parse_function_body` (~858-1255), `compile_inner_function` (~1324-1745),
   `compile_arrow_inner_reparse` (~1879-2248) are ~400-line near-clones.
   Also: default-param-check sequence repeated 3x, destructured-param-binding
   walk repeated 3x within these. ~900 lines total.
   Target: unify into `parse_params_and_body(is_arrow, ...)`. Compiler-only,
   no runtime perf risk, but needs careful coverage of arrow/regular/rest/default edge cases.

4. **VM GETPROP/GETPROPC/GETPROPC2 duplication** (~1,500 lines) — `src/vm/vm_property.c3`.
   GETPROP vs GETPROPC ~90% identical (~750 lines); GETPROPC2 hop-2 dispatch
   repeated 4-5x (~750 lines). Target: shared `getprop_slow()` and `do_hop2()`.
   **Hot path** — needs bench-fast verification (bench_ic_proto, bench_property_lookup) before/after.

5. **Promise combinators** (~400-500 lines) — `src/builtins/promise.c3`.
   `Promise.all/allSettled/any/race` share near-identical capability/resolve-attach
   setup; 8 near-identical resolve/reject element callbacks (~200-250 more lines).
   Target: `promise_run_combinator()` driver + one parametrized element-settled callback.

6. **Destructuring declare-vs-assign twins** (~600-900 lines) — `src/compiler/destructuring.c3`.
   `array_destructure`/`array_destructure_assign`, `object_destructure`/`object_destructure_assign`.
   Target: shared binding-sink abstraction.

7. **Date getters/setters** (~450-600 lines) — `src/builtins/date.c3`.
   16 setters repeat ToNumber-coerce-or-throw; 18 getters differ only in local-vs-UTC.
   Target: `date_to_number_arg()`, `date_get_component(ctx, field_idx, utc)`.

8. **VM call/activation setup duplicated 5x** — `src/vm/vm_calls.c3`.
   CALL, generator-call init, SUPER_CALL, NEW_OBJ each reimplement ~80-line
   var_env/lex_env/this_binding/arguments/rest-params setup.
   **Hot path** — needs bench_function_call / bench_recursion verification.

9. **symbol.c3: 13 identical `ensure_X_symbol()` functions** (~150 lines) — `src/builtins/symbol.c3`.
   Target: one `ensure_wellknown_symbol(heap, HString** cache_slot, char[] desc)`.

10. **Object.keys/getOwnPropertyNames/Reflect.ownKeys** (~250-300 lines) — `src/builtins/object.c3`.
    ~95% identical key-collection (integer-index sort, dense-array phase).
    Target: shared `collect_own_keys()`.

11. **encodeURI/encodeURIComponent and decodeURI/decodeURIComponent pairs** (~250 lines) —
    `src/builtins/global.c3`. Differ only in allowed-character set.
    Target: parameterize with a passthrough-char bitmask/callback.

Lower-priority items noted in the audit but not broken out above (fold into
the relevant item's PR if convenient): heap `destroy`/`reset` teardown overlap
(~150-180 lines, heap.c3), lexer escape-decoder duplication (`scan_string` vs
`scan_template_content`, ~100 lines), lexer hex/octal/binary scan blocks (~3x
~35 lines), array index-clamping repeated 5x (fill/copyWithin/includes),
regexp capture-extraction duplicated 6x, generator next/throw/return resume
logic (~120-130 lines), function.c3 call/apply/bind inner-dispatch blocks,
JSON serialize-object's two parallel iteration branches, `register_proto_accessor`
reimplemented ad hoc in map/set/symbol instead of reused.

## Verification approach per item

- Build + `just bench-fast 2` before/after for any hot-path item (4, 8; also
  spot-check 1, 5 since collections/promises are used in loops).
- Local `test/` JS files relevant to the touched builtin (e.g. `test_map*.js`,
  `test_weakmap.js`, `test_promise_*.js` for item 1/5) — see memory: avoid full
  test262 runs, use local tests / single phase instead.
- Binary size delta: `ls -la out/boomkat` before/after each item, track
  cumulative reduction toward the QuickJS/Duktape gap.

## Non-goals

- Not attempting `-Os`/`-Oz`/`--optsize=small` — already benchmarked, costs
  25-50% perf on hot paths for ~28% size win. Rejected (see commit 082f193 discussion).
- Not touching `ENV_STRICT`/`boomkat_envstrict` target — it's the
  register-locals correctness oracle, not a release-size concern.
