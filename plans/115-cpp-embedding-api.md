# 115: An idiomatic C++ embedding API (`bk::`)

Status: planned, 2026-10-27. Nothing implemented. Baseline: `main` at
`e018e76e`.

Boomkat gets a C++ layer, `include/boomkat.hpp`: header-only, in namespace
`bk::`, written only against the C ABI in `include/boomkat.h`. The C++ header
exports no symbols and relies on no C++ ABI, and a C embedder never includes it.
Before 1.0 the C API has no compatibility constraint: a better call replaces the
old one outright, and the header, `docs/embedding.md`, the C++ header and every
binding under `bindings/` change in the same commit. The design is Boomkat's own and does not
copy LibJS, V8 or JSI types, though it borrows two ideas: V8's handle scopes and
JSI's value-carries-its-runtime ergonomics.

Most of the work is in the C API. The C++ layer cannot be better than the calls
underneath it, so the plan proposes C API changes wherever they make `bk::`
cleaner or cheaper. Each one must also be usable from plain C, including on an
ESP32. Strings are covered by plan 114 and are not redesigned here.

## 1. Where the embedding surface stands

### 1.1 The C ABI

`include/boomkat.h` has 70 `BK_API` functions and 22 `static inline` helpers
(about 92 entry points). The ownership rules (`include/boomkat.h:5-9`):

- Every value a call returns is an owned registry root, released with
  `bk_free_value` (`src/capi.c3:250`).
- Value arguments are borrowed.
- A callback's `this`/`argv` are *scope handles* that borrow the current call.
- A callback returns an owned handle or `BK_EXCEPTION`.

A `bk_value` is a 64-bit word: runtime id, a scope bit, a generation, and an
index (`src/embed.c3:68-99`). Registry handles index `Runtime.slots`, a growable
array that the GC walks through `Heap.capi_mark` (`src/embed.c3:224-227`,
`:275`). Scope handles name a slot in the heap's host-scope stack
(`src/embed.c3:580-600`). `slot_entry` ignores scope handles
(`src/embed.c3:517`), so `bk_free_value` on a scope handle is a no-op. Several
proposals below depend on that.

Gaps that matter for C++:

| Area | Today |
|---|---|
| Value cost | Every returned value, including `undefined`, takes a registry slot (`src/capi.c3:67`, `:482`). The C3 API's `@scope` (`src/embedding.c3:611`) releases slots in bulk but still allocates one per value. |
| Keys | `const char*` + length, interned on every call (`src/capi.c3:611`, `Heap.str_intern` at `src/heap.c3:5545`). No symbol keys. `bk_get_own_property_names` skips symbols (`src/capi.c3:771`). |
| Strings | UTF-8 only (`include/boomkat.h:128-143`). Plan 114 adds the rest. |
| Types | `BK_TYPE_OTHER` lumps symbol and bigint (`src/embed/abi.c3:32`). |
| Objects | No construct, descriptors, prototypes, `instanceof`, intrinsics or symbols. |
| Native objects | None in the C ABI. The add-on ABI has host classes with payload, finalizer and `gc_mark` (`include/boomkat_addon.h:63-110`, `src/addon.c3:169-264`). |
| Closures | `bk_new_c_function` takes an opaque pointer "borrowed for the runtime's lifetime" (`docs/embedding.md:137-138`). Host function slots are never reused (`src/heap.c3:2929-2934`). |
| Promises | Rejection tracker and job pumping only (`include/boomkat.h:100-105`, `:194-198`). |
| Modules | `bk_define_module` only. The C3 API has a reader hook (`src/embedding.c3:268`) over `esm::ModuleHostHooks` (`src/module.c3:136-147`); C has none. |
| Binary data | None. |
| Allocators | `bk_new_runtime` passes nulls to `heap::create` (`src/embed.c3:192`), whose signature already takes alloc/realloc/free/udata/fatal (`src/heap.c3:1575-1581`). |
| Memory limit | Process RSS, and exceeding it calls `fatal_func` (`src/heap.c3:1472-1475`), whose default aborts (`src/heap.c3:1478`). |
| Weak references | None in the engine. WeakRef, FinalizationRegistry and WeakMap hold strongly (`src/builtins/weakref.c3:1-9`). |

### 1.2 What the engine already has

- **Host classes.** `Heap.register_host_class(finalizer, gc_mark, udata, name,
  proto)` (`src/heap.c3:2968`). Instances are `ObjClass.HOST` objects with
  `{payload, class_id}` (`src/hobject.c3:729`). The marker calls `gc_mark` for
  each live instance (`src/heap.c3:4363`, `src/gc/gc_object.c3:264`), and
  `hobject_free_impl` calls the finalizer when the payload is non-null
  (`src/hobject.c3:2909-2917`).
- **Host scopes.** `dispatch_host` pushes one scope per host call, holding
  `this`, `new.target` and the arguments (`src/builtins/core.c3:3690-3702`,
  `HOST_SCOPE_*` at `src/heap.c3:3041-3043`). Scope values are contiguous in
  `Heap.host_vals`, are refcounted, are shaded on write
  (`src/heap.c3:3085`), and are marked as roots (`src/heap.c3:4552`). Popping
  bumps a generation, so stale handles fail validation. This is the mechanism
  that local handles in §4 C4 extend.
- **Construction.** `dispatch_host` already allocates `this` from
  `new.target.prototype` for constructable host functions
  (`src/builtins/core.c3:3655-3681`). `vm_construct_fn_impl(vm, func, args,
  nargs, new_target)` exists (`src/vm/vm_execute.c3:1532`).
- **Object model.** `js_get_with_receiver`, `js_set_with_receiver`,
  `js_has_property` (`src/builtins/proxy.c3:337`, `:385`, `:531`), descriptors
  as `ProxyDesc` (`:68`), `own_property_desc` (`:208`), `object_define_own`
  (`:1159`), `proxy_mop_own_keys` (`:1365`), `proxy_create` (`:1846`). All are
  Proxy-aware.
- **Promises.** `promise_create` (`src/builtins/promise.c3:583`),
  `promise_new_capability` (`:524`), `promise_get_state` (`:39`),
  `promise_get_result` (`:64`), `promise_resolve_with_value` (`:314`),
  `promise_mark_handled` (`:780`). The job queue is host-managed
  (`hp.host_managed_jobs = true` at `src/embed.c3:212`, checked at
  `src/heap.c3:5696`). Jobs are enqueued in one place,
  `Heap.enqueue_microtask` (`src/heap.c3:5648`).
- **Modules.** Resolve/read/loaded/evaluated hooks (`src/module.c3:136-147`).
  Synthetic modules with a single `default` export exist for JSON, text and
  bytes imports (`src/module.c3:239-247`).
- **Symbols.** Symbols are `HString`s with `is_symbol`. Creation, the registry
  and well-known symbol caches are in `src/builtins/symbol.c3:27`, `:151`,
  `:226-275`.
- **Binary data.** `HObjectArrayBuffer {data, byte_length, ...}`
  (`src/hobject.c3:919`) and views (`:936`). Shared blocks are refcounted libc
  allocations that outlive any one heap (`src/agent.c3:34-67`).
- **Agent wakeups.** Each waiting heap has a port; `port_post_event`
  (`src/agent.c3:256`) and `wait_events` (`src/agent.c3:505`) already let a
  host loop sleep until something arrives.
- **Incremental GC.** `Heap.gc_step(work_budget, quiescent, clock_budget)`
  (`src/gc/gc_incremental.c3:266`). A weak-pruning phase exists for variable
  caches (`Heap.gc_prune_weak_step`, `src/gc/gc_roots.c3:258`).
- **Realms.** A context is a realm with its own intrinsics (`RealmState`,
  `src/heap.c3:627`; `create_realm`, `src/realm.c3:36`).

### 1.3 Bugs found during the survey

Fixed on `main` in `f4fe3657`, `3aa590db` and `e018e76e`, with tests in
`test/capi/embed_api.c` and `test/reflect_delete_typed_array.js`. Recorded here
because they shaped C1.

1. `bk_delete_property` returns success with `*out == 0` and deletes nothing
   for array elements and for every Proxy, without calling `deleteProperty`.
   It checks `find_prop_idx` on the object's own property table before the
   Proxy branch (`src/capi.c3:681`). Dense elements and Proxy targets are not
   in that table.
2. `bk_get_property(ctx, "abc", "length")` fails with `BK_ERR_TYPE`. `as_object`
   (`src/capi.c3:567-578`) rejects primitives where the spec does GetV.
3. `bk_get_new_target` stores `new.target` in the registry and returns an owned
   handle (`src/capi.c3:936-943`), while the call scope already holds it at
   `HOST_SCOPE_NEW_TARGET`.

Fixing the first exposed a fourth: `Reflect.deleteProperty` and a trapless
Proxy deleted TypedArray integer indices through `es_delete_prop`, which
ignores §10.4.5.6. All four now share `object_mop_delete`
(`src/builtins/proxy.c3`).

## 2. Constraints

- **The C ABI is the only dependency.** `boomkat.hpp` only includes
  `boomkat.h`. Both change together until 1.0; `make check-abi`
  (`Makefile:171-175`) keeps the header and the exported symbols in step.
- **No exceptions required.** Godot (godot-cpp), Unreal and most game engines
  build with exceptions off. Every fallible call returns `bk::Result<T>`.
  Exceptions are an opt-in mode.
- **No RTTI.** Class identity uses a static tag per C++ type, never `typeid`.
- **No mandatory STL containers.** The core header uses only `<cstddef>`,
  `<cstdint>`, `<cstring>`, `<new>`, `<type_traits>`, `<utility>`, `<optional>`,
  `<string_view>` and `<tuple>`. `std::string`, `std::vector`,
  `std::function` and `std::span` conversions live in an optional adapter header
  (§6).
- **Nothing unwinds through C3.** Every trampoline catches in exceptions mode.
  Engine frames are not unwind-safe.
- **C stays first-class.** Every call must make sense from plain C on an
  ESP32, and the `char*` property conveniences stay. Heavy features
  (promises, binary data, weak handles, exotic hooks) are feature-gated in the
  tiny build and return `BK_ERR_UNSUPPORTED` when compiled out.
- **Strings stay representation-agnostic.** Everything goes through plan 114's
  functions.

## 3. Use cases

Requirement IDs (C1–C24) refer to the C API changes in §4. S refers to plan
114's string API.

### 3.1 Godot (GDExtension module)

```cpp
// Variant bridging: one specialization covers every bound method.
template <> struct bk::Convert<godot::Variant> {
    static bk::Result<godot::Variant> from_js(bk::Value v) {
        switch (v.type()) {
        case bk::Type::undefined: case bk::Type::null: return godot::Variant();
        case bk::Type::boolean: return godot::Variant(v.as_bool());
        case bk::Type::number:  return godot::Variant(v.as_number());
        case bk::Type::string: {
            BK_TRY_ASSIGN(godot::String s, bk::from_js<godot::String>(v));
            return godot::Variant(s);
        }
        case bk::Type::object:
            if (auto* node = bk::unwrap<godot::Object>(v)) return godot::Variant(node);
            if (auto f32 = v.as<bk::TypedArray<float>>()) return godot::Variant(packed_from(*f32));
            BK_TRY_ASSIGN(godot::Dictionary d, dictionary_from(*v.as<bk::Object>()));
            return godot::Variant(d);
        default: return bk::type_error(v.context(), "unsupported value for Variant");
        }
    }
    static bk::Result<bk::Value> to_js(bk::Context cx, const godot::Variant& v);
};

// Nodes are host-owned: Godot frees them, JS only borrows them.
bk::Class<godot::Node>(cx, "Node", bk::borrowed)
    .method<&godot::Node::get_name>("getName")
    .method("getChild", [](godot::Node& self, int i) { return self.get_child(i); })
    .method("connect", [](bk::Context cx, godot::Node& self, godot::StringName sig,
                          bk::Function cb) -> bk::Result<void> {
        auto* call = memnew(JsCallable(cb.persist()));   // CallableCustom holding bk::Global<Function>
        self.connect(sig, godot::Callable(call));
        return {};
    })
    .install(cx.global());

// NOTIFICATION_PREDELETE: drop the wrapper so stale JS references throw.
void JsBinding::on_predelete(godot::Object* o) { wrappers.detach(o); }

// _process(): job checkpoint plus a bounded GC slice.
void JsRuntimeNode::_process(double) { rt.run_jobs(); rt.gc_step(std::chrono::microseconds(500)); }

// Hot reload of res://player.js.
void JsRuntimeNode::reload(godot::String path) {
    cx.invalidate_module(to_utf8(path));
    auto ns = cx.import(to_utf8(path));                // re-reads through the loader
    // Rebind live instances: Object.setPrototypeOf(instance, ns.default.prototype)
}
```

