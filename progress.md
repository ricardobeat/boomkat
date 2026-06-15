# TinyDuck — Progress

> **See `tinyduck.md` for the design spec.**
> **See `AGENTS.md` for working guidance.**

## Phase 0 — Reboot Cleanup (in progress)

Dropped everything tied to the old "Duktape C3 port" framing. Engine source (`src/`) untouched — feature cuts come next.

### Deleted

- `test262/` submodule entry (`.gitmodules`, empty `test262/` dir)
- `test262_runner/` (harness + `tests/`)
- `test262_relevance_report.md`
- `scripts/`: `run_test262.py`, `count_test262_by_phase.sh`, `phase_runner.py`, `test262_skip.cfg`, `capture_fails.py`, `convert_tval_fields.py`, `run_sort_tests.py`
- `scripts/`: all benchmark/comparison infra — `run_benchmarks.sh`, `run_bench_fast.sh`, `run_sizes_bench.sh`, `run_memory_bench.sh`, `profile_rosetta_memory.sh`
- `duktape_cmdline.c` (and the `duktape/` & `quickjs/` submodules that no longer exist in tree)
- `benchmarks/` (entire dir) — Duktape/QuickJS comparison, proto benches, IC benches, `duktape_c3.c3`, `results.txt`
- `architecture_report.md`
- `test/`: debug/trace/comparison cruft — `debug_*`, `trace_*`, `compare_*`, `logical_debug.js`, `logical_min.js`, `try_hang_test.js`, `failing_scenario.js`, `test_set_debug*.js`, `test_clear.js`, `test_sort_error.js`
- `test/`: removed-feature tests — `eval.js`, `function_proto.js`, `test_const_enforcement.js`, `test_defineProperty_fixes.js`, `test_dup_prop_strict.js`, `test_generator*.js`, `test_octal_strict.js`, `test_strict.js`, `test_symbol_minimal.js`, `test_weakmap.js`, `test_weakset.js`, `with.js`
- `test/`: throw/debug duplicates — `test_throw_min2.js`, `test_throw_propagation.js`
- `test/`: duplicate/variant tests — `regexp_literal.js`, `regexp_minimal.js`, `regexp_simple.js`, all `test_map_*.js` (kept none), most `test_promise_t*`/`test_promise_v*`/`test_promise_minimal.js`/`test_promise_tostring.js`/`test_promise_tag.js` (kept `test_promise.js` + `test_promise_full.js` for now), `test_arrow_this.js`, `test_arrow_new.js`, `test_delete2.js`, `test_keys2.js`, `test_getter_simple.js`, `test_tdz_isolated.js`, `test_regexp_*`
- `test/simple_fail.js`

### Still to do in Phase 0

- Rewrite/simplify `justfile` (drop `test262`, `test262-phase`, `build-batch`, `build-bench`, `build-orig-duktape`, `build-quickjs`, all `bench*` targets)
- Rewrite `README.md` (still describes the old Duktape port)
- Audit rosetta tests against the supported subset (see below)
- Rewrite the small handful of `test/*.js` files that exercise removed behavior (e.g. `in_operator.js` expects `"toString" in obj` via prototype; `abstract_eq.js` tests type coercion via `==` which TinyDuck drops)

## Phase 1 — Rosetta Audit

Spec compliance check against `tinyduck.md`'s "What's In" / "What's Out". Test files use `pass`/`fail` counters and `print("rosetta/<name>: X passed, Y failed")`.

### Clean (keep as-is)

ackermann, binary_search, bubble_sort, closures, collatz, currying, date_basics, factorial, fibonacci, gcd, hoisting, linear_search, math_object, matrix_multiply, matrix_transpose, mutual_recursion, palindrome, primality, quicksort, sieve, type_coercion, array_splice, do_while, fizzbuzz, json_roundtrip, map_function, parseint_radix, reduce_sum, regexp, reverse_string, string_methods, switch_case, unicode_strings.

### Delete (use removed features irrecoverably)

- `apply_call.js` — `Function.prototype.apply` / `.call`
- `arguments_object.js` — `arguments`
- `define_property.js` — `Object.defineProperty`
- `prototypes.js` — `Object.create`, prototype chain

### Rewrite (test can be salvaged on class tables / own props / spread)

