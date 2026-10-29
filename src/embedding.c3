// Public C3 embedding API. Callbacks use engine values directly; values held
// between calls are GC-rooted handles shared with the C ABI's embedding core.
//
// Usage sketch:
//
//     JsContext rt;
//     rt.create()!;
//     defer rt.destroy();
//     JsValue v = rt.eval("40 + 2")!;
//     io::printfn("%s", rt.to_display_string(v)!);
//
// Lifetime rules, which are the whole reason this module exists:
//
//   * A `JsValue` is valid until runtime teardown or until
//     `release` is called on it.
//   * Every `JsValue` handed back by `eval` is GC-rooted: the core's registry
//     is walked directly by the mark phase, so a rooted value stays reachable
//     for as long as the host holds it. A borrowed TVal alone cannot keep its
//     object alive across garbage collection.
//   * Runtime destruction frees all roots. Release values inside loops to keep
//     them from accumulating until teardown. The registry grows on demand.
module boomkat @feat(!BYTECODE_ONLY);

import boomkat::agent;
import boomkat::builtins;
import boomkat::embed;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import boomkat::esm;
import std::collections::list;
import std::io;

// ============================================================================
// Errors
// ============================================================================

// Every failure this module can report. These are C3 faults, so callers use
// `!`, `!!`, `if (catch e = ...)` -- the same shape as the rest of the stdlib.
faultdef
    NOT_CREATED,          // operation on an uninitialized runtime or context
    ALREADY_CREATED,      // creation on a live runtime or context
    OUT_OF_MEMORY,
    SYNTAX_ERROR,         // source failed to compile; see last_error()
    JS_EXCEPTION,         // script threw; see last_error()
    INTERNAL_ERROR,       // VM fault with no JS error attached
    INTERRUPTED,          // aborted by the interrupt handler
    ENCODING_ERROR,       // invalid UTF-8 input
    WRONG_TYPE,           // as_number() on a string, etc.
    STALE_VALUE,          // value was released, or belongs to another runtime
    VALUE_TABLE_FULL,     // registry exhausted
    NOT_CALLABLE,         // call() on something that is not a function
    REGISTER_FAILED;      // register_fn could not install the binding

// The JS type of a value, as `typeof` would broadly classify it. Ordinals
// match the core's BK_TYPE_* codes, asserted below rather than spelled twice.
enum JsType : int {
    UNDEFINED,
    NULL,
    BOOLEAN,
    NUMBER,
    STRING,
    OBJECT,
    FUNCTION,
    SYMBOL,
    BIGINT,
}

$assert JsType.UNDEFINED.ordinal == embed::BK_TYPE_UNDEFINED;
$assert JsType.NULL.ordinal      == embed::BK_TYPE_NULL;
$assert JsType.BOOLEAN.ordinal   == embed::BK_TYPE_BOOLEAN;
$assert JsType.NUMBER.ordinal    == embed::BK_TYPE_NUMBER;
$assert JsType.STRING.ordinal    == embed::BK_TYPE_STRING;
$assert JsType.OBJECT.ordinal    == embed::BK_TYPE_OBJECT;
$assert JsType.FUNCTION.ordinal  == embed::BK_TYPE_FUNCTION;
$assert JsType.SYMBOL.ordinal    == embed::BK_TYPE_SYMBOL;
$assert JsType.BIGINT.ordinal    == embed::BK_TYPE_BIGINT;

// Maps a core status onto this module's faults.
macro fault_of(int code) {
    switch (code) {
        case embed::BK_ERR_NOMEM:     return OUT_OF_MEMORY;
        case embed::BK_ERR_SYNTAX:    return SYNTAX_ERROR;
        case embed::BK_ERR_THROW:     return JS_EXCEPTION;
        case embed::BK_ERR_INTERRUPT: return INTERRUPTED;
        case embed::BK_ERR_ENCODING:  return ENCODING_ERROR;
        case embed::BK_ERR_FULL:      return VALUE_TABLE_FULL;
        case embed::BK_ERR_TYPE:      return WRONG_TYPE;
        case embed::BK_ERR_INVALID:   return STALE_VALUE;
        default:                      return INTERNAL_ERROR;
    }
}

// ============================================================================
// Values
// ============================================================================

// A GC-rooted reference to a JS value. Copyable; copies alias the same slot,
// so release exactly once. The registry lives in `boomkat::embed`.
struct JsValue {
    ulong slot;   // 0 == empty/released
}

// The value returned for a statement with no completion value (`var x = 1;`).
const JsValue UNDEFINED_VALUE = { .slot = 0 };

fn bool JsValue.is_empty(self) => self.slot == 0;

// ============================================================================
// Runtime
// ============================================================================

// Owns a heap, a VM, and the root registry.
//
// Several may coexist, each with its own globals, objects and interned
// strings. Values do not cross between them: a `JsValue` names a slot in the
// runtime that produced it, so passing one to another runtime reports
// `STALE_VALUE`.
//
// A runtime must be driven from one thread at a time. The engine has no
// locking, so two threads inside one runtime corrupt it; two threads each
// driving their own runtime share nothing and are fine.
struct JsRuntime {
    embed::Runtime* rt;
    esm::ModuleHostHooks hooks;
    PromiseRejectionHandler rejection_handler;
    void* rejection_udata;
}

struct JsContext {
    embed::Runtime* rt;
    embed::Ctx* context;
    // Handles rooted while a `@scope` is open, released when it closes.
    List{JsValue} scoped;
    uint scope_depth;
    JsRuntime private_runtime;
    JsRuntime* owner;
}

