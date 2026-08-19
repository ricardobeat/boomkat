# 075: Implement `structuredClone` per HTML §2.7

## Goal

Add `structuredClone(value, options)` as a global, implementing the HTML
"Structured cloning API" (WHATWG HTML §2.7.10) over the engine's existing
JS-level types. After this lands, `FEATURES.md` flips
"`structuredClone` ❌ → ✅" for boomkat.

The engine is single-realm and single-agent, so the spec's two-pass
`StructuredSerializeWithTransfer` + `StructuredDeserializeWithTransfer`
collapses into one pass that walks the source graph and emits clones in
place. Cycles and shared references are preserved through an identity map
keyed by `HObject*`.

## Scope

### Supported JS types (per spec §2.7.3-§2.7.6)

- **Primitives**: `undefined`, `null`, `Boolean`, `Number`, `BigInt`, `String`
- **Wrapper objects**: `new Boolean()`, `new Number()`, `new BigInt()`, `new String()`
- **`Date`**: copy `[[DateValue]]`
- **`RegExp`**: copy `[[OriginalSource]]`, `[[OriginalFlags]]`, fresh compiled bytecode via `re_compile(pattern, flags)`; `lastIndex` is intentionally NOT preserved (matches spec: not in the record)
- **`ArrayBuffer`**: copy bytes; reject if detached
- **`SharedArrayBuffer`**: reject — boomkat is single-agent and the SAB would be unobservable in the only agent cluster (§2.7.7 step 2a, repurposed: any SAB is non-portable here)
- **`ResizableArrayBuffer`**: copy bytes and the maxByteLength cap (the engine may or may not support resizing today — if absent, treat as fixed `ArrayBuffer`)
- **TypedArray + `DataView`**: deep-copy the backing buffer, preserve `byteOffset` and `byteLength` / `arrayLength`
- **`Map`**: copy entries
- **`Set`**: copy values
- **`Error`** (and `EvalError`, `RangeError`, `ReferenceError`, `SyntaxError`, `TypeError`, `URIError`): preserve `name`, `message`; copy `[[Stack]]` from the source's `captured_stack` (which the engine already stores as `HObjectError.captured_stack`)
- **`Array`** (Array.isArray): preserve `length`, copy enumerable own indexed + string-keyed properties
- **Plain object** (every other `ObjClass.OBJECT` that survives the rejection list): copy enumerable own properties

### Explicitly rejected (throw `DataCloneError`)

- `Symbol` (any kind, including registered symbols)
- `Function` of any kind (ordinary, arrow, async, generator, async generator, bound, class) — the engine has no `[[Callable]]`-but-cloneable platform objects, so all callables are rejected per §2.7.3 step 21
- `Proxy` — exotic object that is not `Object.prototype` (§2.7.3 step 23)
- Anything with internal slots beyond `[[Prototype]]` / `[[Extensible]]` / `[[PrivateElements]]`: `Promise`, `WeakMap`, `WeakSet`, `WeakRef`, `FinalizationRegistry`, generators, async generators, module namespace objects
- Detached `ArrayBuffer`, out-of-bounds `TypedArray`/`DataView`

### Transferables

Only `ArrayBuffer`. The `transfer` option must contain a non-shared,
non-detached `ArrayBuffer`. On success the source is detached (the existing
`arraybuffer_detach` helper does exactly this). Per §2.7.7 step 1, an entry
in `transfer` that is not an `ArrayBuffer` throws `DataCloneError`; a
SharedArrayBuffer entry throws `DataCloneError`; a duplicate entry throws
`DataCloneError`. The transferred array appears as `null` in the source
value's clone tree.

### Errors

Throw `DataCloneError`. The engine has no `DOMException`, so `DataCloneError`
is a new global Error subclass with `.name === "DataCloneError"`, message
describing the cause. This matches what V8/SpiderMonkey expose in non-DOM
contexts and is what the test262 expectations assert (`.name`, not
`instanceof DOMException`).

### Function signature

```js
structuredClone(value)
structuredClone(value, { transfer: [...] })
```

The `options` parameter is `OrdinaryGetOwnProperties`-d for `transfer`. A
non-object `options` is treated as `{}`. A `transfer` entry that is itself
not array-like throws `DataCloneError` (per spec, transferList is a sequence;
non-objects are a TypeError at the entry-check stage, but the spec calls the
top-level failure `DataCloneError`, so emit that).

## Why a single-pass implementation

