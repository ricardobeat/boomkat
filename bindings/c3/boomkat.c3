// Idiomatic C3 embedding API for the JavaScript engine.
//
// This is the *native* binding. It sits directly on `boomkat::embed`, the
// shared embedding core, so there is no C ABI round-trip: values move as the
// engine's own `TVal`, and failures arrive as C3 faults rather than status
// codes. Use `include/boomkat.h` + `src/capi.c3` instead when the host is not
// C3 (see README.md).
//
// Usage sketch:
//
//     JsRuntime rt;
//     rt.open()!;
//     defer rt.close();
//     JsValue v = rt.eval("40 + 2")!;
//     io::printfn("%s", rt.to_display_string(v)!);
//
// Lifetime rules, which are the whole reason this module exists:
//
//   * A `JsValue` is only valid while its `JsRuntime` is open, and only until
//     `release` is called on it.
//   * Every `JsValue` handed back by `eval` is GC-rooted: the core's registry
//     is walked directly by the mark phase, so a rooted value stays reachable
//     for as long as the host holds it. Nothing else in the engine is safe to
//     hold across an `eval` -- the VM resets and may *relocate* the value
//     stack on every execution, so a raw `TVal` captured from a previous run
//     is a dangling reference.
//   * `release` is optional for short programs (`close` frees everything), but
//     required in a loop, since an unreleased value holds its slot until
//     `close`. The registry grows on demand; only when 65535 values are live
//     at once does rooting report `VALUE_TABLE_FULL`.
module boomkat;

import boomkat::builtins;
import boomkat::embed;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import std::io;

// ============================================================================
// Errors
// ============================================================================

// Every failure this module can report. These are C3 faults, so callers use
// `!`, `!!`, `if (catch e = ...)` -- the same shape as the rest of the stdlib.
faultdef
    NOT_OPEN,             // operation on a runtime that was never opened
    ALREADY_OPEN,         // second open() on the same runtime
    OUT_OF_MEMORY,
    SYNTAX_ERROR,         // source failed to compile; see last_error()
    JS_EXCEPTION,         // script threw; see last_error()
    INTERNAL_ERROR,       // VM fault with no JS error attached
    INTERRUPTED,          // aborted by the interrupt handler
    WRONG_TYPE,           // as_number() on a string, etc.
    STALE_VALUE,          // value was released, or belongs to a closed runtime
    VALUE_TABLE_FULL,     // 65535 values already live
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
    OTHER,        // symbol, bigint, and other non-classified tags
}

$assert JsType.UNDEFINED.ordinal == embed::BK_TYPE_UNDEFINED;
$assert JsType.NULL.ordinal      == embed::BK_TYPE_NULL;
$assert JsType.BOOLEAN.ordinal   == embed::BK_TYPE_BOOLEAN;
$assert JsType.NUMBER.ordinal    == embed::BK_TYPE_NUMBER;
$assert JsType.STRING.ordinal    == embed::BK_TYPE_STRING;
$assert JsType.OBJECT.ordinal    == embed::BK_TYPE_OBJECT;
$assert JsType.FUNCTION.ordinal  == embed::BK_TYPE_FUNCTION;
$assert JsType.OTHER.ordinal     == embed::BK_TYPE_OTHER;