// Returns the source of module `name` (as resolved from its importer), or an
// empty slice or a fault for "no such module". The engine borrows the buffer
// for the runtime's lifetime and never frees it.
alias ModuleReader = fn char[]?(String name, void* udata);


// Create the heap and VM.
//
// Faults: ALREADY_CREATED, OUT_OF_MEMORY
fn void? JsRuntime.create(&self) {
    if (self.rt != null) return ALREADY_CREATED~;
    self.rt = embed::create();
    if (self.rt == null) return OUT_OF_MEMORY~;
    if (self.hooks.read_source) self.rt.heap.set_module_hooks(&self.hooks);
    if (self.rejection_handler) self.set_promise_rejection_tracker(self.rejection_handler, self.rejection_udata);
}

fn void JsRuntime.destroy(&self) {
    embed::destroy(self.rt);
    self.rt = null;
}

fn JsValue? JsRuntime.persist(&self, JsValue value) {
    if (self.rt == null) return NOT_CREATED~;
    TVal tv;
    if (!embed::slot_get(self.rt, value.slot, &tv)) return STALE_VALUE~;
    ulong slot = embed::slot_alloc(self.rt, tv);
    if (slot == 0) return VALUE_TABLE_FULL~;
    return (JsValue){ slot };
}

fn void JsRuntime.release(&self, JsValue value) {
    if (self.rt != null) embed::slot_release(self.rt, value.slot);
}

fn JsType JsRuntime.type_of(&self, JsValue value) {
    TVal tv;
    return self.rt != null && embed::slot_get(self.rt, value.slot, &tv) ? (JsType)embed::classify(tv) : JsType.UNDEFINED;
}

fn bool JsRuntime.is_created(&self) => self.rt != null;

// With no runtime, the context owns its inline runtime. Otherwise it borrows
// the supplied owner, which must outlive it. Keep live owners at stable
// addresses: runtime hooks retain their owner.
fn void? JsContext.create(&self, JsRuntime* runtime = null) {
    if (self.rt != null) return ALREADY_CREATED~;
    if (runtime == null) {
        self.private_runtime.create()!;
        runtime = &self.private_runtime;
    }
    defer catch self.private_runtime.destroy();
    if (runtime.rt == null) return NOT_CREATED~;
    embed::Ctx* context = embed::new_context(runtime.rt);
    if (context == null) return OUT_OF_MEMORY~;
    self.rt = runtime.rt;
    self.context = context;
    self.owner = runtime;
    self.scoped.init(mem);
}

fn void JsContext.destroy(&self) {
    if (self.rt == null) return;
    foreach (value : self.scoped) embed::slot_release(self.rt, value.slot);
    self.scoped.free();
    self.scope_depth = 0;
    embed::free_context(self.context);
    self.context = null;
    self.rt = null;
    self.owner = null;
    self.private_runtime.destroy();
}

fn bool JsContext.is_created(&self) => self.rt != null;

fn JsRuntime* JsContext.get_runtime(&self) => self.owner;

// ============================================================================
// Eval
// ============================================================================

// Compile and run `source`, returning its completion value.
//
// Uses eval semantics, so a trailing expression is the result: `"40 + 2"` yields
// 42 rather than undefined (a plain script body only produces a value through an
// explicit `return`).
//
// Faults: NOT_CREATED, SYNTAX_ERROR, JS_EXCEPTION, INTERNAL_ERROR, INTERRUPTED,
// VALUE_TABLE_FULL
fn JsValue? JsContext.eval(&self, String source, String name = "<eval>", bool strict = false) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    TVal tv;
    bool owned;
    int rc = embed::eval_source(self.rt, (char[])source, (char[])name, &tv, &owned, strict: strict);
    if (rc != embed::BK_OK) return fault_of(rc)~;
    // The registry takes its own reference, so an owned completion value is
    // dropped once rooted.
    defer if (owned) self.rt.heap.decref_tval(&tv);
    return self.root(tv);
}

// Compile, link and evaluate `source` as an ES module named `name`, top-level
// `await` included. Returns the module namespace object. Relative imports
// resolve against `name`.
//
// Faults: NOT_CREATED, SYNTAX_ERROR, JS_EXCEPTION, INTERNAL_ERROR, INTERRUPTED,
// VALUE_TABLE_FULL
fn JsValue? JsContext.eval_module(&self, String source, String name = "<module>") {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    TVal ns;
    int rc = embed::eval_module(self.rt, (char[])source, (char[])name, &ns);
    if (rc != embed::BK_OK) return fault_of(rc)~;
    return self.root(ns);
}

// Make `source` importable as module `name` (`import x from "name"`), ahead
// of any file lookup. Defining a name again replaces it for later imports.
//
// Faults: NOT_CREATED, OUT_OF_MEMORY
fn void? JsContext.define_module(&self, String name, String source) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    if (!esm::define_module(self.rt.heap, (char[])name, (char[])source)) return OUT_OF_MEMORY~;
}

// Serve module sources from `reader` instead of the filesystem, before or after
// `create`. Modules made with define_module still win. The reader receives names
// as resolved and can fall back to `read_module_file` for the default lookup.
fn void JsRuntime.set_module_reader(&self, ModuleReader reader, void* udata = null) {
    self.hooks = { .read_source = (esm::ReadSourceFn)reader, .udata = udata };
    if (self.rt) self.rt.heap.set_module_hooks(&self.hooks);
}

