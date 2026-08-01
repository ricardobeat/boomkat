/// Idiomatic C3 embedding API for the JavaScript engine.
///
/// This is the *native* binding: it links the engine's C3 modules directly and
/// speaks C3 optionals, so there is no C ABI round-trip, no integer handles,
/// and no manual status-code checking. Use `include/jse.h` + `src/capi.c3`
/// instead when the host is not C3 (see README.md).
///
/// Usage sketch:
///
///     JsRuntime rt;
///     rt.open()!;
///     defer rt.close();
///     JsValue v = rt.eval("40 + 2")!;
///     io::printfn("%s", v.to_display_string(&rt)!);
///
/// Lifetime rules, which are the whole reason this module exists:
///
///   * A `JsValue` is only valid while its `JsRuntime` is open, and only until
///     `release` is called on it.
///   * Every `JsValue` handed back by `eval` is GC-rooted. Values are anchored
///     as properties of one registry object that is itself a GC root, so the
///     mark phase reaches them transitively and `put_prop` does the increfs.
///     Nothing else in the engine is safe to hold across an `eval`: the VM
///     resets and may *relocate* the value stack on every execution, so a raw
///     `TVal` captured from a previous run is a dangling reference.
///   * `release` is optional for short programs (`close` frees everything), but
///     required in a loop: the registry holds at most `MAX_ROOTED_VALUES` live
///     values and then reports `JsError.VALUE_TABLE_FULL`.
module jse;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import std::io;

// ============================================================================
// Errors
// ============================================================================

/// Every failure this module can report. These are C3 faults, so callers use
/// `!`, `!!`, `if (catch e = ...)` -- the same shape as the rest of the stdlib.
faultdef
    NOT_OPEN,             // operation on a runtime that was never opened
    ALREADY_OPEN,         // second open() on the same runtime
    RUNTIME_EXISTS,       // another JsRuntime is already open in this process
    OUT_OF_MEMORY,
    SYNTAX_ERROR,         // source failed to compile; see last_error()
    JS_EXCEPTION,         // script threw; see last_error()
    INTERNAL_ERROR,       // VM fault with no JS error attached
    WRONG_TYPE,           // as_number() on a string, etc.
    STALE_VALUE,          // value was released, or belongs to a closed runtime
    VALUE_TABLE_FULL;     // more than MAX_ROOTED_VALUES live values

/// The JS type of a value, as `typeof` would broadly classify it.
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

const usz MAX_ROOTED_VALUES = 1024;
const usz ERROR_BUF = 512;

// ============================================================================
// Values
// ============================================================================

/// A GC-rooted reference to a JS value. Copyable; copies alias the same slot,
/// so release exactly once.
struct JsValue {
    uint slot;   // key into the runtime's registry object; 0 == empty/released
}

/// The value returned for a statement with no completion value (`var x = 1;`).
const JsValue UNDEFINED_VALUE = { .slot = 0 };

fn bool JsValue.is_empty(self) => self.slot == 0;

// ============================================================================
// Runtime
// ============================================================================

/// Owns a heap, a VM, and the root registry. Declare one, `open` it, `close` it.
///
/// Exactly one may be open per process: the engine keeps process-global state
/// (the compiler's error buffer and the active-heap pointer), so a second
/// runtime would corrupt the first. `open` reports RUNTIME_EXISTS rather than
/// letting that happen. Not thread-safe.
struct JsRuntime {
    Heap*    heap;
    Vm*      vm;
    HObject* registry;      // GC root anchoring every live JsValue
    uint     next_slot;
    usz      live;
    char[ERROR_BUF] errbuf;
    usz      errlen;
}

// Process-wide open-runtime guard. See the struct doc for why.
tlocal JsRuntime* active_runtime = null;

/// Create the heap and VM.
///
/// Faults: ALREADY_OPEN, RUNTIME_EXISTS, OUT_OF_MEMORY
fn void? JsRuntime.open(&self) {
    if (self.heap != null) return ALREADY_OPEN~;
    if (active_runtime != null) return RUNTIME_EXISTS~;

    Heap*? hpr = heap::create(null, null, null, null, null);
    if (catch hpr) return OUT_OF_MEMORY~;
    Heap* hp = hpr;

    Vm*? vmr = vm::vm_create(hp);
    if (catch vmr) { hp.destroy(); return OUT_OF_MEMORY~; }

    // One ordinary object, registered once as a GC root (of the 64 available).
    // Rooted values live in it as normal properties: refcounting and marking
    // then come for free from put_prop/delete_prop and the mark phase.
    HObject*? regr = hp.alloc_object(hobject::ObjClass.OBJECT);
    if (catch regr) { vm::vm_destroy(vmr); hp.destroy(); return OUT_OF_MEMORY~; }
    hp.register_gc_root((types::HeapHeader*)regr);

    self.heap = hp;
    self.vm = vmr;
    self.registry = regr;
    self.next_slot = 1;
    self.live = 0;
    self.errlen = 0;
    self.errbuf[0] = 0;
    active_runtime = self;
}