Requirements:

- Result mode by default (godot-cpp builds without exceptions).
- Host-owned wrappers with detach on predelete (C13). `RefCounted` uses the
  shared policy: retain on wrap, release in a deferred finalizer (C13), because
  an unref can run signals.
- One JS wrapper per `Object*`: an identity cache with weak handles (C15).
- `Callable`s from JS functions: persisted functions (registry roots) and
  closures with finalizers for the reverse direction (C12).
- `StringName` maps to atoms (C7). `godot::String` crosses as UTF-8 (S).
- `PackedFloat32Array` and friends as typed arrays (C19); copies, because
  Godot's packed arrays are copy-on-write.
- Hot reload: module invalidation (C18) and `setPrototypeOf` (C9).
- Jobs and GC driven from `_process` (C17, C20).

### 3.2 Unreal Engine (UObject bindings)

```cpp
static bk::RuntimeOptions make_options() {
    bk::RuntimeOptions o;
    o.alloc   = [](void*, size_t n) { return FMemory::Malloc(n, 16); };
    o.realloc = [](void*, void* p, size_t n) { return FMemory::Realloc(p, n, 16); };
    o.free    = [](void*, void* p) { FMemory::Free(p); };
    o.fatal   = [](void*, const char* m) { UE_LOG(LogJs, Fatal, TEXT("%hs"), m); };
    o.heap_limit = 256ull << 20;
    return o;
}

// UObjects are never owned by JS; the payload holds a weak UE pointer.
struct UObjectPolicy {
    using payload = TWeakObjectPtr<UObject>;
    static UObject* get(payload& p) { return p.Get(); }    // null -> TypeError "object destroyed"
};

bk::Class<AActor>(cx, "Actor", bk::policy<UObjectPolicy>)
    .inherits<UObject>()
    .method<&AActor::GetActorLocation>("getLocation")
    .method<&AActor::SetActorLocation>("setLocation")
    .install(cx.global());

template <> struct bk::Convert<FVector> {
    static bk::Result<FVector> from_js(bk::Value v) {
        BK_TRY_ASSIGN(auto o, v.to_object());
        BK_TRY_ASSIGN(double x, o.get<double>(atoms.x));
        BK_TRY_ASSIGN(double y, o.get<double>(atoms.y));
        BK_TRY_ASSIGN(double z, o.get<double>(atoms.z));
        return FVector(x, y, z);
    }
    static bk::Result<bk::Value> to_js(bk::Context cx, const FVector& v);
};

// UE's collector keeps alive the UObjects that JS created.
class FJsReferences : public FGCObject {
    void AddReferencedObjects(FReferenceCollector& c) override { c.AddReferencedObjects(Owned); }
    TArray<TObjectPtr<UObject>> Owned;
};

void UJsSubsystem::Tick(float) {
    Rt.run_jobs();
    Rt.run_finalizers();                          // deferred finalizers on the game thread
    Rt.gc_step(std::chrono::microseconds(300));
}
```

Requirements:

- Allocator and fatal hooks (C5). Wrapper-side allocations (closure boxes,
  class boxes) go through the runtime allocator, `bk_alloc` (C5), so
  `FMemory` sees all of it. Engine paths that still use libc or C3 `mem`
  (compiler, lexer, AST, agent blocks) are a known gap; see §9.
- Compiles with `-fno-exceptions -fno-rtti`. Class ids come from static tags.
- Base-class brand checks: a `UObject` method accepts an `AActor`
  (`inherits<>()`, parent classes in C13).
- Weak wrapper cache keyed by `UObject*` (C15).
- Deferred finalization (C13) so payload teardown runs on the game thread at a
  known point, never inside a JS allocation.
- GC budget per frame (C20), external memory accounting for large native
  assets (C20).
- `FString`/`TCHAR` as UTF-16 (S).
- Interrupts for runaway scripts in PIE (existing `bk_request_interrupt`).
- Cross-heap cycles (UObject to JS to UObject) are not collected. Wrappers
  hold UObjects weakly by default and strongly only when JS created the
  object. Unified tracing with UE's collector is out of scope.

### 3.3 Desktop apps with Qt

```cpp
class JsEngine : public QObject {
public:
    JsEngine() : rt_(bk::Runtime::create().value()), cx_(rt_.new_context().value()) {
        // A job was queued while the queue was empty: schedule one checkpoint.
        rt_.on_job_enqueued([this] {
            QMetaObject::invokeMethod(this, [this] { rt_.run_jobs(); }, Qt::QueuedConnection);
        });
        bk::Scope s(cx_);
        cx_.global().set("setTimeout", bk::closure(cx_, "setTimeout",
            [this](bk::Context cx, bk::Function cb, double ms) {
                auto keep = cb.persist();
                QTimer::singleShot(int(ms), this, [this, keep = std::move(keep)] {
                    bk::Scope s(cx_);
                    (void)keep.get(cx_).call();
                    rt_.run_jobs();
                });
            }));
    }
    bk::Result<bk::Object> wrap(QObject* o);   // built from QMetaObject, see below
private:
    bk::Runtime rt_; bk::OwnedContext cx_;
};

template <> struct bk::Convert<QString> {
    static bk::Result<QString> from_js(bk::Value v) {
        BK_TRY_ASSIGN(bk::String s, v.to_string());
        return s.visit([](auto view) { return to_qstring(view); });  // Latin-1 or UTF-16 view, no UTF-8 detour
    }
    static bk::Result<bk::Value> to_js(bk::Context cx, const QString& s) {
        return bk::String::from_utf16(cx, {reinterpret_cast<const char16_t*>(s.utf16()), size_t(s.size())});
    }
};

// QObject bridging is runtime reflection, so it uses the dynamic builder.
bk::Result<bk::Object> JsEngine::wrap(QObject* o) {
    const QMetaObject* mo = o->metaObject();
    bk::DynamicClass& cls = classes_.get_or_build(mo, [&](bk::DynamicClassBuilder& b) {
        for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i)
            b.accessor(mo->property(i).name(), read_property(i), write_property(i));
        for (int i = mo->methodOffset(); i < mo->methodCount(); ++i)
            if (mo->method(i).methodType() == QMetaMethod::Slot) b.method(mo->method(i).name(), invoke_slot(i));
    });
    BK_TRY_ASSIGN(bk::Object obj, cls.wrap(cx_, o, bk::borrowed));
    QObject::connect(o, &QObject::destroyed, this, [this, o] { wrappers_.detach(o); });
    return obj;
}
```

Requirements:

- UTF-16 creation and reading (S). With plan 114's view, a wide JS string goes
  to `QString` with one copy and no transcode.
- A job-enqueued hook (C17) so the Qt loop schedules checkpoints instead of
  polling.
- Closures with finalizers (C12) for timers and signal connections.
- A runtime class builder for meta-object reflection (C13 accessors through
  descriptors, C8).
- Detach on `QObject::destroyed` (C13).
- `QFuture` and `QNetworkReply` results as promises (C16).
- Qt builds usually enable exceptions, so either mode should work.

### 3.4 CAD and parametric modeling

```cpp
bk::RuntimeOptions o;
o.heap_limit = 1ull << 30;             // per runtime, and exceeding it never aborts
BK_TRY_ASSIGN(bk::Runtime rt, bk::Runtime::create(o));
BK_TRY_ASSIGN(bk::OwnedContext cx, rt.new_context({.allow_eval = false}));
rt.set_module_loader(bk::sandbox_loader(project_dir));   // no filesystem fallback

bk::Scope s(cx);
// Zero copy: the host keeps the vertex buffer and JS sees a Float64Array over it.
BK_TRY_ASSIGN(auto verts, bk::TypedArray<double>::external(cx, mesh.vertices.data(),
                                                          mesh.vertices.size(), bk::release_noop));
cx.global().set("baseMesh", verts);

bk::Watchdog dog(rt, std::chrono::seconds(10));          // thread calling bk_request_interrupt
auto ns = cx.import("part.js");
if (!ns && ns.error().code() == bk::Errc::interrupted) return report_timeout();
BK_TRY_ASSIGN(auto out, ns->get<bk::TypedArray<float>>("vertices"));
upload(std::span<const float>(out.data(), out.length()));  // valid until the next engine call
```

Requirements:

- Typed arrays with direct data pointers, created from host memory with a
  release callback (C19).
- Per-runtime heap limits that end the script with an uncatchable
  `BK_ERR_NOMEM` and leave the runtime usable or at least destroyable (C20).
  The current RSS check aborts the process.
- Interrupts and progress (existing `bk_set_interrupt`).
- A sandbox loader that never falls back to the filesystem (C18;
  `default_module_read` at `src/module.c3:479` reads files).
- Context options to disable `eval`/`Function` (C21).
- Long-running evaluation driving GC slices between steps (C20).
- `ArrayBuffer` lengths are `uint` (`src/hobject.c3:921`), so 4 GiB per buffer.
  Large meshes span several buffers; see §9.

### 3.5 A DAW or audio plugin

```cpp
// One runtime per plugin instance, owned by the message thread.
struct ScriptedPlugin {
    bk::Runtime rt; bk::OwnedContext cx;
    bk::SharedBlock params;             // retained SharedArrayBuffer data block

    ScriptedPlugin() : rt(bk::Runtime::create(rt_options()).value()), cx(rt.new_context().value()) {
        bk::Scope s(cx);
        auto sab = bk::SharedArrayBuffer::create(cx, sizeof(SpscRing)).value();
        params = sab.block();            // refcount +1; outlives the runtime if needed
        cx.global().set("paramRing", sab);
        rt.gc_inhibit(true);             // GC only when the host asks for it
    }

    // Audio thread: no bk:: runtime calls. SharedBlock::data() is the only
    // part of the API that is safe here.
    void process(float* out, int n) noexcept {
        auto* ring = static_cast<SpscRing*>(params.data());
        apply_automation(*ring, out, n);
    }

    // Message thread, 60 Hz.
    void timer() { rt.run_jobs(); rt.gc_step(std::chrono::microseconds(200)); }
};
```

Requirements:

- SharedArrayBuffer creation from C, plus retain and release of the data
  block from any thread (C19, over `block_retain`/`block_release`,
  `src/agent.c3:59-67`).
- Many isolated runtimes per process, one per instance (exists; runtime ids
  are atomic, `src/embed.c3:214-220`).
- GC inhibit and explicit slices (C20) so collection never lands at an
  unpredictable time on the scripting thread.
- An allocator hook (C5) for hosts that want a pool allocator.
- Interrupt deadlines so a script cannot starve the message thread.
- A context option that makes `Atomics.wait` throw on the main agent (C21),
  since it would block the message thread.
- Several plugins can each link a different Boomkat statically into one host
  process. Symbol visibility is a packaging issue (§6).
- The C++ docs list which calls are audio-thread safe: only `SharedBlock` and
  `Runtime::interrupt()`.

### 3.6 A browser engine

```cpp
// Generated from WebIDL.
auto event_target = bk::Class<EventTarget>(cx, "EventTarget", bk::traced).build();
auto node = bk::Class<Node>(cx, "Node", bk::traced).inherits<EventTarget>()
    .accessor<&Node::parent_node>("parentNode")
    .method<&Node::append_child>("appendChild")
    .build();
auto collection = bk::Class<HTMLCollection>(cx, "HTMLCollection", bk::traced)
    .indexed_getter<&HTMLCollection::item>()            // exotic hooks
    .named_getter<&HTMLCollection::named_item>()
    .build();

// The JS marker reaches the DOM through the payload trace and comes back out
// through wrappers.
void Node::trace(bk::Tracer& t) const {
    t.trace(wrapper_);                                   // bk::Traced<Object>
    for (Node* c = first_child_; c; c = c->next_sibling_) t.trace_host(c);
}

// One realm per browsing context, with the Window class as the global.
BK_TRY_ASSIGN(bk::OwnedContext frame, rt.new_context({.global_class = window_class}));
auto text = bk::String::external_utf16(frame, dom_text.data(), dom_text.size(), release_text);
```

Requirements:

- Exotic hooks on host classes: indexed and named getters, `ownKeys`,
  `defineProperty`, callable instances (C22).
- Class inheritance with brand checks through the chain (C13).
- A custom global object class per context (C21). WindowProxy is open (§9).
- UTF-16 and external strings (S).
- Unified marking driven by the JS collector: payload trace hooks, traced
  slots and a root tracer for host-held roots (C14), plus weak wrapper caches
  (C15).
- Realms (exist), cross-realm intrinsics (C10).
- Microtask checkpoints under HTML's rules (existing
  `bk_execute_pending_job`).
- An asynchronous module loader (C18) for `fetch`-backed imports.
- Error stack and position for the console (C11).
- Atoms (C7) for generated bindings' property names.