// Map a core status onto this module's faults. Used by every entry point that
// forwards to the core, so the two vocabularies are related in one place.
macro fault_of(int code) {
    switch (code) {
        case embed::BK_ERR_NOMEM:     return OUT_OF_MEMORY;
        case embed::BK_ERR_SYNTAX:    return SYNTAX_ERROR;
        case embed::BK_ERR_THROW:     return JS_EXCEPTION;
        case embed::BK_ERR_INTERRUPT: return INTERRUPTED;
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
// so release exactly once.
//
// The handle encoding, the generation bookkeeping that retires a released
// slot, and the registry the mark phase walks all live in `boomkat::embed`,
// shared with the C ABI.
struct JsValue {
    ulong slot;   // 0 == empty/released
}

// The value returned for a statement with no completion value (`var x = 1;`).
const JsValue UNDEFINED_VALUE = { .slot = 0 };

fn bool JsValue.is_empty(self) => self.slot == 0;

// ============================================================================
// Runtime
// ============================================================================

// Owns a heap, a VM, and the root registry. Declare one, `open` it, `close` it.
//
// Several may be open at once, each with its own globals, objects and interned
// strings. Values do not cross between them: a `JsValue` names a slot in the
// runtime that produced it, so passing one to another runtime reports
// `STALE_VALUE`.
//
// A runtime must be driven from one thread at a time. The engine has no
// locking, so two threads inside one runtime corrupt it; two threads each
// driving their own runtime share nothing and are fine.
struct JsRuntime {
    embed::Runtime* rt;
}

// Create the heap and VM.
//
// Faults: ALREADY_OPEN, OUT_OF_MEMORY
fn void? JsRuntime.open(&self) {
    if (self.rt != null) return ALREADY_OPEN~;
    embed::Runtime* r = embed::create();
    if (r == null) return OUT_OF_MEMORY~;
    self.rt = r;
}

// Tear down the heap and VM. Safe to call on a runtime that was never opened,
// and safe to call twice. Every JsValue from this runtime becomes stale.
fn void JsRuntime.close(&self) {
    if (self.rt == null) return;
    embed::destroy(self.rt);
    self.rt = null;
}

fn bool JsRuntime.is_open(&self) => self.rt != null;

// ============================================================================
// Eval
// ============================================================================

// Compile and run `source`, returning its completion value.
//
// Uses eval semantics, so a trailing expression is the result: `"40 + 2"` yields
// 42 rather than undefined (a plain script body only produces a value through an
// explicit `return`).
//
// Faults: NOT_OPEN, SYNTAX_ERROR, JS_EXCEPTION, INTERNAL_ERROR, INTERRUPTED,
// VALUE_TABLE_FULL
fn JsValue? JsRuntime.eval(&self, String source, String name = "<eval>") {
    if (self.rt == null) return NOT_OPEN~;
    TVal tv;
    int rc = embed::eval_source(self.rt, (char[])source, (char[])name, &tv);
    if (rc != embed::BK_OK) return fault_of(rc)~;
    return self.root(tv);
}

// Run `source` for its side effects, discarding the completion value.
fn void? JsRuntime.exec(&self, String source, String name = "<eval>") {
    JsValue v = self.eval(source, name)!;
    self.release(v);
}

// Run pending promise reactions. `eval` already drains after each script; call
// this only when a host callback has queued more work outside an eval.
//
// Faults: INTERRUPTED
fn void? JsRuntime.drain_microtasks(&self) {
    if (self.rt == null) return;
    int rc = embed::drain_microtasks(self.rt);
    if (rc != embed::BK_OK) return fault_of(rc)~;
}

// ============================================================================
// Value access
// ============================================================================

// Broad classification of a value. Never fails: a stale or empty handle
// reports UNDEFINED, matching what reading a missing binding would give.
fn JsType JsRuntime.type_of(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return JsType.UNDEFINED;
    return (JsType)embed::classify(tv);
}

// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a number
fn double? JsRuntime.as_number(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_numeric()) return WRONG_TYPE~;
    return tv.get_number_or_fastint();
}

// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a boolean
fn bool? JsRuntime.as_bool(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_boolean()) return WRONG_TYPE~;
    return tv.get_boolean();
}

// Copy a JS string out as UTF-8 into `allocator`.
//
// The engine stores strings as CESU-8 (surrogate pairs kept separate), so the
// bytes are transcoded here; astral characters come back as proper 4-byte UTF-8
// rather than mojibake.
//
// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a string
fn String? JsRuntime.as_string(&self, JsValue v, Allocator allocator = tmem) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_string()) return WRONG_TYPE~;
    return utf8_of((HString*)tv.get_heapptr(), allocator);
}