// The default module lookup: read `path` from disk, probing module
// extensions (`.ts` before `.js`) when it has none. The result is allocated
// with `mem` and never freed, ready to return from a ModuleReader.
fn char[]? read_module_file(String path) => esm::default_module_read((char[])path, null);

// Run `source` for its side effects, discarding the completion value.
fn void? JsContext.exec(&self, String source, String name = "<eval>") {
    JsValue v = self.eval(source, name)!;
    self.release(v);
}

// Run a host-selected promise job checkpoint.
//
// Faults: INTERRUPTED
fn void? JsRuntime.drain_microtasks(&self) {
    if (self.rt == null) return;
    int rc = embed::drain_microtasks(self.rt);
    if (rc != embed::BK_OK) return fault_of(rc)~;
}

// ============================================================================
// Building values
// ============================================================================

// Construct rooted values from host data, for passing to `JsContext.call`.
//
// These are the top-level counterparts of the `JsCtx` builders. They return a
// registry handle rather than a scope value: release it, or let an enclosing
// `@scope` do so.

// Faults: NOT_CREATED, OUT_OF_MEMORY, VALUE_TABLE_FULL
fn JsValue? JsContext.string(&self, String s) {
    if (self.rt == null) return NOT_CREATED~;
    HString* hs = self.rt.heap.str_intern((char[])s);
    if (hs == null) return OUT_OF_MEMORY~;
    TVal v; v.set_string_borrowed(hs);
    return self.root(v);
}

// Faults: NOT_CREATED, VALUE_TABLE_FULL
fn JsValue? JsContext.number(&self, double d) {
    if (self.rt == null) return NOT_CREATED~;
    TVal v; v.set_number(d);
    return self.root(v);
}

// Faults: NOT_CREATED, VALUE_TABLE_FULL
fn JsValue? JsContext.boolean(&self, bool b) {
    if (self.rt == null) return NOT_CREATED~;
    TVal v; v.set_boolean(b);
    return self.root(v);
}

// Faults: NOT_CREATED, VALUE_TABLE_FULL
fn JsValue? JsContext.null_value(&self) {
    if (self.rt == null) return NOT_CREATED~;
    TVal v; v.set_null();
    return self.root(v);
}

// ============================================================================
// Calling
// ============================================================================

// Call a JS function from host code, outside any callback.
//
// Top-level counterpart to `JsCtx.call`. Calling a held function avoids the
// recompile that `eval` pays on every invocation.
//
// `args` and `this_value` are registry handles, not scope values, because
// there is no call in progress to scope them to. A stale or empty handle in
// `args` is passed as undefined, matching the C ABI; a stale `func` is an
// error, since calling nothing is never what the caller meant.
//
// Unlike `JsCtx.call` a throw has no JS frame to propagate into, so it is
// reported as JS_EXCEPTION with the message on `last_error()`. Microtasks
// remain queued until the host runs its checkpoint.
//
// Faults: NOT_CREATED, STALE_VALUE, NOT_CALLABLE, JS_EXCEPTION, INTERRUPTED,
// VALUE_TABLE_FULL
fn JsValue? JsContext.call(&self, JsValue func, JsValue[] args = {},
                           JsValue this_value = UNDEFINED_VALUE) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    embed::clear_err(self.rt);

    TVal fv;
    if (!self.load(func, &fv)) return STALE_VALUE~;
    if (!builtins::is_callable_tval(fv)) return NOT_CALLABLE~;

    // call_fn wants a contiguous TVal array; the handles have to be resolved
    // into one rather than cast, since a JsValue is a slot id, not a value.
    TVal[MAX_INLINE_CALL_ARGS] inline_args;
    TVal* argv = null;
    TVal[] spill;
    if (args.len > 0) {
        if (args.len <= MAX_INLINE_CALL_ARGS) {
            argv = &inline_args[0];
        } else {
            spill = mem::new_array(TVal, args.len);
            argv = spill.ptr;
        }
        for (usz i = 0; i < args.len; i++) {
            TVal a;
            if (!self.load(args[i], &a)) a.set_undefined();
            argv[i] = a;
        }
    }
    defer if (spill.len > 0) free(spill);

    TVal tv;
    if (!self.load(this_value, &tv)) tv.set_undefined();

    self.rt.heap.has_error = false;
    TVal res = self.rt.heap.call_fn((void*)self.rt.vm, fv, argv, (uint)args.len, tv);
    if (self.rt.heap.has_error || self.rt.heap.uncatchable_throw) {
        // Keep interrupts distinct from throws, as vm_fault does.
        if (self.rt.heap.uncatchable_throw) {
            embed::finish_interrupt(self.rt);
            embed::set_err(self.rt, embed::BK_ERR_INTERRUPT, "interrupted");
            return INTERRUPTED~;
        }
        embed::describe_error(self.rt, &self.rt.heap.error_value);
        self.rt.heap.has_error = false;
        self.rt.vm.has_error = false;
        self.rt.vm.throw_pending = false;
        return JS_EXCEPTION~;
    }
    return self.root(res);
}

// ============================================================================
// Objects and properties
// ============================================================================

// Allocate an OBJECT or ARRAY and root it. ARRAY selects array_proto, any other
// class object_proto.
fn JsValue? JsContext.alloc_plain(&self, hobject::ObjClass cls) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    HObject* o = self.rt.heap.alloc_object(cls) ?? null;
    if (o == null) return OUT_OF_MEMORY~;
    o.prototype = cls == hobject::ObjClass.ARRAY ? self.rt.heap.array_proto : self.rt.heap.object_proto;
    TVal v; v.set_object(o);
    return self.root(v);
}

