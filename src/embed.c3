// Shared embedding core.
//
// This module holds the machinery every embedding face needs: the GC-rooted
// value registry, the error buffer and its no-re-entry formatter, the CESU-8
// to UTF-8 sink, and the host-function trampoline. It has no exported symbols
// and defines no ABI of its own.
//
// Two faces sit on top of it:
//
//   * `src/capi.c3`  -- the `bk_` C ABI (`include/boomkat.h`). Marshals to
//     integer handles and status codes.
//   * `bindings/c3/boomkat.c3` -- the native C3 binding. Speaks C3 optionals
//     and passes `TVal` directly, with no ABI round-trip.
//
// Before this module existed both faces carried their own copy of everything
// here, kept in sync by hand.
module boomkat::embed;

import boomkat::builtins;
import boomkat::compiler;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;

// ============================================================================
// Status and type codes
//
// Single source of truth for the numeric values. `include/boomkat.h` mirrors
// these; `make check-abi` proves the two agree.
// ============================================================================

const int BK_OK            = 0;
const int BK_ERR_NOMEM     = -1;
const int BK_ERR_SYNTAX    = -2;
const int BK_ERR_THROW     = -3;
const int BK_ERR_INTERNAL  = -4;
const int BK_ERR_INVALID   = -5;
const int BK_ERR_TYPE      = -6;
const int BK_ERR_FULL      = -7;
const int BK_ERR_INTERRUPT = -8;

const int BK_TYPE_UNDEFINED = 0;
const int BK_TYPE_NULL      = 1;
const int BK_TYPE_BOOLEAN   = 2;
const int BK_TYPE_NUMBER    = 3;
const int BK_TYPE_STRING    = 4;
const int BK_TYPE_OBJECT    = 5;
const int BK_TYPE_FUNCTION  = 6;
const int BK_TYPE_OTHER     = 7;

const usz ERRBUF = 512;

// ============================================================================
// Value handle encoding
// ============================================================================
//
// A handle is one 64-bit word:
//
//    63..48        47        46..32          31..0
//   [ rt id ]   [scope]  [ generation ]   [ index+1 ]
//
// Index is stored biased by one, which keeps 0 reserved as "no value" and lets
// the eval/call paths keep treating a zero out-param as failure.
//
// 32 index bits mean the registry is bounded by memory rather than by the
// encoding. BK_ERR_FULL is still returned when the slot array cannot grow.
//
// 15 generation bits retire a slot on free. A stale handle to a freed slot
// mismatches the slot's current generation and is rejected, so it can never
// resolve to whatever value later occupies that index.
//
// The generation counter is finite, so it is not allowed to wrap. A slot whose
// generation reaches SLOT_GEN_MAX has exhausted its supply of distinct handles
// and is permanently retired instead of being returned to the free list: every
// handle ever issued for that index stays rejectable forever. Without that, the
// counter would return to a value a stale handle still carries and the two
// would become bit-identical, which no check downstream could separate.
//
// Bit 47 is SCOPE_HANDLE_BIT, marking a per-call scope handle. A registry
// handle never sets it: index and generation together occupy only bits 0..46.
//
// Bits 63..48 carry the id of the runtime that issued the handle. Without it
// two runtimes hand out bit-identical handles -- the first value each issues
// is index 0, generation 1 -- and resolving one runtime's handle against the
// other silently answers with an unrelated value of the same shape. That is a
// wrong answer rather than an error, and no check downstream can separate the
// two. With the id present the mismatch is caught and reported as
// BK_ERR_INVALID.
//
// The id comes from a process-wide counter that wraps at 16 bits. A collision
// therefore needs 65536 runtimes to have been opened *and* a handle from an
// old one to still be in the host's hands, which is a far narrower window than
// having no id at all.
const ulong SLOT_INDEX_BITS = 32;
const ulong SLOT_INDEX_MASK = (1ul << SLOT_INDEX_BITS) - 1;   // 4294967295
const ulong SLOT_GEN_BITS   = 15;
const ulong SLOT_GEN_MASK   = (1ul << SLOT_GEN_BITS) - 1;     // 32767
const uint  SLOT_GEN_MAX    = (uint)SLOT_GEN_MASK;
const uint  SLOT_FREE_END   = 0xFFFF_FFFF;
const uint  SLOT_INITIAL_CAP = 64;