/// Tear down the heap and VM. Safe to call on a runtime that was never opened,
/// and safe to call twice. Every JsValue from this runtime becomes stale.
fn void JsRuntime.close(&self) {
    if (self.heap == null) return;
    Heap* hp = self.heap;
    // Order matters: vm_destroy frees through heap.free_func.
    vm::vm_destroy(self.vm);
    hp.destroy();
    self.heap = null;
    self.vm = null;
    self.registry = null;
    self.live = 0;
    if (active_runtime == self) active_runtime = null;
}

fn bool JsRuntime.is_open(&self) => self.heap != null;

// ============================================================================
// Eval
// ============================================================================

/// Compile and run `source`, returning its completion value.
///
/// Uses eval semantics, so a trailing expression is the result: `"40 + 2"` yields
/// 42 rather than undefined (a plain script body only produces a value through an
/// explicit `return`).
///
/// Faults: NOT_OPEN, SYNTAX_ERROR, JS_EXCEPTION, INTERNAL_ERROR, VALUE_TABLE_FULL
fn JsValue? JsRuntime.eval(&self, String source) {
    if (self.heap == null) return NOT_OPEN~;
    self.errlen = 0;
    self.errbuf[0] = 0;

    Lexer lex = lexer::lexer_init((char[])source, self.heap);
    lex.skip_hashbang();
    CompiledFunction*? fnr = compiler::compile_eval(&lex, self.heap);
    if (catch fnr) {
        // The compiler's message buffer is process-global and is overwritten by
        // the next failing compile, so copy it out now. A few failure paths
        // leave it empty; never surface a blank message.
        char* msg = compiler::last_error_msg();
        usz n = 0;
        while (msg[n] != 0 && n < ERROR_BUF - 1) n++;
        if (n == 0) {
            self.set_error("SyntaxError");
        } else {
            self.set_error((String)msg[:n]);
        }
        lex.free_arena();
        return SYNTAX_ERROR~;
    }

    self.heap.has_error = false;
    TVal? result = self.vm.execute(fnr);
    self.heap.drain_microtasks((void*)self.vm);
    lex.free_arena();

    if (catch result) {
        if (self.heap.has_error) {
            self.describe_thrown(&self.heap.error_value);
            return JS_EXCEPTION~;
        }
        self.set_error("internal VM error");
        return INTERNAL_ERROR~;
    }

    return self.root(result);
}

/// Run `source` for its side effects, discarding the completion value.
fn void? JsRuntime.exec(&self, String source) {
    JsValue v = self.eval(source)!;
    self.release(v);
}

/// Run pending promise reactions. `eval` already drains after each script; call
/// this only when a host callback has queued more work outside an eval.
fn void JsRuntime.drain_microtasks(&self) {
    if (self.heap == null) return;
    self.heap.drain_microtasks((void*)self.vm);
}

// ============================================================================
// Value access
// ============================================================================

/// Broad classification of a value. Never fails: a stale or empty handle
/// reports UNDEFINED, matching what reading a missing binding would give.
fn JsType JsRuntime.type_of(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return JsType.UNDEFINED;
    if (tv.is_undefined()) return JsType.UNDEFINED;
    if (tv.is_null()) return JsType.NULL;
    if (tv.is_boolean()) return JsType.BOOLEAN;
    if (tv.is_numeric()) return JsType.NUMBER;
    if (tv.is_string()) return JsType.STRING;
    if (tv.is_object()) {
        HObject* obj = (HObject*)tv.get_heapptr();
        if (obj != null && obj.flags.callable) return JsType.FUNCTION;
        return JsType.OBJECT;
    }
    return JsType.OTHER;
}

/// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a number
fn double? JsRuntime.as_number(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_numeric()) return WRONG_TYPE~;
    return tv.get_number_or_fastint();
}

/// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a boolean
fn bool? JsRuntime.as_bool(&self, JsValue v) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_boolean()) return WRONG_TYPE~;
    return tv.get_boolean();
}

/// Copy a JS string out as UTF-8 into `allocator`.
///
/// The engine stores strings as CESU-8 (surrogate pairs kept separate), so the
/// bytes are transcoded here; astral characters come back as proper 4-byte UTF-8
/// rather than mojibake.
///
/// Faults: STALE_VALUE, WRONG_TYPE : if the value is not a string
fn String? JsRuntime.as_string(&self, JsValue v, Allocator allocator = tmem) {
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    if (!tv.is_string()) return WRONG_TYPE~;
    return utf8_of((HString*)tv.get_heapptr(), allocator);
}