`StructuredSerializeWithTransfer` + `StructuredDeserializeWithTransfer`
exist because postMessage crosses a realm boundary where the target realm
isn't known until the message is delivered. The HTML §2.7.10 note calls
`structuredClone` "the notable exception" because it operates in one realm
and can therefore skip the serialized intermediate form. We get the same
result with a recursive walk that:

1. Looks the source up in the identity map and returns the cached clone if
   present.
2. Allocates the new object (or returns the primitive).
3. Records the clone in the identity map **before** recursing into its
   children — this is the cycle break.
4. Recursively clones children, writing the results into the new object.

This is one allocation per visited node instead of two, no Records to
allocate, and the same memory-map semantics for cycles and shared
references.

## File layout

```
src/builtins/structured_clone.c3   // new, ~700 lines
```

The algorithm is self-contained (no cross-builtin imports beyond
`hobject`, `heap`, `hstring`, `hbigint`, `env`, `vm`, `re_bindings`, plus the
`core.c3` helpers like `builtins_generic_get` and `builtin_intern_string`),
so it belongs in its own file. `register_builtins` gets one new line to
call `register_structured_clone` after `DataCloneError` and the
`structuredClone` function have been wired.

The `Builtin` enum gets two new members:

```
STRUCTURED_CLONE         {"structuredClone", 1, &builtin_structured_clone},
DATA_CLONE_ERROR         {"DataCloneError", 1, &builtin_data_clone_error},
```

`DataCloneError` is a real Error constructor so callers can do
`e instanceof DataCloneError`. Its body is the standard
`coll_construct`-style Error construction with `.name = "DataCloneError"`.

## Algorithm

### Memory map

```c3
struct CloneEntry {
    HObject* src;
    TVal     clone;     // uninitialized until allocated
}

struct CloneMap {
    CloneEntry* entries;   // heap.alloc_func'd, growable
    uint        count;
    uint        cap;
}
```

The map is keyed by `HObject*` (identity). Primitives never enter the map.
Linear-scan lookup is fine for the sizes we expect (the same trade-off as
the existing `CollHashInfo` built lazily — see `src/hobject.c3:738`).

### Per-type cases

Each `switch (obj.flags.obj_class)` arm mirrors a §2.7.3 step:

| ObjClass               | Spec step                                | Implementation |
|------------------------|------------------------------------------|----------------|
| `OBJECT` (plain)       | step 24 (Object)                         | Allocate `ObjClass.OBJECT`, copy enumerable own properties |
| `ARRAY`                | step 18 (Array exotic)                   | Allocate `ObjClass.ARRAY`, set `extra.array_length`, copy enumerable own properties (length derives from `array_length`) |
| `BOOLEAN` wrapper      | step 7 (Boolean)                         | Allocate `ObjClass.OBJECT`, set `prim.primitive_value` |
| `NUMBER` wrapper       | step 8 (Number)                          | Allocate `ObjClass.OBJECT`, set `prim.primitive_value` |
| `BIGINT` wrapper       | step 9 (BigInt)                          | Allocate `ObjClass.OBJECT`, set `prim.primitive_value` |
| `STRING` wrapper       | step 10 (String)                         | Allocate `ObjClass.OBJECT`, set `prim.primitive_value` |
| `DATE`                 | step 11 (Date)                           | Allocate `ObjClass.OBJECT`, set `prim.primitive_value` to the same double |
| `REGEXP`               | step 12 (RegExp)                         | Allocate `ObjClass.REGEXP`, re-compile the source pattern via `re_bindings::re_compile` with the same flags, copy `pattern_str` |
| `ARRAYBUFFER` (fixed)  | step 13.2 (ArrayBuffer)                  | New `ObjClass.ARRAYBUFFER`, `arraybuffer_alloc_bytes(length)`, memcpy |
| `ARRAYBUFFER` (shared) | step 13.1 (SharedArrayBuffer)            | Throw `DataCloneError` |
| `ARRAYBUFFER` (resize) | step 13.2.5 (ResizableArrayBuffer)       | Same as fixed + record `max_byte_length` |
| `DATAVIEW` / typed-arr | step 14 (ArrayBufferView)                | Clone the backing buffer (already in the identity map), allocate view of the right class, set `view.buffer`, `view.byte_offset`, `view.byte_length` |
| `MAP`                  | step 15 (Map)                            | Allocate `ObjClass.OBJECT` (the engine stores Map data in `array_part`, not a subtype — see below), recurse into entries, append to `array_part` |
| `SET`                  | step 16 (Set)                            | Same as Map, single-element entries |
| `ERROR`                | step 17 (Error)                          | Allocate `ObjClass.ERROR`, pick prototype by name, copy `message`, copy `captured_stack` from source |
| `FUNCTION`, `PROXY`    | step 21 (callable), step 23 (exotic)     | Throw `DataCloneError` |
| everything else        | step 22 (other internal slots)           | Throw `DataCloneError` |

