module duktape::capi;

import duktape::builtins;
import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::hobject;
import duktape::env;
import duktape::hstring;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;

// ============================================================================
// Status codes (must mirror include/jse.h)
// ============================================================================

const int JSE_OK            = 0;
const int JSE_ERR_NOMEM     = -1;
const int JSE_ERR_SYNTAX    = -2;
const int JSE_ERR_THROW     = -3;
const int JSE_ERR_INTERNAL  = -4;
const int JSE_ERR_INVALID   = -5;
const int JSE_ERR_TYPE      = -6;
const int JSE_ERR_FULL      = -7;

const int JSE_TYPE_UNDEFINED = 0;
const int JSE_TYPE_NULL      = 1;
const int JSE_TYPE_BOOLEAN   = 2;
const int JSE_TYPE_NUMBER    = 3;
const int JSE_TYPE_STRING    = 4;
const int JSE_TYPE_OBJECT    = 5;
const int JSE_TYPE_FUNCTION  = 6;
const int JSE_TYPE_OTHER     = 7;

const usz ERRBUF = 512;

// ============================================================================
// Value handle encoding
// ============================================================================
//
// A handle is one 32-bit word:
//
//    31          30..19            18..0
//   [scope]  [ generation ]     [ index+1 ]
//
// Bit 31 is SCOPE_HANDLE_BIT, reserved for per-call scope handles, so a global
// slot id must never set it -- the encoding below cannot, since index and
// generation together occupy only bits 0..30.
//
// Index is stored biased by one, which keeps 0 reserved as "no value" and lets
// jse_call/jse_eval keep treating a zero out-param as failure.
//
// 19 index bits cap the registry at 524287 simultaneously live handles. That is
// a real ceiling reported as JSE_ERR_FULL, not a silent wrap: the array itself
// grows on demand and never reserves that much.
//
// 12 generation bits retire a slot on free. A stale handle to a freed slot
// mismatches the slot's current generation and is rejected, so it can never
// resolve to whatever value later occupies that index. On wrap (4096 alloc/free
// cycles on the SAME index while a stale handle to it is still held) a stale
// handle could alias again; the `used` flag catches every stale handle whose
// slot is merely free, which is the reachable case.
const uint SLOT_INDEX_BITS = 19;
const uint SLOT_INDEX_MASK = (1u << SLOT_INDEX_BITS) - 1;   // 524287
const uint SLOT_GEN_BITS   = 12;
const uint SLOT_GEN_MASK   = (1u << SLOT_GEN_BITS) - 1;     // 4095
const uint SLOT_FREE_END   = 0xFFFF_FFFF;
const uint SLOT_INITIAL_CAP = 64;

/// One registry entry. `used` distinguishes a live slot from one on the free
/// list, so the common stale-handle case is caught without relying on the
/// generation having advanced.
struct SlotEntry {
    TVal v;
    uint gen;
    uint next_free;
    bool used;
}

// ============================================================================
// Runtime
// ============================================================================

// The engine keeps process-global state (compiler error buffer, hobject active
// heap), so exactly one runtime may exist at a time. Enforced, not documented.
struct Runtime {
    Heap*    heap;
    Vm*      vm;
    // Host-held values. A dedicated growable array rather than an HObject: the
    // object registry was bounded by the ushort prop_count and burned a shape
    // slot per delete, and it hashed an integer key into a string on every
    // access. The GC walks this array directly (see Heap.capi_roots).
    SlotEntry* slots;
    uint     slot_cap;
    uint     slot_count;     // high-water index, not the live count
    uint     free_head;
    uint     live;
    char[ERRBUF] errmsg;
    int      errcode;
    /// Innermost host-call context, or null outside a host callback. Lets the
    /// readers resolve a scope handle without the host threading the context
    /// through every call.
    void*    active_ctx;
}

Runtime* g_rt = null;

// Set once the engine's compile-time-populated tables are known good; see
// ensure_engine_init. Never cleared, since the tables outlive any runtime.
bool g_engine_ready = false;

fn void set_err(Runtime* rt, int code, char[] msg) {
    rt.errcode = code;
    usz n = msg.len < ERRBUF - 1 ? msg.len : ERRBUF - 1;
    for (usz i = 0; i < n; i++) rt.errmsg[i] = msg[i];
    rt.errmsg[n] = 0;
}