// Faults: NOT_CREATED, OUT_OF_MEMORY, VALUE_TABLE_FULL
fn JsValue? JsContext.object(&self) {
    return self.alloc_plain(hobject::ObjClass.OBJECT);
}

// Faults: NOT_CREATED, OUT_OF_MEMORY, VALUE_TABLE_FULL
fn JsValue? JsContext.array(&self) {
    return self.alloc_plain(hobject::ObjClass.ARRAY);
}

// The global object.
//
// Faults: NOT_CREATED, VALUE_TABLE_FULL
fn JsValue? JsContext.global(&self) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    TVal v;
    v.set_undefined();
    if (self.rt.vm.global_env != null && self.rt.vm.global_env.bindings != null) {
        v.set_object(self.rt.vm.global_env.bindings);
    }
    return self.root(v);
}

// `obj[key]`, with full Get semantics: the prototype chain is walked and
// getters run, so this can throw. A missing property is undefined.
//
// Faults: NOT_CREATED, STALE_VALUE, WRONG_TYPE, JS_EXCEPTION, VALUE_TABLE_FULL
fn JsValue? JsContext.get(&self, JsValue obj, String key) {
    if (self.rt == null) return NOT_CREATED~;
    return self.get_key(obj, self.rt.heap.str_intern((char[])key));
}

// `obj[index]`.
fn JsValue? JsContext.get_index(&self, JsValue obj, uint index) {
    if (self.rt == null) return NOT_CREATED~;
    return self.get_key(obj, self.rt.heap.int_to_hstring((long)index));
}

// `obj[key] = value`, with full Set semantics: setters and proxies run.
//
// Faults: NOT_CREATED, STALE_VALUE, WRONG_TYPE, JS_EXCEPTION
fn void? JsContext.set(&self, JsValue obj, String key, JsValue value) {
    if (self.rt == null) return NOT_CREATED~;
    return self.set_key(obj, self.rt.heap.str_intern((char[])key), value);
}

// `obj[index] = value`.
fn void? JsContext.set_index(&self, JsValue obj, uint index, JsValue value) {
    if (self.rt == null) return NOT_CREATED~;
    return self.set_key(obj, self.rt.heap.int_to_hstring((long)index), value);
}

// `obj.length` as an integer, 0 when absent or not a number.
fn uint? JsContext.length(&self, JsValue obj) {
    JsValue n = self.get(obj, "length")!;
    defer self.release(n);
    double? d = self.as_number(n);
    if (catch d) return 0;
    return d > 0 ? (uint)d : 0;
}

fn JsValue? JsContext.get_key(&self, JsValue obj, HString* key) {
    if (self.rt != null) embed::select_context(self.context);
    TVal ov;
    if (!self.load(obj, &ov)) return STALE_VALUE~;
    if (!ov.is_object()) return WRONG_TYPE~;
    if (key == null) return OUT_OF_MEMORY~;
    embed::clear_err(self.rt);
    TVal got;
    if (!builtins::js_get_with_receiver((void*)self.rt.vm, self.rt.heap, (HObject*)ov.get_heapptr(), key, ov, &got)) {
        return self.vm_fault()~;
    }
    return self.root(got);
}

fn void? JsContext.set_key(&self, JsValue obj, HString* key, JsValue value) {
    if (self.rt != null) embed::select_context(self.context);
    TVal ov, vv;
    if (!self.load(obj, &ov)) return STALE_VALUE~;
    if (!ov.is_object()) return WRONG_TYPE~;
    if (key == null) return OUT_OF_MEMORY~;
    if (!self.load(value, &vv)) vv.set_undefined();
    embed::clear_err(self.rt);
    bool ok;
    if (!builtins::js_set_with_receiver((void*)self.rt.vm, self.rt.heap, (HObject*)ov.get_heapptr(), key, vv, ov, &ok)) {
        return self.vm_fault()~;
    }
    if (!ok) {
        embed::set_err(self.rt, embed::BK_ERR_THROW, "Cannot assign to read only property");
        return JS_EXCEPTION~;
    }
}

// Record the heap's pending error on the runtime and pick the fault for it.
fn fault JsContext.vm_fault(&self) {
    if (self.rt != null) embed::select_context(self.context);
    Heap* h = self.rt.heap;
    if (h.uncatchable_throw) {
        embed::finish_interrupt(self.rt);
        embed::set_err(self.rt, embed::BK_ERR_INTERRUPT, "interrupted");
        return INTERRUPTED;
    }
    embed::describe_error(self.rt, &h.error_value);
    h.has_error = false;
    return JS_EXCEPTION;
}

// ============================================================================
// Value access
// ============================================================================

// Broad classification of a value. Never fails: a stale or empty handle
// reports UNDEFINED, matching what reading a missing binding would give.
fn JsType JsContext.type_of(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return JsType.UNDEFINED;
    return (JsType)embed::classify(tv);
}

// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a number
fn double? JsContext.as_number(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_numeric()) return WRONG_TYPE~;
    return tv.get_number_or_fastint();
}

// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a boolean
fn bool? JsContext.as_bool(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_boolean()) return WRONG_TYPE~;
    return tv.get_boolean();
}

// Copy a JS string out as UTF-8 into `allocator`. The engine stores CESU-8, so
// the bytes are transcoded; astral characters come back as 4-byte UTF-8.
//
// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a string
fn String? JsContext.as_string(&self, JsValue v, Allocator allocator = tmem) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_string()) return WRONG_TYPE~;
    return utf8_of((HString*)tv.get_heapptr(), allocator);
}