### 3.7 A server or edge runtime

```cpp
thread_local bk::Runtime rt = bk::Runtime::create({.heap_limit = 128ull << 20}).value();

void handle(Request& req, Response& res) {
    auto cx = rt.new_context().value();              // per-request realm
    bk::Scope s(cx);
    auto handler = cx.import("app.js").value().get<bk::Function>("default").value();
    auto promise = BK_TRY_OR(handler.call(make_request(cx, req)), return res.error(500));
    bk::Watchdog dog(rt, std::chrono::milliseconds(50));
    while (promise.as<bk::Promise>()->state() == bk::PromiseState::pending) {
        rt.run_jobs();
        rt.wait_events(next_io_deadline());          // woken by bk_wake from the I/O thread
        poll_io_completions(cx);                     // resolves host promises
    }
}
```

Requirements:

- Cheap context creation and reclamation. Realms live until runtime
  destruction today (`docs/embedding.md:47-51`), so per-request contexts leak.
  Open (§9).
- Per-runtime memory and CPU limits (C20, interrupts).
- Host promises resolved from I/O completions (C16) and a loop that sleeps
  until woken from another thread (C17, over the agent port).
- A module loader with resolution and compiled-code caching (C18, C23).
- Moving a runtime between pool threads. `module_async_eval_counter` and the
  module batch state are thread-local (`src/module.c3:1898-1909`), as is
  `index_state` (`src/ast/index.c3:37`). Open (§9).

## 4. Proposed C API changes

Kind is "new" for calls that did not exist, or "replaces" for a change that
removes or redefines an existing call. Replacements carry no shims or
deprecation period; the commit updates every caller in `test/`, `bindings/`
and `docs/`. Option structs have no `struct_size` field before 1.0; the ABI
versioning scheme is a 1.0 decision. New status: `BK_ERR_UNSUPPORTED = -10`
(plan 114 takes -9 for `BK_ERR_ENCODING`).

| ID | Change | Kind | Enables in C++ | Phase |
|---|---|---|---|---|
| C1 | Fix delete, GetV on primitives, borrowed `new.target` | done | correct `Object::remove`, `Value::get` | 0 |
| C2 | `BK_ERR_UNSUPPORTED` | new | `Errc::unsupported` | 0 |
| C3 | Immediate handles for `undefined`/`null`/`true`/`false` | replaces `bk_new_undefined`, `bk_new_null`, `bk_new_bool` | free constants, cheaper results | 1 |
| C4 | Local scopes; callback results are locals | replaces callback result ownership | `bk::Scope`, `bk::Value` locals | 1 |
| C5 | Runtime options and allocator access | replaces `bk_new_runtime()` | `RuntimeOptions`, allocator-aware boxes | 1 |
| C6 | Embedder data slots | replaces the four opaque calls | per-context C++ state beside C state | 1 |
| C7 | Atoms and atom-keyed property calls | new; replaces `bk_get_own_property_names` | `bk::Atom`, symbol keys, fast keys | 1 |
| C8 | Property descriptors | new | accessors, `defineProperty`, class builder | 3 |
| C9 | Object model: construct, prototypes, equality, type enum | new; replaces `BK_TYPE_OTHER` | `Function::construct`, `instanceof`, `Type` | 1 |
| C10 | Intrinsics, symbols, BigInt | new | `bk::Symbol`, `bk::BigInt`, `cx.intrinsic()` | 4 |
| C11 | Error values, non-reentrant describe, stack in error info | new; replaces `bk_error_info` | `bk::Error` diagnostics | 1 |
| C12 | Finalizers on C functions | replaces `bk_new_c_function` | lambdas as JS functions | 3 |
| C13 | Host classes in the C ABI | new; the add-on ABI moves onto it | `bk::Class<T>`, ownership policies | 3 |
| C14 | Traced slots, tracer, root tracer | new | `bk::Traced<T>`, cycle-safe payloads | 3 |
| C15 | Weak handles | new | `bk::Weak<T>`, identity caches | 8 |
| C16 | Promises | new | `bk::Promise`, `bk::Resolver` | 5 |
| C17 | Job hook, wait and wake | new | event-loop adapters | 5 |
| C18 | Module loader, native modules, invalidation | new | `bk::ModuleLoader`, native modules, hot reload | 6 |
| C19 | ArrayBuffer, typed arrays, external and shared buffers | new | `bk::TypedArray<T>`, `bk::SharedBlock` | 7 |
| C20 | GC control, external memory, heap limit without abort | new; removes `bk_set_memory_limit` | `Runtime::gc_*`, limits | 8 |
| C21 | Context options | replaces `bk_new_context` | `rt.new_context({...})` | 8 |
| C22 | Exotic hooks and Proxy creation | new | indexed/named getters | 9 |
| C23 | Compiled scripts | new | `bk::Script`, reload without reparse | 6 |
| C24 | One callback style | removes `bk_host_fn`, `bk_return`; `bk_register_fn` takes `bk_c_function` | one trampoline shape | 1 |
| S | Plan 114 string API | new | `bk::String` | 4 |

### C1. Bug fixes and borrowed `new.target`

Done (§1.3). `bk_delete_property` probes the own property through
`ordinary_own_desc` (by key for module namespaces, so a TDZ export does not
throw) and deletes through `object_mop_delete`; a proxy reports its trap's
answer. `bk_get_property` and `bk_get_property_uint32` read primitives through
their `ToObject` wrapper with the primitive as receiver, keeping the wrapper
registered while getters run. `bk_get_new_target` returns the scope handle at
`HOST_SCOPE_NEW_TARGET`; the Python, Rust and Zig bindings no longer free it.

Still open: `bk_has_property` rejects primitives. `in` throws on primitives in
JS, so that matches the language; the C++ `has` keeps the same rule.

### C2. Unsupported status

```c
/* src/embed/abi.c3 [abi:status], appended */
BK_ERR_UNSUPPORTED = -10  /* feature compiled out of this build */
```

### C3. Immediate handles

```c
#define BK_UNDEFINED ((bk_value)1)
#define BK_NULL      ((bk_value)2)
#define BK_TRUE      ((bk_value)3)
#define BK_FALSE     ((bk_value)4)
#define BK_BOOL(b)   ((b) ? BK_TRUE : BK_FALSE)
```

These are handles with runtime id 0, valid with any context, never freed
(`bk_free_value` ignores them). Every value-returning call whose result is one
of those four values returns the constant. `bk_call(fn, BK_UNDEFINED, ...)` is
the same as `this_value == 0`. `bk_new_undefined`, `bk_new_null` and
`bk_new_bool` are removed.

- C++: `bk::undefined(cx)` and friends are constants. Most setters and calls
  that return `undefined` stop allocating.
- Kind: replaces. Bindings that wrapped the removed calls (Python, Ruby, Rust,
  Zig) use the constants. `bk_dup_value` of an immediate returns it.
- Internals: `resolve_handle` (`src/embed.c3:588`) gains a branch for runtime
  id 0 before the registry lookup. Runtime ids skip 0 already
  (`src/embed.c3:220`).
- Not done: immediate int32. A NaN-boxed double does not fit in the handle
  bits left after the tag, and a number-only fast path complicates every
  reader for a small win.

### C4. Local scopes

```c
typedef uint32_t bk_scope;   /* 0 = none */

/* Open a scope on this context's thread. While it is the innermost scope,
 * every value-returning call yields a scope handle that dies when the scope
 * closes, instead of a registry root. Scopes nest strictly. */
BK_API bk_scope bk_scope_open(bk_ctx ctx);
BK_API void     bk_scope_close(bk_ctx ctx, bk_scope scope);
/* Close `scope` and return `value` as a handle in the enclosing scope, or as
 * an owned registry root when no local scope encloses it. */
BK_API bk_value bk_scope_close_escape(bk_ctx ctx, bk_scope scope, bk_value value);
/* Copy any handle into the innermost scope (a registry root stays owned). */
BK_API bk_value bk_scope_local(bk_ctx ctx, bk_value value);
BK_API bk_scope bk_scope_current(bk_ctx ctx);
```

Inside a host callback the call's own scope is a local scope: every value a
callback creates is a local that dies when the callback returns, like its
`argv`. One rule then covers arguments and results. `bk_dup_value` of a scope
handle returns a registry root; that is the only way a value outlives its
scope. Callbacks return a local (or an immediate) and the trampoline copies it
before popping. Top-level code outside any scope still gets registry roots, so
a simple C embedder that never opens a scope sees today's behavior.

- C++: `bk::Scope` (RAII), `bk::Value` and typed locals at 16 bytes each with
  no registry traffic, `Global<T>::get(cx)` through `bk_scope_local`, and
  trampolines that return locals.
- Kind: replaces. Callback code that stores a created value past the call
  must `bk_dup_value` it. Callbacks no longer free what they create, so most
  callback bodies get shorter. The trampoline's check that rejects scope-handle
  returns (`src/embed.c3:733-736`) inverts. Every `bindings/` callback adapter
  and the `test/capi` callbacks change in the same commit.
- Internals:
  - `Heap.host_scope_push` (`src/heap.c3:3047`) already allocates a scope of
    `count` slots. Add `host_scope_append(TVal) -> long index` for the
    innermost scope. `host_vals` is contiguous and the innermost scope is at
    its end, so appending grows `count` in place. It shades like
    `host_scope_set` (`src/heap.c3:3085`).
  - `store()` (`src/capi.c3:67`) checks a `local_results` flag on the
    innermost scope and appends instead of calling `slot_alloc`.
  - `MAX_HOST_DEPTH` (`src/builtins/core.c3:3620`) counts host frames through
    `host_scope_depth`. Local scopes must not count, so the check moves to a
    separate `host_call_depth` counter.
  - The handle's index field is 17 bits (`src/embed.c3:577`). A scope holds
    at most 131,070 locals; overflow returns `BK_ERR_FULL`. The C++ header
    documents opening nested scopes inside large loops.
- Ordering: C4 lands in Phase 1, before any C++ exists, so `bk::Scope` is
  never registry-backed.

### C5. Runtime options and allocator access

```c
typedef struct {
    void *(*alloc)(void *opaque, size_t size);
    void *(*realloc)(void *opaque, void *ptr, size_t size);
    void  (*free)(void *opaque, void *ptr);
    void  *alloc_opaque;
    void  (*fatal)(void *opaque, const char *message);   /* must not return */
    uint64_t heap_limit;      /* bytes through the allocator; 0 = none (see C20) */
    unsigned flags;           /* BK_RUNTIME_* */
} bk_runtime_options;

BK_API bk_runtime bk_new_runtime(const bk_runtime_options *options);  /* NULL = defaults */
BK_API void *bk_alloc(bk_runtime runtime, size_t size);
BK_API void *bk_realloc(bk_runtime runtime, void *ptr, size_t size);
BK_API void  bk_free_memory(bk_runtime runtime, void *ptr);
```

- C++: `bk::RuntimeOptions`. Closure and class boxes allocate with `bk_alloc`,
  so a host allocator sees the wrapper's memory too.
- Kind: replaces. `bk_new_runtime()` gains the options argument; existing
  callers pass `NULL`. `bk_create()` stays as the one-call convenience.
- Internals: `heap::create(a, r, f, udata, fatal)` (`src/heap.c3:1575`) takes
  these today; `embed::create` passes nulls (`src/embed.c3:192`). The add-on
  ABI exposes the same allocator (`src/addon.c3:377-385`). Engine paths that
  bypass the heap allocator (C3 `mem`/libc in `src/compiler/`, `src/ast/`,
  `src/lexer.c3`, `src/agent.c3`) are listed in the header comment. Routing
  them is a separate item (Phase 8).

### C6. Embedder data slots

```c
#define BK_DATA_SLOTS 4      /* slot 3 is reserved for boomkat.hpp */
BK_API void  bk_set_context_data(bk_ctx ctx, unsigned slot, void *data);
BK_API void *bk_get_context_data(bk_ctx ctx, unsigned slot);
BK_API void  bk_set_runtime_data(bk_runtime runtime, unsigned slot, void *data);
BK_API void *bk_get_runtime_data(bk_runtime runtime, unsigned slot);
```

- C++: the class registry (C++ type tag to `bk_class` per context) and the
  atom cache live in slot 3. Slots 0-2 belong to the host, so a C++ host and a
  C library can share a context.
- Kind: replaces `bk_set_context_opaque`, `bk_get_context_opaque`,
  `bk_set_runtime_opaque` and `bk_get_runtime_opaque`; their callers use
  slot 0.
- Internals: `ContextState` (`src/embed.c3:119-132`) holds `context_opaque`;
  the slots go beside it. `Runtime.opaque` (`src/embed.c3:156`) likewise.

### C7. Atoms