/// Coerce any value to its display string, the way `String(v)` would.
///
/// This runs JS (`toString`/`valueOf` may be user code), so it can throw.
///
/// Faults: STALE_VALUE, JS_EXCEPTION
fn String? JsRuntime.to_display_string(&self, JsValue v, Allocator allocator = tmem) {
    if (self.heap == null) return NOT_OPEN~;
    TVal tv;
    if (!self.load(v, &tv)) return STALE_VALUE~;
    self.heap.has_error = false;
    HString*? s = vm::vm_to_string(self.vm, &tv);
    if (catch s) {
        if (self.heap.has_error) self.describe_thrown(&self.heap.error_value);
        return JS_EXCEPTION~;
    }
    return utf8_of(s, allocator);
}

// ============================================================================
// Rooting
// ============================================================================

/// Drop a value's root. Idempotent; the handle is stale afterwards.
fn void JsRuntime.release(&self, JsValue v) {
    if (self.heap == null || v.slot == 0) return;
    HString* key = self.heap.int_to_hstring((long)v.slot);
    if (key == null) return;
    if (self.registry.delete_prop(key) && self.live > 0) self.live--;
}

/// Anchor a raw engine value in the registry and hand back a stable handle.
fn JsValue? JsRuntime.root(&self, TVal tv) {
    // Immediates (undefined, null, small ints, ...) carry no heap pointer, so
    // there is nothing for the collector to lose; storing them still costs a
    // slot, which is what keeps type_of/as_number uniform across all values.
    if (self.live >= MAX_ROOTED_VALUES) return VALUE_TABLE_FULL~;
    uint id = self.next_slot;
    self.next_slot++;
    if (self.next_slot == 0) self.next_slot = 1;
    HString* key = self.heap.int_to_hstring((long)id);
    if (key == null) return OUT_OF_MEMORY~;
    if (!self.registry.put_prop(key, tv, hobject::PROP_FLAGS_WEC)) return OUT_OF_MEMORY~;
    self.live++;
    JsValue handle = { .slot = id };
    return handle;
}

fn bool JsRuntime.load(&self, JsValue v, TVal* out) {
    if (self.heap == null || v.slot == 0) return false;
    HString* key = self.heap.int_to_hstring((long)v.slot);
    if (key == null) return false;
    TVal? tv = self.registry.get_prop(key);
    if (catch tv) return false;
    *out = tv;
    return true;
}

// ============================================================================
// Errors
// ============================================================================

/// Message for the most recent failure, or "" if there was none. Valid until
/// the next eval on this runtime.
fn String JsRuntime.last_error(&self) {
    return (String)self.errbuf[:self.errlen];
}

fn void JsRuntime.set_error(&self, String msg) {
    usz n = msg.len < ERROR_BUF - 1 ? msg.len : ERROR_BUF - 1;
    for (usz i = 0; i < n; i++) self.errbuf[i] = msg[i];
    self.errbuf[n] = 0;
    self.errlen = n;
}

/// Record a thrown value's message without re-entering the VM: this runs while
/// the VM is already unwinding, and a user `toString`/`get message` could throw
/// again from there.
fn void JsRuntime.describe_thrown(&self, TVal* thrown) {
    if (thrown.is_string()) {
        HString* s = (HString*)thrown.get_heapptr();
        self.set_error((String)s.get_data());
        return;
    }
    if (thrown.is_object()) {
        HObject* obj = (HObject*)thrown.get_heapptr();
        HString* message_key = self.heap.strs[heap::BuiltinStr.MESSAGE];
        if (try m = obj.get_prop(message_key)) {
            if (m.is_string()) {
                self.set_error((String)((HString*)m.get_heapptr()).get_data());
                return;
            }
        }
    }
    self.set_error("uncaught exception");
}

// ============================================================================
// CESU-8 -> UTF-8
// ============================================================================

// write_cesu8_as_utf8 takes a bare `fn void(char)` with no user-data pointer,
// so the sink has to be module state. Single-runtime and single-threaded by
// contract, and thread-local for defence in depth.
tlocal DString* utf8_sink @local;

fn void utf8_put(char c) @local {
    utf8_sink.append_char(c);
}

fn String utf8_of(HString* s, Allocator allocator) @local {
    if (s == null) return "";
    DString buf = dstring::temp_with_capacity(s.get_data().len + 4);
    utf8_sink = &buf;
    hstring::write_cesu8_as_utf8(s.get_data(), &utf8_put);
    utf8_sink = null;
    return buf.copy_str(allocator);
}