// The registry cannot hand out an index of SLOT_FREE_END, which is the free
// list's end marker, so that is the ceiling on live slots.
const uint SLOT_INDEX_LIMIT = SLOT_FREE_END;

// Marks a per-call scope handle. Set on handles naming `this`, `new.target`
// or an argument, which live in the call scope rather than the registry.
const ulong SCOPE_HANDLE_BIT = 1ul << 47;

const ulong RT_ID_SHIFT = 48;
const ulong RT_ID_MASK  = 0xFFFF;

// Process-wide source of runtime ids. Starts at 1 so a zero id, which is what
// a zeroed-out or never-opened Runtime would carry, is never valid.
uint g_next_rt_id = 1;

macro ulong handle_rt_id(ulong h) => (h >> RT_ID_SHIFT) & RT_ID_MASK;

// One registry entry. `used` distinguishes a live slot from one on the free
// list, so the common stale-handle case is caught without relying on the
// generation having advanced.
struct SlotEntry {
    TVal v;
    uint gen;
    uint next_free;
    bool used;
}

// ============================================================================
// Runtime
// ============================================================================

// A runtime and its value registry. Several may exist at once; each owns its
// heap, VM, globals and interned strings, and shares nothing with the others.
//
// A runtime must be driven from one thread at a time. The engine has no
// locking, so two threads inside one runtime corrupt it; two threads each
// driving their own runtime are fine.
struct Runtime {
    Heap*    heap;
    Vm*      vm;
    uint     rt_id;          // identifies this runtime's handles; see above
    // Host-held values. A dedicated growable array rather than an HObject: the
    // object registry was bounded by the ushort prop_count and burned a shape
    // slot per delete, and it hashed an integer key into a string on every
    // access. The GC walks this array directly (see Heap.capi_roots).
    SlotEntry* slots;
    uint     slot_cap;
    uint     slot_count;     // high-water index, not the live count
    uint     free_head;
    uint     live;
    uint     retired;        // slots withheld from reuse at generation max
    char[ERRBUF] errmsg;
    int      errcode;
    int      err_line;       // 1-based, 0 when unknown
    int      err_col;
    char[ERRBUF] err_name;   // script name for the most recent failure

    // Handed to the host as its `bk_ctx`. A callback gets a different Ctx,
    // built on the trampoline's stack, naming the same runtime plus the call.
    Ctx      root;

    // Ring of scratch buffers behind bk_cstr, so a host can put several
    // converted values in one printf without owning any memory. Freed with
    // the runtime.
    char*[CSTR_RING] cstr_buf;
    usz[CSTR_RING]   cstr_cap;
    uint     cstr_next;
}

// How many bk_cstr results stay valid at once. Four covers every realistic
// format string; the fifth call reuses the first buffer.
const usz CSTR_RING = 4;

// What a `bk_ctx` points at.
//
// One type covers both tiers the ABI used to have. Outside a callback the
// host holds the runtime's own `root`, whose `bctx` is null; inside one it
// holds a stack Ctx naming the same runtime and the live call. Every entry
// point therefore reaches both without asking which tier it is in, and
// `bk_ctx_get_number` and its five siblings simply do not need to exist.
struct Ctx {
    Runtime* rt;
    void*    bctx;   // builtins::BuiltinContext*, null outside a host call
}

// Set once the engine's compile-time-populated tables are known good; see
// ensure_engine_init. Never cleared, since the tables outlive any runtime.
bool g_engine_ready = false;

// The engine's one @init function (builtins::init_builtin_dispatch_table)
// normally runs from the C3 runtime's startup walk of the Mach-O/ELF init
// sections. That walk is only reliable when c3c also drives the final link:
// when this archive is linked by a foreign toolchain the C3 startup can bind
// to the wrong image header and either fault or silently skip the section, so
// the dispatch table stays all-null and the first builtin call misbehaves.
// Observed concretely with the Zig linker, which emits a second, bogus
// __mh_execute_header in __DATA,__bss that the walk latches onto.
//
// Running the initializer explicitly here removes the embedding surface's
// dependence on that walk entirely. It is idempotent -- it just re-stores
// compile-time constants into a fixed-size table -- so double execution with
// the startup path is harmless, and this is the only place a host can reach
// the engine first.
fn void ensure_engine_init() {
    if (g_engine_ready) return;
    g_engine_ready = true;
    builtins::init_builtin_dispatch_table();
}