```c
typedef uint32_t bk_atom;    /* 0 = invalid; runtime-wide, valid in every context */

BK_API bk_atom bk_new_atom(bk_ctx ctx, const char *utf8, size_t length);
BK_API bk_atom bk_new_atom_index(bk_ctx ctx, uint32_t index);
BK_API bk_atom bk_value_to_atom(bk_ctx ctx, bk_value key);     /* ToPropertyKey; may throw */
BK_API bk_value bk_atom_to_value(bk_ctx ctx, bk_atom atom);    /* string or symbol */
BK_API bk_atom bk_dup_atom(bk_ctx ctx, bk_atom atom);
BK_API void    bk_free_atom(bk_ctx ctx, bk_atom atom);

BK_API bk_value  bk_get_property_atom(bk_ctx ctx, bk_value object, bk_atom key);
BK_API bk_status bk_set_property_atom(bk_ctx ctx, bk_value object, bk_atom key, bk_value value);
BK_API bk_status bk_has_property_atom(bk_ctx ctx, bk_value object, bk_atom key, int *out);
BK_API bk_status bk_delete_property_atom(bk_ctx ctx, bk_value object, bk_atom key, int *out);

enum { BK_KEYS_OWN = 0, BK_KEYS_STRINGS = 1, BK_KEYS_SYMBOLS = 2,
       BK_KEYS_ENUMERABLE_ONLY = 4, BK_KEYS_SKIP_INDICES = 8 };
BK_API bk_value bk_get_own_property_keys(bk_ctx ctx, bk_value object, unsigned flags);
```

An atom is an index into a runtime table of pinned, interned `HString`s.
Symbols are `HString`s, so symbol keys are atoms with no extra machinery.
Index keys normalize the way property keys already do (`int_to_hstring`, used
at `src/capi.c3:618`).

- C++: `bk::Atom` (RAII), `bk::atoms` static tables per binding, symbol keys,
  `obj.get<T>(atom)`. Generated bindings (WebIDL, Godot `StringName`, UE
  `FName`) intern names once.
- Kind: new, and `bk_get_own_property_keys` replaces
  `bk_get_own_property_names`. The `char*` property calls stay as the simple
  path; an ESP32 host that wants speed precomputes atoms.
- Internals: `Heap.str_intern` (`src/heap.c3:5545`); pinning through
  `HeapHeader.is_pinned` (checked at `src/embed.c3:550`); `ordinary_own_keys`
  and `proxy_mop_own_keys` (`src/builtins/proxy.c3:1294`, `:1365`) for the
  keys call. The atom table is a GC root, like the registry
  (`Heap.capi_mark`, `src/heap.c3:1100`).

### C8. Property descriptors

```c
enum {
    BK_PROP_WRITABLE = 1, BK_PROP_ENUMERABLE = 2, BK_PROP_CONFIGURABLE = 4,
    BK_PROP_HAS_VALUE = 8, BK_PROP_HAS_GET = 16, BK_PROP_HAS_SET = 32,
    BK_PROP_HAS_WRITABLE = 64, BK_PROP_HAS_ENUMERABLE = 128, BK_PROP_HAS_CONFIGURABLE = 256
};
typedef struct {
    unsigned flags;
    bk_value value, get, set;   /* borrowed on input; owned or local on output */
} bk_property_descriptor;

BK_API bk_status bk_define_property(bk_ctx ctx, bk_value object, bk_atom key,
                                    const bk_property_descriptor *desc, int *ok);
BK_API bk_status bk_get_own_property(bk_ctx ctx, bk_value object, bk_atom key,
                                     bk_property_descriptor *out, int *found);
```

- C++: `obj.define(atom, bk::accessor(getter, setter))`, `bk::data(value,
  bk::enumerable)`, the class builder's accessors and statics.
- Kind: new.
- Internals: `ProxyDesc` (`src/builtins/proxy.c3:68-83`) has the same
  presence bits; `object_define_own` (`:1159`) and `own_property_desc`
  (`:208`).

### C9. Object model

```c
BK_API bk_value  bk_construct(bk_ctx ctx, bk_value constructor, const bk_value *argv,
                              unsigned argc, bk_value new_target /* 0 = constructor */);
BK_API bk_value  bk_new_object_with_proto(bk_ctx ctx, bk_value proto /* BK_NULL allowed */);
BK_API bk_value  bk_get_prototype(bk_ctx ctx, bk_value object);
BK_API bk_status bk_set_prototype(bk_ctx ctx, bk_value object, bk_value proto);
BK_API bk_status bk_instanceof(bk_ctx ctx, bk_value value, bk_value constructor, int *out);
BK_API int       bk_strict_equals(bk_ctx ctx, bk_value a, bk_value b);
BK_API int       bk_same_value(bk_ctx ctx, bk_value a, bk_value b);
BK_API int       bk_is_array(bk_ctx ctx, bk_value value);          /* IsArray; may see through Proxy */
BK_API bk_status bk_get_length(bk_ctx ctx, bk_value object, uint64_t *out);  /* LengthOfArrayLike */
BK_API bk_value  bk_json_parse(bk_ctx ctx, const char *utf8, size_t length);
BK_API bk_value  bk_json_stringify(bk_ctx ctx, bk_value value);

/* [abi:type]: OTHER is removed */
BK_TYPE_SYMBOL = 7, BK_TYPE_BIGINT = 8
```

- C++: `Function::construct`, `Object::create(cx, proto)`,
  `value.instance_of(ctor)`, `operator==` as strict equality,
  `bk::Type::symbol`/`bigint`, `bk::json::parse`.
- Kind: new calls; the type enum replaces `BK_TYPE_OTHER` with `SYMBOL` and
  `BIGINT`, which are the only kinds it covered. A new kind gets its own
  value.
- Internals: `vm_construct_fn_impl` (`src/vm/vm_execute.c3:1532`);
  `object_get_proto` (`src/builtins/proxy.c3:275`) and `Heap.set_prototype`;
  `classify` (`src/embed.c3:615`) already separates symbols from strings;
  `src/builtins/json.c3`.

### C10. Intrinsics, symbols and BigInt

```c
typedef enum {
    BK_INTRINSIC_OBJECT_PROTOTYPE, BK_INTRINSIC_FUNCTION_PROTOTYPE,
    BK_INTRINSIC_ARRAY_PROTOTYPE, BK_INTRINSIC_ERROR_PROTOTYPE,
    BK_INTRINSIC_TYPE_ERROR_PROTOTYPE, BK_INTRINSIC_PROMISE_PROTOTYPE,
    BK_INTRINSIC_ITERATOR_PROTOTYPE, /* ... appended only */
} bk_intrinsic;
BK_API bk_value bk_get_intrinsic(bk_ctx ctx, bk_intrinsic which);

typedef enum { BK_SYMBOL_ITERATOR, BK_SYMBOL_ASYNC_ITERATOR, BK_SYMBOL_TO_STRING_TAG,
               BK_SYMBOL_TO_PRIMITIVE, BK_SYMBOL_HAS_INSTANCE, /* ... */ } bk_well_known_symbol;
BK_API bk_value bk_new_symbol(bk_ctx ctx, const char *description, size_t length);
BK_API bk_value bk_symbol_for(bk_ctx ctx, const char *key, size_t length);
BK_API bk_value bk_get_well_known_symbol(bk_ctx ctx, bk_well_known_symbol which);
BK_API bk_value bk_symbol_description(bk_ctx ctx, bk_value symbol);   /* string or undefined */

BK_API bk_value  bk_new_bigint_int64(bk_ctx ctx, int64_t value);
BK_API bk_value  bk_new_bigint_uint64(bk_ctx ctx, uint64_t value);
BK_API bk_status bk_read_bigint_int64(bk_ctx ctx, bk_value value, int64_t *out, int *lossless);
BK_API bk_value  bk_new_bigint_words(bk_ctx ctx, int negative, const uint64_t *words, size_t count);
BK_API bk_status bk_read_bigint_words(bk_ctx ctx, bk_value value, int *negative,
                                      uint64_t *words, size_t capacity, size_t *count);
```

- C++: `cx.intrinsic(bk::Intrinsic::array_prototype)`, `bk::Symbol`,
  `bk::BigInt`, `Convert<int64_t>` that accepts BigInt.
- Kind: new. `BK_ERR_UNSUPPORTED` in builds without BigInt
  (`src/hbigint_disabled.c3`).
- Internals: `RealmState` prototypes (`src/heap.c3:627-700`), resolved
  through the context's realm. `create_symbol_string`, `symbol_registry_get`,
  `ensure_*_symbol` (`src/builtins/symbol.c3:27`, `:151`, `:226-275`).
  `hbigint_alloc` (`src/hbigint.c3:70`).

### C11. Errors

```c
BK_API bk_value bk_new_error(bk_ctx ctx, bk_error_kind kind, const char *message);  /* not thrown */
/* Format a value for diagnostics without running JS: no getters, no Proxy
 * traps, no toString. Same contract as bk_read_string for sizing. */
BK_API bk_status bk_describe(bk_ctx ctx, bk_value value, char *buffer, size_t capacity, size_t *length);

/* bk_error_info gains the stack; no separate extended form. */
typedef struct {
    bk_status code;
    int line, col;
    const char *script_name;
    const char *stack;        /* context-owned, may be NULL */
} bk_error_info;
BK_API bk_status bk_get_error_info(bk_ctx ctx, bk_error_info *out);
```

- C++: `bk::Error::describe()` reads the exception after later engine calls
  have overwritten the context's diagnostics. `bk::type_error(cx, "...")`
  builds errors without throwing.
- Kind: new calls; `bk_error_info` is redefined in place. Read the current
  struct (`include/boomkat.h`) when implementing; keep its existing fields and
  add `stack`.
- Internals: `describe_error` (`src/embed.c3:418`) formats into the context
  buffer and also replaces the pending exception. `bk_describe` factors out the
  formatting half. The stack is in `HObjectError` (`src/hobject.c3:739-743`).

### C12. Finalizers on C functions

```c
typedef void (*bk_finalizer)(void *data, void *opaque);
BK_API bk_value bk_new_c_function(bk_ctx ctx, bk_c_function callback, const char *name,
                                  int arity, unsigned flags, void *data,
                                  bk_finalizer finalize, void *finalize_opaque);
```

There is one constructor for C functions. The callback receives `data` as its
`opaque`. `finalize` runs once when the function object is collected or the
runtime is destroyed, under the same rules as host class finalizers (C13).
`finalize == NULL` gives today's behavior: `data` is borrowed for the
runtime's lifetime. `bk_fn_def` gains the same two fields.

- C++: `bk::closure(cx, name, lambda)` with captures, `std::function`
  adapters, signal connections that clean up.
- Kind: replaces `bk_new_c_function`; callers that need no cleanup pass
  `NULL, NULL`.
- Internals: host function slots are permanent (`src/heap.c3:2929-2934`), so a
  closure must not take a slot per instance. One slot per distinct
  `callback` pointer, cached in a small table on the runtime. The per-closure
  `data` lives in a hidden-keyed HOST object of an internal class whose
  finalizer calls `finalize`, attached the way promise resolve functions
  attach their promise (`src/builtins/promise.c3:565`). The trampoline
  reads it through `ctx.callee_obj` (used at `src/builtins/core.c3:3667`).

### C13. Host classes

```c
typedef uint32_t bk_class;   /* 0 = invalid; ids are per runtime */

typedef struct bk_tracer bk_tracer;
typedef void (*bk_trace_fn)(void *payload, bk_tracer *tracer, void *opaque);

enum { BK_CLASS_DEFER_FINALIZE = 1 };

typedef struct {
    const char   *name;
    bk_class      parent;          /* 0 = none; brand checks accept subclasses */
    bk_finalizer  finalize;        /* payload, opaque; must not call the engine */
    bk_trace_fn   trace;           /* report JS values held in the payload */
    bk_c_function construct;       /* NULL = not constructible from JS */
    int           arity;
    unsigned      flags;
    void         *opaque;
    const struct bk_exotic_hooks *exotic;   /* C22; NULL = ordinary */
} bk_class_def;

/* Creates the class, its prototype (inheriting the parent's) and its
 * constructor function in this context's realm. */
BK_API bk_class bk_define_class(bk_ctx ctx, const bk_class_def *def,
                                bk_value *constructor_out, bk_value *prototype_out);
BK_API bk_value bk_new_instance(bk_ctx ctx, bk_class cls, void *payload,
                                bk_value new_target /* 0 = class prototype */);
/* The payload when `value` is an instance of `cls` or a subclass, else NULL. */
BK_API void *bk_get_instance_payload(bk_ctx ctx, bk_value value, bk_class cls);
/* Set the payload of an instance whose payload is NULL (the constructor's
 * `this`), or clear it to detach. Clearing does not run the finalizer. */
BK_API bk_status bk_set_instance_payload(bk_ctx ctx, bk_value value, bk_class cls, void *payload);
BK_API bk_class bk_get_instance_class(bk_ctx ctx, bk_value value);
/* Run finalizers deferred by BK_CLASS_DEFER_FINALIZE. Returns how many ran. */
BK_API unsigned bk_run_finalizers(bk_runtime runtime);
```