- `object_keys.js` — drop prototype + `defineProperty` + `hasOwnProperty`; keep own-prop only
- `object_merge.js` — drop `Object.create`, `hasOwnProperty`, `arguments`; rewrite merge to use `for..in` over own props + spread
- `error_types.js` — drop prototype subclassing; use direct `Error`/`TypeError`/etc. construction
- `this_binding.js` — drop `Function.prototype.call/apply` and prototype methods; cover `obj.method()`, `new`, arrow
- `try_catch.js` — drop `ValueError.prototype = new Error()`; keep try/catch/finally + error classes
- `typeof_instanceof.js` — drop `Bar.prototype = {}` prototype reassignment; cover plain instanceof

## Phase 2 — Engine Feature Cuts (in progress)

Order chosen by isolation: smallest, most-self-contained cuts first, saving the object-model rewrite (no prototypes) for last since it changes everything.

### Done

1. **`with` statement** — removed from parser, VM, bytecode, and env.
   - `src/compiler/statements.c3`: `case TokenType.WITH` now returns `COMPILE_ERROR~`. The `with_statement()` function is gone.
   - `src/bytecode.c3`: `Opcode.WITH_START` / `Opcode.WITH_END` removed from enum, format table, and disassembler names. Replaced with comments pointing here.
   - `src/vm.c3`: Both case handlers (~90 lines) removed.
   - `src/env.c3`: `is_with` field removed, `env_create_with_object` removed, `env_get` / `env_has` / `env_put` simplified (no prototype walk, no `first_non_with` tracking).
   - Verified: `c3c build test_vm` succeeds; `with (obj) { ... }` now fails at compile time; smoke test still runs.


1. **`with` statement** ✅ — parser + VM. (See above.)
2. **`import.meta`** — trivial; parser-only.
3. **Dynamic `import()`** — should already be absent, verify.
4. **`WeakMap` / `WeakSet` / `WeakRef`** — delete `src/builtins/weakmap.c3`, `weakset.c3`; drop global registrations. No GC finalizer code.
5. **`Symbol` builtin + well-known symbols** — delete `src/builtins/symbol.c3`. The for...of duck-typed `.next()` path should already not depend on `Symbol.iterator`.
6. **`eval()`** — drop `src/builtins/global.c3`'s eval binding and the runtime-compile path in `vm.c3`.
7. **`arguments` object** — function setup no longer binds `arguments`; tests that depend on it go.
8. **Generators** — delete `src/builtins/generator.c3`, `src/builtins/iterator.c3` (the latter is the `Iterator` global, not the duck-typed `.next()`); drop generator opcodes from `vm.c3` / `bytecode.c3`. Keep `for...of` as a `.next()`-duck-typed loop.
9. **`Object.defineProperty` / property descriptors** — drop `Object.defineProperty`, `Object.getOwnPropertyDescriptor`, `Object.getOwnPropertyNames`, `Object.create` (also used by prototypes). All property writes go through the simple shape path.
10. **Strict/sloppy mode** — collapse to a single code path: no `this` coercion, no octal literals (already gone), no `with`, no duplicate params, no `delete var`.
11. **Prototypes (the big one)** — remove `__proto__` field from `HObject`, drop prototype-chain lookups, drop `Object.create`/`Object.getPrototypeOf`/`Object.setPrototypeOf`/`isPrototypeOf`. Property lookup becomes: own prop → class method table → done. `instanceof` becomes a class-ID check. `for...in` walks own props only.

Each cut: edit code, `c3c build`, smoke-test with `test/hello.js` and a relevant rosetta test.

## Phase 3 — Bring It Up

- Re-run full rosetta; every test must pass.
- Verify `just build` and `just test` (rosetta runner) work end-to-end on a clean tree.
- Add a couple of regression tests for each cut (parser rejects `with`, `eval` is a name error, etc.).

## Open Questions

- **No-prototype `for...in`** — does it iterate keys in insertion order? Match ES2017 own-enumerable order (insertion order for string keys, numeric keys first). Decide and lock down.
- **No-prototype classes** — class methods live where? Per-class table on the class object, referenced by all instances. Each instance has a `(class_id, own_props)` pair. Or just method table pointer shared. Need to pick a layout and not change it.
- **`.call` / `.apply`** — explicit spec line? tinyduck.md doesn't list them under "In" or "Out". Treated as out for now (paired with `arguments`). Revisit if it turns out to be a recurring need.
- **Static-only modules** — how are imports resolved at parse time? Source-root relative paths? Need a concrete rule.