// Create a runtime: heap, VM, empty registry, GC root hookup.
// Returns null on allocation failure, with nothing left allocated.
fn Runtime* create() {
    ensure_engine_init();

    Heap*? hpr = heap::create(null, null, null, null, null);
    if (catch hpr) return null;
    Heap* hp = hpr;

    Vm*? vr = vm::vm_create(hp);
    if (catch vr) { hp.destroy(); return null; }
    Vm* v = vr;

    void* raw = hp.alloc_func(hp.heap_udata, Runtime::size);
    if (raw == null) { vm::vm_destroy(v); hp.destroy(); return null; }
    Runtime* rt = (Runtime*)raw;
    rt.heap = hp; rt.vm = v;
    rt.slots = null; rt.slot_cap = 0; rt.slot_count = 0;
    rt.free_head = SLOT_FREE_END; rt.live = 0; rt.retired = 0;
    rt.root.rt = rt;
    rt.root.bctx = null;
    for (usz i = 0; i < CSTR_RING; i++) { rt.cstr_buf[i] = null; rt.cstr_cap[i] = 0; }
    rt.cstr_next = 0;
    rt.rt_id = g_next_rt_id & (uint)RT_ID_MASK;
    g_next_rt_id++;
    // Id 0 is reserved as "no runtime", so skip it when the counter wraps.
    if (rt.rt_id == 0) { rt.rt_id = 1; g_next_rt_id = 2; }
    clear_err(rt);

    // The slot array is not an HObject, so the mark phase cannot reach it
    // transitively. Hand the heap a direct view of it instead; mark_roots walks
    // every live entry from there.
    hp.capi_roots = (void*)rt;
    hp.capi_runtime = (void*)rt;
    hp.capi_mark = (heap::CapiMarkFn)&mark_slots;

    return rt;
}

// GC root walk for the value registry. Every live host handle keeps its value
// reachable for as long as the host holds it; freed slots hold undefined and
// mark nothing.
fn void mark_slots(void* rtp) {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    if (rt.slots == null) return;
    for (uint i = 0; i < rt.slot_count; i++) {
        if (!rt.slots[i].used) continue;
        rt.heap.mark_tval(&rt.slots[i].v);
    }
}

// Destroy the runtime and everything it owns. All outstanding handles become
// invalid. Safe with null.
fn void destroy(Runtime* rt) {
    if (rt == null) return;
    Heap* hp = rt.heap;
    // Stop the GC walking the registry before any of it is torn down.
    hp.capi_roots = null;
    hp.capi_runtime = null;
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
    for (usz i = 0; i < CSTR_RING; i++) {
        if (rt.cstr_buf[i] != null) hp.free_func(hp.heap_udata, (void*)rt.cstr_buf[i]);
    }
    // Teardown order is load-bearing: vm_destroy uses heap.free_func.
    vm::vm_destroy(rt.vm);
    hp.free_func(hp.heap_udata, (void*)rt);
    hp.destroy();
}

// ============================================================================
// Error state
// ============================================================================

fn void set_err(Runtime* rt, int code, char[] msg) {
    rt.errcode = code;
    usz n = msg.len < ERRBUF - 1 ? msg.len : ERRBUF - 1;
    for (usz i = 0; i < n; i++) rt.errmsg[i] = msg[i];
    rt.errmsg[n] = 0;
}

fn void set_err_at(Runtime* rt, int code, char[] msg, int line, int col) {
    set_err(rt, code, msg);
    rt.err_line = line;
    rt.err_col = col;
}

fn void set_script_name(Runtime* rt, char* name, usz len) {
    usz n = len < ERRBUF - 1 ? len : ERRBUF - 1;
    for (usz i = 0; i < n; i++) rt.err_name[i] = name[i];
    rt.err_name[n] = 0;
}

fn void clear_err(Runtime* rt) {
    rt.errcode = BK_OK;
    rt.errmsg[0] = 0;
    rt.err_line = 0;
    rt.err_col = 0;
    rt.err_name[0] = 0;
}

// The error message as a C3 slice, without its NUL.
fn char[] err_slice(Runtime* rt) {
    usz n = 0;
    while (n < ERRBUF && rt.errmsg[n] != 0) n++;
    return rt.errmsg[:n];
}