fn void clear_err(Runtime* rt) {
    rt.errcode = JSE_OK;
    rt.errmsg[0] = 0;
}

// The engine's one @init function (builtins::init_builtin_dispatch_table)
// normally runs from the C3 runtime's startup walk of the Mach-O/ELF init
// sections. That walk is only reliable when c3c also drives the final link:
// when this archive is linked by a foreign toolchain the C3 startup can bind
// to the wrong image header and either fault or silently skip the section, so
// the dispatch table stays all-null and the first builtin call misbehaves.
// Observed concretely with the Zig linker, which emits a second, bogus
// __mh_execute_header in __DATA,__bss that the walk latches onto.
//
// Running the initializer explicitly here removes the ABI's dependence on that
// walk entirely. It is idempotent -- it just re-stores compile-time constants
// into a fixed-size table -- so double execution with the startup path is
// harmless, and this is the only place a host can reach the engine first.
fn void ensure_engine_init() {
    if (g_engine_ready) return;
    g_engine_ready = true;
    builtins::init_builtin_dispatch_table();
}

fn int jse_open(void** out_rt) @export("jse_open") {
    if (out_rt == null) return JSE_ERR_INVALID;
    *out_rt = null;
    if (g_rt != null) return JSE_ERR_INVALID;   // single-runtime rule
    ensure_engine_init();

    Heap*? hpr = heap::create(null, null, null, null, null);
    if (catch hpr) return JSE_ERR_NOMEM;
    Heap* hp = hpr;

    Vm*? vr = vm::vm_create(hp);
    if (catch vr) { hp.destroy(); return JSE_ERR_NOMEM; }
    Vm* v = vr;

    void* raw = hp.alloc_func(hp.heap_udata, Runtime::size);
    if (raw == null) { vm::vm_destroy(v); hp.destroy(); return JSE_ERR_NOMEM; }
    Runtime* rt = (Runtime*)raw;
    rt.heap = hp; rt.vm = v;
    rt.slots = null; rt.slot_cap = 0; rt.slot_count = 0;
    rt.free_head = SLOT_FREE_END; rt.live = 0;
    rt.active_ctx = null;
    clear_err(rt);

    // The slot array is not an HObject, so the mark phase cannot reach it
    // transitively. Hand the heap a direct view of it instead; mark_roots walks
    // every live entry from there.
    hp.capi_roots = (void*)rt;
    hp.capi_mark = (heap::CapiMarkFn)&mark_slots;

    g_rt = rt;
    *out_rt = (void*)rt;
    return JSE_OK;
}

/// GC root walk for the value registry. Every live host handle keeps its value
/// reachable for as long as the host holds it; freed slots hold undefined and
/// mark nothing.
fn void mark_slots(void* rtp) {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    if (rt.slots == null) return;
    for (uint i = 0; i < rt.slot_count; i++) {
        if (!rt.slots[i].used) continue;
        rt.heap.mark_tval(&rt.slots[i].v);
    }
}

fn void jse_close(void* rtp) @export("jse_close") {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    Heap* hp = rt.heap;
    // Stop the GC walking the registry before any of it is torn down.
    hp.capi_roots = null;
    hp.capi_mark = null;
    if (rt.slots != null) {
        for (uint i = 0; i < rt.slot_count; i++) {
            if (rt.slots[i].used && rt.slots[i].v.is_heap_allocated()) {
                hp.decref_tval(&rt.slots[i].v);
            }
        }
        hp.free_func(hp.heap_udata, (void*)rt.slots);
        rt.slots = null;
    }
    // Teardown order is load-bearing: vm_destroy uses heap.free_func.
    vm::vm_destroy(rt.vm);
    hp.free_func(hp.heap_udata, (void*)rt);
    hp.destroy();
    if (g_rt == rt) g_rt = null;
}

// ============================================================================
// Slot registry
// ============================================================================