### Map/Set storage reality check

The engine stores Map and Set entries in `HObject.array_part` (the
`CollHashInfo` doc at `src/hobject.c3:738` describes this), not in a
subtype-specific slot. A Map's `array_part` is `[k0, v0, k1, v1, ...]`,
a Set's is `[v0, v1, ...]`. Cloning a Map means walking `array_part` in
pairs, cloning each key and each value (which itself recurses), and
appending to the clone's `array_part`. The `CollHashInfo.slots` index on
the source is dropped — the clone rebuilds it lazily on first lookup, the
same way `new Map()` does. This is correct: the engine treats
`array_part` as the single source of truth and the hash index as a cache.

### Enumerable own properties

For `Object` and `Array` (steps 18.4 and 24.4), walk the object's
property table via `HObject.get_prop_proto` filtering by
`PROP_FLAGS_ENUMERABLE`, then call `builtins_generic_get` to invoke
accessor getters. Set on the clone with `PROP_FLAGS_WEC` (writable,
enumerable, configurable) — the clone is a fresh ordinary object, and
`CreateDataProperty` per spec creates properties that way.

### ArrayBuffer copy

```c3
uint len = src_ab.byte_length;
char* dst = ctx.heap.alloc_func(ctx.heap.heap_udata, len);
if (dst == null) { throw DataCloneError; }
if (len > 0) std::memcpy(dst, src_ab.data, len);
```

The existing `arraybuffer_alloc_bytes` (or whatever the constructor uses)
already wraps this and marks `data` null for zero-length. For the
detached case, `IsDetachedBuffer` translates to `byte_length == 0xFFFFFFFF`,
which throws `DataCloneError` per §2.7.3 step 13.2.1.

### TypedArray / DataView clone