// Read property `key` off `o` or its prototype chain, returning it only if it
// holds a string. Needed for the `name`/`message` pair on a thrown Error: an
// engine-thrown TypeError owns only `message`, and `name` lives on
// Error.prototype.
//
// This walks the chain by hand instead of calling get_prop_proto because that
// routes a Proxy anywhere on the chain back through the trap machinery and
// an accessor back into the VM. Both are re-entry, and this runs on the
// unwind path where re-entry is exactly what must not happen.
fn HString* str_prop(HObject* o, HString* key, Heap* h) {
    HObject* cur = o;
    int depth = 0;
    while (cur != null && depth < 16) {
        if (cur.flags.exotic_proxyobj) return null;
        int idx = cur.find_prop_idx((void*)key, h);
        if (idx >= 0) {
            // An accessor slot holds a getter/setter pair, not a value. Reading
            // it would mean calling into the VM, so treat it as absent.
            if (cur.get_prop_flags((uint)idx, h).is_accessor) return null;
            TVal got = cur.prop_values()[idx];
            if (got.is_string()) return (HString*)got.get_heapptr();
            return null;
        }
        cur = cur.prototype;
        depth++;
    }
    return null;
}

// Format a thrown value into the runtime error buffer without re-entering
// the VM (a user toString could throw again on the unwind path). Every JS
// value reaches a useful message: `throw 42` reports "42", not a placeholder.
fn void describe_error(Runtime* rt, TVal* ev) {
    if (ev.is_string()) {
        HString* s = (HString*)ev.get_heapptr();
        set_err(rt, BK_ERR_THROW, s.get_data());
        return;
    }
    if (ev.is_undefined()) { set_err(rt, BK_ERR_THROW, "undefined"); return; }
    if (ev.is_null())      { set_err(rt, BK_ERR_THROW, "null"); return; }
    if (ev.is_boolean())   {
        set_err(rt, BK_ERR_THROW, ev.get_boolean() ? "true" : "false");
        return;
    }
    if (ev.is_numeric()) {
        // Same shortest-roundtrip formatter the engine uses for Number->String,
        // and it is a pure buffer write: no VM re-entry, no allocation.
        char[64] nbuf;
        usz n = builtins::json_number_to_string(ev.get_number_or_fastint(), &nbuf[0], 64);
        set_err(rt, BK_ERR_THROW, nbuf[:n]);
        return;
    }
    if (ev.is_object()) {
        HObject* o = (HObject*)ev.get_heapptr();
        HString* msg  = str_prop(o, rt.heap.strs[heap::BuiltinStr.MESSAGE], rt.heap);
        HString* name = str_prop(o, rt.heap.strs[heap::BuiltinStr.NAME], rt.heap);

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
            set_err(rt, BK_ERR_THROW, buf[:pos]);
            return;
        }
        if (msg != null && msg.blen != 0) { set_err(rt, BK_ERR_THROW, msg.get_data()); return; }
        if (name != null && name.blen != 0) { set_err(rt, BK_ERR_THROW, name.get_data()); return; }
        set_err(rt, BK_ERR_THROW, "uncaught exception (object)");
        return;
    }
    set_err(rt, BK_ERR_THROW, "uncaught exception");
}

// ============================================================================
// Slot registry
// ============================================================================