/// Grow the slot array. Returns false on allocation failure, leaving the
/// registry usable at its current size.
fn bool slot_grow(Runtime* rt) {
    uint new_cap = rt.slot_cap == 0 ? SLOT_INITIAL_CAP : rt.slot_cap * 2;
    if (new_cap > SLOT_INDEX_MASK) new_cap = SLOT_INDEX_MASK;
    if (new_cap <= rt.slot_cap) return false;
    usz bytes = (usz)new_cap * SlotEntry::size;
    void* raw = rt.heap.realloc_func(rt.heap.heap_udata, (void*)rt.slots, bytes);
    if (raw == null) return false;
    usz old_bytes = (usz)rt.slot_cap * SlotEntry::size;
    mem::clear((char*)raw + old_bytes, (sz)(bytes - old_bytes));
    rt.slots = (SlotEntry*)raw;
    rt.slot_cap = new_cap;
    return true;
}

/// Register a value and return its handle, or 0 if none could be issued.
///
/// Returning 0 is the ONLY failure signal, and every caller turns it into an
/// explicit error: a handle is never handed back for a value that was not
/// stored.
fn uint slot_alloc(Runtime* rt, TVal v) {
    uint idx;
    if (rt.free_head != SLOT_FREE_END) {
        idx = rt.free_head;
        rt.free_head = rt.slots[idx].next_free;
    } else {
        // slot_count indexes from 0 and the handle stores index+1, so the last
        // usable index is SLOT_INDEX_MASK - 1.
        if (rt.slot_count >= SLOT_INDEX_MASK) return 0;
        if (rt.slot_count == rt.slot_cap && !slot_grow(rt)) return 0;
        idx = rt.slot_count;
        rt.slot_count++;
        rt.slots[idx].gen = 1;
    }
    if (v.is_heap_allocated()) {
        void* ptr = v.get_heapptr();
        if (ptr != null) ((types::HeapHeader*)ptr).incref();
    }
    rt.slots[idx].v = v;
    rt.slots[idx].used = true;
    rt.live++;
    return ((rt.slots[idx].gen & SLOT_GEN_MASK) << SLOT_INDEX_BITS) | (idx + 1);
}

/// Resolve a handle to its entry, or null if the handle is stale, freed, out of
/// range, or a scope handle. This is the single validation point.
fn SlotEntry* slot_entry(Runtime* rt, uint id) {
    if (rt == null || id == 0) return null;
    if ((id & SCOPE_HANDLE_BIT) != 0) return null;
    uint biased = id & SLOT_INDEX_MASK;
    if (biased == 0) return null;
    uint idx = biased - 1;
    if (idx >= rt.slot_count) return null;
    SlotEntry* e = &rt.slots[idx];
    if (!e.used) return null;
    if (((id >> SLOT_INDEX_BITS) & SLOT_GEN_MASK) != (e.gen & SLOT_GEN_MASK)) return null;
    return e;
}

/// Resolve any handle: a scope handle against the innermost host call, a
/// global slot id against the registry. Readers go through this so a host can
/// pass jse_arg() straight into jse_get_number and friends.
fn bool any_get(Runtime* rt, uint id, TVal* out) {
    if ((id & SCOPE_HANDLE_BIT) != 0) {
        if (rt == null || rt.active_ctx == null) return false;
        return resolve_handle(rt, rt.active_ctx, id, out);
    }
    if (rt == null) return false;
    return slot_get(rt, id, out);
}

fn bool slot_get(Runtime* rt, uint id, TVal* out) {
    SlotEntry* e = slot_entry(rt, id);
    if (e == null) return false;
    *out = e.v;
    return true;
}

fn void jse_value_free(void* rtp, uint id) @export("jse_value_free") {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    // Scope handles are owned by the call that issued them, so freeing one is
    // ignored rather than treated as an error.
    SlotEntry* e = slot_entry(rt, id);
    if (e == null) return;

    if (e.v.is_heap_allocated()) rt.heap.decref_tval(&e.v);
    e.v.set_undefined();
    e.used = false;
    // Retire the slot: every handle still naming this index is now stale and
    // slot_entry will reject it, so a later occupant is never resolved through
    // an old handle.
    e.gen = (e.gen + 1) & SLOT_GEN_MASK;
    if (e.gen == 0) e.gen = 1;
    uint idx = (id & SLOT_INDEX_MASK) - 1;
    e.next_free = rt.free_head;
    rt.free_head = idx;
    if (rt.live > 0) rt.live--;
}