// Coerce any value to its display string, the way `String(v)` would.
//
// This runs JS (`toString`/`valueOf` may be user code), so it can throw.
//
// Faults: NOT_CREATED, STALE_VALUE, JS_EXCEPTION
fn String? JsContext.to_display_string(&self, JsValue v, Allocator allocator = tmem) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    self.rt.heap.has_error = false;
    HString*? s = vm::vm_to_string(self.rt.vm, &tv);
    if (catch s) {
        if (self.rt.heap.has_error) embed::describe_error(self.rt, &self.rt.heap.error_value);
        return JS_EXCEPTION~;
    }
    return utf8_of(s, allocator);
}

// ============================================================================
// Rooting
// ============================================================================

// Anchor a raw engine value in the registry and hand back a stable handle.
//
// Faults: NOT_CREATED, VALUE_TABLE_FULL
fn JsValue? JsContext.root(&self, TVal tv) {
    if (self.rt == null) return NOT_CREATED~;
    ulong slot = embed::slot_alloc(self.rt, tv);
    if (slot == 0) return VALUE_TABLE_FULL~;
    embed::release_parked_result(self.rt, tv);
    JsValue handle = { .slot = slot };
    if (self.scope_depth > 0) self.scoped.push(handle);
    return handle;
}

// Run `body`, then release every value rooted inside it, so code that reads
// a lot of values (walking an object graph, say) needs no per-value
// `release`. Scopes nest; a value that must outlive its scope is copied out
// with `persist`.
//
//     rt.@scope() {
//         JsValue name = rt.get(user, "name")!;
//         io::printn(rt.as_string(name)!);
//     };
macro void JsContext.@scope(&self; @body()) {
    var mark = self.scoped.len();
    self.scope_depth++;
    defer {
        self.scope_depth--;
        while (self.scoped.len() > mark) self.release(self.scoped.pop()!!);
    }
    @body();
}

// A new root for `v` that no enclosing `@scope` will release. Release it
// yourself.
//
// Faults: NOT_CREATED, STALE_VALUE, VALUE_TABLE_FULL
fn JsValue? JsContext.persist(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    uint depth = self.scope_depth;
    self.scope_depth = 0;
    defer self.scope_depth = depth;
    return self.root(tv);
}

// Drop a value's root. Idempotent; the handle is stale afterwards.
fn void JsContext.release(&self, JsValue v) {
    if (self.rt == null) return;
    embed::slot_release(self.rt, v.slot);
}

fn bool JsContext.load(&self, JsValue v, TVal* out) {
    if (self.rt == null) return false;
    return embed::slot_get(self.rt, v.slot, out);
}

// ============================================================================
// Errors
// ============================================================================

// The value thrown by the most recent failure, or undefined when there was none.
fn JsValue? JsContext.get_exception(&self) {
    if (self.rt == null) return NOT_CREATED~;
    embed::select_context(self.context);
    ulong value = embed::take_exception(self.rt);
    if (value == 0) return VALUE_TABLE_FULL~;
    if (self.scope_depth > 0) self.scoped.push({ value });
    return (JsValue){ value };
}

// Message for the most recent failure, or "" if there was none. Valid until the
// next eval on this runtime.
fn String JsContext.last_error(&self) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return "";
    return (String)embed::err_slice(self.rt);
}

// Line of the most recent failure, 1-based, or 0 when unknown.
fn int JsContext.last_error_line(&self) {
    if (self.rt == null) return 0;
    embed::select_context(self.context);
    return self.rt.err_line;
}

// Column of the most recent failure, 1-based, or 0 when unknown.
fn int JsContext.last_error_col(&self) {
    if (self.rt == null) return 0;
    embed::select_context(self.context);
    return self.rt.err_col;
}

// ============================================================================
// CESU-8 -> UTF-8
// ============================================================================

// The sink is the caller's buffer, passed back through udata, so nothing is
// shared between calls.
fn void utf8_put(char c, void* udata) {
    ((DString*)udata).append_char(c);
}

fn String utf8_of(HString* s, Allocator allocator) {
    if (s == null) return "";
    DString buf = dstring::temp_with_capacity((sz)(s.utf8_len() + 4));
    s.write_utf8(&utf8_put, &buf);
    return buf.copy_str(allocator);
}

// ============================================================================
// Host functions
// ============================================================================

// A value seen from inside a host callback.
//
// Deliberately a different type from `JsValue`: a `JsValue` is a registry slot
// that stays rooted until `release`, while a `JsArg` is scoped to the call and
// dies with it. Keeping them apart means the compiler rejects the mistake that
// would otherwise be a use-after-free -- stashing an argument in a global and
// reading it after the callback returned.
//
// Copyable; wraps the engine's raw value.
struct JsArg {
    TVal tv;
}

// Host callback signature: receives the call context and the `udata` passed to
// `register_fn`. It returns nothing. Produce a result with `ctx.ret*` and a
// failure with `ctx.throw_error`; see `JsCtx.throw_error` for why throwing does
// not unwind.
alias JsHostFn = fn void(JsCtx ctx, void* udata);

// The error constructor a host callback can throw. Ordinals match the engine's
// builtins::HOST_ERR_* codes, asserted below rather than spelled twice.
enum JsErrorKind : int {
    ERROR,
    TYPE,
    RANGE,
    REFERENCE,
    SYNTAX,
}