// Grow the slot array. Returns false on allocation failure, leaving the
// registry usable at its current size.
fn bool slot_grow(Runtime* rt) {
    uint new_cap = rt.slot_cap == 0 ? SLOT_INITIAL_CAP : rt.slot_cap * 2;
    if (new_cap > SLOT_INDEX_LIMIT) new_cap = SLOT_INDEX_LIMIT;
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

// Register a value and return its handle, or 0 if none could be issued.
//
// Returning 0 is the ONLY failure signal, and every caller turns it into an
// explicit error: a handle is never handed back for a value that was not
// stored.
fn ulong slot_alloc(Runtime* rt, TVal v) {
    uint idx;
    if (rt.free_head != SLOT_FREE_END) {
        idx = rt.free_head;
        rt.free_head = rt.slots[idx].next_free;
    } else {
        if (rt.slot_count >= SLOT_INDEX_LIMIT) return 0;
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
    return ((ulong)rt.rt_id << RT_ID_SHIFT)
         | (((ulong)rt.slots[idx].gen & SLOT_GEN_MASK) << SLOT_INDEX_BITS)
         | ((ulong)idx + 1);
}

// Resolve a handle to its entry, or null if the handle is stale, freed, out of
// range, or a scope handle. This is the single validation point.
fn SlotEntry* slot_entry(Runtime* rt, ulong id) {
    if (rt == null || id == 0) return null;
    if ((id & SCOPE_HANDLE_BIT) != 0) return null;
    // A handle issued by a different runtime names a slot in that runtime's
    // registry, not this one. Reject it instead of resolving it here.
    if (handle_rt_id(id) != (ulong)rt.rt_id) return null;
    ulong biased = id & SLOT_INDEX_MASK;
    if (biased == 0) return null;
    ulong idx = biased - 1;
    if (idx >= (ulong)rt.slot_count) return null;
    SlotEntry* e = &rt.slots[idx];
    if (!e.used) return null;
    if (((id >> SLOT_INDEX_BITS) & SLOT_GEN_MASK) != ((ulong)e.gen & SLOT_GEN_MASK)) return null;
    return e;
}

fn bool slot_get(Runtime* rt, ulong id, TVal* out) {
    SlotEntry* e = slot_entry(rt, id);
    if (e == null) return false;
    *out = e.v;
    return true;
}

// Release a handle. Scope handles and already-freed handles are ignored
// rather than treated as an error.
fn void slot_release(Runtime* rt, ulong id) {
    SlotEntry* e = slot_entry(rt, id);
    if (e == null) return;

    if (e.v.is_heap_allocated()) rt.heap.decref_tval(&e.v);
    e.v.set_undefined();
    e.used = false;
    if (rt.live > 0) rt.live--;

    // Advance the generation so every handle naming this index is now stale and
    // slot_entry rejects it, keeping a later occupant unreachable through an old
    // handle.
    //
    // At SLOT_GEN_MAX the counter has no unused value left: bumping it would
    // return to a generation some outstanding handle still carries, making the
    // two handles bit-identical. Such a slot is permanently retired instead of
    // being relisted, so it is never allocated again and every handle for it
    // stays rejected.
    if (e.gen >= SLOT_GEN_MAX) {
        rt.retired++;
        return;
    }
    e.gen++;

    uint idx = (uint)((id & SLOT_INDEX_MASK) - 1);
    e.next_free = rt.free_head;
    rt.free_head = idx;
}

// ============================================================================
// Handles: scope and registry
// ============================================================================

// Encode a scope handle for argument/this/new_target index `idx`.
//
// Scope handles are distinguished from global slot ids by the high bit, so
// the type query and the readers accept both kinds without separate entry
// points.
fn ulong scope_handle(Runtime* rt, ulong idx) @inline {
    ulong rid = rt == null ? 0 : (ulong)rt.rt_id;
    return (rid << RT_ID_SHIFT) | SCOPE_HANDLE_BIT | idx;
}

// Resolve any handle to a TVal. Global slot ids go to the slot registry;
// scope handles read the innermost host call scope through the context.
fn bool resolve_handle(Runtime* rt, void* ctxp, ulong id, TVal* out) {
    if ((id & SCOPE_HANDLE_BIT) != 0) {
        if (ctxp == null) return false;
        // A scope handle belongs to one call in one runtime, so it is checked
        // the same way a registry handle is.
        if (rt != null && handle_rt_id(id) != (ulong)rt.rt_id) return false;
        builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
        uint idx = (uint)(id & ~(SCOPE_HANDLE_BIT | (RT_ID_MASK << RT_ID_SHIFT)));
        if (idx == heap::HOST_SCOPE_THIS)       { *out = builtins::host_this(ctx); return true; }
        if (idx == heap::HOST_SCOPE_NEW_TARGET) { *out = builtins::host_new_target(ctx); return true; }
        *out = builtins::host_arg(ctx, idx - heap::HOST_SCOPE_ARG0);
        return true;
    }
    return slot_get(rt, id, out);
}

// The runtime owning a call context, or null if the context is not one of
// ours. A host function is handed a context, not a runtime, so this is how
// the context-tier entry points find their runtime without consulting a
// global.
fn Runtime* ctx_runtime(void* ctxp) @inline {
    if (ctxp == null) return null;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    if (ctx.heap == null) return null;
    return (Runtime*)ctx.heap.capi_runtime;
}

// ============================================================================
// Value classification
// ============================================================================

// Broad `typeof`-style classification of a resolved value.
fn int classify(TVal v) {
    if (v.is_undefined()) return BK_TYPE_UNDEFINED;
    if (v.is_null()) return BK_TYPE_NULL;
    if (v.is_boolean()) return BK_TYPE_BOOLEAN;
    if (v.is_numeric()) return BK_TYPE_NUMBER;
    // A Symbol is a STRING-tagged HString with is_symbol set, so is_string()
    // alone would misreport it as a string and let a string read hand back
    // the symbol's raw internal bytes.
    if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null && s.is_symbol()) return BK_TYPE_OTHER;
        return BK_TYPE_STRING;
    }
    if (v.is_object()) {
        HObject* o = (HObject*)v.get_heapptr();
        if (o != null && o.flags.callable) return BK_TYPE_FUNCTION;
        return BK_TYPE_OBJECT;
    }
    return BK_TYPE_OTHER;
}