Walk `view.buffer` first (it'll be cloned into the identity map). Allocate
a new view of the same class. Wire `view.buffer = clone_of_buffer`,
`view.byte_offset = src.byte_offset`, `view.byte_length = src.byte_length`.
The `length_tracking` flag carries over if both the source buffer is
resizable and the source view was length-tracking; otherwise the clone is
fixed-length. The `views_head` chain on the new buffer is rewired so the
new view is registered.

### Transfer handling

Before cloning:

1. Validate `options.transfer` is array-like; iterate.
2. For each entry `t`:
   - Must be an `ArrayBuffer` (rejects `SharedArrayBuffer` and other
     classes with `DataCloneError`).
   - Must not be detached.
   - Must not appear twice (track a seen-set of `HObject*`).
3. Record `(src_ab, TVal::NULL)` in the identity map for each entry —
   this is how §2.7.7 ensures the cloned tree sees `null` at the source's
     position.

During the walk, when an entry in the transfer list is reached as part of
the cloned graph, the identity map returns the pre-seeded `null`.

After the walk completes successfully:

4. For each entry, detach the source (`arraybuffer_detach`).

If anything throws during the walk, transfer entries that have already
been detached are leaked (the spec accepts this — detachment is
irreversible). We follow suit.

### Error capture

For `Error` clones, copy the source's `captured_stack` field directly to
the clone's `captured_stack` so the new error's `error.stack` accessor
returns the same string. The spec leaves the post-deserialization stack
"implementation-defined"; cloning the source's stack is the most
consistent choice and matches V8.

### `lastIndex` reset

`RegExp.prototype.lastIndex` is intentionally NOT preserved (spec
§2.7.3 step 12 records only `[[OriginalSource]]` and
`[[OriginalFlags]]`). The fresh re-compile produces a fresh matcher
with `lastIndex = 0`, which matches V8/SpiderMonkey.

## API entry point

```c3
fn void builtin_structured_clone(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        // structuredClone() with no argument must throw TypeError per spec
        // (§2.7.10 step 1: "Let value be ? options..."; missing argument is
        // a missing required parameter).
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "structuredClone requires at least 1 argument");
        return;
    }

    // Build identity map, walk, write result.
    CloneMap map;
    map.init(ctx.heap);
    defer map.free();

    // Pre-seed transfer entries.
    TransferState ts;
    if (!apply_transfer_options(ctx, &ts, &map)) return;  // throws DataCloneError on bad input

    TVal out; out.set_undefined();
    if (!clone_value(ctx, ctx.regs[ctx.base_reg], &map, &ts, &out)) return;

    // Detach transferred buffers (only after a successful walk).
    for (uint i = 0; i < ts.count; i++) arraybuffer_detach(ctx.heap, ts.entries[i]);

    *ctx.result = out;
}
```

## Registration

In `register_builtins` (the master function in `src/builtins/core.c3`),
after the Error constructors are wired so `ctx.heap.error_proto` exists,
call:

```c3
if (!register_data_clone_error_ctor(global_env, heap)) return false;
if (!register_simple_builtin(global_env, heap, "structuredClone",
                             Builtin.STRUCTURED_CLONE.ordinal)) return false;
```

`register_data_clone_error_ctor` allocates an Error subclass, sets its
prototype chain (`DataCloneError.prototype.__proto__ === Error.prototype`),
and registers the constructor on the global as `DataCloneError` with
`.name = "DataCloneError"` and `.length = 1`.

## Tests

Three layers, mirroring the existing test strategy:

1. **`test/structured_clone_basic.js`** — local smoke test under
   `just test-local`:
   - primitives, wrapper objects, Date, RegExp
   - cycles, shared references, deeply nested objects
   - Map/Set with primitives and with object keys
   - ArrayBuffer / TypedArray / DataView
   - Error subclasses
   - plain object and Array
   - transfer option: source detached, clone sees null
   - bad transfer: throws DataCloneError
   - non-cloneable types: Symbol, function, Proxy, Promise, WeakMap

2. **`test/structured_clone_rosetta.js`** — appended to the rosetta
   suite (or a new entry in `benchmarks/`) for regression coverage.

3. **test262** — run `just test262 --phase <N>` (the phase that
   exercises Built-ins/Structured cloning, in test262's tree). Add the
   phase to `SKIP_GLOBS`/`UNSUPPORTED_PATTERN` only if a known engine
   gap requires it; aim for green.

The plan assumes test262 is the conformance oracle; `just rosetta` is
the fast regression check during development.

## Phasing

Three commits, each independently useful and each leaving the test
suite green.

### Phase 1 — primitives, wrappers, Object, Array, Date, RegExp

- Add `STRUCTURED_CLONE` and `DATA_CLONE_ERROR` to the `Builtin` enum.
- Implement `clone_value` for primitive fast paths (return as-is) and
  the §2.7.3 cases 7-12 and 18, 24.
- Register the global.
- `just rosetta` green, `test/structured_clone_basic.js` covers the
  Phase 1 types.

### Phase 2 — ArrayBuffer, TypedArray, DataView, Map, Set

- Add the buffer copy, the view rewire, and the Map/Set walk.
- No `transfer` yet — that's Phase 3.
- `just rosetta` green, `structured_clone_basic.js` extended.

### Phase 3 — Error, transfer, final rejection list

- Add Error capture.
- Add `transfer` handling, including the pre-seeded `null` entries and
  the post-walk detach.
- Add the Symbol/Proxy/Function/Promise/WeakMap rejection paths and
  the DataCloneError messages for each.
- `just test262 --phase <N>` green for the structured-cloning phase.

## Out of scope (called out so we don't drift)

- `SharedArrayBuffer` portability: boomkat is single-agent; SAB
  instances are usable as keys/values, but cloning is rejected.
- `ResizableArrayBuffer` resize behavior: if the engine doesn't yet
  implement `ArrayBuffer.prototype.resize`, we still preserve
  `max_byte_length` on the clone — `ArrayBuffer.prototype.resize` is a
  separate feature.
- `Blob`, `File`, `ImageBitmap`, `MessagePort`: not JS types, not in
  this engine.
- Cross-realm cloning: the engine has one realm.
- Async / `Promise` cloning: rejected.

## Verification checklist

- [ ] `just build` clean
- [ ] `just rosetta` green
- [ ] `just test-local` green
- [ ] `just run test/structured_clone_basic.js` green
- [ ] `just test262-phase <N>` green for the structured cloning phase
- [ ] `FEATURES.md` flips the `structuredClone` row
- [ ] `docs/engine-scope.md` updated if it lists the unsupported
  features