$assert JsErrorKind.ERROR.ordinal     == builtins::HOST_ERR_ERROR;
$assert JsErrorKind.TYPE.ordinal      == builtins::HOST_ERR_TYPE;
$assert JsErrorKind.RANGE.ordinal     == builtins::HOST_ERR_RANGE;
$assert JsErrorKind.REFERENCE.ordinal == builtins::HOST_ERR_REFERENCE;
$assert JsErrorKind.SYNTAX.ordinal    == builtins::HOST_ERR_SYNTAX;

// One host call in progress. Valid only for the body of the callback; do not
// store it. A thin wrapper over the VM's staged call context: `ctx.arg(0)` is a
// scope read, with no marshalling or handle table.
struct JsCtx {
    builtins::BuiltinContext* ctx;
}

// Registration record: the C3 callback plus the host's udata. Allocated
// through the heap allocator so it lives exactly as long as the heap does.
struct HostReg {
    embed::HostPayload lifetime;
    JsHostFn handler;
    void*    udata;
}

// Adapts the engine's `fn void(BuiltinContext*, void*)` shape. The handler
// travels in HostReg alongside the host's udata.
fn void host_trampoline(builtins::BuiltinContext* bctx, void* udata) {
    if (udata == null) return;
    HostReg* reg = (HostReg*)udata;
    if (reg.handler == null) return;
    if (bctx.heap.realms == null) {
        reg.handler({ .ctx = bctx }, reg.udata);
        if (bctx.heap.uncatchable_throw) builtins::host_throw(bctx, bctx.heap.error_value);
        return;
    }
    embed::Runtime* runtime = embed::ctx_runtime(bctx);
    embed::Ctx* context = embed::realm_context(runtime, bctx.heap.realm);
    embed::Ctx* previous = runtime.active;
    heap::Realm* previous_realm = bctx.heap.realm;
    void* previous_call = context.bctx;
    embed::select_context(context);
    context.bctx = bctx;
    defer {
        context.bctx = previous_call;
        embed::select_context(previous);
        bctx.heap.enter_realm(previous_realm);
    }
    reg.handler({ .ctx = bctx }, reg.udata);
    if (bctx.heap.uncatchable_throw) builtins::host_throw(bctx, bctx.heap.error_value);
}

// Bind `handler` as a global function named `name`.
//
// `arity` becomes the function's `.length` and is advisory: JS may call with
// any number of arguments, so the callback must consult `ctx.argc()`.
// `constructable` decides whether `new name()` works. Without it `new` throws a
// TypeError, as for ECMA-262 built-in functions, which are constructors only
// when specified: https://tc39.es/ecma262/#sec-built-in-function-objects
//
// `udata` is stored verbatim and handed back on every call. The engine never
// dereferences or frees it, so the caller must keep it alive for the runtime's
// lifetime. Registrations last until runtime destruction and cannot be removed.
//
// Faults: NOT_CREATED, OUT_OF_MEMORY, REGISTER_FAILED
fn void? JsContext.register_fn(&self, String name, JsHostFn handler, void* udata = null,
                               int arity = 0, bool constructable = false) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    if (handler == null) return REGISTER_FAILED~;
    Heap* hp = self.rt.heap;

    void* raw = hp.alloc_func(hp.heap_udata, HostReg::size);
    if (raw == null) return OUT_OF_MEMORY~;
    HostReg* reg = (HostReg*)raw;
    reg.handler = handler;
    reg.udata = udata;

    // The trampoline is this module's, so a C3 callback keeps its JsCtx
    // signature; everything around it -- interning, claiming a host-fn slot,
    // building the function object, declaring the global -- is the core's.
    int rc = embed::install_fn(self.rt, (char[])name, (void*)&host_trampoline, raw,
                               arity, constructable);
    if (rc != embed::BK_OK) {
        return fault_of(rc)~;
    }
}

// Install `handler` as method `name` on `obj` rather than as a global, which
// is how a host builds a namespace object (`os.getenv`, `fs.read`).
//
// Faults: NOT_CREATED, STALE_VALUE, WRONG_TYPE, OUT_OF_MEMORY, REGISTER_FAILED
fn void? JsContext.register_method(&self, JsValue obj, String name, JsHostFn handler,
                                   void* udata = null, int arity = 0) {
    if (self.rt != null) embed::select_context(self.context);
    if (self.rt == null) return NOT_CREATED~;
    if (handler == null) return REGISTER_FAILED~;
    TVal ov;
    if (!self.load(obj, &ov)) return STALE_VALUE~;
    if (!ov.is_object()) return WRONG_TYPE~;
    Heap* hp = self.rt.heap;
    void* raw = hp.alloc_func(hp.heap_udata, HostReg::size);
    if (raw == null) return OUT_OF_MEMORY~;
    HostReg* reg = (HostReg*)raw;
    reg.handler = handler;
    reg.udata = udata;
    TVal fv;
    int rc = embed::make_fn_value(self.rt, (char[])name, (void*)&host_trampoline, raw, arity, false, &fv);
    if (rc != embed::BK_OK) {
        return fault_of(rc)~;
    }
    HString* k = hp.str_intern((char[])name);
    if (k == null || !((HObject*)ov.get_heapptr()).put_prop(k, fv, hobject::PROP_FLAGS_WC, hp)) {
        return REGISTER_FAILED~;
    }
}

// --- reading the call -------------------------------------------------------

// Number of arguments actually passed, which may differ from the declared
// arity in either direction.
fn uint JsCtx.argc(self) => builtins::host_argc(self.ctx);