// ============================================================================
// String marshalling
// ============================================================================

// UTF-8 conversion sink. The state is per-call and lives on the caller's
// stack, reached through the udata pointer write_cesu8_as_utf8 passes back.
//
// `len` counts every byte the conversion produces, including those past `cap`,
// because the two-call protocol needs the full required size even when the
// buffer is too small or absent.
struct StringSink {
    char* buf;
    usz   len;
    usz   cap;
}

fn void sink_put(char c, void* udata) {
    StringSink* sink = (StringSink*)udata;
    if (sink.len + 1 < sink.cap) { sink.buf[sink.len] = c; }
    sink.len++;
}

// Byte length of `s` as standard UTF-8, excluding a NUL.
fn usz utf8_len(HString* s) {
    StringSink sink = { .buf = null, .len = 0, .cap = 0 };
    hstring::write_cesu8_as_utf8(s.get_data(), &sink_put, &sink);
    return sink.len;
}

// Convert `s` from the engine's CESU-8 into `buf` as standard UTF-8, so
// astral characters emerge as proper 4-byte sequences rather than surrogate
// halves. Returns the full byte length needed, whether or not it fit.
// Pass buf == null / cap == 0 to measure only.
fn usz utf8_write(HString* s, char* buf, usz cap) {
    StringSink sink = { .buf = buf, .len = 0, .cap = (buf == null) ? 0 : cap };
    hstring::write_cesu8_as_utf8(s.get_data(), &sink_put, &sink);
    return sink.len;
}

// ============================================================================
// Host functions
// ============================================================================

// The C-facing callback signature: (ctx, udata).
alias BkHostFn = fn void(void*, void*);

// Trampoline: every registered host function enters the engine through this
// one C3 function, which forwards to the C callback with the context as an
// opaque pointer. The udata the engine stored is a HostReg* holding the real
// C function pointer and the host's own udata.
struct HostReg {
    void* cfn;
    void* udata;
}

fn void host_trampoline(builtins::BuiltinContext* ctx, void* udata) {
    if (udata == null) return;
    HostReg* reg = (HostReg*)udata;
    if (reg.cfn == null) return;
    // The callback's `bk_ctx` is a Ctx naming this runtime and this call. It
    // lives on this frame, which is exactly the lifetime the header promises:
    // valid for the body of the callback and no longer.
    Ctx c = { .rt = ctx_runtime((void*)ctx), .bctx = (void*)ctx };
    BkHostFn cfn = (BkHostFn)reg.cfn;
    cfn((void*)&c, reg.udata);
}

// Install a function object as a global binding named `name`, dispatching
// through `trampoline` with `reg_udata` handed back to it.
//
// The trampoline is a parameter rather than fixed, because each face has its
// own: the C ABI forwards to a C function pointer, the C3 binding to a C3
// callback taking a JsCtx. Everything around that -- interning the name,
// claiming a host-function slot, building the function object and declaring
// the binding -- is identical for both and lives here.
//
// Returns a BK_* status. On failure `reg_udata` is left alone; the caller
// allocated it and frees it.
fn int install_fn(Runtime* rt, char[] name, void* trampoline, void* reg_udata,
                  int arity, bool constructable) {
    TVal fv;
    int rc = make_fn_value(rt, name, trampoline, reg_udata, arity, constructable, &fv);
    if (rc != BK_OK) return rc;
    return declare_global(rt, name, fv);
}