// Coerce any value to its display string, the way `String(v)` would.
//
// This runs JS (`toString`/`valueOf` may be user code), so it can throw.
//
// Faults: NOT_OPEN, STALE_VALUE, JS_EXCEPTION
fn String? JsRuntime.to_display_string(&self, JsValue v, Allocator allocator = tmem) {
    if (self.rt == null) return NOT_OPEN~;
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
// Faults: NOT_OPEN, VALUE_TABLE_FULL
fn JsValue? JsRuntime.root(&self, TVal tv) {
    if (self.rt == null) return NOT_OPEN~;
    ulong slot = embed::slot_alloc(self.rt, tv);
    if (slot == 0) return VALUE_TABLE_FULL~;
    JsValue handle = { .slot = slot };
    return handle;
}

// Drop a value's root. Idempotent; the handle is stale afterwards.
fn void JsRuntime.release(&self, JsValue v) {
    if (self.rt == null) return;
    embed::slot_release(self.rt, v.slot);
}

fn bool JsRuntime.load(&self, JsValue v, TVal* out) {
    if (self.rt == null) return false;
    return embed::slot_get(self.rt, v.slot, out);
}

// ============================================================================
// Errors
// ============================================================================

// Message for the most recent failure, or "" if there was none. Valid until
// the next eval on this runtime.
fn String JsRuntime.last_error(&self) {
    if (self.rt == null) return "";
    return (String)embed::err_slice(self.rt);
}

// Line of the most recent failure, 1-based, or 0 when unknown.
fn int JsRuntime.last_error_line(&self) => self.rt == null ? 0 : self.rt.err_line;

// Column of the most recent failure, 1-based, or 0 when unknown.
fn int JsRuntime.last_error_col(&self) => self.rt == null ? 0 : self.rt.err_col;

// ============================================================================
// CESU-8 -> UTF-8
// ============================================================================

// The sink state is the caller's buffer, reached through the udata pointer
// write_cesu8_as_utf8 passes back, so nothing here is shared between runtimes
// or between calls.
fn void utf8_put(char c, void* udata) {
    ((DString*)udata).append_char(c);
}

fn String utf8_of(HString* s, Allocator allocator) {
    if (s == null) return "";
    DString buf = dstring::temp_with_capacity(s.get_data().len + 4);
    hstring::write_cesu8_as_utf8(s.get_data(), &utf8_put, &buf);
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
// Copyable and cheap; it wraps the engine's raw value directly.
struct JsArg {
    TVal tv;
}

// What a host callback is: it receives the call context and the `udata`
// pointer that was handed to `register_fn`.
//
// It returns nothing. A result is produced with `ctx.ret*`, a failure with
// `ctx.throw_error`, exactly as the engine's own builtins do -- see the note
// on `JsCtx.throw_error` for why throwing does not unwind.
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
// store it.
//
// It is a thin wrapper over the context the VM already staged, so `ctx.arg(0)`
// costs a scope read and nothing else -- no marshalling, no handle table.
struct JsCtx {
    builtins::BuiltinContext* ctx;
}

// Registration record: the C3 callback plus the host's udata. Allocated
// through the heap allocator so it lives exactly as long as the heap does.
struct HostReg {
    JsHostFn handler;
    void*    udata;
}

// The engine calls a `fn void(BuiltinContext*, void*)`, so this adapts the
// shape. The C3 callback travels as udata alongside the host's own, which is
// why HostReg exists rather than casting the callback straight into the table.
fn void host_trampoline(builtins::BuiltinContext* bctx, void* udata) {
    if (udata == null) return;
    HostReg* reg = (HostReg*)udata;
    if (reg.handler == null) return;
    JsCtx ctx = { .ctx = bctx };
    reg.handler(ctx, reg.udata);
}

// Bind `handler` as a global function named `name`.
//
// `arity` becomes the function's `.length` and is advisory: JS may call with
// any number of arguments, so the callback must consult `ctx.argc()`.
// `constructable` decides whether `new name()` works; without it `new` throws
// a TypeError, matching ES2015 section 10.3 where built-ins are constructors
// only when specified.
//
// `udata` is stored verbatim and handed back on every call. The engine never
// dereferences or frees it, so keeping the pointed-to storage alive for the
// runtime's lifetime is the caller's job. Registrations last until `close` and
// cannot be removed.
//
// Faults: NOT_OPEN, OUT_OF_MEMORY, REGISTER_FAILED
fn void? JsRuntime.register_fn(&self, String name, JsHostFn handler, void* udata = null,
                               int arity = 0, bool constructable = false) {
    if (self.rt == null) return NOT_OPEN~;
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
        hp.free_func(hp.heap_udata, raw);
        return fault_of(rc)~;
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

// The receiver. In this strict-only engine an undefined receiver stays
// undefined; it is never coerced to the global object.
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

// --- inspecting a JsArg -----------------------------------------------------

fn JsType JsArg.type_of(self) {
    if (self.tv.is_undefined()) return JsType.UNDEFINED;
    if (self.tv.is_null()) return JsType.NULL;
    if (self.tv.is_boolean()) return JsType.BOOLEAN;
    if (self.tv.is_numeric()) return JsType.NUMBER;
    if (self.tv.is_string()) return JsType.STRING;
    if (self.tv.is_object()) {
        HObject* obj = (HObject*)self.tv.get_heapptr();
        if (obj != null && obj.flags.callable) return JsType.FUNCTION;
        return JsType.OBJECT;
    }
    return JsType.OTHER;
}

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

// Copy the string out as UTF-8. The engine stores CESU-8, so this transcodes;
// astral characters come back as proper 4-byte UTF-8.
//
// The default `tmem` allocator suits the common case -- read the string, use
// it, return -- since a callback runs inside one temp scope.
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

// Throw a fresh error of `kind` carrying `msg`.
//
// This does NOT unwind. It records the exception and returns normally, so the
// callback keeps running and must return under its own control -- mirroring
// how the engine's builtins report failure, which is what every dispatch site
// is written against. `return` immediately after it unless you mean to keep
// working. If `ret` is also called, the throw wins.
fn void JsCtx.throw_error(self, JsErrorKind kind, String msg) {
    builtins::host_throw_error(self.ctx, kind.ordinal, (char[])msg);
}

// Throw `v` as-is, so a non-Error value round-trips to JS unchanged. Same
// non-unwinding contract as `throw_error`.
fn void JsCtx.throw_value(self, JsArg v) => builtins::host_throw(self.ctx, v.tv);

// --- calling back into JS ---------------------------------------------------

// Call a JS function from inside the callback.
//
// This is what makes host functions composable rather than leaf-only: without
// it there is no `setTimeout`, no event emitter, no async I/O. It routes
// through the same entry point builtins use for user callbacks, so the
// re-entry guard bounds it -- a runaway host -> JS -> host chain gets a
// RangeError rather than a faulted stack.
//
// If the callee throws, the exception is transferred onto this call and this
// reports JS_EXCEPTION. Returning immediately then propagates it to JS. The
// pending throw is already recorded, so a `ret` after a failed `call` is
// ignored rather than silently swallowing the exception.
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