// ============================================================================
// Eval
// ============================================================================

fn int jse_eval(void* rtp, char* src, usz len, uint* out_val) @export("jse_eval") {
    if (rtp == null || src == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);
    if (out_val != null) *out_val = 0;

    Lexer lex = lexer::lexer_init(src[:len], rt.heap);
    lex.skip_hashbang();
    // compile_eval, not compile: a top-level *script* only yields a value via an
    // explicit RET, so `40+2` would come back undefined. eval-form code carries a
    // completion value, which is what an embedder expects from jse_eval.
    CompiledFunction*? fr = compiler::compile_eval(&lex, rt.heap);
    if (catch fr) {
        // Copy immediately: the compiler error buffer is process-global and
        // is clobbered by the next failing compile.
        char* m = compiler::last_error_msg();
        usz n = 0;
        while (m[n] != 0 && n < ERRBUF - 1) n++;
        // Some compiler failure paths return without populating the global
        // buffer (e.g. "var = = ="). Never hand the host an empty message.
        if (n == 0) {
            set_err(rt, JSE_ERR_SYNTAX, "SyntaxError");
        } else {
            set_err(rt, JSE_ERR_SYNTAX, m[:n]);
        }
        lex.free_arena();
        return JSE_ERR_SYNTAX;
    }
    CompiledFunction* f = fr;

    rt.heap.has_error = false;
    TVal? res = rt.vm.execute(f);
    lex.free_arena();

    if (catch res) {
        if (rt.heap.has_error) {
            describe_error(rt, &rt.heap.error_value);
            return JSE_ERR_THROW;
        }
        set_err(rt, JSE_ERR_INTERNAL, "internal VM error");
        return JSE_ERR_INTERNAL;
    }

    if (out_val != null) {
        TVal v = res;
        // slot_alloc returns 0 only on genuine exhaustion or OOM, so report it
        // for every value kind. Letting an undefined result through as handle 0
        // would turn a failed registration into an ordinary undefined -- a
        // silent wrong answer rather than an error.
        uint id = slot_alloc(rt, v);
        if (id == 0) {
            set_err(rt, JSE_ERR_FULL, "value slot table full");
            return JSE_ERR_FULL;
        }
        *out_val = id;
    }
    return JSE_OK;
}

/// Read property `key` off `o` or its prototype chain, returning it only if it
/// holds a string. Needed for the `name`/`message` pair on a thrown Error: an
/// engine-thrown TypeError owns only `message`, and `name` lives on
/// Error.prototype.
///
/// This walks the chain by hand instead of calling get_prop_proto because that
/// routes a Proxy anywhere on the chain back through the trap machinery and
/// into the VM. describe_error runs on the unwind path, where re-entering the
/// VM could throw again; a proxy link simply ends the search instead.
fn HString* str_prop(HObject* o, HString* key) {
    HObject* cur = o;
    uint depth = 0;
    while (cur != null && depth < 64) {
        if (cur.flags.exotic_proxyobj) return null;
        int idx = cur.find_prop_idx((void*)key);
        if (idx >= 0) {
            // An accessor slot holds a getter/setter pair, not a value. Reading
            // it would mean calling into the VM, so treat it as absent.
            if (cur.get_prop_flags((uint)idx).is_accessor) return null;
            TVal got = cur.prop_values()[idx];
            if (got.is_string()) return (HString*)got.get_heapptr();
            return null;
        }
        cur = cur.prototype;
        depth++;
    }
    return null;
}