// Install `cfn` as a global function named `name`, arriving through
// host_trampoline. Returns a BK_* status.
fn int register_host_fn(Runtime* rt, char[] name, void* cfn, void* udata,
                        int arity, bool constructable) {
    // The registration record outlives the call, so it is heap-allocated and
    // owned by the runtime; the host function table keeps the only pointer.
    void* raw = rt.heap.alloc_func(rt.heap.heap_udata, HostReg::size);
    if (raw == null) { set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    HostReg* reg = (HostReg*)raw;
    reg.cfn = cfn;
    reg.udata = udata;

    int rc = install_fn(rt, name, (void*)&host_trampoline, (void*)reg, arity, constructable);
    if (rc != BK_OK) rt.heap.free_func(rt.heap.heap_udata, raw);
    return rc;
}

// ============================================================================
// Eval
// ============================================================================

// Compile and run `src` for its completion value, leaving the result in
// *out (untouched on failure). `name` is recorded for error reporting.
//
// Returns a BK_* status; on anything but BK_OK the runtime's error state
// carries the detail. Never re-enters the VM to format a message.
fn int eval_source(Runtime* rt, char[] src, char[] name, TVal* out) {
    clear_err(rt);
    if (name.len != 0) set_script_name(rt, &name[0], name.len);
    // A fresh eval starts with a clean interrupt state: an abort from a prior
    // run was cleared when it surfaced here, and a near-zero budget must not
    // trigger an immediate unprompted callback.
    rt.heap.uncatchable_throw = false;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;

    Lexer lex = lexer::lexer_init(src, rt.heap, name.len != 0 ? name : (char[])"<eval>");
    lex.skip_hashbang();
    // compile_eval, not compile: a top-level *script* only yields a value via an
    // explicit RET, so `40+2` would come back undefined. eval-form code carries a
    // completion value, which is what an embedder expects.
    CompiledFunction*? fr = compiler::compile_eval(&lex, rt.heap);
    if (catch fr) {
        // Copy immediately: the compiler error buffer lives on the lexer and
        // is clobbered by the next failing compile.
        char* m = &lex.err_msg[0];
        usz n = 0;
        while (m[n] != 0 && n < ERRBUF - 1) n++;
        // Some compiler failure paths return without populating the global
        // buffer (e.g. "var = = ="). Never hand the host an empty message.
        if (n == 0) {
            set_err_at(rt, BK_ERR_SYNTAX, "SyntaxError", (int)lex.err_line, (int)lex.err_col);
        } else {
            set_err_at(rt, BK_ERR_SYNTAX, m[:n], (int)lex.err_line, (int)lex.err_col);
        }
        lex.free_arena();
        return BK_ERR_SYNTAX;
    }
    CompiledFunction* f = fr;

    rt.heap.has_error = false;
    TVal? res = rt.vm.execute(f);
    lex.free_arena();

    if (catch res) {
        if (rt.heap.has_error) {
            // The interrupt flag marks this failure as an abort of a runaway
            // script and is cleared here, at the host boundary.
            if (rt.heap.uncatchable_throw) {
                rt.heap.uncatchable_throw = false;
                set_err(rt, BK_ERR_INTERRUPT, "interrupted");
                return BK_ERR_INTERRUPT;
            }
            describe_error(rt, &rt.heap.error_value);
            return BK_ERR_THROW;
        }
        set_err(rt, BK_ERR_INTERNAL, "internal VM error");
        return BK_ERR_INTERNAL;
    }

    *out = res;
    return BK_OK;
}

// Run pending promise jobs. Returns BK_OK, or BK_ERR_INTERRUPT when an
// interrupt fired inside a job (the drain aborts, remaining queue dropped).
fn int drain_microtasks(Runtime* rt) {
    clear_err(rt);
    rt.heap.uncatchable_throw = false;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
    rt.heap.drain_microtasks((void*)rt.vm);
    // The drain aborts on an interrupt: the host needs to know its abort
    // landed, and a reader-style error would be wiped by the next call.
    if (rt.heap.uncatchable_throw) {
        rt.heap.uncatchable_throw = false;
        set_err(rt, BK_ERR_INTERRUPT, "interrupted");
        return BK_ERR_INTERRUPT;
    }
    return BK_OK;
}

// ============================================================================
// String coercion
// ============================================================================

// ToString(v) through the VM, so valueOf/toString run and may throw.
// Returns a BK_* status; on BK_OK *out holds the result.
fn int to_string(Runtime* rt, TVal v, HString** out) {
    clear_err(rt);
    rt.heap.has_error = false;
    HString*? s = vm::vm_to_string(rt.vm, &v);
    if (catch s) {
        if (rt.heap.uncatchable_throw) {
            rt.heap.uncatchable_throw = false;
            set_err(rt, BK_ERR_INTERRUPT, "interrupted");
            return BK_ERR_INTERRUPT;
        }
        if (rt.heap.has_error) {
            describe_error(rt, &rt.heap.error_value);
            return BK_ERR_THROW;
        }
        set_err(rt, BK_ERR_INTERNAL, "could not convert value to string");
        return BK_ERR_INTERNAL;
    }
    *out = s;
    return BK_OK;
}

// Claim the next ring buffer, grown to hold `need` bytes plus a NUL.
// Returns null if it could not be grown, leaving the ring usable.
fn char* cstr_slot(Runtime* rt, usz need) {
    uint i = rt.cstr_next % (uint)CSTR_RING;
    rt.cstr_next = i + 1;
    usz want = need + 1;
    if (rt.cstr_cap[i] < want) {
        // Round up so a host converting similar values in a loop stops
        // reallocating after the first few.
        usz cap = rt.cstr_cap[i] == 0 ? 64 : rt.cstr_cap[i];
        while (cap < want) cap *= 2;
        void* raw = rt.heap.realloc_func(rt.heap.heap_udata, (void*)rt.cstr_buf[i], cap);
        if (raw == null) return null;
        rt.cstr_buf[i] = (char*)raw;
        rt.cstr_cap[i] = cap;
    }
    return rt.cstr_buf[i];
}

// ============================================================================
// Function values
// ============================================================================

// Build a host-function object without binding it to a name, for installing
// onto an arbitrary object rather than the global environment.
// Returns a BK_* status; on BK_OK *out holds the function value.
fn int make_fn_value(Runtime* rt, char[] name, void* trampoline, void* reg_udata,
                     int arity, bool constructable, TVal* out) {
    HString* nm = rt.heap.str_intern(name);
    if (nm == null) { set_err(rt, BK_ERR_NOMEM, "could not intern function name"); return BK_ERR_NOMEM; }

    long slot = rt.heap.register_host_fn(trampoline, reg_udata, (void*)nm,
                                         arity, constructable);
    if (slot < 0) {
        set_err(rt, BK_ERR_NOMEM, "host function table full");
        return BK_ERR_NOMEM;
    }
    HObject*? fo = builtins::make_host_function(rt.heap, (uint)slot);
    if (catch fo) { set_err(rt, BK_ERR_NOMEM, "could not create function object"); return BK_ERR_NOMEM; }
    out.set_object(fo);
    return BK_OK;
}

// Declare `name` in the global environment, bound to `v`.
fn int declare_global(Runtime* rt, char[] name, TVal v) {
    HString* nm = rt.heap.str_intern(name);
    if (nm == null) { set_err(rt, BK_ERR_NOMEM, "could not intern name"); return BK_ERR_NOMEM; }
    if (!env::env_declare(rt.vm.global_env, (void*)nm, v)) {
        set_err(rt, BK_ERR_INTERNAL, "could not bind global name");
        return BK_ERR_INTERNAL;
    }
    return BK_OK;
}

// ============================================================================
// Names for logging
// ============================================================================

fn char* status_name(int status) {
    switch (status) {
        case BK_OK:            return "OK";
        case BK_ERR_NOMEM:     return "NOMEM";
        case BK_ERR_SYNTAX:    return "SYNTAX";
        case BK_ERR_THROW:     return "THROW";
        case BK_ERR_INTERNAL:  return "INTERNAL";
        case BK_ERR_INVALID:   return "INVALID";
        case BK_ERR_TYPE:      return "TYPE";
        case BK_ERR_FULL:      return "FULL";
        case BK_ERR_INTERRUPT: return "INTERRUPT";
        default:               return "UNKNOWN";
    }
}

fn char* type_name(int type) {
    switch (type) {
        case BK_TYPE_UNDEFINED: return "undefined";
        case BK_TYPE_NULL:      return "null";
        case BK_TYPE_BOOLEAN:   return "boolean";
        case BK_TYPE_NUMBER:    return "number";
        case BK_TYPE_STRING:    return "string";
        case BK_TYPE_OBJECT:    return "object";
        case BK_TYPE_FUNCTION:  return "function";
        case BK_TYPE_OTHER:     return "other";
        default:                return "unknown";
    }
}
