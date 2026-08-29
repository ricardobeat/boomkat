# Plan: Native add-ons — make Temporal-class APIs pluggable

## Goal & honest framing

The request: make APIs like Temporal work like add-ons, maybe compiled separately as a
library and plugged in.

**Calibration up front — there are two different goals here, and only one of them is
cheap.**

1. **Make a built-in feature removable at build time** — a build that does not want
   Temporal should not link it.
2. **Make new features loadable at runtime from a separate shared library**, the way
   QuickJS's `dlopen` + `js_init_module` works.

They sound like the same project and are not. (1) is a mechanical decoupling of the
builtin registration tables. (2) needs a *stable ABI* for object internals, GC, and
error propagation — the hard part is not loading code, it is letting foreign code own
objects the GC traces.

The honest sequencing is that **(1) is a prerequisite for (2)**: until a feature can be
cleanly detached from the engine's static tables, there is nothing to hand to a loader.
This plan does (1) properly, then builds (2) on top, and is explicit about which
guarantees each stage buys.

The prize is that one mechanism lets Intl, a crypto module, a filesystem module, or a
user's own C library plug in without patching `core.c3`. Build it for the general case;
Temporal is the proving ground because it is the most demanding consumer — typed
objects, GC-traced payloads, deep VM coupling. Anything that carries Temporal carries
the rest.

## Why Temporal cannot be gated today — the measurement

I built the naive version and it saves **zero bytes**:

| Build | Size |
|---|---|
| `--features THREADED_DISPATCH,TEMPORAL` | 2,673,864 |
| `--features THREADED_DISPATCH` | 2,673,864 |

All 240 `builtin_temporal_*` symbols survive in both. The anchor is the `Builtin` enum (`core.c3:201` on the temporal branch):

```c3
enum Builtin : uint (String js_name, int js_arity, BuiltinFunc handler) {
    ...
    TEMPORAL_CALENDAR_CTOR {"Calendar", 1, &builtin_temporal_calendar_ctor},
```

On that branch 274 of 844 entries take the address of a Temporal handler. That is a static
initializer in `__DATA_CONST`, so every handler is reachable from a live root and the
linker cannot drop any of it. Gating the eight `setUpTemporal*()` calls removes eight call sites and nothing else.

Wrapping the enum entries in `$if` is not available: C3 rejects `$if` inside an enum
body (`Error: A constant name was expected here`), verified on a minimal case.

**So the enum is the thing to fix, and that is stage 1.**

## The real coupling surface

Measured on the `temporal` branch, Temporal touches 12 engine files outside its own two
(`src/builtins/temporal.c3`, `src/lib/temporal/`). Line references below are to that
branch; this plan's own work lands on `main`, where those files do not yet exist.

| File | refs | What it is |
|---|---|---|
| `src/builtins/core.c3` | 285 | 274 `Builtin` enum entries + 8 setup calls |
| `src/heap.c3` | 35 | 11 root pointers + `mark_temporal` GC tracing |
| `src/hobject.c3` | 22 | 10 `ObjClass` variants + `HObjectTemporal` in the union |
| `src/vm/vm_coerce.c3` | 10 | `TEMPORAL_CALENDAR_CTOR` special case in coercion |
| `src/builtins/date.c3` | 6 | `Date.prototype.toTemporalInstant` bridge |
| `src/vm/vm_execute.c3`, `bytecode.c3`, `env.c3`, `compiler/*` | 2 each | incidental |

Three of these are genuine architectural coupling, not incidental references:

**Object kind.** `ObjClass` is a closed `enum : char` and Temporal owns 10 variants.
`HObjectExtra` is a union with `HObjectTemporal` as a member, so `sizeof(HObject)` is
partly determined by Temporal's payload. A foreign module cannot add a variant.

**GC tracing.** `Heap.mark_temporal()` walks Temporal payloads, called from a `switch`
on `ObjClass` in the mark phase, plus 11 `temporal_*_proto` root pointers marked
directly. GC must trace foreign payloads or they are collected out from under the module.

**Allocation sizing.** `alloc_size_for_class()` switches on `ObjClass` to pick an object
size class. A foreign kind has no size.

This is the list any add-on ABI has to answer. Notably `host_fns` (`HostFnEntry`, `heap.c3:444`) already
solves the *function* half at runtime — `HOST_FN_BASE = 0x4000_0000` (`core.c3:3156`), slots registered
into `Heap.host_fns`, dispatched via `dispatch_host()`. What is missing is the *object*
half: no way to register a class with its own payload, finalizer, and GC mark.

## What QuickJS does (and what to borrow)

`quickjs-libc.c:491` — the loader is ~50 lines:

```c
hd = dlopen(filename, RTLD_NOW | RTLD_LOCAL);
init = dlsym(hd, "js_init_module");
m = init(ctx, module_name);
```

The loading is trivially easy. The part worth borrowing is `JSClassDef` (`quickjs.h:529`),
which is the contract that makes foreign objects first-class:

```c
typedef struct JSClassDef {
    const char *class_name;
    JSClassFinalizer *finalizer;
    JSClassGCMark *gc_mark;      // <- the critical one
    JSClassCall *call;
    JSClassExoticMethods *exotic;
} JSClassDef;
```

Paired with `JS_NewClassID()` for **runtime-allocated** class ids, and
`JS_SetOpaque`/`JS_GetOpaque` for the payload. `examples/point.c` is the whole pattern in
100 lines: allocate a class id, register a `JSClassDef` with a finalizer, stash a
`JSPointData*` via `JS_SetOpaque`.