/// Format a thrown value into the runtime error buffer without re-entering
/// the VM (a user toString could throw again on the unwind path). Every JS
/// value reaches a useful message: `throw 42` reports "42", not a placeholder.
fn void describe_error(Runtime* rt, TVal* ev) {
    if (ev.is_string()) {
        HString* s = (HString*)ev.get_heapptr();
        set_err(rt, JSE_ERR_THROW, s.get_data());
        return;
    }
    if (ev.is_undefined()) { set_err(rt, JSE_ERR_THROW, "undefined"); return; }
    if (ev.is_null())      { set_err(rt, JSE_ERR_THROW, "null"); return; }
    if (ev.is_boolean())   {
        set_err(rt, JSE_ERR_THROW, ev.get_boolean() ? "true" : "false");
        return;
    }
    if (ev.is_numeric()) {
        // Same shortest-roundtrip formatter the engine uses for Number->String,
        // and it is a pure buffer write: no VM re-entry, no allocation.
        char[64] nbuf;
        usz n = builtins::json_number_to_string(ev.get_number_or_fastint(), &nbuf[0], 64);
        set_err(rt, JSE_ERR_THROW, nbuf[:n]);
        return;
    }
    if (ev.is_object()) {
        HObject* o = (HObject*)ev.get_heapptr();
        HString* msg  = str_prop(o, rt.heap.strs[heap::BuiltinStr.MESSAGE]);
        HString* name = str_prop(o, rt.heap.strs[heap::BuiltinStr.NAME]);

        // "TypeError: x is not a function" -- name comes off the prototype, so
        // this reads like the message a JS host would print.
        if (name != null && msg != null && msg.blen != 0) {
            char[ERRBUF] buf;
            usz pos = 0;
            char[] np = name.get_data();
            char[] mp = msg.get_data();
            for (usz i = 0; i < np.len && pos < ERRBUF - 3; i++) buf[pos++] = np[i];
            buf[pos++] = ':';
            buf[pos++] = ' ';
            for (usz i = 0; i < mp.len && pos < ERRBUF - 1; i++) buf[pos++] = mp[i];
            set_err(rt, JSE_ERR_THROW, buf[:pos]);
            return;
        }
        if (msg != null && msg.blen != 0) { set_err(rt, JSE_ERR_THROW, msg.get_data()); return; }
        if (name != null && name.blen != 0) { set_err(rt, JSE_ERR_THROW, name.get_data()); return; }
        set_err(rt, JSE_ERR_THROW, "uncaught exception (object)");
        return;
    }
    set_err(rt, JSE_ERR_THROW, "uncaught exception");
}

// ============================================================================
// Readers
// ============================================================================

fn int jse_type_of(void* rtp, uint id) @export("jse_type_of") {
    if (rtp == null) return JSE_TYPE_OTHER;
    Runtime* rt = (Runtime*)rtp;
    TVal v;
    if (!any_get(rt, id, &v)) return JSE_TYPE_UNDEFINED;
    if (v.is_undefined()) return JSE_TYPE_UNDEFINED;
    if (v.is_null()) return JSE_TYPE_NULL;
    if (v.is_boolean()) return JSE_TYPE_BOOLEAN;
    if (v.is_numeric()) return JSE_TYPE_NUMBER;
    // A Symbol is a STRING-tagged HString with is_symbol set, so is_string()
    // alone would misreport it as a string and let jse_get_string hand back
    // the symbol's raw internal bytes.
    if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null && s.is_symbol()) return JSE_TYPE_OTHER;
        return JSE_TYPE_STRING;
    }
    if (v.is_object()) {
        HObject* o = (HObject*)v.get_heapptr();
        if (o != null && o.flags.callable) return JSE_TYPE_FUNCTION;
        return JSE_TYPE_OBJECT;
    }
    return JSE_TYPE_OTHER;
}

// A reader that fails must leave a message behind: jse_last_error is documented
// as describing "the most recent failure", and a host that logs it on a bad
// status would otherwise print an empty string (or, worse, a stale message from
// an unrelated earlier call).
fn int reader_fail(Runtime* rt, int code, String msg) {
    set_err(rt, code, msg);
    return code;
}