// Argument `i`, or undefined when `i >= argc()`. No arity check needed.
fn JsArg JsCtx.arg(self, uint i) {
    JsArg a = { .tv = builtins::host_arg(self.ctx, i) };
    return a;
}

// The receiver, as the call path bound it: a sloppy callee's undefined or
// primitive receiver has already become the global object or a wrapper, while
// a strict one stays as passed.
fn JsArg JsCtx.this_value(self) {
    JsArg a = { .tv = builtins::host_this(self.ctx) };
    return a;
}

// `new.target`, or undefined on a plain call.
fn JsArg JsCtx.new_target(self) {
    JsArg a = { .tv = builtins::host_new_target(self.ctx) };
    return a;
}

// True when invoked through `new` or `super()`.
fn bool JsCtx.is_construct(self) => builtins::host_is_construct(self.ctx);

// Root an argument in the registry so it survives the callback, typically a
// JS callback the host will invoke later. Release it when done.
//
// Faults: VALUE_TABLE_FULL
fn JsValue? JsCtx.persist(self, JsArg v) {
    embed::Runtime* rt = embed::ctx_runtime((void*)self.ctx);
    ulong slot = embed::slot_alloc(rt, v.tv);
    if (slot == 0) return VALUE_TABLE_FULL~;
    JsValue handle = { .slot = slot };
    return handle;
}

// A rooted value seen as an argument of this call, for passing it back to JS
// (`ret`, `call`). Undefined when the handle is stale.
fn JsArg JsCtx.value(self, JsValue v) {
    embed::Runtime* rt = embed::ctx_runtime((void*)self.ctx);
    JsArg a;
    if (!embed::slot_get(rt, v.slot, &a.tv)) a.tv.set_undefined();
    return a;
}

// --- inspecting a JsArg -----------------------------------------------------

fn JsType JsArg.type_of(self) => (JsType)embed::classify(self.tv);

fn bool JsArg.is_undefined(self) => self.tv.is_undefined();
fn bool JsArg.is_number(self)    => self.tv.is_numeric();
fn bool JsArg.is_string(self)    => self.tv.is_string();

// Faults: WRONG_TYPE : if the argument is not a number
fn double? JsArg.as_number(self) {
    if (!self.tv.is_numeric()) return WRONG_TYPE~;
    return self.tv.get_number_or_fastint();
}

// Faults: WRONG_TYPE : if the argument is not a boolean
fn bool? JsArg.as_bool(self) {
    if (!self.tv.is_boolean()) return WRONG_TYPE~;
    return self.tv.get_boolean();
}

// Copy the string out as UTF-8; see `JsContext.as_string`. The default `tmem`
// allocator suits reads that finish within the callback.
//
// Faults: WRONG_TYPE : if the argument is not a string
fn String? JsArg.as_string(self, Allocator allocator = tmem) {
    if (!self.tv.is_string()) return WRONG_TYPE~;
    return utf8_of((HString*)self.tv.get_heapptr(), allocator);
}

// --- producing a result -----------------------------------------------------

// Build a JS string from UTF-8 bytes. Interned like every other engine string,
// so `===` against an equal literal is true.
fn JsArg JsCtx.string(self, String s) {
    JsArg a = { .tv = builtins::host_new_string(self.ctx, (char[])s) };
    return a;
}

fn JsArg JsCtx.number(self, double d) {
    JsArg a;
    a.tv.set_number(d);
    return a;
}

fn JsArg JsCtx.boolean(self, bool b) {
    JsArg a;
    a.tv.set_boolean(b);
    return a;
}

fn JsArg JsCtx.null_value(self) {
    JsArg a;
    a.tv.set_null();
    return a;
}

fn JsArg JsCtx.undefined_value(self) {
    JsArg a;
    a.tv.set_undefined();
    return a;
}

// Set the return value. Calling it more than once keeps the last value; not
// calling it at all returns undefined.
fn void JsCtx.ret(self, JsArg v) => builtins::host_return(self.ctx, v.tv);

fn void JsCtx.ret_number(self, double d) => self.ret(self.number(d));
fn void JsCtx.ret_bool(self, bool b) => self.ret(self.boolean(b));
fn void JsCtx.ret_string(self, String s) => self.ret(self.string(s));
fn void JsCtx.ret_null(self) => self.ret(self.null_value());

// --- object properties ------------------------------------------------------
//
// Enough to populate `this` in a constructor and to read a field off an
// options object, which is what host callbacks actually need. Anything richer
// is better expressed in JS and reached through `call`.

// Read `obj.key`, or undefined when it is absent.
//
// Own and inherited data properties only: this does not run getters, so it
// cannot re-enter the VM and cannot throw.
//
// Faults: WRONG_TYPE : if `obj` is not an object
fn JsArg? JsCtx.get_prop(self, JsArg obj, String key) {
    if (!obj.tv.is_object() || self.ctx == null || self.ctx.heap == null) return WRONG_TYPE~;
    HObject* o = (HObject*)obj.tv.get_heapptr();
    HString* k = self.ctx.heap.str_intern((char[])key);
    if (o == null || k == null) return WRONG_TYPE~;
    JsArg out = { .tv = {} };
    out.tv.set_undefined();
    TVal? v = o.get_prop(k, self.ctx.heap);
    if (try got = v) out.tv = got;
    return out;
}