When `construct` is set, `new C(...)` and `super(...)` from a JS subclass
allocate `this` as an `ObjClass.HOST` instance of `cls` with a null payload and
the prototype of `new.target`. The callback then sets the payload with
`bk_set_instance_payload`. So `class Foo extends Vec3` works without anything
extra.

- C++: `bk::Class<T>`, `bk::DynamicClass`, the `owned`, `borrowed`, `shared`
  and custom ownership policies, `bk::unwrap<T>(value)`, detach. Deferred
  finalizers give Unreal and Godot a safe place to destroy native objects.
- Kind: new. The add-on ABI (`include/boomkat_addon.h:63-110`) registers its
  classes through the same `bk_class_def`, so there is one host-class model;
  its separate registration entry points are removed.
- Internals:
  - `register_host_class` and `HostClassEntry` (`src/heap.c3:2968`, `:516`)
    gain `parent`, `trace` (replacing `gc_mark`'s `Heap*` argument with a
    tracer), `flags` and `exotic`.
  - `HostClassEntry.proto` is a single prototype per runtime, but prototypes
    belong to realms. A class defined through the C ABI is per context. Each
    `bk_define_class` call registers a fresh id; ids are dense and cheap.
  - `dispatch_host`'s `made_this` path (`src/builtins/core.c3:3655-3681`)
    allocates `ObjClass.HOST` when the host function entry carries a class
    id. `HostFnEntry` (`src/heap.c3:524`) gains `class_id`.
  - Deferred finalization: `hobject_free_impl` (`src/hobject.c3:2909-2917`)
    appends `{payload, finalize, opaque}` to a runtime list instead of
    calling it. Frees can come from a refcount reaching zero in the middle of
    any engine call, which is why a finalizer must not call the engine and
    why deferring matters to hosts.

### C14. Traced slots and tracers

```c
/* Opaque storage for one JS value inside host memory. Sized for the
 * NONANBOX build, matching BK_TVAL_SIZE in boomkat_addon.h. */
typedef struct { uint64_t opaque[2]; } bk_slot;

BK_API void      bk_slot_init(bk_slot *slot);                      /* undefined */
BK_API bk_status bk_slot_set(bk_ctx ctx, bk_slot *slot, bk_value value);
BK_API bk_value  bk_slot_get(bk_ctx ctx, const bk_slot *slot);
BK_API void      bk_slot_clear(bk_ctx ctx, bk_slot *slot);

BK_API void bk_trace_slot(bk_tracer *tracer, const bk_slot *slot);
/* Host roots: called during root marking, including incremental root scans. */
typedef void (*bk_root_tracer)(bk_tracer *tracer, void *opaque);
BK_API void bk_set_root_tracer(bk_runtime runtime, bk_root_tracer callback, void *opaque);
```

A slot holds a reference without being a root. It stays alive only while
something traces it: the owning host object's `trace`, or the root tracer.
That is what lets a payload point back at JS objects without leaking cycles.
Registry roots cannot do that.

- C++: `bk::Traced<T>` members, `bk::Tracer::trace`, `T::trace(bk::Tracer&)`
  detected by the class builder.
- Kind: new.
- Internals: `api_handle_store`, `api_value_init`, `api_value_clear`,
  `api_mark_value` (`src/addon.c3:341-375`) are the add-on versions. Two
  corrections for the incremental collector: `bk_slot_set` shades the stored
  value as `slot_alloc` does (`src/embed.c3:504`). That is an insertion
  barrier, required because a payload traced earlier in the cycle is not
  revisited. The root tracer hooks next to `capi_mark`/`capi_mark_slice`
  (`src/heap.c3:1100-1101`), with a slice variant so the incremental root scan
  (`src/gc/gc_roots.c3:192`) can budget it.

### C15. Weak handles

```c
typedef uint64_t bk_weak;
BK_API bk_weak  bk_new_weak(bk_ctx ctx, bk_value object);       /* objects and non-registered symbols */
BK_API bk_value bk_weak_get(bk_ctx ctx, bk_weak weak);          /* BK_UNDEFINED once collected */
BK_API void     bk_free_weak(bk_ctx ctx, bk_weak weak);
```

- C++: `bk::Weak<T>`, wrapper identity caches (Godot `Object*`, `UObject*`,
  DOM nodes, `QObject*`).
- Kind: new.
- Internals: the engine has no weak references at all
  (`src/builtins/weakref.c3:1-9`). A weak table on the runtime is cleared in
  two places: `gc_prune_weak_step` (`src/gc/gc_roots.c3:258`) after marking
  reaches a fixed point, and `hobject_free_impl` for refcount frees, guarded by
  a "weakly referenced" header bit so ordinary frees pay one test. The same
  table could later make `WeakRef` and `FinalizationRegistry` real. That is a
  separate decision with test262 consequences (§9).

### C16. Promises

```c
typedef enum { BK_PROMISE_PENDING, BK_PROMISE_FULFILLED, BK_PROMISE_REJECTED } bk_promise_state;

/* A pending promise and its resolving functions. */
BK_API bk_value  bk_new_promise(bk_ctx ctx, bk_value *resolve_out, bk_value *reject_out);
BK_API bk_status bk_promise_state_get(bk_ctx ctx, bk_value promise, bk_promise_state *out);
BK_API bk_value  bk_promise_result(bk_ctx ctx, bk_value promise);
BK_API bk_status bk_promise_mark_handled(bk_ctx ctx, bk_value promise);
BK_API bk_value  bk_promise_resolve(bk_ctx ctx, bk_value value);   /* Promise.resolve */
BK_API bk_value  bk_promise_then(bk_ctx ctx, bk_value promise, bk_value on_fulfilled, bk_value on_rejected);
```

Resolution goes through `bk_call` on the resolving functions, which run the
spec's resolve procedure, thenable adoption included.

- C++: `auto [promise, resolver] = bk::Promise::create(cx)`,
  `resolver.resolve(value)`, `promise.then(cx, lambda, lambda)` over C12
  closures, and a C++20 coroutine adapter.
- Kind: new.
- Internals: `promise_create` and `promise_new_capability`
  (`src/builtins/promise.c3:583`, `:524`), `promise_get_state` (`:39`),
  `promise_get_result` (`:64`), `promise_mark_handled` (`:780`),
  `promise_resolve_default_ctor` (`:371`).

### C17. Job hook, wait and wake

```c
/* Called on the engine thread when a job is enqueued into an empty queue.
 * Must not run JS. Hosts schedule a checkpoint from here. */
typedef void (*bk_job_hook)(bk_runtime runtime, void *opaque);
BK_API void bk_set_job_hook(bk_runtime runtime, bk_job_hook hook, void *opaque);

/* Block until bk_wake, an Atomics.waitAsync settlement, or the timeout.
 * Returns 1 when woken by an event, 0 on timeout. Engine thread only. */
BK_API int  bk_wait_events(bk_runtime runtime, double timeout_ms);
/* Any thread, while the runtime lives. Latched until the next wait returns. */
BK_API void bk_wake(bk_runtime runtime);
```

- C++: `rt.on_job_enqueued(f)`, `rt.wait_events(deadline)`, a thread-safe
  `bk::Waker` handle, and loop adapters for Qt, libuv and a minimal reference
  loop.
- Kind: new.
- Internals: `Heap.enqueue_microtask` (`src/heap.c3:5648`) calls the hook on
  the empty-to-non-empty transition. `bk_wait_events` and `bk_wake` are
  `agent::wait_events` (`src/agent.c3:505`) and `port_post_event`
  (`src/agent.c3:256`) through `port_for` (`:239`), so host wakeups and
  `Atomics.waitAsync` share one sleep.

### C18. Modules

```c
typedef struct bk_module_request bk_module_request;   /* engine-owned, valid until answered */

typedef struct {
    /* Resolve `specifier` against `referrer` into a canonical name, written with
     * bk_module_set_name. Return BK_OK, or a failure status. */
    bk_status (*resolve)(bk_ctx ctx, const char *referrer, const char *specifier,
                         bk_module_request *request, void *opaque);
    /* Supply source for a canonical name with bk_module_provide (copies) or
     * bk_module_provide_native. May answer later for async loaders (flag below). */
    bk_status (*load)(bk_ctx ctx, const char *name, bk_module_request *request, void *opaque);
    void *opaque;
    unsigned flags;            /* BK_LOADER_ASYNC, BK_LOADER_NO_FILESYSTEM_FALLBACK */
} bk_module_loader;

BK_API void      bk_set_module_loader(bk_runtime runtime, const bk_module_loader *loader);
BK_API bk_status bk_module_set_name(bk_module_request *request, const char *name, size_t length);
BK_API bk_status bk_module_provide(bk_module_request *request, const char *source, size_t length);
BK_API bk_status bk_module_provide_native(bk_module_request *request, bk_value exports);
BK_API bk_status bk_module_fail(bk_module_request *request, bk_value error);

/* Named exports from an object's own enumerable properties, plus `default`. */
BK_API bk_status bk_define_native_module(bk_ctx ctx, const char *name, size_t length, bk_value exports);
/* Drop the module record so the next import loads it again. Existing
 * namespaces and bindings keep the old instance. */
BK_API bk_status bk_invalidate_module(bk_ctx ctx, const char *name, size_t length);
BK_API bk_value  bk_import(bk_ctx ctx, const char *specifier, size_t length);  /* promise of namespace */
```

- C++: a `bk::ModuleLoader` interface with `resolve`/`load` virtuals or
  lambdas, `cx.define_module("engine:math", exports)`, `cx.import(name)`,
  `bk::sandbox_loader`, hot reload.
- Kind: new. `bk_define_module` stays: it is the simple path for one
  in-memory module.
- Internals: `ModuleHostHooks` (`src/module.c3:136-147`) takes C3 slices and
  "borrows the buffer for the runtime's lifetime"
  (`src/embedding.c3:138-141`). The C wrapper copies into heap-owned storage
  so C hosts can free immediately. Native modules generalize synthetic
  modules (`is_synthetic`/`synth_value`, `src/module.c3:246-247`) from one
  `default` export to named exports. Invalidation removes the module map
  entry for the context's realm. The async flag needs the module loader's
  pending-load state, which is the largest part of this item; the synchronous
  loader lands first.

### C19. Binary data

```c
typedef enum { BK_INT8, BK_UINT8, BK_UINT8_CLAMPED, BK_INT16, BK_UINT16, BK_INT32, BK_UINT32,
               BK_FLOAT16, BK_FLOAT32, BK_FLOAT64, BK_BIGINT64, BK_BIGUINT64 } bk_element_type;

BK_API bk_value  bk_new_array_buffer(bk_ctx ctx, size_t length, void **data_out);
BK_API bk_value  bk_new_external_array_buffer(bk_ctx ctx, void *data, size_t length,
                                              bk_finalizer release, void *opaque);
BK_API bk_status bk_get_array_buffer(bk_ctx ctx, bk_value buffer, void **data, size_t *length);
BK_API bk_status bk_detach_array_buffer(bk_ctx ctx, bk_value buffer);

BK_API bk_value  bk_new_typed_array(bk_ctx ctx, bk_element_type type, bk_value buffer,
                                    size_t byte_offset, size_t length);
typedef struct {
    bk_element_type type;
    void  *data;          /* buffer data + byte offset; NULL when detached */
    size_t length;        /* elements */
    size_t byte_offset;
    bk_value buffer;      /* owned or local */
} bk_typed_array_info;
BK_API bk_status bk_get_typed_array(bk_ctx ctx, bk_value view, bk_typed_array_info *out);

BK_API bk_value  bk_new_shared_array_buffer(bk_ctx ctx, size_t length, void **data_out);
BK_API bk_value  bk_adopt_shared_block(bk_ctx ctx, void *data);   /* SAB over a retained block */
BK_API void      bk_shared_block_retain(void *data);              /* any thread */
BK_API void      bk_shared_block_release(void *data);             /* any thread */
```

Data pointers are valid until the next call that can run JS, resize or detach.
The C++ docs repeat that for `std::span` views.

- C++: `bk::ArrayBuffer`, `bk::TypedArray<float>` and friends with
  `data()`/`length()`/`span()`, `bk::SharedArrayBuffer`, `bk::SharedBlock`
  (RAII retain/release; safe on an audio thread).
