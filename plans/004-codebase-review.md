# Codebase Review — May 29, 2026

Reviewer pass over the Boomkat engine. Goal: prioritize work that closes the
gap to QuickJS (currently 5–12× slower) and fixes architecture/quality debt.

## Where we stand (benchmarks/results.txt)

| Benchmark            | C3      | Duktape | QuickJS | C3/QJS |
|----------------------|---------|---------|---------|--------|
| arithmetic           | 178ms   | 330ms   | 27ms    | 6.6×   |
| array                | 28ms    | 39ms    | 7ms     | 4.1×   |
| function_call        | 99ms    | 131ms   | 18ms    | 5.5×   |
| loop                 | 81ms    | 139ms   | 15ms    | 5.4×   |
| object               | 97ms    | 170ms   | 23ms    | 4.2×   |
| property_lookup      | 93ms    | 182ms   | 18ms    | 5.2×   |
| **recursion_deep**   | 3238ms  | 1926ms  | 493ms   | 6.6×   |
| **recursion**        | 622ms   | 461ms   | 120ms   | 5.2×   |
| string               | 9.5ms   | 17ms    | 5ms     | 1.9×   |
| valstack_copy        | 17ms    | 12ms    | 9ms     | 1.9×   |

Key signal: **we beat Duktape almost everywhere except the two recursion
benchmarks**, where we are 1.4–1.7× *slower* than Duktape. That is the clearest
regression to chase, and it points straight at call/return overhead. The broad
5× gap to QuickJS is structural (no inline caches, name-based variable/property
resolution, no register-allocated scope chain).

---

## P0 — Highest impact on performance

### P0.1 Property access has no inline cache (the single biggest QJS gap)
`GETPROP`/`PUTPROP` call `get_prop_or_accessor_proto` → `find_prop_idx`, which
hashes the key pointer (FNV/xorshift) and probes the hash table, then walks the
prototype chain — *every single access, every time*. QuickJS attaches an inline
cache (shape + slot index) to each access site and resolves a monomorphic hit in
~2–3 instructions.

- **What to do:** Introduce a *shape* (hidden class) on `HObject`: a shared,
  immutable descriptor of `{key → slot, flags}` that objects with the same
  property-addition history share. Then add a small per-call-site inline cache
  in the bytecode stream (cache the shape pointer + slot offset alongside the
  `GETPROP`/`PUTPROP`). On a shape match, read `props[slot].value` directly.
- This is the highest-leverage change for `object`, `property_lookup`, and any
  real-world OO code. It is also the largest single piece of work — plan it as
  its own multi-session effort. See `hobject.c3:273` (HObject layout),
  `hobject.c3:459` (find_prop_idx), `vm.c3:1674` (GETPROP).
- **Interim cheaper win:** a 1-entry inline cache keyed on `(obj.shape_or_proto,
  key) → last_slot_idx` stored in a side array indexed by PC. Even a
  last-shape/last-slot guard avoids the hash probe on monomorphic sites.

### P0.2 Variable access is name-based through heap env records
`GETVAR`/`PUTVAR` resolve identifiers by walking a chain of `EnvRecord`s, each of
which is a **separately malloc'd struct wrapping a full HObject** whose props are
looked up by interned-string-pointer hash (`env.c3:122`, `vm.c3:3660`). Locals
*are* register-cached by the compiler (good — `compiler.c3:710`), but:
  - Globals always go through the env (`compiler.c3:198` `is_global`).
  - Any captured variable falls back to `GETVAR` (`compiler.c3:738`).
  - `with`, `eval`, and closures force the slow path.

- **What to do:**
  1. Resolve free variables to `(depth, slot)` pairs at compile time and emit
     `GETVAR_FAST depth, slot` that indexes directly into a flat upvalue/cell
     array — no string, no hash. This is the QuickJS/Lua model.
  2. Represent declarative environments as a flat `TVal[]` cell array, not an
     `HObject`. Reserve `HObject`-backed environments only for `with`/global.
  3. Cache the global object's shape so global reads hit an inline cache too.
- Impacts `function_call`, `recursion`, `loop`, and closures broadly.

### P0.3 Per-call overhead in the RET / CALL hot path (recursion regression)
The recursion benchmarks are the only place we lose to Duktape. Findings in the
call/return path:

- **`RET` checks generator state on every return** (`vm.c3:3552`):
  `if (vm.heap.resume_gen != null)` plus the whole generator-wrap block is in the
  hot path even for plain functions. Split generator returns into a separate
  opcode (`RET_GEN`) emitted only inside generator bodies, or hoist the check so
  the common path is a straight-line return.