The lesson for Boomkat: **`ObjClass` must stop being a closed enum for foreign types.**
QuickJS reserves low class ids for built-ins and hands out high ones dynamically —
exactly mirroring what `HOST_FN_BASE` already does for functions.

## Design

### Object model: `ObjClass.HOST` + a class registry

Add one `ObjClass` variant, `HOST`, and a runtime registry parallel to `host_fns`:

```c3
struct HostClass {
    void*  name;            // HString*, interned
    void*  finalizer;       // fn void(void* payload, void* udata)
    void*  gc_mark;         // fn void(void* payload, MarkCtx* ctx)
    void*  udata;
    usz    payload_size;
    uint   proto_slot;      // module-owned prototype root
}
```

Objects of class `HOST` carry `{uint class_id; void* payload;}` in `HObjectExtra` — two
pointers, no per-module union growth, so `sizeof(HObject)` stops depending on which
features are compiled in.

The mark phase gains one `case ObjClass.HOST:` that looks up the class and calls its
`gc_mark`, which re-enters the engine through a `bk_mark_value()` callback. This is the
single most important piece: without it, foreign objects holding JS values are unsafe.

`alloc_size_for_class()` returns a fixed size for `HOST` — payloads are separately
allocated and owned by the module, freed via the finalizer on the existing
`finalize_list` (`heap.c3:518`), which already exists for FinalizationRegistry.

### Builtin registration: table, not enum

Replace the `Builtin` enum's role as *linkage anchor* while keeping it as a *name*.
The dispatch table (`init_builtin_dispatch_table`, `core.c3:3509` on main) is an ordinal-indexed array filled by a
`$foreach` — that indirection is the escape hatch.

Split the enum into per-feature modules, each exposing a registration function:

```c3
// src/builtins/temporal_register.c3
fn void register_temporal(Registry* r) {
    r.add("Temporal.Calendar", 1, &builtin_temporal_calendar_ctor);
    ...
}
```

and a link-time list of registrations, so a feature not in the list contributes no
references and its code is dropped. This is what actually unlocks the build-time win —
and it is the same registry a `dlopen`ed module writes into, which is why stage 1 and
stage 2 share a design rather than being two mechanisms.

### Loader

Once the registry exists, the loader is the easy part — mirror QuickJS:

```c3
fn int bk_load_addon(Runtime* rt, char* path) {
    void* hd = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    BkInitFn init = dlsym(hd, "bk_init_addon");
    return init(rt, &BK_ADDON_API);
}
```

`BK_ADDON_API` is an explicit vtable struct with a version field, not a symbol soup —
the module links against no engine symbols, receiving every entry point through the
struct. That keeps the ABI reviewable and lets it version cleanly.

## Stages

**Stage 1 — `ObjClass.HOST` + class registry.** Add the variant, the `HostClass` table,
GC mark integration, finalizer wiring, allocation sizing. Extend the C API with
`bk_class_register` / `bk_object_new_host` / `bk_object_payload`. Prove it by porting
`test/capi/host_fn.c` to a class with a payload and a GC-traced JS value field.
*No Temporal changes.* Ships value on its own: embedders can define real object types.

**Stage 2 — registry-based builtin registration.** Move builtin declaration from the
`Builtin` enum to per-feature registration functions, starting with one small feature
(`Atomics` or `DataView`) to validate the shape before touching 274 Temporal entries.
Verify with test262 at each step.

**Stage 3 — Temporal as a first-class add-on.** Port Temporal onto the registry and
`ObjClass.HOST`: 10 `ObjClass` variants collapse to host classes, `mark_temporal`
becomes the class `gc_mark`, 11 heap roots become module-owned. Then the build flag
works, and `--features` without `TEMPORAL` genuinely drops it. Keep it statically linked
by default.

**Stage 4 — `dlopen` loader.** `bk_load_addon`, the versioned `BK_ADDON_API` vtable, and
Temporal built as a `.so`/`.dylib` to prove the ABI carries the most demanding consumer.

Stages 1 and 2 are independently valuable and low-risk. Stage 3 is where a feature first
becomes genuinely detachable. Stage 4 is optional and should only follow if stage 3's ABI
proved stable.

## Risks

**Performance.** Temporal builtins currently dispatch through a direct array index. A
registry adds an indirection on every builtin call — the hot path for *all* builtins,
not just Temporal. Must benchmark `bench_function_call` and `bench_property_lookup`
before and after stage 2; if the regression is real, keep static builtins on the fast
path and route only registered ones through the registry.

**GC correctness is the sharp edge.** A module that fails to mark a held value gets
use-after-free that reproduces only under memory pressure. Stage 1 must land with
`gc_stress` coverage (`out/boomkat_gc_stress` exists) exercising a host class holding JS
values across a collection.

**ABI stability.** Once modules ship, `BK_ADDON_API` is frozen. Hence the version field
and the vtable, and hence not doing stage 4 until stage 3 has exercised the surface.

**test262 regression risk in stage 3.** Temporal is 4600 tests at a 4240/360 baseline.
Port incrementally, one object kind at a time, running phase 26 at each step.

## What this does not solve

Making a feature an add-on relocates its code; it does not shrink it. An add-on only
stops costing anything once you opt out of it — the engine gets a floor, and each
feature is priced separately at the point you choose to include it.

That is the actual goal: **modularity and extensibility**. A build that wants Temporal
pays for Temporal either way, so this work should be judged on whether new APIs can be
added without patching `core.c3`, not on what it does to the default binary.
