# Host native function support

Enabling JS code running in this engine to call into host (embedder) code, and
enabling the host to call back into JS. Today the `jse_` ABI can evaluate source
and read results out; it cannot install a single host callback. For an
embeddable engine that is the load-bearing gap.

Status: design document. Nothing here is implemented.

## Contents

- [Verification of the premises](#verification-of-the-premises)
- [The key finding: dispatch_builtin is the chokepoint](#the-key-finding-dispatch_builtin-is-the-chokepoint)
- [Value model and storage](#value-model-and-storage)
- [The seam](#the-seam)
- [Call protocol](#call-protocol)
- [GC correctness](#gc-correctness)
- [Errors and unwinding](#errors-and-unwinding)
- [Lifetime and teardown](#lifetime-and-teardown)
- [The C ABI surface](#the-c-abi-surface)
- [jse_call: calling JS from the host](#jse_call-calling-js-from-the-host)
- [Bindings](#bindings)
- [Staging](#staging)
- [Test strategy](#test-strategy)
- [Risks](#risks)

---

## Verification of the premises

Each premise in the brief was checked against the source. Seven of them hold.
One is wrong in a way that changes the whole design, and one is more nuanced
than stated.

**1. Values do not carry code pointers. CONFIRMED.**

`src/hobject.c3:508` in `struct HObjectFunction`:

```c3
struct HObjectFunction {
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
    int               builtin_fn_index;
    TVal              captured_this;
    HObject*          captured_new_target;
    TVal              bound_target;
    TVal              bound_this;
    HObject*          bound_args;
}
```

`builtin_fn_index` is an `int` ordinal. There is no code pointer anywhere in a
function value. `TAG_LIGHTFUNC` (`src/types.c3:129`) does embed a pointer-shaped
payload, but per the comment in `include/jse.h` and `types.c3:550`
`set_lightfunc` it carries an ordinal cast to `void*`, not a code address.

**2. The table is compile-time. CONFIRMED.**

`src/builtins/core.c3:2936`:

```c3
BuiltinFunc[Builtin.LAST.ordinal] builtin_dispatch_table;

fn void init_builtin_dispatch_table() @init
{
    $foreach $b : Builtin::values:
        $if $b != Builtin.LAST:
            builtin_dispatch_table[$b.ordinal] = $b.handler;
        $endif
    $endforeach
}
```

Fixed-size array, sized from the enum, filled at `@init`. A runtime host has no
ordinal to claim, and the array cannot grow. This is real and is the core
obstacle.

**3. `CallableKind` is the natural seam. PARTIALLY CORRECT — and I recommend
NOT using it.**

`src/hobject.c3:902` is exactly as described:

```c3
fn CallableKind HObject.callable_kind(&self) @inline {
    if (self.flags.is_bound) return CallableKind.BOUND_FN;
    if ((*self.extra_ptr()).func.builtin_fn_index >= 0) return CallableKind.BUILTIN_FN;
    if ((*self.extra_ptr()).func.comp_func != null) return CallableKind.COMPILED_FN;
    return CallableKind.OTHER;
}
```

A `HOST_FN` arm does fit the taxonomy cleanly, and in a green-field engine that
is what you would write. But adding an arm here means every consumer of
`callable_kind()` that currently handles `BUILTIN_FN` must grow a parallel
`HOST_FN` branch — and there are 23 such comparisons across five files, most of
them 40-to-80-line blocks of `BuiltinContext` staging code that would have to be
duplicated verbatim. That is a large, mechanical, error-prone diff, and the
brief is right that missing one produces mysterious failures.

There is a strictly better seam. See the next section.

**4. The call protocol to mirror already exists. CONFIRMED.**

`src/builtins/core.c3:146` `struct BuiltinContext` carries `vm`, `regs`,
`base_reg`, `argc`, `result`, `heap`, `this_val`, `is_constructor`,
`needs_re_dispatch`, `re_nargs`, `global_env`, `should_throw`, `throw_value`,
`callee_obj`, `new_target`. `core.c3:175`:

```c3
alias BuiltinFunc = fn void(BuiltinContext*);
```

Errors are returned as data on `should_throw`/`throw_value`, never thrown
through C3. Every dispatch site checks `ctx.should_throw` immediately after the
call and routes it into `vm_throw_value`. The host protocol should mirror this
exactly.

**5. Re-entry is bounded. CONFIRMED, with an important caveat.**

`src/vm/vm_types.c3:72` `const uint MAX_RUN_DEPTH = 128;`, counted by
`Vm.run_depth` (`vm_types.c3:307`), incremented at `vm_execute.c3:1647`:

```c3
vm.run_depth++;
defer vm.run_depth--;
```

and checked by `vm_run_depth_exceeded` (`vm_execute.c3:190`) at three entry
points (`vm_execute.c3:353`, `:1015`, `:1447`). The doc comment at
`vm_execute.c3:175` is explicit that this exists precisely for "recursion that
bounces through a native builtin ... re-enters the VM here rather than pushing
an activation, so MAX_CALLS never sees it."

Caveat: this guard covers host→JS re-entry, because host code re-enters through
`vm_call_fn_impl`, which hits the check at `vm_execute.c3:353`. It does **not**
bound pure host→host recursion that never touches the VM, and it does not bound
the C3 stack consumed by the host's own frames, which may be much larger than a
builtin's. Mitigation is discussed under [Errors and unwinding](#errors-and-unwinding).

**6. ~20 dispatch sites branch on CallableKind. CONFIRMED — 23 comparisons.**

Full enumeration (`grep -rn "callable_kind" src/`, excluding the definition):

| File:line | Kind tested | Path |
|---|---|---|
| `src/builtins/function.c3:317` | BUILTIN_FN | `Function.prototype.call/apply` inner dispatch |
| `src/builtins/function.c3:1177` | BOUND_FN | `bind` target unwrap |
| `src/builtins/array.c3:3586` | BUILTIN_FN | sort comparator fast path |
| `src/vm/vm_execute.c3:277-283` | BUILTIN_FN, BOUND_FN | `vm_call_fn_impl` Case 2 |
| `src/vm/vm_execute.c3:924` | BUILTIN_FN | construct: proxy-safe `comp_func` guard |
| `src/vm/vm_execute.c3:946-947` | BUILTIN_FN, BOUND_FN | construct: builtin ctor dispatch |
| `src/vm/vm_core.c3:219` | BUILTIN_FN | **getter** invocation |
| `src/vm/vm_calls.c3:706, 729` | COMPILED_FN | compiled-call fast paths |
| `src/vm/vm_calls.c3:1187` | BOUND_FN | CALL: bound dispatch |
| `src/vm/vm_calls.c3:1272, 1395` | BUILTIN_FN | CALL: re-dispatch after bound/lightfunc |
| `src/vm/vm_calls.c3:1313` | BUILTIN_FN | CALL: plain builtin dispatch |
| `src/vm/vm_calls.c3:2290` | BOUND_FN | **super()**: bound superclass |
| `src/vm/vm_calls.c3:2415` | BUILTIN_FN | **super()**: builtin superclass |
| `src/vm/vm_calls.c3:2738` | BOUND_FN | **new**: bound ctor |
| `src/vm/vm_calls.c3:2797` | BUILTIN_FN | **new**: re-dispatch after bound |
| `src/vm/vm_calls.c3:2846` | BUILTIN_FN | **new**: plain builtin ctor |
| `src/vm/vm_property.c3:2340, 2565` | BUILTIN_FN | **setter** invocation (two PUTPROP paths) |

The brief's warning is exactly right: plain calls, `new`, `super()`, getters and
setters are five distinct code paths, and a design that wires only the first is
broken.

**7. GC. CONFIRMED.**

- `src/heap.c3:79` `const uint GC_MAX_ROOTS = 64;`
- `src/heap.c3:1961` `register_gc_root` silently drops the root when
  `gc_root_count >= GC_MAX_ROOTS` — it does not report failure. Worth noting:
  overflow here is a silent correctness hazard, not an error.
- `src/capi.c3:111-112` the ABI spends one root on the slot registry, an
  `ObjClass.OBJECT` whose properties are the handles, so the mark phase reaches
  them transitively.
- Temproot: `src/types.c3:775-779` `HeapHeader.set_temproot` /
  `clear_temproot` / `is_temproot`; `heap.c3:1708` `alloc_object` sets
  temproot on every freshly allocated object.
- **`heap.c3:3034`**: `bool clear_temproots = safepoint && self.native_frame_depth == 0;`
  and `heap.c3:3112`: `bool quiescent = self.native_frame_depth == 0;` — both
  reclamation passes are suppressed while a native frame is on the stack.

The last point is the crucial one and it is better news than the brief assumes.
See [GC correctness](#gc-correctness).

---

## The key finding: dispatch_builtin is the chokepoint

Every one of those 23 `callable_kind()` sites, after staging its
`BuiltinContext`, calls exactly one function. `grep -rn "dispatch_builtin("
src/` returns 27 call sites and one definition. All 27 look like:

```c3
builtins::dispatch_builtin(fn_idx, &ctx);
```

The definition, `src/builtins/core.c3:2947`:

```c3
fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    if (fn_index >= Builtin.LAST.ordinal) {
        ctx.result.set_undefined();
        return;
    }
    BuiltinFunc handler = builtin_dispatch_table[fn_index];
    if (handler == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.heap.native_frame_depth++;
    handler(ctx);
    ctx.heap.native_frame_depth--;
}
```

Read that first bounds check again. `fn_index >= Builtin.LAST.ordinal` is
already a defined, non-crashing path that returns `undefined`. **That is the
extension point.** It is the single funnel through which plain calls, `new`,
`super()`, getters and setters all pass, and it already brackets the handler
with the `native_frame_depth` guard that makes GC safe across native frames.

The design therefore is:

> A host function is a `FUNCTION` HObject whose `builtin_fn_index` is
> `>= Builtin.LAST.ordinal`. It is a `BUILTIN_FN` to every existing dispatch
> site, which stages a `BuiltinContext` for it exactly as for any builtin.
> `dispatch_builtin` turns the out-of-range index into a lookup in a
> runtime-growable host table and invokes the host trampoline.

Consequences:

- **Zero changes to the 23 `callable_kind()` sites.** All five call shapes work
  on day one, including `new`, `super()`, getters and setters, because they
  already work for builtins and a host function is indistinguishable from one at
  those sites.
- **Zero changes to `callable_kind()` itself**, so no cost on the hot path.
- `Function.prototype.call/apply/bind` work unchanged — `function.c3:317` and
  `:1177` are just more `BUILTIN_FN` sites.
- The dispatch cost is one extra comparison, and only on the already-cold
  out-of-range branch.

The remaining work is real but bounded: the index space, `builtin_get_metadata`,
the constructor gate, marshalling, and the ABI.

---

## Value model and storage

### Design A: new fields in `HObjectFunction`

Add `void* host_fn; void* host_udata;` to the struct.

Rejected. `src/hobject.c3:643`:

```c3
struct HObjectProxy {
    HObject* target;
    HObject* handler;
    void*    _reserved;          // keeps builtin_fn_index at the same offset as HObjectFunction
    int      builtin_fn_index;
}
```

The overlay is explicit and load-bearing, and `hobject.c3:514` and
`vm_execute.c3:920-923` both document that generic dispatch reads
`builtin_fn_index` through `HObjectFunction` without first checking the class.
Appending fields after `bound_args` would not break the overlay (the offset of
`builtin_fn_index` is unchanged), so this is not fatal — but it grows **every**
function object in the heap by 16 bytes to serve a feature used by a handful of
objects. `HObjectExtra` is a union, so `HObjectFunction` is already among the
largest variants and likely sets the union's size; growing it inflates
`alloc_size_for_class` for FUNCTION objects across the board. Given this repo
has five plans dedicated to memory reduction (`029`, `030`, `031`, `033`,
`011`), that is the wrong trade for a sparse feature.

### Design B: a new `ObjClass.HOSTFN` with its own union variant

Add `HOSTFN` to `ObjClass` (`hobject.c3:121`) and `HObjectHostFunction` to
`HObjectExtra` (`hobject.c3:690`).

Rejected, and this is the one that looks most "correct" and is in fact the
worst. A new ObjClass is not free: it must be threaded through
`alloc_size_for_class`, the GC mark switch, `Object.prototype.toString`'s class
mapping, `typeof`, and — fatally — **every site that reads
`(*obj.extra_ptr()).func.builtin_fn_index` on a callable without checking the
class first**. There are dozens of those, and `vm_execute.c3:920` exists
precisely because getting this wrong on Proxy caused a pointer to be
reinterpreted. A new callable class re-opens that entire hazard class. It also
guarantees the 23-site diff that Design C avoids.

### Design C (RECOMMENDED): reserved index range plus a side table

A host function is an ordinary `ObjClass.FUNCTION` HObject. Its
`builtin_fn_index` holds `HOST_FN_BASE + slot`, where:

```c3
// src/builtins/core.c3, next to the dispatch table.
//
// Host function indices live above every compile-time Builtin ordinal, so a
// host function is a BUILTIN_FN to callable_kind() and to every dispatch site,
// and dispatch_builtin's existing out-of-range branch routes it to the host
// table instead of returning undefined.
const uint HOST_FN_BASE = 0x4000_0000;
```

`HOST_FN_BASE` must satisfy two constraints:

1. `> Builtin.LAST.ordinal` (~800), so it lands in the out-of-range branch.
2. Representable as a positive `int`, because `builtin_fn_index` is `int` and
   `callable_kind()` tests `>= 0`. `0x40000000` = 2^30 is comfortably positive
   and leaves 2^30 host slots, which is 2^30 more than anyone needs.

Choosing 2^30 rather than `Builtin.LAST.ordinal + 1` is deliberate: it makes
host indices instantly recognisable in a debugger and in any future assertion,
and it means adding builtins can never collide with a persisted host index.

The side table lives on the `Heap` (per-runtime, see
[Lifetime](#lifetime-and-teardown)):

```c3
// src/heap.c3, in struct Heap.
struct HostFnEntry {
    void* fn;        // the host trampoline (jse_host_fn), never null when live
    void* udata;     // opaque host pointer, passed through untouched
    void* name;      // HString*, interned; backs Function.prototype.name
    int   arity;     // backs .length
    bool  constructable;
}
...
    HostFnEntry* host_fns;
    uint         host_fn_count;
    uint         host_fn_capacity;
```

`host_fns` is a plain `realloc_func`-grown array, freed in `Heap.destroy`. It is
**not** a GC root and does not need to be: `name` is an interned `HString`, and
interned strings are already reachable from the intern table for the heap's
lifetime. No `TVal` is stored in the table, so the 64-root budget is untouched.

**Why this is the right choice.** It is the only design that leaves all 23
dispatch sites, `callable_kind()`, `HObjectProxy`'s overlay, `HObjectFunction`'s
size, and `ObjClass` completely untouched, while making `new`, `super()`,
getters and setters work for free. The cost is one non-obvious invariant — "an
out-of-range `builtin_fn_index` means host function" — which is paid for with a
named constant and a comment at both `HOST_FN_BASE` and `dispatch_builtin`.

Tradeoff stated plainly: Design C is less self-describing than Design B. A
reader seeing `builtin_fn_index = 0x40000003` must know the convention. I accept
that in exchange for eliminating a 23-site duplication whose failure mode is
silent breakage of `new` and accessors. The convention is documented in exactly
the two places a reader will be when they need it.

### Function object construction

Mirror `register_array_proto_method` (`core.c3:2577`), which is the existing
template for building a builtin function object:

```c3
fn HObject*? Heap.make_host_function(&self, uint host_index) {
    HObject*? raw = self.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch e = raw) return e?;
    HObject* fo = raw;
    (*fo.extra_ptr()).func.builtin_fn_index = (int)(HOST_FN_BASE + host_index);
    (*fo.extra_ptr()).func.comp_func = null;
    fo.flags.callable = true;
    fo.flags.constructable = <entry.constructable>;
    fo.prototype = self.function_proto;
    // .length then .name, in that order (ES2015 §17).
    ...
    return fo;
}
```

`comp_func` must be explicitly null. `callable_kind()` never reaches the
`comp_func` test for a host function (the `builtin_fn_index >= 0` test wins
first), but `vm_execute.c3:924` reads `comp_func` directly when
`callable_kind() != BUILTIN_FN`, and other paths may too; leaving it null is the
safe invariant and matches what `alloc_object`'s zeroing already gives.

---

## The seam

Because host functions reuse `BUILTIN_FN`, `callable_kind()` (`hobject.c3:902`)
is **not modified**. Its cost is unchanged: three predictable branches on the
existing hot path, no added test, no added instruction. This is the single
strongest argument for Design C and it is worth stating explicitly since the
brief asked for the cost of an added branch — the answer is that the right
design has no added branch there at all.

The one added branch is inside `dispatch_builtin`, on the path that is currently
a dead end:

```c3
fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    if (fn_index >= Builtin.LAST.ordinal) {
        // Host functions occupy indices at or above HOST_FN_BASE (see
        // core.c3). Everything else out of range keeps the old behaviour.
        if (fn_index >= HOST_FN_BASE) {
            dispatch_host(fn_index - HOST_FN_BASE, ctx);
            return;
        }
        ctx.result.set_undefined();
        return;
    }
    ... unchanged ...
}
```

Ordering matters and is chosen for the common case: the existing
`fn_index >= Builtin.LAST.ordinal` test is already there and is
overwhelmingly false, so builtins take exactly the path they take today with
zero additional work. The host test is nested inside the already-cold branch.
Net cost to every existing builtin call: zero instructions.

`dispatch_host` brackets the trampoline with the same `native_frame_depth`
increment/decrement, for the reasons given in [GC correctness](#gc-correctness).

### The two other tables keyed by builtin index

Two functions switch on `builtin_fn_index` and must learn about host indices.
Both are single chokepoints, which is why this stays small.

**`builtin_get_metadata`** (`core.c3:2564`), which has 19 call sites all feeding
`.name` and `.length`:

```c3
fn BuiltinMeta builtin_get_metadata(uint idx) {
    if (idx >= Builtin.LAST.ordinal) return { "", -1 };
    Builtin b = (Builtin)idx;
    return { b.js_name, b.js_arity };
}
```

This is pure — it has no `Heap*` — but the host table is per-heap. Two options:

- Add a `Heap*` parameter and update 19 call sites. Mechanical but noisy, and
  several call sites are in deeply nested register-staging code.
- **Recommended:** set `.name` and `.length` as real own properties on the host
  function object at registration time (as `register_array_proto_method`
  already does at `core.c3:2589` for builtins), and leave
  `builtin_get_metadata` alone. Its 19 consumers are all fallbacks for when the
  own property is absent; if it is present they never run. The one-line guard
  `if (idx >= Builtin.LAST.ordinal) return { "", -1 };` already returns a safe
  empty result for host indices, so nothing crashes even if a path is missed.

This must be verified during Phase 1, not assumed. The check is a test asserting
`hostFn.name === 'expected'` and `hostFn.length === 2`. If some path reads
metadata in preference to the own property, fall back to threading `Heap*`.

**`builtin_fn_is_constructor`** (`vm_coerce.c3:318`), the gate at
`vm_calls.c3:2800` and `:2853` that makes `new String.prototype.charAt` throw:

```c3
fn bool builtin_fn_is_constructor(Vm* vm, uint fn_idx) {
    if (lightfunc_get_proto(vm, fn_idx) != null) return true;
    switch (fn_idx) { ... }
}
```

This one **must** be extended — it takes `Vm*`, so it can reach
`vm.heap.host_fns`:

```c3
    if (fn_idx >= HOST_FN_BASE) {
        return heap_host_fn_is_constructor(vm.heap, fn_idx - HOST_FN_BASE);
    }
```

placed before the `lightfunc_get_proto` call, since a host index is never a
lightfunc ordinal and `lightfunc_get_proto` would index a table with it.
Defaulting to `false` when the slot is out of range means an unregistered index
yields `TypeError: function is not a constructor`, which is the correct
conservative answer.

---

## Call protocol

### Host-facing signature

```c
typedef void (*jse_host_fn)(jse_call_ctx ctx);
```

One opaque parameter, mirroring `alias BuiltinFunc = fn void(BuiltinContext*)`
(`core.c3:175`). `jse_call_ctx` is `void *`; internally it is the
`BuiltinContext*` the VM already staged. No new struct, no copy, and the host
reads and writes it only through `jse_` accessors, so the layout never leaks.

Returning `void` and communicating result and error through the context is not
an aesthetic choice — it is required to mirror `should_throw`, which is how
every existing dispatch site expects to be told about an error.

### Argument marshalling, JS to host

`BuiltinContext` gives arguments as `ctx.regs[ctx.base_reg + i]` for
`i < ctx.argc`. The host never sees `TVal`. `jse_arg(ctx, i)` allocates a slot
handle for argument `i` and returns it.

The important decision: **arguments are exposed as handles allocated in a
per-call scope, not in the global slot registry.** Rationale under
[GC correctness](#gc-correctness).

`jse_argc(ctx)` returns `ctx.argc`. `jse_arg` with `i >= argc` returns a handle
to `undefined` rather than `JSE_INVALID_VALUE`, matching JS semantics where
missing arguments are `undefined` and sparing every host from writing an arity
check.

### Marshalling, host to JS

The host builds values with constructors that take the context (so the new value
lands in the call scope):

```c
jse_value jse_new_undefined(jse_call_ctx ctx);
jse_value jse_new_null(jse_call_ctx ctx);
jse_value jse_new_bool(jse_call_ctx ctx, int b);
jse_value jse_new_number(jse_call_ctx ctx, double d);
jse_value jse_new_string(jse_call_ctx ctx, const char *utf8, size_t len);
```

`jse_new_string` takes UTF-8 and converts to the engine's internal CESU-8, the
inverse of what `jse_get_string` already does (`capi.c3:382`, and see the
`jse.h` note about astral characters).

### Returning a value

```c
void jse_return(jse_call_ctx ctx, jse_value v);
```

Resolves the handle to a `TVal` and writes it to `*ctx.result`. It must use
`Heap.store_builtin_result` semantics or plain `tval_copy_ref` — **not** a raw
struct assignment, because `ctx.result` may alias a register and the refcount
must be adjusted. Note that `store_builtin_result` (`heap.c3:1860`) is the
*consumer* side, applied by the dispatch site to a transient; from inside the
handler the correct primitive is `tval_copy_ref(ctx.result, &v)`.

A host function that never calls `jse_return` yields `undefined`, since the
dispatch sites initialise `builtin_result.set_undefined()` before staging
(e.g. `vm_calls.c3:1316`).

### Throwing

```c
void jse_throw(jse_call_ctx ctx, jse_value v);
void jse_throw_error(jse_call_ctx ctx, int kind, const char *msg);
```

Both set `ctx.should_throw = true` and `ctx.throw_value`. They do **not**
longjmp and do not return early — control returns to the host function, which
must then return normally. This is exactly how builtins behave and is what all
27 dispatch sites are written against.

The `kind` argument selects a prototype: `JSE_ERROR`, `JSE_ERROR_TYPE`,
`JSE_ERROR_RANGE`, `JSE_ERROR_REFERENCE`, `JSE_ERROR_SYNTAX`, mapping onto
`heap.type_err_proto`, `heap.range_err_proto` and friends.
`jse_throw_error` is the ergonomic path and the one bindings will use; it also
avoids the host needing to construct an Error object through handles.

If a host calls `jse_throw` and then also `jse_return`, the throw wins: dispatch
sites check `should_throw` before consulting `result`. Document that; do not
try to make it an error.

### Constructors, `this`, and `new.target`

Host functions **can** be constructors, and the mechanism is already in place:
`vm_calls.c3:2846` dispatches builtin constructors, `vm_execute.c3:946` handles
the `vm_call_fn_impl` construct path, and both consult
`builtin_fn_is_constructor`, which Design C extends.

Semantics, matching what builtin constructors already receive:

- `jse_is_construct(ctx)` returns `ctx.is_constructor`.
- On a plain call, `jse_this(ctx)` is a handle to `ctx.this_val`. Because the
  engine is strict-only, an undefined receiver stays `undefined` — it is not
  coerced to the global object.
- On `new`, the VM has already allocated `this` with the prototype resolved from
  `new.target.prototype` (`vm_execute.c3:910-916`), and `jse_this` sees it. A
  host constructor may populate it and return nothing, in which case the VM
  keeps the allocated object; or it may `jse_return` an object, which per ES
  §9.2.2 replaces it.
- `jse_new_target(ctx)` exposes `ctx.new_target` (a handle, or
  `JSE_INVALID_VALUE` when null). Needed for a host constructor that subclasses
  correctly under `super()`.

Registration takes a `constructable` flag. It defaults to false, matching ES
§10.3 where built-in functions are constructors only when specified — the exact
rule `builtin_fn_is_constructor`'s comment cites.

Deliberately out of scope for v1: host functions cannot be `class`
superclasses in the sense of running derived-constructor `this` initialisation
beyond what builtin constructors already do. `super()` to a host function will
route through `vm_calls.c3:2415` and behave as a builtin superclass does. Test
it (see [Test strategy](#test-strategy)); if it misbehaves, document the
limitation rather than reworking derived-constructor semantics in this change.

---

## GC correctness

This is the part that will actually go wrong, so it gets the most precision.

### What the engine already guarantees

`heap.c3:3034`:

```c3
bool clear_temproots = safepoint && self.native_frame_depth == 0;
```

`heap.c3:3112`:

```c3
bool quiescent = self.native_frame_depth == 0;
```

with the comment at `heap.c3:435`: "Non-zero means a builtin may hold a fresh
object in a raw local that no GC root can see, so temproot flags must survive a
safepoint collection." And `alloc_object` (`heap.c3:1708`) sets temproot on
**every** freshly allocated object.

Together: while `native_frame_depth > 0`, any object allocated during that
native frame is temproot-flagged, and temproot flags are neither cleared nor
reclaimed. `dispatch_builtin` already brackets every handler with
`native_frame_depth++/--` (`core.c3:2960-2962`).

**Therefore the primary GC hazard for host functions is already solved**,
provided `dispatch_host` keeps the same bracketing. Everything a host allocates
via `jse_new_*` during its call is pinned for the duration of that call.

Do not treat this as a reason to skip the rest. It covers allocation; it does
not cover arguments, and it does not cover handles that outlive the call.

### The invariant

> **Host-function GC invariant.** For the dynamic extent of a host callback,
> every `jse_value` produced by `jse_arg`, `jse_this`, `jse_new_target`, or
> `jse_new_*` on that call's context refers to a value that is reachable from a
> GC root. Handles are scoped to the call: on return they become invalid, and
> the host must not retain them. A host that needs a value beyond the call must
> promote it with `jse_value_persist`, which moves it into the global slot
> registry and hands back a handle the host owns and must `jse_value_free`.

Two handle lifetimes, distinguished at creation, is the whole design.

### Why arguments need explicit rooting despite the above

Arguments are **not** freshly allocated, so they carry no temproot flag. They
live in VM registers (`ctx.regs[ctx.base_reg + i]`), which the mark phase does
scan — so long as the register frame is live and within
`vm.valstack..vm.valstack_top`.

The failure mode: a host callback calls back into JS (`jse_call`), that nested
execution grows the valstack, `ensure_valstack` reallocs it, and `ctx.regs` is
now a dangling pointer. The engine already knows this hazard — `vm_calls.c3:1331`
and `:1345` carry comments about exactly it ("Use a local result slot so that
heap.call_fn-triggered valstack reallocations inside the builtin don't leave a
stale ctx.result ptr", "Refresh ds.regs_base: valstack may have been
reallocated"). Builtins cope by refreshing after the call; a host cannot,
because it holds an opaque handle, not a pointer.

**Resolution: the call scope owns copies, not register references.** When a host
function is dispatched, `dispatch_host` materialises a per-call scope holding
copies of `this`, `new_target`, and all `argc` arguments, in storage that is
itself a GC root. `jse_arg(ctx, i)` returns a handle into that scope. The scope
is torn down on return.

### The call scope

Reusing the existing slot registry for this is tempting and wrong. It is a
single flat `ObjClass.OBJECT` with monotonically increasing integer keys
(`capi.c3:141-151`) and a hard `MAX_SLOTS = 1024` cap. Per-call arguments there
would churn the intern table (`int_to_hstring` per argument per call), leak on
any path that forgets teardown, and let a recursive host→JS→host chain exhaust
1024 slots. It is built for host-owned long-lived handles and should stay that
way.

Instead, a **scope stack**:

```c3
// Per-runtime, on the Heap.
struct HostScope {
    HObject* values;      // JS Array; index i is handle (i+1) within this scope
    uint     generation;  // guards against use of a stale handle
}
    HostScope* host_scopes;
    uint       host_scope_depth;
    uint       host_scope_capacity;
```

Each scope's `values` is a real JS Array, allocated by `alloc_object` and thus
temproot-flagged for the duration (`native_frame_depth > 0` throughout), so its
contents are reachable without consuming a `GC_MAX_ROOTS` entry. Elements are
written with `put_prop`/dense-array writes so refcounts are correct, exactly as
the slot registry does.

`dispatch_host`:

1. `native_frame_depth++`.
2. Push a scope; populate index 0 with `this`, 1 with `new_target`, then the
   `argc` arguments. If allocation fails, set `should_throw` with a
   `RangeError` and return without calling the host.
3. Call the trampoline.
4. Read `ctx.should_throw` / `ctx.result` — both already live outside the scope
   (`throw_value` is a `TVal` in the context; `result` points at the dispatch
   site's local). `jse_return` and `jse_throw` write through immediately, so
   nothing is lost when the scope dies.
5. Pop and free the scope, bump `generation`.
6. `native_frame_depth--`.

A `jse_value` from `jse_arg` encodes `(scope_depth, index)` plus a generation
tag. Using a handle after its scope pops fails the generation check and every
accessor returns `JSE_ERR_INVALID` rather than reading freed memory. This is the
difference between a bug the host debugs in a minute and one they debug in a
week, and it costs one comparison.

Encoding: `jse_value` is `unsigned int` (32 bits) and already carries global
slot ids in `1..MAX_SLOTS`. Reserve the high bit: `0x80000000` set means "scope
handle", with the remaining 31 bits split into generation and index. Global slot
ids stay small and unchanged, so `jse_value_free`, `jse_type_of` and the readers
keep working on both kinds by testing that bit. This does mean every reader
gains a two-way dispatch on handle kind; that is one branch in code that already
does a property lookup, so it is not a concern.

### Handles that escape the call

`jse_value_persist(jse_call_ctx ctx, jse_value v)` copies the value into the
global slot registry and returns a global handle. The host owns it and frees it
with `jse_value_free`. This is the only supported way to keep a value past the
callback, and it is the same 1024-slot budget already documented in `jse.h`.

A scope handle passed to `jse_value_free` should be a no-op (scope handles are
not host-owned), not an error, and definitely not a slot-registry deletion.

### Re-entrancy: host calls JS which triggers GC

Timeline for `js → hostFn → jse_call → js → allocate → GC`:

- `native_frame_depth` is ≥ 1 from `dispatch_host` and stays so for the whole
  nested execution, so temproots survive and reclamation is suppressed
  (`heap.c3:3034`, `:3112`).
- The outer scope's `values` array is temproot-flagged and holds strong
  references to the arguments, so a valstack realloc during the nested run
  cannot invalidate them — the array is heap storage, not stack storage.
- The nested `Vm.run` pushes its own activation; its registers are marked
  normally.
- If the nested JS itself calls another host function, a second scope is pushed.
  Scopes nest as a stack, matching the C3 call stack exactly.

The one thing to verify by test rather than by argument: that
`native_frame_depth` is genuinely non-zero throughout. The comment at
`heap.c3:296` flags a real exception — "Resuming drops native_frame_depth to 0"
for async generator body resumption. **A host function called from an async
generator body resume, or a host function that resumes one, is the case I am
least confident about.** It must be tested explicitly (see
[Test strategy](#test-strategy)) and, if it breaks, the fix is for the scope's
`values` array to be additionally pinned via `set_temproot` re-application, or
for `dispatch_host` to register the array as a GC root for its duration —
which would consume one of the 64 root slots per nesting level and needs a depth
cap. Do not design that in speculatively; test first.

### Testing it

- `make boomkat_gc_stress` (`Makefile:65`, `project.json:93`) collects at
  every allocation. Every host-function test must pass under it. This is the
  single highest-value test in this plan: it turns "the scope array might not be
  rooted" from a subtle heisenbug into a deterministic failure.
- `scripts/run_gc_stress.sh` via `just` (`justfile:141`).
- `project.json:188` is a GC_STRESS + ASan shared build — use it for the C99
  host-function tests, so a use-after-free on a popped scope handle traps
  immediately instead of reading plausible garbage.
- A dedicated stress test: a host function that allocates 1000 strings, calls
  back into JS between each, and reads argument handles after each call,
  asserting they are still correct. Under GC_STRESS this exercises every
  safepoint.

---

## Errors and unwinding

### Host throws

`jse_throw`/`jse_throw_error` set `ctx.should_throw` and `ctx.throw_value`, the
host returns normally, `dispatch_host` pops the scope and returns, and the
dispatch site does what it already does for builtins:

```c3
if (ctx.should_throw) {
    if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
        return vm_uncaught_error(vm, &ctx.throw_value);
    }
    return (TVal){};
}
```

(`vm_calls.c3:1338-1344` and its 20-odd siblings.) The value propagates to the
nearest JS `catch`, or to `jse_eval`'s `JSE_ERR_THROW` with
`jse_last_error` populated by `describe_error` (`capi.c3:262`). No new
machinery.

One subtlety: `ctx.throw_value` must hold a reference. If the host throws a
freshly allocated Error, that object is temproot-flagged (allocated under
`native_frame_depth > 0`) and survives until the throw is consumed. If the host
throws a scope handle's value, `jse_throw` must `tval_copy_ref` into
`throw_value` before the scope pops, not merely copy bits. This is a concrete
implementation requirement, not a nicety.

### Host returns an error, host-side

There is no separate "host returns an error" channel and there should not be
one. A host function either returns a value or throws a JS exception. Anything
else would create a second error path that none of the 27 dispatch sites know
how to read.

### Host calls JS which throws

`jse_call` re-enters through `vm_call_fn_impl`. That function signals failure
through `vm.has_error` / `heap.has_error` / `heap.error_value` rather than a
status — as `jse.h` already notes ("It returns a bare value and signals failure
through a heap flag rather than a status"). `jse_call` must therefore:

1. Clear `heap.has_error` before the call.
2. Call `vm_call_fn_impl`.
3. If `heap.has_error`, return `JSE_ERR_THROW` and leave the pending exception
   where the host can see it via `jse_last_error`.

The host then chooses: return normally (swallowing the exception — it must be
cleared, or it will re-fire), or re-throw with `jse_throw`. **The default must
be that an unhandled nested exception propagates.** If the host ignores
`jse_call`'s status and returns, `dispatch_host` should notice
`heap.has_error` still set on return and convert it into `should_throw`
automatically. That turns the most likely host bug — ignoring a return code —
into correct-by-default behaviour instead of a silently swallowed exception.

### MAX_RUN_DEPTH

A `js → host → jse_call → js → host → ...` chain increments `run_depth` once
per `jse_call` (`vm_execute.c3:1647`). At 128 levels
`vm_run_depth_exceeded` (`vm_execute.c3:190`) fires a `RangeError: Maximum call
stack size exceeded` on the `has_error` channel, `jse_call` returns
`JSE_ERR_THROW`, and per the paragraph above it becomes a JS throw the script
can catch.

The doc comment at `vm_execute.c3:186` is emphatic that only
`vm.has_error`/`heap.has_error`/`heap.error_value` are set and **not**
`throw_pending`, because throw_pending would survive the unwind and re-fire
after a user's catch. `jse_call`'s error handling must respect that: read the
`has_error` channel, clear it when converting, and never set `throw_pending`
directly.

**Gap, stated as a gap:** `MAX_RUN_DEPTH` bounds VM re-entry, not host C3 stack
usage. A host function whose frame is 64 KB, recursing 128 deep, needs 8 MB of
stack — likely more than the default. There is no way for the engine to know the
host's frame size. Mitigation: document the 128 limit in `jse.h`, and consider a
`jse_set_max_call_depth` in a later phase. Do not add one in v1 without
evidence; `MAX_RUN_DEPTH` is a `const` at `vm_types.c3:72` and making it a
runtime field touches the hot check.

---

## Lifetime and teardown

Registration is **per-runtime** state. The `host_fns` array and the scope stack
live on the `Heap`, which `jse_open` creates (`capi.c3:98`) and `jse_close`
destroys (`capi.c3:126-135`). The single-runtime-per-process rule (`g_rt` at
`capi.c3:95`) means there is no ambiguity about which runtime a registration
belongs to, but putting the state on `Heap` rather than in a global keeps the
door open if that rule is ever lifted, at no cost today.

Teardown, extending `jse_close`:

```c3
fn void jse_close(void* rtp) {
    ...
    vm::vm_destroy(rt.vm);          // existing
    // host_fns and host_scopes are freed inside hp.destroy(), which already
    // owns every allocation made through hp.alloc_func.
    hp.free_func(hp.heap_udata, (void*)rt);
    hp.destroy();
    ...
}
```

`Heap.destroy` frees `host_fns`, and the scope stack, which must be empty —
`jse_close` from inside a host callback is a host bug. It should be detected
(`host_scope_depth != 0`) and refused rather than executed, because tearing the
heap down under a live native frame will crash on return. Since `jse_close`
returns `void`, "refused" means returning without doing anything; log it into
the error buffer for `jse_last_error`. This is worth the four lines: it is a
mistake every embedder makes once.

The host function objects themselves are ordinary GC-managed HObjects. If the
host registers a function and JS drops every reference, the object is collected;
the `host_fns` entry remains (it is just a fn pointer and a name) and is
harmless. Entries are never removed — there is no `jse_unregister`. That is
deliberate: unregistering would leave live function objects with dangling
indices, and the sane semantics ("subsequent calls throw") is not worth the API
surface for v1. Registration is expected to happen at startup.

`host_fn_count` should be capped (say 4096) with `JSE_ERR_FULL` beyond it, so a
host looping over registration cannot exhaust memory silently.

---

## The C ABI surface

New declarations for `include/jse.h`, in the existing style. **Another agent is
concurrently editing `include/jse.h`; this is a specification to apply, not a
patch to apply blind.**

```c
/* ------------------------------------------------------- host functions */

/*
 * Opaque per-call context, valid only for the duration of one host callback.
 * Never store it; never use it after the callback returns.
 */
typedef void *jse_call_ctx;

/*
 * A host callback. Reads its arguments through jse_arg / jse_argc, produces a
 * result with jse_return, and reports failure with jse_throw / jse_throw_error.
 *
 * Returns void: the result and any exception travel through the context, which
 * mirrors how the engine's own built-ins work. Nothing may longjmp or throw a
 * C++ exception across this boundary.
 */
typedef void (*jse_host_fn)(jse_call_ctx ctx);

/* Error kinds accepted by jse_throw_error. */
typedef enum {
    JSE_ERROR           = 0,
    JSE_ERROR_TYPE      = 1,
    JSE_ERROR_RANGE     = 2,
    JSE_ERROR_REFERENCE = 3,
    JSE_ERROR_SYNTAX    = 4
} jse_error_kind;

/*
 * Register `fn` as a global function named `name`, callable from JS.
 *
 * `nargs` becomes the function's .length and is advisory: JS may call with any
 * number of arguments, and the callback must consult jse_argc.
 *
 * `udata` is stored verbatim and handed back through jse_udata on every call.
 * The engine never dereferences it and never frees it; keeping the pointed-to
 * storage alive for the runtime's lifetime is the host's responsibility.
 *
 * Registrations are per-runtime, last until jse_close, and cannot be removed.
 * Registering the same name twice replaces the global binding; the earlier
 * function object, if JS still holds one, keeps working.
 *
 * Returns JSE_OK, JSE_ERR_INVALID (null argument or empty name),
 * JSE_ERR_NOMEM, or JSE_ERR_FULL (registration table exhausted).
 */
JSE_API int jse_register_function(jse_runtime rt, const char *name,
                                  jse_host_fn fn, int nargs, void *udata);

/*
 * As jse_register_function, but the resulting function may also be used with
 * `new`. Without this, `new f()` throws TypeError, matching ES2015 section 10.3
 * where built-in functions are constructors only when specified.
 *
 * Inside such a callback jse_is_construct reports 1, jse_this is the object the
 * engine already allocated with the prototype taken from new.target, and
 * jse_new_target is the constructor that was invoked. Returning an object with
 * jse_return replaces the allocated `this`; returning nothing keeps it.
 */
JSE_API int jse_register_constructor(jse_runtime rt, const char *name,
                                     jse_host_fn fn, int nargs, void *udata);

/* -------------------------------------------- inside a host callback */

/* The udata given at registration. */
JSE_API void *jse_udata(jse_call_ctx ctx);

/* Number of arguments actually passed. */
JSE_API int jse_argc(jse_call_ctx ctx);

/*
 * Handle for argument `i`. Indices at or past jse_argc yield a handle to
 * undefined, matching JS, so no arity check is needed.
 *
 * SCOPE HANDLES. Handles from jse_arg, jse_this, jse_new_target and the
 * jse_new_* constructors are scoped to this callback. They are released
 * automatically when it returns, and using one afterwards fails cleanly with
 * JSE_ERR_INVALID rather than reading freed memory. Passing one to
 * jse_value_free is a harmless no-op. To keep a value past the callback, copy
 * it out with jse_value_persist.
 */
JSE_API jse_value jse_arg(jse_call_ctx ctx, int i);

/* The receiver. In this strict-only engine an undefined receiver stays
 * undefined; it is never coerced to the global object. */
JSE_API jse_value jse_this(jse_call_ctx ctx);

/* 1 when invoked with `new`, else 0. */
JSE_API int jse_is_construct(jse_call_ctx ctx);

/* new.target, or JSE_INVALID_VALUE when there is none. */
JSE_API jse_value jse_new_target(jse_call_ctx ctx);

/* ------------------------------------------------ building values */

JSE_API jse_value jse_new_undefined(jse_call_ctx ctx);
JSE_API jse_value jse_new_null(jse_call_ctx ctx);
JSE_API jse_value jse_new_bool(jse_call_ctx ctx, int b);
JSE_API jse_value jse_new_number(jse_call_ctx ctx, double d);

/*
 * A JS string from `len` bytes of UTF-8. The bytes are copied; the buffer may
 * be released immediately. Converts to the engine's internal CESU-8, the
 * inverse of jse_get_string, so astral characters round-trip.
 * Returns JSE_INVALID_VALUE on allocation failure or invalid UTF-8.
 */
JSE_API jse_value jse_new_string(jse_call_ctx ctx, const char *utf8, size_t len);

/* -------------------------------------------- returning and throwing */

/*
 * Set the callback's return value. Calling it more than once keeps the last
 * value. Not calling it at all returns undefined.
 */
JSE_API void jse_return(jse_call_ctx ctx, jse_value v);

/*
 * Throw `v` as a JS exception once the callback returns.
 *
 * This does NOT unwind: it records the exception and returns normally, so the
 * callback keeps running and must return under its own control. Any work after
 * this call still happens. If jse_return is also called, the throw wins.
 */
JSE_API void jse_throw(jse_call_ctx ctx, jse_value v);

/*
 * Throw a fresh Error of the given kind with `msg` (NUL-terminated UTF-8) as
 * its message. Same non-unwinding contract as jse_throw. This is the ergonomic
 * path and does not require building the Error through handles.
 */
JSE_API void jse_throw_error(jse_call_ctx ctx, jse_error_kind kind,
                             const char *msg);

/* --------------------------------------------------- escaping a value */

/*
 * Copy a scope handle's value into the runtime's long-lived slot registry and
 * return a handle the caller owns and must release with jse_value_free. This
 * is the only supported way to keep a value beyond the callback.
 *
 * Subject to the same 1024-handle budget as jse_eval's results; returns
 * JSE_INVALID_VALUE when the registry is full.
 */
JSE_API jse_value jse_value_persist(jse_call_ctx ctx, jse_value v);
```

Every one of these is opaque: `jse_call_ctx` and `jse_runtime` are `void *`,
`jse_value` stays `unsigned int`, and no engine struct appears. `TVal`,
`BuiltinContext`, `HObject` and `Heap` remain entirely internal.

---

## jse_call: calling JS from the host

**It belongs in this work.** Not as a nicety — as a requirement. A host function
that cannot invoke a JS callback cannot implement `setTimeout`, cannot implement
an event emitter, cannot implement a promise-returning I/O function. Every
realistic use of host functions needs it, and the GC scope machinery designed
above is exactly what makes it safe. Landing host functions without it would
mean building the scope infrastructure and then not using it for the case it
most exists for.

```c
/*
 * Call a JS function value with `argc` arguments.
 *
 * `fn` must be a handle to a callable; `this_val` may be JSE_INVALID_VALUE for
 * an undefined receiver. On JSE_OK, *out_val (when non-NULL) receives the
 * result: a scope handle when `ctx` is a live callback context, so it needs no
 * explicit release.
 *
 * On JSE_ERR_THROW the JS exception is pending. The callback may re-throw it
 * with jse_throw to propagate, or handle it and continue. IGNORING THIS RETURN
 * VALUE DOES NOT SWALLOW THE EXCEPTION: a pending exception left unhandled when
 * the callback returns is re-raised into JS, so a host that forgets to check
 * still behaves correctly.
 *
 * Nesting is capped at 128 levels of JS re-entry, after which the call fails
 * with a RangeError rather than exhausting the C stack.
 *
 * Returns JSE_OK, JSE_ERR_THROW, JSE_ERR_TYPE (fn is not callable),
 * JSE_ERR_INVALID, or JSE_ERR_NOMEM.
 */
JSE_API int jse_call(jse_call_ctx ctx, jse_value fn, jse_value this_val,
                     int argc, const jse_value *argv, jse_value *out_val);

/*
 * As jse_call, but outside any host callback: takes the runtime, and *out_val
 * is a runtime-scoped handle the caller must release with jse_value_free.
 */
JSE_API int jse_call_global(jse_runtime rt, jse_value fn, jse_value this_val,
                            int argc, const jse_value *argv,
                            jse_value *out_val);
```

Implementation notes against the real code:

- `vm_call_fn_impl` (`vm_execute.c3:213`) takes
  `(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val)` and is
  verified working per the `jse.h` note.
- **The argument array must be GC-visible.** `jse.h` already flags this. A C3
  local `TVal[N]` is invisible to the mark phase. Resolve by materialising
  arguments into the current host scope's `values` array (which is
  temproot-pinned) and passing a pointer into its dense element storage, or by
  staging them on the valstack above `valstack_top` and advancing it. The scope
  array is simpler and reuses machinery this plan already builds; prefer it, and
  note that the array must not be reallocated between staging and the call.
- Error handling follows the `has_error` protocol described under
  [Errors and unwinding](#errors-and-unwinding).
- `jse_call_global` must bump `native_frame_depth` around the call itself, since
  there is no `dispatch_host` frame to do it.

---

## Bindings

The six bindings differ in how well they can express a C function pointer
callback. Two are trivial, two are straightforward, and two need real care.

### C99 (`examples/c99`)

Nothing to design; this is the reference shape.

```c
static void host_now(jse_call_ctx ctx) {
    (void)ctx;
    jse_return(ctx, jse_new_number(ctx, (double)time(NULL) * 1000.0));
}
...
jse_register_function(rt, "now", host_now, 0, NULL);
```

### C3 (`bindings/c3/jse.c3`)

Also direct — C3 has native function pointers and the binding already speaks the
ABI. Idiomatic wrapper: a `HostFn` alias plus a `register_fn` helper. Worth
adding a small `Ctx` struct with methods (`ctx.arg(0)`, `ctx.ret(v)`) so C3
hosts get method syntax rather than free functions.

### Zig (`bindings/zig/src/js.zig`)

Zig exports C-ABI functions cleanly with `callconv(.C)`. The idiomatic wrapper
uses `comptime` to generate a trampoline from a Zig function, so the host writes
normal Zig:

```zig
fn now(ctx: js.Ctx) void {
    ctx.ret(ctx.number(@floatFromInt(std.time.timestamp())));
}
try rt.register("now", now, 0);
```

with `register` wrapping `now` in a `comptime`-generated `export fn(...) callconv(.C)`.
Zig closures over runtime state are not C-ABI-compatible, so runtime state goes
through `udata` as an `*anyopaque` — same as C. Note the existing `jse.h`
caveat that Zig must link the **shared** library, not the static archive, for
the C3 constructor walk to work; that applies unchanged here.

Zig errors cannot cross the boundary: a Zig host callback returning `!void`
must catch its own errors and turn them into `jse_throw_error`. The wrapper
should accept an error-returning function and do that conversion, which is both
idiomatic and safe.

### Rust (`bindings/rust/jse`, `jse-sys`)

`extern "C" fn` is a natural fit. The safe wrapper should accept a
`Fn(&Ctx) -> Result<Value, Error>` closure:

```rust
rt.register("now", 0, |ctx| Ok(ctx.number(now_millis())))?;
```

by boxing the closure, leaking it (registrations live for the runtime's
lifetime, so leaking is honest rather than sloppy — document it), passing the
raw pointer as `udata`, and using one generic `extern "C"` trampoline that
recovers the closure from `udata`.

Two Rust-specific hazards that must be handled, not hand-waved:

- **Unwinding.** A Rust panic crossing an `extern "C"` boundary is undefined
  behaviour (it aborts on modern Rust, but the trampoline should not rely on
  that). Every trampoline wraps the closure in `std::panic::catch_unwind` and
  converts a caught panic into `jse_throw_error(JSE_ERROR, "host panic")`. This
  is mandatory, not optional.
- **Lifetimes.** `Ctx` must be invariant over a lifetime tied to the callback so
  the borrow checker prevents a `Value` escaping the closure. Combined with the
  runtime generation check this gives Rust hosts compile-time safety for
  precisely the mistake the C API can only catch at runtime. This is where the
  Rust binding earns its keep.

### Python (`bindings/python/js.py`, ctypes)

Feasible, with three real problems.

- **Closure lifetime.** `ctypes.CFUNCTYPE(...)(pyfunc)` produces a callable
  object that must be kept alive by Python for as long as C can call it. If it
  is garbage collected, the next call jumps into freed memory. The binding must
  hold every trampoline in a list on the runtime object. This is the classic
  ctypes bug and it must be handled explicitly, with a comment saying why.
- **Exceptions.** A Python exception raised inside a ctypes callback does not
  propagate through C; ctypes prints a traceback to stderr and returns a
  default. The trampoline must therefore wrap the user function in
  `try/except`, and on exception call `jse_throw_error` with
  `str(exc)`, then return. Stashing the original exception on the runtime so it
  can be re-raised after `eval` returns is a nice refinement worth doing.
- **GIL.** CPython's ctypes callbacks acquire the GIL automatically, so this is
  not a correctness problem for a single-threaded embedder. It is a performance
  ceiling, and it is a hard blocker only if the engine is ever driven from a
  non-Python thread — which the ABI forbids anyway ("NOT thread-safe"). Note it;
  do not engineer around it.

Verdict: fully feasible, and the resulting API is pleasant:

```python
@rt.function("now")
def now(ctx):
    return time.time() * 1000
```

with the decorator handling the trampoline, the keep-alive list, and the
exception conversion.

### Ruby (`bindings/ruby/lib/js.rb`, fiddle)

Feasible but the weakest of the six, and the one to be honest about.

- `Fiddle::Closure::BlockCaller` is the mechanism, and it works.
- **Closure lifetime is worse than Python's.** A `Fiddle::Closure` that is
  garbage collected frees its executable trampoline; calling it afterwards is a
  jump into unmapped memory. Same fix — hold references on the runtime object —
  but Ruby's GC gives fewer warnings when you get it wrong.
- **Exceptions.** Raising a Ruby exception inside a `BlockCaller` invoked from C
  is not reliably safe across Ruby versions; the exception may propagate through
  C frames that are not prepared for it. The trampoline must
  `rescue => e` and convert to `jse_throw_error`, never letting a Ruby exception
  cross. This is a firm requirement.
- **`Fiddle::Closure` availability.** It depends on libffi closure support,
  which is present in mainstream CRuby builds but not universally (some
  hardened/no-exec-memory environments disable it). The binding should detect
  this at load and raise a clear "host functions unavailable on this Ruby build"
  rather than segfaulting.
- Not feasible at all on JRuby or TruffleRuby via fiddle. Document that.

Note: another agent is concurrently editing `bindings/ruby/`. Coordinate before
implementing this section.

### Summary

| Binding | Feasible | Main hazard |
|---|---|---|
| C99 | Yes, reference | none |
| C3 | Yes, direct | none |
| Zig | Yes | must link shared lib; errors must be caught in the trampoline |
| Rust | Yes, best ergonomics | panics must be `catch_unwind`; closures leaked deliberately |
| Python | Yes | ctypes closure keep-alive; exceptions must be converted |
| Ruby | Yes, with caveats | Fiddle::Closure keep-alive and availability; exceptions must never cross; CRuby only |

---

## Staging

Five phases. Each is independently landable and leaves the tree green.

### Phase 1 — engine core: host table and dispatch

Scope: `src/heap.c3` (table fields, `HostFnEntry`, alloc/free in
`create`/`destroy`), `src/builtins/core.c3` (`HOST_FN_BASE`, `dispatch_host`,
the one added branch in `dispatch_builtin`, `make_host_function`),
`src/vm/vm_coerce.c3` (`builtin_fn_is_constructor` host arm).

No ABI, no C header. Tested from C3 by a test target that registers a host
function directly against the `Heap` and evaluates JS that calls it.

Deliverable: JS can call a host function that takes no arguments and returns
nothing. Proves the chokepoint thesis.

Green because: nothing existing changes behaviour — the added branch is inside
an already-dead `if`.

### Phase 2 — call scope and marshalling

Scope: `src/heap.c3` (scope stack), scope push/pop in `dispatch_host`, the
handle encoding (high-bit split), argument/`this`/`new_target` materialisation,
`should_throw` plumbing.

Still C3-only tests. Deliverable: arguments in, values out, throwing works, all
verified under `boomkat_gc_stress`.

This is the phase where the GC design is proven, and it must not be merged with
Phase 3 — a bug here surfaces as a C-level crash if the ABI is in the way.

### Phase 3 — the C ABI

Scope: `src/capi.c3` (all the `jse_` entry points above),
`include/jse.h` (declarations, and removal of the now-stale "NOT IN v1" note
about native registration).

**Both files are being edited concurrently by other agents. This phase must be
sequenced against that work, not merged blind.**

Deliverable: the C99 example registers a function and calls it. Tests build
against `out/libjse.dylib` and run under the GC_STRESS+ASan shared target
(`project.json:188`).

### Phase 4 — `jse_call`

Scope: `src/capi.c3` (`jse_call`, `jse_call_global`), argument staging into the
scope array, the `has_error` protocol, the auto-propagate-on-return behaviour.

Separable from Phase 3 because host functions are useful without it, and it is
the riskiest single piece (GC-visible argument arrays, re-entrancy). Landing it
alone means a bisect points straight at it.

Deliverable: host→JS→host round trip; MAX_RUN_DEPTH test.

### Phase 5 — bindings

Six independent, parallelisable sub-tasks in dependency order of risk: C3 and
Zig first (direct), Rust next (panic handling), Python and Ruby last (managed
closures). Each lands with its own example and README section.

Documentation (`docs/embedding.md`) lands with Phase 3 for the ABI and is
amended per binding in Phase 5.

### Must land together vs. can follow

- Phases 1 and 2 must land together **if** Phase 1 alone would expose a
  registration path with no argument access — it would not, because Phase 1's
  API is C3-internal and not public. They can therefore land separately.
- Phase 3 must not land before Phase 2: a public ABI over an unproven GC design
  is the worst ordering.
- Phase 4 can follow Phase 3 by any interval.
- Phase 5 can follow at leisure, per language.

---

## Test strategy

Test files go in `test/` alongside the existing suite (`test/*.js`) for the
JS-visible behaviour, and in `examples/c99` (or a new `test/capi/`) for the ABI.
Every JS-level test must also pass under `make boomkat_gc_stress`.

### Call shapes — the five paths from premise 6

| # | Case | JS | Asserts |
|---|---|---|---|
| 1 | plain call | `hostAdd(1, 2)` | returns 3 |
| 2 | as a method, `this` | `({x:5}).m = hostGetX; obj.m()` | `jse_this` sees the receiver |
| 3 | `.call` | `hostGetX.call({x:7})` | exercises `function.c3:317` |
| 4 | `.apply` | `hostAdd.apply(null,[1,2])` | same path, spread args |
| 5 | `.bind` | `hostAdd.bind(null,1)(2)` | exercises `function.c3:1177`, `vm_calls.c3:1272` |
| 6 | as a getter | `Object.defineProperty(o,'p',{get:hostFn})` | exercises `vm_core.c3:219` |
| 7 | as a setter | `...{set:hostFn}`; `o.p = 1` | exercises `vm_property.c3:2340` and `:2565` — **both** PUTPROP paths |
| 8 | `new` | `new HostCtor(1)` | exercises `vm_calls.c3:2846`; `this` populated, instance returned |
| 9 | `new` on a non-constructor | `new hostAdd()` | throws TypeError via `builtin_fn_is_constructor` |
| 10 | `super()` | `class D extends HostCtor { constructor(){ super(1) } }` | exercises `vm_calls.c3:2415`; **may reveal a limitation, document if so** |
| 11 | `new` on a bound host ctor | `new (HostCtor.bind(null,1))()` | exercises `vm_calls.c3:2797` |
| 12 | via `vm_call_fn_impl` | `[3,1,2].sort(hostCmp)` | exercises `vm_execute.c3:277` — a builtin calling a host fn |
| 13 | `.name` / `.length` | `hostAdd.name === 'hostAdd' && hostAdd.length === 2` | validates the metadata decision |
| 14 | `typeof` | `typeof hostAdd === 'function'` | |

Case 12 is the sleeper: a host function passed as a callback to a *builtin* goes
through a path most designs forget. Case 7 needs both variants because
`vm_property.c3` has two separate setter dispatch blocks.

### Value round-tripping

For each of undefined, null, true, false, 0, -0, NaN, Infinity, 2^53, a small
string, an empty string, a string with an astral character (verifying the
CESU-8/UTF-8 conversion), and a string with an embedded NUL: pass into a host
function and return it unchanged; assert identity in JS. Plus reading an object
and an array argument's type via `jse_type_of`.

### Errors

| Case | Asserts |
|---|---|
| `jse_throw_error(TYPE, "boom")` | JS `catch` sees a TypeError with message `boom` |
| host throws a value handle | `catch (e) { e === thatValue }` |
| host throws, uncaught | `jse_eval` returns `JSE_ERR_THROW`, `jse_last_error` is `"TypeError: boom"` |
| host throws then returns a value | throw wins |
| host calls JS that throws, checks status, re-throws | propagates |
| host calls JS that throws, **ignores** the status, returns | still propagates (the auto-propagate rule) |
| host calls JS that throws, catches and continues | host's own return value is used, no pending exception |

### Recursion and depth

- host→JS→host, 3 levels, values correct at each level.
- Mutual recursion computing a known result (e.g. a host/JS ping-pong
  factorial), asserting the value.
- Deep recursion to 200 levels: expect a catchable
  `RangeError: Maximum call stack size exceeded` at 128, and — critically —
  assert that after catching it, **a subsequent normal call still works**. That
  is the exact failure the `vm_execute.c3:186` comment warns about
  (`throw_pending` surviving the unwind), and it will not be caught by any test
  that only checks the RangeError fires.

### GC

- All of the above under `make boomkat_gc_stress`.
- Host function allocating 1000 strings in one call, returning the last;
  assert correctness under GC_STRESS.
- Host function that reads `jse_arg(ctx, 0)` *after* an intervening `jse_call`
  that allocates heavily — the valstack-realloc scenario. This is the test that
  justifies the scope-array design; it should fail loudly if arguments were
  register references.
- Handle-after-scope: store a scope handle in a C static, use it after the
  callback returns, assert `JSE_ERR_INVALID` and no crash. Run under ASan.
- `jse_value_persist` across many evals, then read it — assert the value
  survived collections.
- Slot exhaustion: persist 1025 values, assert `JSE_INVALID_VALUE` and a clean
  `JSE_ERR_FULL`.
- **Async generator interaction** (the low-confidence case from
  [GC correctness](#gc-correctness)): a host function called from inside an
  async generator body, under GC_STRESS. If `native_frame_depth` is reset to 0
  during resume (`heap.c3:296`), this is where it shows.

### Teardown

- Register functions, `jse_close`, assert no leak under ASan.
- `jse_close` called from inside a host callback: assert it is refused and the
  process survives.
- Register up to the cap, assert `JSE_ERR_FULL` beyond it.
- `jse_open`/`jse_close` cycles with registration each time: assert no
  cross-runtime state leaks (registration must be per-runtime).

---

## Risks

Ordered by expected pain.

**1. `native_frame_depth` reset during async generator resume.** `heap.c3:296`
says "Resuming drops native_frame_depth to 0". If a host function is live on the
stack when that happens, temproot clearing resumes and the scope array's
contents can be collected mid-call. This is the single thing in this plan I am
least sure about. It is testable (see above) and fixable (root the scope array
explicitly, or make the reset save/restore rather than zero), but I have not
traced the resume path far enough to say which. **Trace it in Phase 2 before
writing the scope code.**

**2. `register_gc_root` fails silently.** `heap.c3:1961` drops the root when the
64-entry table is full, with no error. If any fallback for risk 1 uses GC roots
per nesting level, deep host recursion silently loses rooting and corrupts the
heap in a way that will look like a random crash weeks later. If that fallback
is needed, it must cap depth and fail loudly. Prefer the temproot-based design
precisely to avoid this.

**3. The metadata assumption.** The recommendation to set `.name`/`.length` as
own properties and leave `builtin_get_metadata` alone rests on all 19 consumers
being fallbacks. I read several and they look like fallbacks, but I did not read
all 19. If one takes precedence, `.name` reads empty and the fix is a 19-site
`Heap*` thread. Low severity, moderate likelihood; test 13 catches it in
Phase 1.

**4. `super()` to a host constructor.** `vm_calls.c3:2415` handles builtin
superclasses, and derived-constructor `this` initialisation
(`vm_execute.c3:930-940`, the `is_derived_target` logic) is subtle. Host
constructors will route through the builtin path; whether that produces correct
`this` binding for a derived class I genuinely do not know. Test 10 will tell.
If it is wrong, the right answer for v1 is to document the limitation, not to
rework derived-constructor semantics.

**5. The out-of-range-index convention is implicit.** `builtin_fn_index >=
HOST_FN_BASE` means "host function" is a real invariant with no type-system
support. Someone adding a table keyed by builtin index later will index it with
a host value. Mitigation: name the constant, comment both `HOST_FN_BASE` and
`dispatch_builtin`, and audit for `switch`/array-index uses of
`builtin_fn_index` during Phase 1 — I found two (`builtin_get_metadata`,
`builtin_fn_is_constructor`) but a third could exist in a submodule I did not
grep exhaustively.

**6. Handle encoding collision.** Splitting `jse_value`'s bit space between
global slots and scope handles changes the meaning of a value the ABI has
already shipped. Existing handles are small integers and stay in range, so this
is compatible, but every reader must learn the two-way test. A reader that
forgets it will misinterpret a scope handle as a slot id and read the wrong
value. Mitigation: route every handle resolution through one internal
`resolve_handle` function, and never test the bit inline.

**7. Concurrent edits.** `src/capi.c3`, `include/jse.h`, `Makefile`,
`project.json` and `bindings/ruby/` are being modified by other agents right
now. Phases 3 and 5 must be rebased onto that work rather than developed against
today's tree.

**8. Ruby's `Fiddle::Closure`.** Availability and exception-safety are both
genuinely uncertain across Ruby builds. Plan for the Ruby binding to ship with a
runtime capability check and a documented "unsupported here" path rather than
assuming parity with the other five.

**9. C3 stack depth is unbounded by `MAX_RUN_DEPTH`.** A host with large frames
can overflow the C stack before hitting 128 VM levels. No engine-side fix is
possible without knowing the host's frame size. Document the limit; revisit only
with evidence.