- Kind: new. `BK_ERR_UNSUPPORTED` when typed arrays or shared memory are
  compiled out (`NO_SHARED_MEMORY`, plan 109).
- Internals:
  - `HObjectArrayBuffer` (`src/hobject.c3:919-927`) frees `data` through
    `heap.free_func` on detach (`src/builtins/arraybuffer.c3:174-180`) and
    finalization. External buffers need an `external` flag and a release
    record. The record is a small header in front of a descriptor, the way
    shared blocks are laid out (`src/agent.c3:34-57`), so the object payload
    does not grow (plan 081).
  - `byte_length` is `uint`. `size_t` arguments above `UINT32_MAX` return
    `BK_ERR_INVALID` until buffer lengths widen (§9).
  - `ta_typed_array_create` (`src/builtins/typedarray.c3:3358`),
    `ta_element_count` (`:1163`).
  - `block_alloc`/`block_retain`/`block_release` (`src/agent.c3:49-67`).

### C20. GC and resource control

```c
enum { BK_GC_MINOR = 0, BK_GC_FULL = 1 };
BK_API void     bk_gc(bk_runtime runtime, int kind);
/* Run collector work for at most `budget_ns`. Returns nonzero while a cycle
 * is in progress. */
BK_API int      bk_gc_step(bk_runtime runtime, uint64_t budget_ns);
/* While inhibited, allocation never starts a cycle; bk_gc and bk_gc_step still run. */
BK_API void     bk_gc_inhibit(bk_runtime runtime, int inhibit);
BK_API void     bk_add_external_memory(bk_runtime runtime, int64_t delta_bytes);
/* Bytes allocated through the runtime allocator. Exceeding it raises an
 * uncatchable termination reported as BK_ERR_NOMEM; the runtime stays usable. */
BK_API void     bk_set_heap_limit(bk_runtime runtime, uint64_t bytes);
typedef struct { uint64_t heap_bytes, external_bytes, heap_limit;
                 uint32_t live_handles, gc_cycles; } bk_heap_stats;
BK_API bk_status bk_get_heap_stats(bk_runtime runtime, bk_heap_stats *out);
```

- C++: `rt.gc_step(std::chrono::microseconds(300))`, `bk::GcInhibitor`
  (RAII), `rt.add_external_memory(n)`, `RuntimeOptions::heap_limit`.
- Kind: new; `bk_set_memory_limit` (process RSS, fatal on excess,
  `src/capi.c3:1000`, `src/heap.c3:1472-1475`) is removed. The Rust binding
  and `test/capi/embed_api.c`'s memory-limit test move to `bk_set_heap_limit`.
- Internals: `Heap.gc_step` (`src/gc/gc_incremental.c3:266`);
  `gc_trigger_counter` for external pressure; the uncatchable-throw path that
  interrupts use (`Heap.uncatchable_throw`, `finish_interrupt` at
  `src/embed.c3:1040`). Byte accounting needs either sized frees or a size
  header on allocations above the pool classes; pool allocations
  (`POOL_CLASS_COUNT`, `src/heap.c3:556`) already know their class. The hard
  part is allocation failure: every path that can fail must reach a status
  instead of `fatal_func`. That audit is the bulk of Phase 8.

### C21. Context options

```c
typedef struct {
    unsigned flags;          /* BK_CONTEXT_NO_EVAL, BK_CONTEXT_CANNOT_BLOCK, BK_CONTEXT_NO_INTL, ... */
    bk_class global_class;   /* 0 = ordinary global object */
    void    *global_payload;
} bk_context_options;
BK_API bk_ctx bk_new_context(bk_runtime runtime, const bk_context_options *options);  /* NULL = defaults */
```

- C++: `rt.new_context({.allow_eval = false, .global_class = window})`.
- Kind: replaces `bk_new_context(runtime)`; existing callers pass `NULL`.
- Internals: `new_context` and `create_realm` (`src/embed.c3:244`,
  `src/realm.c3:36`). `CANNOT_BLOCK` is the `CanBlockIsFalse` agent property
  (plan 109). `NO_EVAL` checks direct and indirect eval and `Function`
  construction at their entry points. A host-class global object needs
  `global_env.bindings` to be a HOST object; the global environment already
  treats it as an ordinary object.

### C22. Exotic hooks and Proxy creation

```c
BK_API bk_value bk_new_proxy(bk_ctx ctx, bk_value target, bk_value handler);

typedef struct bk_exotic_hooks {
    /* Return 1 when handled (result in *desc, *ok or *keys_out), 0 to fall
     * through to the ordinary behavior, or -1 after bk_throw/bk_throw_error. */
    int (*get_own)(bk_ctx, bk_value self, bk_atom key, bk_property_descriptor *desc, void *opaque);
    int (*define_own)(bk_ctx, bk_value self, bk_atom key, const bk_property_descriptor *desc, int *ok, void *opaque);
    int (*remove)(bk_ctx, bk_value self, bk_atom key, int *ok, void *opaque);
    int (*own_keys)(bk_ctx, bk_value self, bk_value *keys_out, void *opaque);
    bk_c_function call;          /* callable instances; NULL = not callable */
} bk_exotic_hooks;
```

`get`, `set` and `has` derive from `get_own`/`define_own` through the ordinary
algorithms, so the hooks stay small and the invariants hold.

- C++: `indexed_getter`, `named_getter`, `named_setter`, `legacy_caller` on
  the class builder; `bk::Proxy::create` for prototypes and tests.
- Kind: new.
- Internals: there are 149 `is_proxy()` checks under `src/`. Most route
  through the MOP functions in `src/builtins/proxy.c3` (`proxy_mop_get` at
  `:607` through `proxy_mop_own_keys` at `:1365`). The plan is one
  `exotic_host` object flag tested next to `is_proxy()` in those MOP entry
  points, falling back to ordinary behavior. Fast paths that bail on proxies
  must also bail on the new flag; the audit is part of the phase. Until then,
  the C++ builder can emulate indexed getters with `bk_new_proxy` over a host
  handler at Proxy speed.

### C23. Compiled scripts

```c
BK_API bk_value bk_compile(bk_ctx ctx, const char *source, size_t length,
                           const char *filename, unsigned flags);   /* a script object */
BK_API bk_value bk_run_script(bk_ctx ctx, bk_value script);
```

- C++: `bk::Script`, re-run without reparsing (CAD regeneration, per-request
  handlers).
- Kind: new. Bytecode caching across processes builds on
  `src/bytecode_image.c3` later and is not part of this plan.
- Internals: `eval_source` (`src/embed.c3:804-878`) splits into compile and
  execute. The compiled function is tracked by the heap already.

### S. Strings (plan 114)

`bk::String` uses plan 114's calls only: `bk_new_string`,
`bk_new_string_latin1`, `bk_new_string_utf16`, `bk_read_string_utf8` (with
`bk_utf8_mode`), `bk_read_string_utf16`, `bk_string_length`,
`bk_string_view_get` and the external-string constructors. Phase 4 here
follows plan 114's C API Phase 2. `bk::String::view()` waits for plan 114's
Phase 3.

### C24. One callback style

Today a host function is either a `bk_c_function` (arguments in, owned handle
out) or a `bk_host_fn` that reads its call through `bk_argc`/`bk_arg` and
answers with `bk_return`. Every binding and the C++ layer use `bk_c_function`;
`bk_host_fn` appears only in `bindings/c/`, `docs/embedding.md` and
`test/capi/dozen_lines.c`. Keep one:

```c
/* Install `fn` on `target` (0 = global). */
BK_API bk_status bk_register_fn(bk_ctx ctx, bk_value target, const char *name,
                                bk_c_function fn, int arity, unsigned flags, void *data);
```

- Kind: removes `bk_host_fn` and `bk_return`. `bk_register_fn` takes a
  `bk_c_function`. `bk_argc`, `bk_arg`, `bk_this` and `bk_get_new_target`
  stay; they read the current call from any depth, which helpers called from a
  callback use. With C4 the two styles would differ only in how the result is
  returned, so one trampoline shape is enough.
- Internals: the `bk_host_fn` trampoline beside `dispatch_c_function`
  (`src/embed.c3:733-753`) and `Ctx.host_return` (`src/capi.c3:912-924`) go
  away.

### Deliberately not changed

- `char*` property calls stay as the simple C path.
- `bk_value` stays a plain 64-bit integer, which keeps the C, Rust, Zig,
  Python and Ruby bindings simple.

## 5. The `bk::` API

### 5.1 Core types and ownership

```cpp
namespace bk {
class Runtime;            // owns a bk_runtime; move-only
class RuntimeRef;         // non-owning
class OwnedContext;       // owns a bk_ctx; move-only; converts to Context
class Context;            // non-owning, trivially copyable bk_ctx wrapper
class Scope;              // RAII over bk_scope_open/close

class Value;              // {bk_ctx, bk_value}: a local, valid until its scope closes
class Object;   class Function;  class Array;   class String;  class Symbol;
class BigInt;   class Promise;   class ArrayBuffer; class SharedArrayBuffer;
template <class E> class TypedArray;

template <class T = Value>  class Global;   // owned registry root; copy = dup, move = steal
template <class T = Object> class Weak;     // C15
template <class T = Value>  class Traced;   // a bk_slot inside a host object; C14
class Atom;                                  // C7; RAII, runtime-wide
class SharedBlock;                           // C19; thread-safe refcount on a SAB block
}
```

Rules:

- Locals carry their context. `obj.get("x")` needs no context argument.
  Trivially copyable, 16 bytes, passed by value.
- Locals need an open scope. A callback has one implicitly (the trampoline
  opens it); host code opens `bk::Scope s(cx);`. Debug builds assert
  `bk_scope_current(ctx) != 0` when a local is created (C4).
- `value.persist()` returns `Global<T>`; `global.get(cx)` returns a local
  (`bk_scope_local`). A `Global` is the only handle that can be stored in
  long-lived host structures, except `Traced` inside traced payloads.
- Typed locals are checked views: `value.as<Object>()` returns
  `std::optional<Object>`, and `value.to<Object>()` returns a `Result` with a
  TypeError.
- `bk::Context` is non-owning so that callbacks, converters and lambdas can
  take it by value without lifetime questions. `OwnedContext` frees the
  context on destruction; `Runtime` frees the runtime and asserts that no
  `OwnedContext` outlives it.

### 5.2 Errors

```cpp
enum class Errc : int { ok = 0, nomem = -1, syntax = -2, thrown = -3, internal = -4,
                        invalid = -5, type = -6, full = -7, interrupted = -8,
                        encoding = -9, unsupported = -10 };

class Error {                    // move-only
public:
    Errc code() const;
    bool is_uncatchable() const;     // interrupted, or nomem from a heap limit
    Global<Value> exception() const; // the thrown value; an Error for API failures
    int line() const; int column() const;
    // Formats without running JS (bk_describe), into a caller buffer or a sink.
    size_t describe(char* buf, size_t cap) const;
};

template <class T> class [[nodiscard]] Result {
public:
    bool ok() const; explicit operator bool() const;
    T& value() &;  T&& value() &&;    // exceptions mode: throws bk::JsError; otherwise bk::panic
    Error& error();
    template <class U> T value_or(U&& fallback) &&;
    template <class F> auto and_then(F&& f) &&;
    template <class F> auto map(F&& f) &&;
    T* operator->(); T& operator*();
};
template <> class [[nodiscard]] Result<void>;

#define BK_TRY_ASSIGN(decl, expr) /* declares decl or returns the Error */
#define BK_TRY(expr)              /* for Result<void> and discarded results */
#define BK_TRY_OR(expr, ...)      /* evaluates the fallback statement on error */
```

`Error` owns its exception as a registry root. Failures are rare, and an error
has to survive the scope it was produced in. `Error` converts implicitly into
any `Result<U>`, so `return err;` propagates.

`BK_TRY_ASSIGN` is a declaration macro rather than a statement expression,
because MSVC has no statement expressions. In C++20 mode an
`operator co_await` on `Result` is not provided. Coroutines are for async
(§5.6), not for error propagation.

Exceptions mode is on when `BOOMKAT_CPP_EXCEPTIONS` is 1. It defaults to
`__cpp_exceptions`. In that mode `Result::value()` throws `bk::JsError`
(derived from `std::exception`, holding the `Error`), and trampolines catch
`bk::JsError` (rethrown as the JS value), `std::exception` (a JS `Error` with
`what()`), and `...` (a JS `Error`). Nothing escapes into C3. Without
exceptions, `value()` on an error calls `bk::panic`, a replaceable function
pointer that defaults to `std::abort`. Uncatchable failures (interrupt, heap
limit) are never converted into catchable JS throws by a trampoline.

With C++23, `Result<T>::to_expected()` returns `std::expected<T, Error>`
when `__cpp_lib_expected` is defined. `Result` stays the API type, because
C++17 hosts need it and one type is easier to document than two.