- **`handle_return` re-derives caller state, then `RET` re-derives it again**
  (`vm.c3:932` then `vm.c3:3600`): `handle_return` restores `valstack_top`/
  `bottom`, and immediately afterward the `RET` case reloads `act`, `code_base`,
  `constants`, `nregs`, `regs_base`, `code_end`. Fold the bookkeeping into one
  place; `handle_return` does work the caller throws away.
- **`CALL` rechecks `ensure_valstack` + bounds + `MAX_CALLS` per call**
  (`vm.c3:2268`). The `ensure_valstack` fast path is a pointer compare (fine),
  but consider precomputing the high-water mark per function so deep recursion
  doesn't repeatedly test/grow.
- **`memset` of unused registers on every call** (`vm.c3:2305`). For small
  functions (fib has 1–2 regs) the call is cheap, but the memset + the arguments-
  object `uses_arguments` branch still cost. Verify the compiler sets
  `uses_arguments=false` for functions like `fib`, and that `num_regs` is tight.

### P0.4 `ADD` string path frees a freshly-interned concat every time
`vm.c3:1187` ADD on strings: allocates a concat HString, interns it (copying the
bytes again), then **immediately frees the concat** (`hstring_free`). That is two
allocations + a hash + a copy for every string `+`. The `string` benchmark is
already close to QJS, but heavy string building (templates, loops) will suffer.

- **What to do:** intern directly from the two source slices without the
  intermediate `hstring_concat` allocation (hash the concatenation, allocate the
  final interned string once). Or, for `+` results that are unlikely to be reused
  as keys, skip interning entirely and only intern lazily when used as a property
  key (rope/non-interned string class).

---

## P1 — Significant performance / correctness-adjacent

### P1.1 Repeated `intern_string` of string literals in hot paths
`get_prop_key` (`vm.c3:330`) calls `intern_string(vm, "undefined")`,
`"true"`, `"false"`, `"null"` on every non-string property key. `typeof_string`
(`vm.c3:379`) re-interns `"number"`/`"string"`/`"boolean"` on every `TYPEOF`.
Each call hashes the C literal and probes the string table.

- **What to do:** pre-intern all well-known strings once at VM/heap init and
  store them as `HString*` fields (`vm.heap.str_undefined`, `str_number`, …).
  Replace the literal calls with field reads. There is likely a long tail of
  `intern_string(vm, "literal")` calls across `builtins.c3` — grep and convert
  the hot ones (`length`, `prototype`, `constructor`, `message`, `value`,
  `done`, `name`).

### P1.2 Eager `arguments` object construction is very expensive
`vm.c3:2326`: when a function uses `arguments`, each call allocates an HObject,
then for each arg formats the index to a string (`int_to_buf`), allocates+interns
the key, and `put_prop`s it, plus `length`. This is O(argc) allocations per call.

- **What to do:** implement a lazy/mapped arguments object: store argc + a
  pointer to the arg slots, materialize properties only on access. Or special-
  case the common read patterns (`arguments.length`, `arguments[i]`) without a
  full object.

### P1.3 GC tracking via a `realloc`'d `void*[]` array
`heap.c3:404` keeps every object in `gc_objects` (a growable array) *and* objects
carry `next/prev` HeapHeader links (`types.c3:597`). That is two bookkeeping
structures for the same set. The array is appended on every allocation and
realloc'd on growth.

- **What to do:** pick one. If the doubly-linked list is the GC walk structure,
  drop the array (the comment at `heap.c3:407` says the array exists because
  "safe-mode forbids" the cast-pointer walk — revisit whether a typed list head
  avoids that). Removing one structure cuts allocation overhead and memory.

### P1.4 `EnvRecord`s are malloc'd individually and never pooled
`env.c3:36/64/81` each do `libc::malloc(EnvRecord::size)` + `memset` + an HObject
alloc. Closures and blocks create these constantly. Once P0.2 lands (flat cell
arrays) most of these disappear, but until then a free-list/pool would help.

### P1.5 No fast path for integer-indexed property access on arrays
`GETPROP`/`PUTPROP` route array index access through `get_prop_key` →
`vm_number_to_string`/`vm_fastint_to_string` → interned-string lookup, even
though `HObject` has a dense `array_part` (`hobject.c3:304`). Confirm the
array fast path is taken *before* stringifying the index in the VM opcode, not
just inside `put_prop`. If indices are stringified first, that defeats the dense
array entirely for the common `a[i]` case.

---

## P2 — Architecture & maintainability