fn int jse_get_number(void* rtp_in, uint id, double* out) @export("jse_get_number") {
    if (out == null) return JSE_ERR_INVALID;
    Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;
    if (rt == null) return JSE_ERR_INVALID;
    clear_err(rt);
    TVal v;
    if (!any_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_numeric()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a number");
    *out = v.get_number_or_fastint();
    return JSE_OK;
}

fn int jse_get_bool(void* rtp_in, uint id, int* out) @export("jse_get_bool") {
    if (out == null) return JSE_ERR_INVALID;
    Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;
    if (rt == null) return JSE_ERR_INVALID;
    clear_err(rt);
    TVal v;
    if (!any_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_boolean()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a boolean");
    *out = v.get_boolean() ? 1 : 0;
    return JSE_OK;
}

// UTF-8 conversion sink. write_cesu8_as_utf8's callback takes no udata, so a
// module-global sink is the only option; single-runtime + no threads make it safe.
char* g_sink;
usz   g_sink_len;
usz   g_sink_cap;

fn void sink_put(char c) {
    if (g_sink_len + 1 < g_sink_cap) { g_sink[g_sink_len] = c; }
    g_sink_len++;
}

/// Copy a JS string out as NUL-terminated UTF-8. Two-call protocol: pass
/// buf==null to learn the required size (excluding NUL).
fn int jse_get_string(void* rtp_in, uint id, char* buf, usz cap, usz* out_len) @export("jse_get_string") {
    Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;
    if (rt == null) return JSE_ERR_INVALID;
    clear_err(rt);
    TVal v;
    if (!any_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_string()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a string");
    HString* s = (HString*)v.get_heapptr();
    // Symbols share the string tag but carry no meaningful text; copying their
    // bytes out would yield invalid UTF-8. JS forbids implicit conversion too.
    if (s != null && s.is_symbol()) return JSE_ERR_TYPE;

    g_sink = buf; g_sink_len = 0; g_sink_cap = (buf == null) ? 0 : cap;
    hstring::write_cesu8_as_utf8(s.get_data(), &sink_put);
    usz need = g_sink_len;
    if (out_len != null) *out_len = need;
    if (buf == null) return JSE_OK;
    if (need + 1 > cap) return reader_fail(rt, JSE_ERR_FULL, "buffer too small for string");
    buf[need] = 0;
    return JSE_OK;
}

// ============================================================================
// Errors / microtasks
// ============================================================================

fn char* jse_last_error(void* rtp) @export("jse_last_error") {
    if (rtp == null) return null;
    Runtime* rt = (Runtime*)rtp;
    return &rt.errmsg[0];
}

fn int jse_last_error_code(void* rtp) @export("jse_last_error_code") {
    if (rtp == null) return JSE_ERR_INVALID;
    return ((Runtime*)rtp).errcode;
}

fn void jse_drain_microtasks(void* rtp) @export("jse_drain_microtasks") {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    rt.heap.drain_microtasks((void*)rt.vm);
}

fn char* jse_version() @export("jse_version") {
    return "0.1.0";
}

// ============================================================================
// Host functions
//
// A host callback is a C function the engine calls when JS invokes the
// corresponding function value. The engine side (builtins::dispatch_host)
// stages a per-call scope; everything here is the opaque-handle layer over it.
//
// Handles inside a callback are SCOPE handles: they carry the high bit and are
// valid only for the duration of that call. jse_value_persist copies one into
// the global slot registry when the host needs it to outlive the callback.
// ============================================================================

const uint SCOPE_HANDLE_BIT = 0x8000_0000;

/// The C-facing callback signature: (ctx, udata).
alias JseHostFn = fn void(void*, void*);

/// Encode a scope handle for argument/this/new_target index `idx`.
///
/// Scope handles are distinguished from global slot ids by the high bit, so
/// jse_type_of and the readers accept both kinds without separate entry points.
fn uint scope_handle(uint idx) @inline {
    return SCOPE_HANDLE_BIT | idx;
}

/// Resolve any handle to a TVal. Global slot ids go to the slot registry;
/// scope handles read the innermost host call scope through the context.
fn bool resolve_handle(Runtime* rt, void* ctxp, uint id, TVal* out) {
    if ((id & SCOPE_HANDLE_BIT) != 0) {
        if (ctxp == null) return false;
        builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
        uint idx = id & ~SCOPE_HANDLE_BIT;
        if (idx == heap::HOST_SCOPE_THIS)       { *out = builtins::host_this(ctx); return true; }
        if (idx == heap::HOST_SCOPE_NEW_TARGET) { *out = builtins::host_new_target(ctx); return true; }
        *out = builtins::host_arg(ctx, idx - heap::HOST_SCOPE_ARG0);
        return true;
    }
    return slot_get(rt, id, out);
}

/// Trampoline: every registered host function enters the engine through this
/// one C3 function, which forwards to the C callback with the context as an
/// opaque pointer. The udata the engine stored is a HostReg* holding the real
/// C function pointer and the host's own udata.
struct HostReg {
    void* cfn;
    void* udata;
}

fn void host_trampoline(builtins::BuiltinContext* ctx, void* udata) {
    if (udata == null) return;
    HostReg* reg = (HostReg*)udata;
    if (reg.cfn == null) return;
    JseHostFn cfn = (JseHostFn)reg.cfn;
    // Publish this call's context so the readers can resolve scope handles
    // without the host threading it through. Saved and restored rather than
    // cleared: a host -> JS -> host chain must leave the outer call's context
    // in place when the inner one returns.
    void* prev = null;
    if (g_rt != null) { prev = g_rt.active_ctx; g_rt.active_ctx = (void*)ctx; }
    cfn((void*)ctx, reg.udata);
    if (g_rt != null) { g_rt.active_ctx = prev; }
}

/// Register `cfn` as a global function named `name`.
///
/// Returns JSE_OK, or JSE_ERR_INVALID / JSE_ERR_NOMEM. The binding is created
/// on the global environment, so JS reaches it by bare name.
fn int jse_register_fn(void* rtp, char* name, usz name_len, void* cfn, void* udata,
                       int arity, int constructable) @export("jse_register_fn") {
    if (rtp == null || name == null || cfn == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);

    HString* nm = rt.heap.str_intern(name[:name_len]);
    if (nm == null) { set_err(rt, JSE_ERR_NOMEM, "could not intern function name"); return JSE_ERR_NOMEM; }

    // The registration record outlives the call, so it is heap-allocated and
    // owned by the runtime; the host function table keeps the only pointer.
    void* raw = rt.heap.alloc_func(rt.heap.heap_udata, HostReg::size);
    if (raw == null) { set_err(rt, JSE_ERR_NOMEM, "out of memory"); return JSE_ERR_NOMEM; }
    HostReg* reg = (HostReg*)raw;
    reg.cfn = cfn;
    reg.udata = udata;

    long slot = rt.heap.register_host_fn((void*)&host_trampoline, (void*)reg, (void*)nm,
                                         arity, constructable != 0);
    if (slot < 0) {
        rt.heap.free_func(rt.heap.heap_udata, raw);
        set_err(rt, JSE_ERR_NOMEM, "host function table full");
        return JSE_ERR_NOMEM;
    }

    HObject*? fo = builtins::make_host_function(rt.heap, (uint)slot);
    if (catch fo) { set_err(rt, JSE_ERR_NOMEM, "could not create function object"); return JSE_ERR_NOMEM; }
    TVal fv;
    fv.set_object(fo);
    if (!env::env_declare(rt.vm.global_env, (void*)nm, fv)) {
        set_err(rt, JSE_ERR_INTERNAL, "could not bind function name");
        return JSE_ERR_INTERNAL;
    }
    return JSE_OK;
}

// --- inside a callback ------------------------------------------------------

fn uint jse_argc(void* ctxp) @export("jse_argc") {
    if (ctxp == null) return 0;
    return builtins::host_argc((builtins::BuiltinContext*)ctxp);
}

/// Handle to argument `i`. Out-of-range yields a handle to undefined, matching
/// JS semantics and sparing every host an arity check.
fn uint jse_arg(void* ctxp, uint i) @export("jse_arg") {
    return scope_handle(heap::HOST_SCOPE_ARG0 + i);
}

fn uint jse_this(void* ctxp) @export("jse_this") {
    return scope_handle(heap::HOST_SCOPE_THIS);
}

fn uint jse_new_target(void* ctxp) @export("jse_new_target") {
    return scope_handle(heap::HOST_SCOPE_NEW_TARGET);
}

fn int jse_is_construct(void* ctxp) @export("jse_is_construct") {
    if (ctxp == null) return 0;
    return builtins::host_is_construct((builtins::BuiltinContext*)ctxp) ? 1 : 0;
}

/// Set the callback's return value from a handle.
fn void jse_return(void* ctxp, uint id) @export("jse_return") {
    if (ctxp == null || g_rt == null) return;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    TVal v;
    if (!resolve_handle(g_rt, ctxp, id, &v)) return;
    builtins::host_return(ctx, v);
}

fn void jse_return_number(void* ctxp, double d) @export("jse_return_number") {
    if (ctxp == null) return;
    TVal v;
    v.set_number(d);
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

fn void jse_return_bool(void* ctxp, int b) @export("jse_return_bool") {
    if (ctxp == null) return;
    TVal v;
    v.set_boolean(b != 0);
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

fn void jse_return_null(void* ctxp) @export("jse_return_null") {
    if (ctxp == null) return;
    TVal v;
    v.set_null();
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

/// Set the return value to a fresh JS string built from UTF-8 bytes.
fn void jse_return_string(void* ctxp, char* utf8, usz len) @export("jse_return_string") {
    if (ctxp == null || utf8 == null) return;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    builtins::host_return(ctx, builtins::host_new_string(ctx, utf8[:len]));
}

/// Throw a fresh Error of `kind` with `msg`. Does not unwind: the callback
/// must still return normally, and the throw beats any return value set.
fn void jse_throw_error(void* ctxp, int kind, char* msg) @export("jse_throw_error") {
    if (ctxp == null || msg == null) return;
    usz n = 0;
    while (msg[n] != 0) n++;
    builtins::host_throw_error((builtins::BuiltinContext*)ctxp, kind, msg[:n]);
}

/// Throw an arbitrary value by handle.
fn void jse_throw(void* ctxp, uint id) @export("jse_throw") {
    if (ctxp == null || g_rt == null) return;
    TVal v;
    if (!resolve_handle(g_rt, ctxp, id, &v)) return;
    builtins::host_throw((builtins::BuiltinContext*)ctxp, v);
}

/// Promote a scope handle to a runtime-owned global handle the host may keep
/// past the callback. The caller then owns it and must jse_value_free it.
fn uint jse_value_persist(void* ctxp, uint id) @export("jse_value_persist") {
    if (g_rt == null) return 0;
    TVal v;
    if (!resolve_handle(g_rt, ctxp, id, &v)) return 0;
    return slot_alloc(g_rt, v);
}

/// Call a JS function from host code.
///
/// `argv` is an array of `argc` handles. On success stores a scope-independent
/// global handle in *out_val (caller owns it) and returns JSE_OK. On an
/// exception in the callee the throw is staged on the context, so the host
/// should return promptly; the status is JSE_ERR_THROW.
fn int jse_call(void* ctxp, uint func_id, uint* argv, uint argc, uint this_id,
                uint* out_val) @export("jse_call") {
    if (ctxp == null || g_rt == null) return JSE_ERR_INVALID;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    Runtime* rt = g_rt;
    if (out_val != null) *out_val = 0;

    TVal fv;
    if (!resolve_handle(rt, ctxp, func_id, &fv)) return JSE_ERR_INVALID;
    TVal tv;
    if (this_id == 0) { tv.set_undefined(); } else if (!resolve_handle(rt, ctxp, this_id, &tv)) { tv.set_undefined(); }

    // Bounded stack array: the engine's own call paths cap staged arguments
    // the same way, and a host needing more can build an array in JS.
    TVal[16] args;
    uint n = argc > 16 ? 16 : argc;
    for (uint i = 0; i < n; i++) {
        TVal a;
        if (argv == null || !resolve_handle(rt, ctxp, argv[i], &a)) a.set_undefined();
        args[i] = a;
    }

    bool ok = false;
    TVal res = builtins::host_call(ctx, fv, &args[0], n, tv, &ok);
    if (!ok) return JSE_ERR_THROW;
    if (out_val != null) {
        // Report exhaustion for every value kind, undefined included: handle 0
        // reads back as undefined, so returning it on a failed registration
        // would be a silent wrong answer rather than an error.
        uint id = slot_alloc(rt, res);
        if (id == 0) {
            set_err(rt, JSE_ERR_FULL, "value slot table full");
            return JSE_ERR_FULL;
        }
        *out_val = id;
    }
    return JSE_OK;
}