### 5.3 Strings

```cpp
class String : public Value {
public:
    static Result<String> from_utf8(Context, std::string_view);
    static Result<String> from_latin1(Context, const uint8_t*, size_t);
    static Result<String> from_utf16(Context, std::u16string_view);
    static Result<String> external_latin1(Context, const uint8_t*, size_t, Release, void*);
    static Result<String> external_utf16(Context, const char16_t*, size_t, Release, void*);
#if BOOMKAT_CPP20
    static Result<String> from_utf8(Context, std::u8string_view);
#endif
    size_t length() const;                                   // UTF-16 units
    Result<size_t> utf8(char* buf, size_t cap, Utf8Mode = Utf8Mode::replace) const;
    Result<size_t> utf16(char16_t* buf, size_t cap) const;
    template <class Sink> Result<void> write_utf8(Sink&&) const;   // chunked, no full copy
    StringView view() const;          // plan 114 bk_string_view: Latin-1 or UTF-16, ascii flag
    template <class F> auto visit(F&& f) const;   // f(std::string_view latin1) or f(std::u16string_view)
};
```

`Convert<std::string>`, `Convert<std::u16string>` and
`Convert<std::string_view>` (to JS only) live in the adapter header. Host
adapters (`QString`, `FString`, `godot::String`) are three-line
specializations over `visit`/`from_utf16`. A view is valid until the next
engine call (plan 114's contract), so `view()` returns a type that is not
copyable out of the expression in debug builds.

### 5.4 Functions and the converter trait

```cpp
template <class T, class Enable = void>
struct Convert;   // no primary definition: a missing specialization is a compile error

// User specialization:
template <> struct bk::Convert<Vec2> {
    static constexpr const char* js_name = "Vec2";            // used in argument errors
    static bk::Result<Vec2> from_js(bk::Value v);
    static bk::Result<bk::Value> to_js(bk::Context cx, const Vec2& v);
};
```

Built-in specializations: `bool`; integers (ToNumber then the spec's ToInt32
or ToUint32 style conversion for 32-bit types, and a RangeError outside the
exact-double range for 64-bit types, which also accept BigInt); `float` and
`double` (ToNumber); enums through their underlying type; `std::optional<T>`
(`undefined`/missing to `nullopt`); `bk::` handle types; `T*`/`T&` for bound
classes (brand-checked); `bk::Nullable<T*>`; and in the adapter header
`std::string`, `std::vector<T>`, `std::map<std::string, T>`, `std::function`,
`std::span<T>` (typed arrays, C++20) and `std::pair`/`std::tuple` (arrays).

Coercion follows WebIDL-style conversion by default. `bk::Strict<T>`
rejects instead of coercing.

Binding:

```cpp
double add(double a, double b) { return a + b; }

cx.global().set("add", bk::function<&add>(cx, "add"));       // no allocation, no closure

cx.global().set("greet", bk::closure(cx, "greet",              // captures need C12
    [prefix = std::string("hi ")](std::string name) { return prefix + name; }));

// Special parameters, in any position:
//   bk::Context, bk::CallInfo& (this, new.target, argc, raw args),
//   bk::This<T>, bk::Rest<T> (remaining arguments), bk::Value (raw).
// Return types: void (undefined), T via Convert, Result<T> (errors throw into JS).
```

The trampoline is one function template per bound function pointer or
lambda type:

```cpp
template <auto F>
bk_value trampoline(bk_ctx c, bk_value self, unsigned argc, const bk_value* argv, void*) {
    detail::CallScope scope(c);                 // bk_scope_open
    CallInfo info{Context(c), self, argc, argv};
    BOOMKAT_CPP_TRY {
        auto args = detail::convert_args<detail::params_t<decltype(F)>>(info);
        if (!args) return scope.fail(std::move(args).error());     // bk_throw, returns BK_EXCEPTION
        if constexpr (detail::returns_void<F>) { std::apply(F, *args); return BK_UNDEFINED; }
        else return scope.escape(detail::to_js(info.cx, std::apply(F, *std::move(args))));
    } BOOMKAT_CPP_CATCH(scope)
}
```

`scope.escape` uses `bk_scope_close_escape` (C4), so a returned local becomes a
handle in the call scope and the C callback can return it. Before C4, the
same code calls `bk_dup_value`.

Argument conversion errors become `TypeError: add: argument 2: expected
number` and are built from `Convert<T>::js_name` and the function name.

### 5.5 Host classes and wrapped native objects

```cpp
struct Vec3 { double x, y, z; double length() const; Vec3 scaled(double) const; };

auto vec3 = bk::Class<Vec3>(cx, "Vec3")          // default policy: bk::owned
    .constructor<double, double, double>()
    .field<&Vec3::x>("x")                        // accessor pair over the member
    .field<&Vec3::y>("y")
    .field<&Vec3::z>("z")
    .method<&Vec3::length>("length")
    .method<&Vec3::scaled>("scaled")             // returns Vec3 by value: a new owned instance
    .static_method("zero", [] { return Vec3{}; })
    .to_string_tag("Vec3")
    .build();                                    // Result<bk::ClassHandle<Vec3>>
BK_TRY(cx.global().set("Vec3", vec3->constructor()));
```

Ownership policies decide what the payload is and what the finalizer does:

| Policy | Payload | Finalizer | Use |
|---|---|---|---|
| `bk::owned` | `T*` from `ClassTraits<T>::create` | `ClassTraits<T>::destroy` | value types made from JS |
| `bk::borrowed` | `T*` | none; host calls `bk::detach(obj)` before freeing `T` | Godot nodes, QObjects, DOM nodes owned by the host |
| `bk::shared<P>` | `P` (smart pointer) | drops `P` | `std::shared_ptr`, Godot `Ref<T>`, `TStrongObjectPtr` |
| `bk::policy<X>` | `X::payload` | `X::release` | UE `TWeakObjectPtr`, custom handles |

`ClassTraits<T>` defaults to `new`/`delete` through `bk_alloc`/placement new
and can be specialized (UE `NewObject`, Godot `memnew`). A detached object
throws `TypeError: Vec3 object has been destroyed` from every method.

Inheritance without RTTI: `.inherits<Base>()` registers the parent class (C13)
and an upcast thunk, `static_cast<Base*>(static_cast<T*>(p))`, stored in the
class record. `bk::unwrap<Base>(v)` finds the instance's class through
`bk_get_instance_class` and walks the recorded thunks. Each class gets a
static tag (`&detail::class_tag<T>`) mapped to its `bk_class` per context in
embedder slot 3 (C6). `bk::DynamicClass` is the same machinery built at run
time from names and callables (Qt meta-objects, Godot `ClassDB`).

Tracing: if `T` has `void trace(bk::Tracer&) const`, the builder installs it
as the class `trace`. `bk::Traced<U>` members hold JS values without rooting
them. Classes with `bk::Traced` members and no `trace` fail to compile.

Finalizer rules, stated in the header: a finalizer never calls the engine. It
can run inside any engine call that drops a reference. Classes that need
engine access or must run on a host-chosen thread use
`.defer_finalization()` (C13) and the host calls `rt.run_finalizers()`.

Identity caches (one wrapper per native object) are a library type,
`bk::WrapperCache<T>`, keyed by pointer and holding `bk::Weak<Object>` (C15).
Until C15 lands, borrowed objects can use a strong cache that the host clears
on destruction, which is enough for Godot, Qt and the DOM, where native
destruction is explicit.

### 5.6 Promises and host event loops

```cpp
// Host-resolved promise.
BK_TRY_ASSIGN(auto pair, bk::Promise::create(cx));
auto& [promise, resolver] = pair;
io.read_file(path, [r = std::move(resolver)](Bytes b) mutable {   // later, on the engine thread
    bk::Scope s(r.context());
    (void)r.resolve(bk::ArrayBuffer::copy(r.context(), b.data(), b.size()));
});
return promise;

// Consuming a JS promise.
BK_TRY(js_promise.then(cx,
    [](bk::Value v) { log("done: ", v); },
    [](bk::Value reason) { log("failed: ", reason); }));

// C++20, optional header boomkat_coro.hpp.
bk::Task<bk::Result<int>> fetch_count(bk::Context cx, bk::Function fetch) {
    bk::Result<bk::Value> r = co_await bk::await(cx, fetch.call("/count"));
    if (!r) co_return std::move(r).error();
    co_return r->to<int>();
}
```

`bk::Resolver` holds two `Global<Function>` and is move-only. Resolving twice
is a no-op, as in JS. A resolver dropped unresolved leaves the promise
pending; debug builds warn.

Event loops: the engine has no timers or I/O. `bk::Runtime` exposes
`on_job_enqueued` (C17), `run_jobs`, `run_one_job`, `wait_events` and a
thread-safe `bk::Waker`. The adapter header ships a minimal single-threaded
reference loop (timers and posted tasks, used by tests and demos). Qt and
libuv integrations are examples, not library code. Unhandled rejection
reporting wraps `bk_set_promise_rejection_tracker` with the existing
"report after the checkpoint" rule (`include/boomkat.h:194-198`).

### 5.7 Modules

```cpp
struct GameLoader : bk::ModuleLoader {
    bk::Result<void> resolve(bk::Context, std::string_view referrer, std::string_view spec,
                             bk::ModuleName& out) override;
    bk::Result<void> load(bk::Context, std::string_view name, bk::ModuleSource& out) override;
};
rt.set_module_loader(std::make_unique<GameLoader>());   // or bk::loader(resolve_fn, load_fn)

BK_TRY(cx.define_module("engine:math", bk::exports(cx)
    .add("Vec3", vec3->constructor())
    .add("lerp", bk::function<&lerp>(cx, "lerp"))));

auto ns = cx.import("game/main.js");       // runs the job queue until the namespace settles
```

`ModuleSource` accepts source text (copied by `bk_module_provide`) or a native
exports object. `cx.import` is a convenience that pumps jobs until the import
promise settles; `cx.import_async` returns the promise. Hot reload is
`invalidate_module` plus a re-import (C18).

### 5.8 Threading model

- A runtime and everything from it belong to one thread at a time, as the C
  API already states (`include/boomkat.h:2-3`). `bk::` types are not
  thread-safe and do not lock.
- Thread-safe surface: `Runtime::interrupt()`, `Runtime::clear_interrupt()`,
  `bk::Waker::wake()` (C17), `bk::SharedBlock` (C19), and `bk::Watchdog`
  (a helper thread that calls `bk_request_interrupt` after a deadline and is
  joined in its destructor, per `include/boomkat.h:199-200`).
- Debug builds record the thread that created the runtime through an
  overridable `BOOMKAT_CPP_THREAD_ID()` hook and assert on every call.
- Isolation: separate runtimes on separate threads share nothing except
  SharedArrayBuffer blocks.
- Moving a runtime between threads between calls (thread pools, Godot's
  `WorkerThreadPool`) is not supported until the thread-local state listed in
  §3.7 moves into the heap (§9). The header documents it.

### 5.9 Allocators

- Engine memory: `RuntimeOptions` maps to `bk_runtime_options` (C5).
- Wrapper memory: closure boxes, class payload boxes and the per-context
  class registry use `bk_alloc(rt)`. `ClassTraits<T>` can override instance
  allocation.
- The core header never calls global `operator new` except through
  `ClassTraits` defaults, and never uses `std::allocator`. The adapter header's
  STL conversions use the standard allocator, since a host using them has
  chosen the STL.
- Shared blocks stay in libc (`src/agent.c3:24-27` explains why). A
  process-wide hook for them is an open question.

### 5.10 GC interplay summary

| Need | Mechanism |
|---|---|
| Native object holds JS values | `bk::Traced<T>` in a traced payload (C14) |
| Host structure outside JS holds JS values | `Global<T>` (root), or `Traced<T>` reported by the root tracer (C14) |
| Native-to-wrapper identity | `bk::WrapperCache` over `Weak` (C15) |
| Big native memory behind small JS objects | `rt.add_external_memory` (C20) |
| Frame-paced collection | `rt.gc_inhibit`, `rt.gc_step(budget)` (C20) |
| Destroy natives on a host thread | deferred finalizers, `rt.run_finalizers()` (C13) |
| Host GC (UE) keeps natives alive for JS | host-side reference set; JS-created objects only |

## 6. Build and packaging

### 6.1 Files

- `include/boomkat.hpp`: the core. Requires only `boomkat.h` and the standard
  headers listed in §2.
- `include/boomkat_std.hpp`: optional STL adapters (`std::string`, `vector`,
  `map`, `function`, `span`) and the reference event loop.
- `include/boomkat_coro.hpp`: optional, C++20 coroutines.

These are the only C++ files. Godot, Unreal and Qt adapters are documented
examples under `bindings/cpp/examples/`, not shipped headers, because each
host's types change on their own schedule.

### 6.2 C++ standard

The baseline is **C++17**.

- Godot's godot-cpp builds as C++17. Qt 6 requires C++17. JUCE 8 requires
  C++17. ESP-IDF toolchains support C++17 and newer. Unreal 5.3+ defaults to
  C++20, but plugins still target engines that default to C++17.
- What the design needs is in C++17: `template <auto F>` for zero-cost
  function binding, `if constexpr`, fold expressions, `std::optional`,
  `std::string_view`, `std::apply`, `[[nodiscard]]`.
- C++20, detected with `__cplusplus` (and `_MSVC_LANG` on MSVC), adds
  concepts on the binding templates (readable errors for a missing
  `Convert<T>`), `std::span` overloads, `char8_t` string overloads,
  designated initializers in the docs' option examples, and coroutines in the
  separate header. With C++23, `std::expected` interop.

C++20 as the baseline would cut off godot-cpp and many shipping plugins for
gains that are mostly diagnostics. Errors under C++17 are kept usable with
`static_assert`s in the primary templates.

### 6.3 Build integration

- `make cpp-check` compiles `test/cpp/` (§7) and a header self-containment
  test. A `just cpp-test` recipe wraps it.
- CMake: a top-level `cmake/` directory with `boomkatConfig.cmake` defining
  `boomkat::c` (imported static or shared library from `out/`) and
  `boomkat::cpp` (INTERFACE target linking `boomkat::c`, adding
  `include/` and `cxx_std_17`). `make install PREFIX=...` installs headers,
  libraries, the CMake package and a `boomkat.pc` for pkg-config. The engine
  itself keeps building with c3c and make; CMake consumes the result. A
  `FetchContent` path calls `make lib` through `ExternalProject` for
  consumers that build from source.
- Godot (SCons), Unreal (`Build.cs` with `PublicAdditionalLibraries`) and Qt
  (CMake) get snippets in `docs/embedding-cpp.md`.
- Plugins (DAW, Unreal) link a static archive into a shared object that can
  coexist with another copy of Boomkat. The static archive must not export
  engine symbols from the plugin. The shared library already has export lists
  (`Makefile:159-165`). For static use, document `-Wl,--exclude-libs,ALL` on
  ELF and `-exported_symbols_list` on Mach-O, and check whether c3c can emit
  hidden visibility for non-`@export` symbols (§9).

## 7. Testing

- **`test/cpp/`**, built by `make cpp-check` in this matrix:
  - `-std=c++17 -fno-exceptions -fno-rtti -Wall -Wextra -Werror -pedantic`
  - `-std=c++17` with exceptions
  - `-std=c++20 -fno-exceptions -fno-rtti`
  - clang and gcc on Linux, Apple clang on macOS; MSVC `/W4 /WX` when a
    Windows runner exists.
  A small in-repo test harness (a few macros) instead of a test framework
  dependency, so the target builds with exceptions off.
- **Coverage by area:** scopes (locals die with the scope, escape works,
  nested callbacks), every `Convert` specialization and its error messages,
  closures (finalizer runs exactly once, including at runtime teardown), classes
  (subclassing from JS, brand checks across inheritance, detach, deferred
  finalizers, traced cycles collected), promises (host and JS resolution,
  rejection tracking), modules (loader, native modules, invalidation), typed
  arrays (external release callback, detach), shared blocks across two
  threads, interrupts surfacing as `Errc::interrupted` through nested
  callbacks.
- **Compile-fail tests:** a script compiles snippets that must not compile
  (missing `Convert`, `Traced` member without `trace`, storing a `Value` in a
  `static`) and checks the diagnostic text.
- **GC stress:** the same tests linked against the `boomkat_stress` build
  (GC at every allocation, ASan; `Makefile:193-195`). Missing traces and
  missing barriers show up there.
- **C tests for every C API change** in `test/capi/` at
  `-std=c99 -Wall -Wextra -pedantic`, including the three Phase 0 repros.
  The C API stays testable without C++.
- **ABI hygiene:** `make check-abi` passes after each phase; `nm` on the
  shared library shows no C++ symbols; `test/capi/dozen_lines.c` stays a
  dozen lines after each replacement.
- **Bindings:** each C API replacement runs the Python example, the Rust
  tests and the Zig and Ruby builds where their toolchains are installed.
- **NaN-boxing:** the C++ tests also run against `just build-nonanbox`,
  because `bk_slot` is sized for the larger representation.
- **Demos** under `bindings/cpp/examples/`, each built by `make cpp-examples`:
  `hello.cpp`, `vec3.cpp` (class binding), `event_loop.cpp` (reference loop,
  timers, host promises), `mesh.cpp` (external typed arrays, interrupts, heap
  limit), `audio_ring.cpp` (two threads over a shared block). `qt_bridge.cpp`
  builds only when Qt is found. Godot and Unreal samples are documentation
  and are compiled in CI only if their SDKs are present.

## 8. Milestones

Each phase lands on `main` independently. Every phase passes
`just test-local`, `just rosetta`, `just modules`, `make check-abi`, the C
API tests and (once it exists) `make cpp-check`. Phases that touch the GC
also pass the stress build and `just build-nonanbox`. A phase that changes
engine paths shared with JS (C1, C13, C22) runs a narrow test262 directory
for the area plus one full run before landing.

**Phase 0: survey fixes.** C1 is done (§1.3). C2 lands with the first
feature-gated call.

**Phase 1: C foundations.** C3, C4, C5, C6, C7, C9, C11, C24. Each
replacement updates `test/capi`, `bindings/` and `docs/embedding.md` in its
own commit. Acceptance:
- A C test opens a scope, makes 100,000 values, closes it, and the registry's
  live count is unchanged.
- An immediate-handle test shows that a call returning `undefined` allocates
  no slot.
- A callback that creates 1,000 values leaves the registry's live count
  unchanged.
- A custom allocator counts every byte of a runtime's heap allocations made
  through `heap::create` (the documented libc gaps excepted).
- Atom-keyed access matches `char*` access for strings, indices and symbols.
- `bk_construct` with a distinct `new_target` gives the instance that
  prototype.

**Phase 2: `boomkat.hpp` core.** `Runtime`, `Context`, `Scope`, locals,
`Global`, `Result`/`Error`, `Convert` for primitives and handles, `eval`,
`call`, `construct`, `get`/`set`, `bk::function<&F>`, exceptions mode,
`boomkat_std.hpp` string and vector adapters, CMake package. Acceptance: the
C++17 no-exceptions/no-RTTI build of `test/cpp/core.cpp` passes; `hello.cpp`
is under 15 lines; a bound free function with three arguments makes no
registry allocation per call (checked with `bk_get_heap_stats` live handle
count, or a debug counter until C20).

**Phase 3: closures, classes, tracing.** C8, C12, C13, C14 in C, then
`bk::closure`, `bk::Class<T>`, policies, `DynamicClass`, `Traced`,
`WrapperCache` (strong mode). Acceptance: `vec3.cpp` works with a JS subclass;
a cycle JS object to payload `Traced` to the same JS object is collected under
the stress build; closures' finalizers run exactly once; deferred finalizers
run only in `run_finalizers`.

**Phase 4: strings, symbols, BigInt.** After plan 114's C API Phase 2: S,
C10, `bk::String`, `bk::Symbol`, `bk::BigInt`, `Convert<std::u16string>`.
`String::view()` follows plan 114's Phase 3. Acceptance: lone surrogates,
astral characters and Latin-1 round-trip through every `bk::String` creator
and reader; a `QString`-style adapter compiles against `from_utf16`/`visit`.

**Phase 5: promises and event loops.** C16, C17, `bk::Promise`,
`bk::Resolver`, reference loop, `bk::Waker`, `boomkat_coro.hpp`. Acceptance:
`event_loop.cpp` runs a timer chain and a host promise resolved from another
thread through `bk_wake`; the job hook fires once per empty-to-non-empty
transition; a coroutine test passes under C++20.

**Phase 6: modules and scripts.** C18 (synchronous loader, native modules,
invalidation), C23, `bk::ModuleLoader`, `cx.import`, `bk::Script`.
Acceptance: a native module's named exports import in JS; a sandbox loader
denies a filesystem path; invalidate-and-reimport picks up new source while an
old namespace keeps working; the async loader flag returns
`BK_ERR_UNSUPPORTED` until its follow-up lands.

**Phase 7: binary data.** C19, typed array and shared block types.
Acceptance: `mesh.cpp` shares a host vertex buffer without copying and its
release callback runs on collection and on teardown; `audio_ring.cpp` passes
under ThreadSanitizer.

**Phase 8: GC and resource control.** C15, C20, C21, and routing the
compiler and lexer allocations through the heap allocator. Acceptance: a
script that allocates past `heap_limit` fails with `Errc::nomem`, the process
survives, and the runtime runs another script; `gc_step` respects its budget
within the batch granularity of `gc_step`; weak handles clear after
collection, including refcount frees; context options disable eval.

**Phase 9: exotic hooks.** C22 and the builder's indexed/named getters.
Acceptance: an `HTMLCollection`-like class passes a test of indexed access,
`Object.keys`, `in`, `delete`, and spread; the `is_proxy()` audit lists every
fast path that now also checks the host-exotic flag; JS benchmarks (Octane
minis) show no regression.

**Phase 10: documentation.** `docs/embedding-cpp.md` with the use-case
sketches from §3 turned into compiled examples where the SDK allows,
`docs/embedding.md` updated for every C addition, and a row in
`plans/index.md`.

Order rationale: the C API work for each feature lands at the start of its
phase and the C++ layer follows in the same phase. Phase 1 has no C++ code.
Phase 2 depends only on Phase 1, so a usable `bk::` exists before the larger
engine items (classes, GC control, exotic hooks).

## 9. Open questions

- **Realm reclamation.** Contexts keep their realm until runtime destruction
  (`docs/embedding.md:47-51`). Server per-request contexts and Godot hot reload
  by fresh context both need realms that the GC can reclaim once nothing
  references them. Is that worth doing, or is module invalidation plus
  long-lived contexts enough?
- **Real `WeakRef`.** C15 builds the machinery that `WeakRef`,
  `FinalizationRegistry` and `WeakMap` would need. Making them weak changes
  observable behavior and test262 expectations. Decide separately.
- **Thread migration.** Move `module_async_eval_counter`, the module batch
  state (`src/module.c3:1898-1909`) and `index_state` (`src/ast/index.c3:37`)
  into the heap, or document that a runtime is pinned to the thread that
  created it? The Date timezone memo (`src/builtins/date.c3:140-142`) is
  harmless either way.
- **Buffer sizes.** `ArrayBuffer` lengths are 32-bit (`src/hobject.c3:921`).
  CAD can live with split buffers. Widening affects plan 081's payload sizing.
- **Host call depth.** `MAX_HOST_DEPTH` is 32 (`src/builtins/core.c3:3620`).
  Event-driven hosts (Qt signals into JS into Qt) can nest deeper than a
  scripting host expects. Make it a runtime option?
- **Scope capacity.** 131,070 locals per scope. Is a wider index worth a
  different handle layout, or is "open a nested scope in big loops" fine?
- **Exotic hooks vs Proxy.** C22's flag touches hot paths. If the Proxy
  emulation is fast enough for real DOM collections, C22 may not be needed.
  Phase 9 measures before committing.
- **WindowProxy and `document.all`.** A browser needs a global that can swap
  its target Window, and the `IsHTMLDDA` object. Neither fits C21 or C22.
  Out of scope until a browser host exists.
- **Asynchronous module loading.** The loader is synchronous. Browsers and
  servers need loads that finish later. How much of the module state machine
  must change?
- **Static library symbol hiding.** Can c3c emit hidden visibility for
  non-exported symbols in `boomkat_static`? Without it, two plugins with
  different Boomkat versions in one host may interpose on ELF.
- **Shared block allocator.** Hosts with strict accounting (Unreal) may want
  SharedArrayBuffer blocks through their allocator too. A process-wide hook
  set before any runtime exists?
- **Allocation failure.** C20 assumes every allocation failure can become a
  status. How many paths still go to `fatal_func`, and is "uncatchable
  `BK_ERR_NOMEM`, runtime destroyable but not reusable" an acceptable first
  step?
- **Locals carry `bk_ctx`.** That doubles a local to 16 bytes. JSI and V8
  locals are one word. The context is needed for every call; measure whether
  passing `Context` explicitly is worth the ergonomic cost.
- **ABI versioning at 1.0.** Option structs drop `struct_size` for now.
  Before 1.0, decide between size-prefixed structs, versioned entry points or
  a single ABI version check at runtime creation.