// Write `obj.key = value` as a plain writable/enumerable/configurable data
// property. Returns false when the write did not happen.
//
// Faults: WRONG_TYPE : if `obj` is not an object
fn bool? JsCtx.set_prop(self, JsArg obj, String key, JsArg value) {
    if (!obj.tv.is_object() || self.ctx == null || self.ctx.heap == null) return WRONG_TYPE~;
    HObject* o = (HObject*)obj.tv.get_heapptr();
    HString* k = self.ctx.heap.str_intern((char[])key);
    if (o == null || k == null) return WRONG_TYPE~;
    return o.put_prop(k, value.tv, hobject::PROP_FLAGS_WEC, self.ctx.heap);
}

// --- failing ----------------------------------------------------------------

// Throw a fresh error of `kind` carrying `msg`. Does not unwind: it records the
// exception and returns, so the callback keeps running. `return` right after it
// unless more work is intended. If `ret` is also called, the throw wins.
fn void JsCtx.throw_error(self, JsErrorKind kind, String msg) {
    builtins::host_throw_error(self.ctx, kind.ordinal, (char[])msg);
}

// Throw `v` as-is, so a non-Error value round-trips to JS unchanged. Same
// non-unwinding contract as `throw_error`.
fn void JsCtx.throw_value(self, JsArg v) => builtins::host_throw(self.ctx, v.tv);

// --- calling back into JS ---------------------------------------------------

// Call a JS function from inside the callback, so host functions can compose
// (timers, event emitters). Uses the entry point builtins use for user
// callbacks, so the re-entry guard turns a runaway host -> JS -> host chain into
// a RangeError rather than a faulted stack.
//
// If the callee throws, the exception is transferred onto this call and this
// reports JS_EXCEPTION. Returning immediately propagates it to JS. A `ret` after
// a failed `call` is ignored, so the exception is not swallowed.
//
// Faults: NOT_CALLABLE, JS_EXCEPTION
fn JsArg? JsCtx.call(self, JsArg func, JsArg[] args = {}, JsArg this_value = {}) {
    if (func.type_of() != JsType.FUNCTION) return NOT_CALLABLE~;

    // host_call wants a contiguous TVal array. Copying rather than casting the
    // JsArg slice keeps the single-field layout an implementation detail.
    TVal[MAX_INLINE_CALL_ARGS] inline_args;
    TVal* argv = null;
    TVal[] spill;
    if (args.len > 0) {
        if (args.len <= MAX_INLINE_CALL_ARGS) {
            argv = &inline_args[0];
        } else {
            spill = mem::new_array(TVal, args.len);
            argv = spill.ptr;
        }
        for (usz i = 0; i < args.len; i++) argv[i] = args[i].tv;
    }
    defer if (spill.len > 0) free(spill);

    bool ok = false;
    TVal r = builtins::host_call(self.ctx, func.tv, argv, (uint)args.len, this_value.tv, &ok);
    if (!ok) return JS_EXCEPTION~;
    JsArg out = { .tv = r };
    return out;
}

// Argument counts up to this are staged on the C3 stack; beyond it `call`
// allocates. Sized to cover every realistic callback signature.
const usz MAX_INLINE_CALL_ARGS = 8;

// The callback runs synchronously on the engine thread. It may inspect and
// retain values, but must not execute JS or replace the hook. Promise identity
// is stable while a retained promise keeps the object alive. Both handles are
// borrowed for the callback; use persist() to keep either beyond its return.
alias PromiseRejectionHandler = fn void(JsRuntime* runtime, ulong promise_id,
    JsValue promise, JsValue reason, bool handled, void* udata);

fn void JsRuntime.set_promise_rejection_tracker(&self, PromiseRejectionHandler handler, void* udata = null) {
    self.rejection_handler = handler;
    self.rejection_udata = udata;
    if (self.rt == null) return;
    self.rt.heap.promise_rejection_fn = handler != null ? &native_rejection_tracker : null;
    self.rt.heap.promise_rejection_udata = self;
}

fn void native_rejection_tracker(void* heap_raw, TVal promise, TVal reason, bool handled, void* udata) {
    JsRuntime* runtime = (JsRuntime*)udata;
    ulong p = embed::slot_alloc(runtime.rt, promise);
    if (p == 0) return;
    defer embed::slot_release(runtime.rt, p);
    ulong r = embed::slot_alloc(runtime.rt, reason);
    if (r == 0) return;
    defer embed::slot_release(runtime.rt, r);
    runtime.rejection_handler(runtime, (ulong)promise.get_heapptr(), { p }, { r }, handled,
        runtime.rejection_udata);
}

// Install poll handlers on the engine thread. They must not re-enter JS.
alias InterruptHandler = heap::BkInterruptFn;

fn void JsRuntime.set_interrupt(&self, InterruptHandler handler, void* opaque = null) {
    if (self.rt == null) return;
    self.rt.heap.capi_interrupt_fn = (void*)handler;
    self.rt.heap.capi_interrupt_opaque = opaque;
    self.rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
}

// A watchdog may call this concurrently with execution. Keep the runtime alive
// and stationary until the watchdog has stopped; all other operations belong
// to the engine thread. Requests stay latched until clear_interrupt().
fn void JsRuntime.request_interrupt(&self) {
    if (self.rt == null) return;
    mem::@atomic_store(self.rt.heap.interrupt_requested, 1u);
    // A thread blocked in Atomics.wait sleeps on a condition, not on this flag.
    agent::wake_interrupt(self.rt.heap);
}

fn void JsRuntime.clear_interrupt(&self) {
    if (self.rt != null) mem::@atomic_store(self.rt.heap.interrupt_requested, 0u);
}