### P2.1 `vm.c3` is a 4,300-line function-heavy file; `builtins.c3` is 15,000 lines
`Vm.execute` is one enormous switch. That is normal for an interpreter (keeps the
dispatch hot), so **don't split the dispatch loop**. But:
- `builtins.c3` (600 KB) should be split by namespace into multiple files
  (`builtins_string.c3`, `builtins_array.c3`, `builtins_object.c3`, …) under one
  module. Compile time and navigability both suffer at 15k lines.
- Extract the repeated **error-construction boilerplate** (alloc ERROR object,
  set prototype, `snprintf` into `char[160]`, intern message, set `.message`,
  throw) into a helper like `vm_throw_type_error(vm, fmt, args...)`. This pattern
  is copy-pasted dozens of times (GETPROP, CALL, GETVAR, …) — it is the biggest
  source of duplicated code and a frequent place for subtle divergence.

### P2.2 Computed-goto / token-threaded dispatch not used
C3 compiles the `switch` to a jump table, but a single switch still pays one
bounds check + indirect jump per instruction with poor branch prediction. If C3
exposes labels-as-values or `@inline` tail-dispatch, **token-threaded dispatch**
(each opcode handler jumps directly to the next) typically buys 10–20% on
interpreter loops. Investigate whether C3 can express this; if not, document it
as a known ceiling.

### P2.3 `USE_NANBOX` dual-representation doubles every accessor
Every `TVal` accessor in `types.c3` has a `$if USE_NANBOX / $else` pair. The
non-nanbox path is presumably never shipped. If it is only kept for debugging,
consider gating it behind a build flag and pruning the dead branches from the
mental model, or keep but add a CI build that actually exercises
`USE_NANBOX=false` so it doesn't bitrot.

### P2.4 Recursive `env_destroy` and recursive GC marking
`env_destroy` (`env.c3:103`) recurses up the parent chain; `mark_object` takes a
`depth` param (`heap.c3:557`) implying recursion with a depth cap. Both risk
stack overflow / silent truncation on deep structures. Prefer explicit work-list
(stack/queue) traversal for GC marking; the `depth` cap (see `MAX_PROTO_DEPTH`
usage in `vm.c3`) can silently produce wrong results on legitimately deep chains.

---

## P3 — Code smells / smaller items

- **Magic `char[160]` / `char[32]` buffers everywhere** for error messages and
  number formatting. Centralize sizes as named constants; several `snprintf`
  sites silently drop the message if `len >= 160`.
- **`builtin_fn_index < 0` sentinel** mixed with `comp_func != null` checks to
  classify callables (`vm.c3:2259`). A single `enum CalleeKind` on the function
  object would be clearer and avoid the multi-field guard on the call fast path.
- **`get_prop_or_accessor_proto` returns a kind enum + writes two out-params**
  (`hobject.c3:1058`). Workable, but a small tagged struct return would be
  cleaner and the compiler can keep it in registers.
- **Duplicated proto-chain walks** with `MAX_PROTO_DEPTH` open-coded in several
  opcodes (INSTANCEOF `vm.c3:1524`, IN, GETPROP). Factor into one iterator.
- **`es5_results.txt` committed to repo root** (untracked, in git status). Move
  test artifacts under `out/` or gitignore them; root is cluttered with build
  outputs (`test_lex`, `test_parse`, `duktape.a`, `*.dSYM`).
- **`architecture_report.md` (May 25) vs this review vs `plans/`** — three
  overlapping doc sources. Consolidate or cross-link so there's one source of
  truth for the perf roadmap.

---

## Recommended sequencing

1. **P0.3** (call/RET hot path) + **P1.1** (pre-interned literals) — cheap,
   self-contained, directly attacks the recursion regression and broad overhead.
   Re-baseline benchmarks after.
2. **P0.2** (register/cell-based variable resolution) — large but unlocks
   function_call/loop/closures and is a prerequisite mindset for P0.1.
3. **P0.1** (shapes + inline caches) — the big structural win toward QuickJS,
   on objects and property lookup. Do shapes first, then layer the IC.
4. **P0.4 / P1.2 / P1.5** (string concat, arguments object, array index fast
   path) — targeted, independent.
5. **P2.1** (split builtins, error helper) — do alongside the above; it reduces
   the cost of every subsequent change.
6. **P2.2** (threaded dispatch) — last, once the algorithmic wins are banked, to
   chase the final constant factor.

### How to measure
Run `scripts/run_benchmarks.sh > benchmarks/results.txt` after each P0/P1 item.
Watch the two recursion rows for P0.3, the object/property_lookup rows for P0.1,
and function_call/loop for P0.2. Keep test262 pass-rate flat or rising
(`scripts/count_test262_by_phase.sh`) — none of these changes should regress
conformance; the inline-cache work in particular must invalidate correctly on
shape transitions and `delete`.
