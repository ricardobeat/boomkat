# Plan 036: Split vm.c3 into vm/*.c3

## Motivation

`src/vm.c3` is 9,079 lines — the largest file in the codebase by far. It's difficult to navigate, slow to review, and conflates several distinct concerns. Splitting it into focused files improves editability without any runtime cost.

## C3 Module Mechanics

C3 compiles all `.c3` files sharing the same `module` declaration as a single translation unit. All functions are visible across files within the module — no forward declarations needed. The compiler sees them as one file; the split is purely organizational.

`project.json` uses `"sources": ["src"]` (directory glob), so adding `src/vm/` requires updating sources to `["src", "src/vm"]` in every target. Alternatively, keep `vm/` files inside `src/` by flattening to `src/vm_*.c3` — no `project.json` changes needed.

**Recommendation: flat files `src/vm_*.c3`** — zero project.json changes, simpler than a subdirectory.

## Proposed Split

All files use `module boomkat::vm;` and the same imports as the current `vm.c3`.

| File | Lines (approx) | Contents |
|------|---------------|----------|
| `vm_types.c3` | ~300 | Structs: `Vm`, `Activation`, `Catcher`, `ForInState`, `GeneratorState`. Constants. |
| `vm_core.c3` | ~400 | `vm_create`, `vm_destroy`, `vm_reset`, `vm_mark_activations`, `ensure_valstack`, `curr_act`, valstack helpers, `track_heap_store`, `decref_callee_regs`, `zero_regs_undefined` |
| `vm_coerce.c3` | ~700 | Type conversions: `vm_to_number`, `toint32`, `vm_to_string`, `vm_number_to_string`, `vm_fastint_to_string`, `hstring_to_number`, `to_primitive_value`, `typeof_string`, `is_ecma_whitespace`, `es5_fix_exponent` |
| `vm_throw.c3` | ~200 | `vm_throw_value`, `vm_uncaught_error`, `vm_set_type_error`, `vm_set_toprimitive_error`, `vm_check_to_number_throw`, `vm_check_call_fn_error` |
| `vm_call.c3` | ~500 | `setup_call`, `invoke_getter`, `handle_return`, `vm_call_fn_impl`, `vm_call_handler_fn_impl` |
| `vm_prop.c3` | ~250 | `get_prop_key`, `get_prop_with_proto`, `lightfunc_get_proto`, `intern_string` |
| `vm_eq.c3` | ~100 | `abstract_eq`, `strict_eq` |
| `vm_forin.c3` | ~150 | `forin_ensure_cap`, `forin_add_key`, `collect_forin_keys` |
| `vm_execute.c3` | ~6500 | `Vm.execute`, `Vm.run`, `trace_print_tval`, `trace_instruction`, and the entire opcode dispatch switch |

The execute file stays large because the switch statement cannot be split across files in C3 — the entire `switch (opcode)` block must live in one function. Individual opcode handlers can be extracted as helper functions called from the switch, but that's a separate refactor (plan 007 covers this).

## Opcode groupings within vm_execute.c3

Even though the switch stays in one file, natural comment sections already exist:

- Lines 2258–3421: loads, arithmetic, bitwise, comparison, jumps
- Lines 3422–3449: JUMP, IF_TRUE, IF_FALSE
- Lines 3450–4562: GETPROP, GETPROPC, GETPROPC_CACHED, GETPROPC2
- Lines 4563–4916: PUTPROP
- Lines 4917–5454: NEWOBJ, NEWARR, NEWREGEXP, SETALEN, ARRSPRD, OBJSPRD, SPREAD_ARG
- Lines 5455–7013: CALL, CALL_S, CALL_PROP, SETPROTO, SUPER_CALL, NEWTARGET, NEW_OBJ
- Lines 7014–7753: LOAD_RESUME, AWAIT, YIELD, YIELD_STAR
- Lines 7754–8022: RET, RETUNDEF, RET_GEN, RETUNDEF_GEN
- Lines 8023–8631: GETVAR, TYPEOFIDENT, PUTVAR, DECLVAR, PUTLEX, INITTZ, DELVAR, CLOSURE, GETBOUND
- Lines 8632–9079: INITFOR, NEXTFOR, TRY/CATCH/FINALLY, THROW, NOP, INITGET/INITSET, LEX ops, REQUIRE_OBJ

## Migration Steps

1. Create `src/vm_types.c3` — copy struct definitions and module/import header
2. Create `src/vm_coerce.c3`, `src/vm_throw.c3`, etc. — move functions with their doc comments
3. Create `src/vm_execute.c3` — move `Vm.execute`, `Vm.run`, the switch, and trace helpers
4. Delete `src/vm.c3`
5. Build: `c3c build test_vm` — fix any compilation errors (likely just missing imports in individual files)
6. Run test suite to confirm no regressions

## Risks

- **Missing imports**: each new file needs its own `import` declarations. The current `vm.c3` imports `boomkat::types`, `boomkat::heap`, `boomkat::hobject`, `boomkat::builtins`, `boomkat::bytecode`, `boomkat::env`, `boomkat::hstring`, `boomkat::re_bindings`, `libc`, `std::math`. Copy all to every file — the compiler deduplicates.
- **`@inline` functions referenced before definition**: C3 resolves within-module references at link time, not parse time, so order doesn't matter.
- **No partial switch**: the `switch (opcode)` in `execute()` cannot be split. `vm_execute.c3` will still be ~6500 lines. That's acceptable — the goal is separating concerns, not making every file small.

## Out of scope

Extracting individual opcode handlers into separate functions (reducing the switch body size) is a separate performance/readability refactor tracked in plan 007. This plan is purely a file reorganization with no logic changes.
