// Shared embedding core.
//
// Provides the GC-rooted value registry, error buffer with no-re-entry
// formatting, CESU-8 to UTF-8 conversion, and host-function trampolines
// for the C ABI (src/capi.c3) and public C3 API (src/embedding.c3).
module boomkat::embed;

import boomkat::builtins;
import std::thread;
import boomkat::compiler;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import boomkat::embed::abi;
import boomkat::esm;

// ============================================================================
// Status and type codes from boomkat::embed::abi (src/embed/abi.c3)
// ============================================================================

const int BK_OK            = abi::BK_OK;
const int BK_ERR_NOMEM     = abi::BK_ERR_NOMEM;
const int BK_ERR_SYNTAX    = abi::BK_ERR_SYNTAX;
const int BK_ERR_THROW     = abi::BK_ERR_THROW;
const int BK_ERR_INTERNAL  = abi::BK_ERR_INTERNAL;
const int BK_ERR_INVALID   = abi::BK_ERR_INVALID;
const int BK_ERR_TYPE      = abi::BK_ERR_TYPE;
const int BK_ERR_FULL      = abi::BK_ERR_FULL;
const int BK_ERR_INTERRUPT = abi::BK_ERR_INTERRUPT;
const int BK_ERR_ENCODING  = abi::BK_ERR_ENCODING;
const int BK_ERR_UNSUPPORTED = abi::BK_ERR_UNSUPPORTED;

const int BK_UTF8_REPLACE = abi::BK_UTF8_REPLACE;
const int BK_UTF8_STRICT  = abi::BK_UTF8_STRICT;

const int BK_TYPE_UNDEFINED = abi::BK_TYPE_UNDEFINED;
const int BK_TYPE_NULL      = abi::BK_TYPE_NULL;
const int BK_TYPE_BOOLEAN   = abi::BK_TYPE_BOOLEAN;
const int BK_TYPE_NUMBER    = abi::BK_TYPE_NUMBER;
const int BK_TYPE_STRING    = abi::BK_TYPE_STRING;
const int BK_TYPE_OBJECT    = abi::BK_TYPE_OBJECT;
const int BK_TYPE_FUNCTION  = abi::BK_TYPE_FUNCTION;
const int BK_TYPE_OTHER     = abi::BK_TYPE_OTHER;

const usz ERRBUF = 512;
// Embedder data slots per runtime and per context (BK_DATA_SLOTS).
const uint DATA_SLOTS = 4;
// Live bk_cstr results per runtime before the oldest buffer is reused.
const usz CSTR_RING = 4;

fn ulong take_exception(Runtime* rt) {
    ulong value = rt.exception;
    if (value != 0) { rt.exception = 0; rt.pending_code = 0; return value; }
    if (rt.pending_code == 0) {
        TVal undefined; undefined.set_undefined();
        return slot_alloc(rt, undefined);
    }
    int kind = rt.pending_code == BK_ERR_SYNTAX ? builtins::HOST_ERR_SYNTAX
             : rt.pending_code == BK_ERR_TYPE ? builtins::HOST_ERR_TYPE : builtins::HOST_ERR_ERROR;
    builtins::BuiltinContext ctx = { .heap = rt.heap, .vm = rt.vm };
    char[] message = ((ZString)&rt.pending_message).str_view();
    builtins::host_throw_error(&ctx, kind, message);
    rt.pending_code = 0;
    return slot_alloc(rt, ctx.throw_value);
}

// ============================================================================
// Value handle encoding
// ============================================================================
//
// A handle is one 64-bit word:
//
//    63..48        47        46..32          31..0
//   [ rt id ]   [scope]  [ generation ]   [ index+1 ]
//
// Index is stored biased by one, reserving 0 as "no value".
//
// 15 generation bits detect stale handles. A slot whose generation reaches
// SLOT_GEN_MAX is permanently retired rather than returned to the free list,
// preventing counter wraparound.
//
// Bit 47 (SCOPE_HANDLE_BIT) distinguishes per-call scope handles from registry
// handles.
//
// Bits 63..48 identify the issuing Runtime to catch cross-runtime lookups.
//
// Runtime id 0 is never issued. Handles 1 to 4 are the immediates undefined,
// null, true and false: valid in every runtime, never stored, never freed.
const ulong SLOT_INDEX_BITS = 32;
const ulong SLOT_INDEX_MASK = (1ul << SLOT_INDEX_BITS) - 1;
const ulong SLOT_GEN_BITS   = 15;
const ulong SLOT_GEN_MASK   = (1ul << SLOT_GEN_BITS) - 1;
const uint  SLOT_GEN_MAX    = (uint)SLOT_GEN_MASK;
const uint  SLOT_FREE_END   = 0xFFFF_FFFF;
const uint  SLOT_INITIAL_CAP = 64;

// The free list end marker limits the live slot count.
const uint SLOT_INDEX_LIMIT = SLOT_FREE_END;

// Marks a per-call scope handle (this, new.target, arguments).
const ulong SCOPE_HANDLE_BIT = 1ul << 47;

const ulong RT_ID_SHIFT = 48;
const ulong RT_ID_MASK  = 0xFFFF;

// Process-wide source of runtime IDs. Starts at 1; 0 is reserved as invalid.
uint g_next_rt_id = 1;

macro ulong handle_rt_id(ulong h) => (h >> RT_ID_SHIFT) & RT_ID_MASK;

const ulong IMM_UNDEFINED = 1;
const ulong IMM_NULL      = 2;
const ulong IMM_TRUE      = 3;
const ulong IMM_FALSE     = 4;

// The immediate handle for `v`, or 0 when `v` has none.
fn ulong immediate_of(TVal v) @inline {
    if (v.is_undefined()) return IMM_UNDEFINED;
    if (v.is_null()) return IMM_NULL;
    if (v.is_boolean()) return v.get_boolean() ? IMM_TRUE : IMM_FALSE;
    return 0;
}

// Reads an immediate handle into `out`. False for any other handle.
fn bool immediate_get(ulong id, TVal* out) @inline {
    switch (id) {
        case IMM_UNDEFINED: out.set_undefined();
        case IMM_NULL:      out.set_null();
        case IMM_TRUE:      out.set_boolean(true);
        case IMM_FALSE:     out.set_boolean(false);
        default:            return false;
    }
    return true;
}

// One registry entry. `used` distinguishes live slots from free-list entries.
struct SlotEntry {
    TVal v;
    uint gen;
    uint next_free;
    bool used;
}

// ============================================================================
// Runtime
// ============================================================================

// Context state is inline in the runtime while active, preserving direct loads.
struct ContextState {
    char[ERRBUF] errmsg;
    int      errcode;
    int      err_line;       // 1-based, 0 when unknown
    int      err_col;
    char[ERRBUF] err_name;   // script name for the most recent failure
    // Backing store for the strings of Heap.jsx (bk_set_jsx).
    char*    jsx_buf;

    ulong exception;
    int pending_code;
    char[ERRBUF] pending_message;
    void*[DATA_SLOTS] context_data;
}

// Owns one heap, VM, and value registry.
// Not thread-safe; a runtime must be driven from one thread at a time.
struct Runtime {
    inline ContextState state;
    Heap*    heap;
    Vm*      vm;
    uint     rt_id;
    // Host-held values. The GC walks this array directly (see Heap.capi_roots).
    SlotEntry* slots;
    uint     slot_cap;
    uint     slot_count;     // high-water index, not the live count
    uint     free_head;
    uint     live;
    uint     retired;        // slots withheld from reuse at generation max

    void* promise_rejection_fn;
    void* promise_rejection_udata;
    // Root context for embedding operations outside host callbacks.
    Ctx      root;
    Ctx*     contexts;
    Ctx*     active;
    bool     root_used;
    void*[DATA_SLOTS] data;
    HostPayload* host_payloads;
    // Set by bk_create, whose context owns the runtime.
    bool     owned_by_context;
    char*[CSTR_RING] cstr_buf;
    usz[CSTR_RING]   cstr_cap;
    uint     cstr_next;
    // Atoms: property keys held by index. An atom is its entry index + 1.
    AtomEntry* atoms;
    uint     atom_cap;
    uint     atom_count;     // high-water index
    uint     atom_free;      // free list head, ATOM_FREE_END when empty
    // Open-addressed map from key to atom, so one key has one atom.
    uint*    atom_index;
    uint     atom_index_cap; // a power of two, or 0
    uint     atom_live;

}

// Context handle passed to embedding calls and host callbacks.
// Outside host callbacks, `bctx` is null.
struct Ctx {
    Runtime* rt;
    void*    bctx;   // builtins::BuiltinContext*, null outside a host callback
    heap::Realm* realm;
    Ctx* next;
    ContextState saved;
    bool released;
}

// Set once engine-wide static tables are initialized.
OnceFlag g_engine_once;

// Initializes built-in dispatch tables. Foreign toolchain linkers may skip
// C3 @init sections, so runtime creation calls this explicitly. Idempotent.
fn void ensure_engine_init() {
    g_engine_once.call(&builtins::init_builtin_dispatch_table);
}

// Create a runtime: heap, VM, empty registry, GC root hookup. Null functions
// select the libc allocator and the aborting fatal handler.
// Returns null on allocation failure, with nothing left allocated.
fn Runtime* create(heap::AllocFunc alloc = null, heap::ReallocFunc realloc = null,
                   heap::FreeFunc free = null, void* udata = null, heap::FatalFunc fatal = null) {
    ensure_engine_init();

    Heap*? hpr = heap::create(alloc, realloc, free, udata, fatal);
    if (catch hpr) return null;
    Heap* hp = hpr;

    Vm*? vr = vm::vm_create(hp);
    if (catch vr) { hp.destroy(); return null; }
    Vm* v = vr;

    void* raw = hp.alloc_func(hp.heap_udata, Runtime::size);
    if (raw == null) { vm::vm_destroy(v); hp.destroy(); return null; }
    Runtime* rt = (Runtime*)raw;
    mem::clear(rt, (sz)Runtime::size);
    rt.heap = hp; rt.vm = v;
    rt.slots = null; rt.slot_cap = 0; rt.slot_count = 0;
    rt.free_head = SLOT_FREE_END; rt.live = 0; rt.retired = 0;
    rt.atom_free = ATOM_FREE_END;
    rt.promise_rejection_fn = null;
    rt.promise_rejection_udata = null;
    rt.root.rt = rt;
    rt.root.bctx = null;
    rt.active = &rt.root;
    hp.host_managed_jobs = true;
    // Runtime IDs must remain distinct during concurrent worker creation.
    do {
        uint next = mem::@atomic_load(g_next_rt_id);
        while (mem::compare_exchange(&g_next_rt_id, next, next + 1u) != next) {
            next = mem::@atomic_load(g_next_rt_id);
        }
        rt.rt_id = next & (uint)RT_ID_MASK;
    } while (rt.rt_id == 0);
    clear_err(rt);

    // Register the slot array with the heap for GC root marking.
    hp.capi_roots = (void*)rt;
    hp.capi_runtime = (void*)rt;
    hp.capi_mark = (heap::CapiMarkFn)&mark_slots;
    hp.capi_mark_slice = (heap::CapiMarkSliceFn)&mark_slots_slice;

    return rt;
}

fn void select_context(Ctx* ctx) @inline {
    Runtime* rt = ctx.rt;
    if (rt.active != ctx) activate_context(rt, ctx);
    rt.heap.enter_realm(ctx.realm);
}

fn void activate_context(Runtime* rt, Ctx* ctx) @noinline {
    rt.active.saved = rt.state;
    rt.state = ctx.saved;
    rt.active = ctx;
}

fn Ctx* new_context(Runtime* rt) {
    if (!rt.root_used) { rt.root_used = true; return &rt.root; }
    void* raw = rt.heap.alloc_func(rt.heap.heap_udata, Ctx::size);
    if (raw == null) return null;
    if (try realm = rt.heap.create_realm()) {
        Ctx* ctx = (Ctx*)raw;
        *ctx = { .rt = rt, .realm = realm, .next = rt.contexts };
        rt.contexts = ctx;
        return ctx;
    }
    rt.heap.free_func(rt.heap.heap_udata, raw);
    return null;
}

// Records survive public release because escaped native functions retain their realm.
fn Ctx* realm_context(Runtime* rt, heap::Realm* realm) {
    if (realm == null) return &rt.root;
    for (Ctx* ctx = rt.contexts; ctx != null; ctx = ctx.next) {
        if (ctx.realm == realm) return ctx;
    }
    return null;
}

fn void free_context(Ctx* ctx) {
    if (ctx == null || ctx.bctx != null || ctx.released) return;
    select_context(ctx);
    clear_exception(ctx.rt);
    ctx.released = true;
}

// GC root walk for the value registry. Marks values in active slots.
fn void mark_slots(void* rtp) {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    for (uint i = 0; i < rt.slot_count; i++) {
        if (!rt.slots[i].used) continue;
        rt.heap.mark_tval(&rt.slots[i].v);
    }
    for (uint i = 0; i < rt.atom_count; i++) {
        if (rt.atoms[i].key == null) continue;
        TVal kv; kv.set_string_borrowed(rt.atoms[i].key);
        rt.heap.mark_tval(&kv);
    }
}

// The cursor runs over registry entries and then atoms, by index, so a resize
// cannot invalidate it between slices. Newly published handles and atoms
// shade their values when created.
fn bool mark_slots_slice(void* rtp, void* heap_ptr, uint* cursor, uint budget) {
    if (rtp == null) return true;
    Runtime* rt = (Runtime*)rtp;
    heap::Heap* h = (heap::Heap*)heap_ptr;
    uint done = 0;
    while (*cursor < rt.slot_count + rt.atom_count && done < budget) {
        uint i = (*cursor)++;
        if (i < rt.slot_count) {
            if (rt.slots[i].used) h.shade_root_tval(rt.slots[i].v);
        } else if (rt.atoms[i - rt.slot_count].key != null) {
            TVal kv; kv.set_string_borrowed(rt.atoms[i - rt.slot_count].key);
            h.shade_root_tval(kv);
        }
        done++;
    }
    return *cursor >= rt.slot_count + rt.atom_count;
}

// Destroy the runtime and everything it owns. All outstanding handles become
// invalid. Safe with null.
fn void destroy(Runtime* rt) {
    if (rt == null) return;
    Heap* hp = rt.heap;
    for (HostPayload* payload = rt.host_payloads; payload != null; ) {
        HostPayload* next = payload.next;
        hp.free_func(hp.heap_udata, payload);
        payload = next;
    }
    if (rt.active != &rt.root && rt.root.saved.jsx_buf != null) hp.free_func(hp.heap_udata, rt.root.saved.jsx_buf);
    for (Ctx* ctx = rt.contexts; ctx != null; ) {
        if (ctx != rt.active && ctx.saved.jsx_buf != null) hp.free_func(hp.heap_udata, ctx.saved.jsx_buf);
        Ctx* next = ctx.next;
        hp.free_func(hp.heap_udata, ctx);
        ctx = next;
    }
    // Stop the GC walking the registry before any of it is torn down.
    hp.capi_roots = null;
    hp.capi_runtime = null;
    hp.capi_mark = null;
    hp.capi_mark_slice = null;
    atoms_destroy(rt);
    if (rt.slots != null) {
        for (uint i = 0; i < rt.slot_count; i++) {
            if (rt.slots[i].used && rt.slots[i].v.is_heap_allocated()) {
                hp.decref_tval(&rt.slots[i].v);
            }
        }
        hp.free_func(hp.heap_udata, (void*)rt.slots);
        rt.slots = null;
    }
    if (rt.jsx_buf != null) hp.free_func(hp.heap_udata, (void*)rt.jsx_buf);
    foreach (buf : rt.cstr_buf) if (buf != null) hp.free_func(hp.heap_udata, (void*)buf);
    // Teardown order is load-bearing: vm_destroy uses heap.free_func.
    vm::vm_destroy(rt.vm);
    hp.free_func(hp.heap_udata, (void*)rt);
    hp.destroy();
}

// ============================================================================
// Atoms
// ============================================================================

const uint ATOM_FREE_END = 0xFFFF_FFFF;

// One atom: a property key (an interned string or a symbol) the runtime holds
// a reference to while any host reference remains.
struct AtomEntry {
    HString* key;     // null when the entry is free
    uint refs;
    uint next_free;
}

fn uint atom_hash(HString* key) @inline {
    ulong h = (ulong)(usz)key >> 4;
    return (uint)((h * 0x9E3779B97F4A7C15) >> 32);
}

// The slot of `key` in the index, or of the empty slot where it belongs.
fn uint atom_probe(Runtime* rt, HString* key) {
    uint mask = rt.atom_index_cap - 1;
    uint i = atom_hash(key) & mask;
    while (rt.atom_index[i] != 0 && rt.atoms[rt.atom_index[i] - 1].key != key) i = (i + 1) & mask;
    return i;
}

fn bool atom_index_grow(Runtime* rt) {
    uint cap = rt.atom_index_cap == 0 ? 16 : rt.atom_index_cap * 2;
    uint* fresh = (uint*)rt.heap.alloc_func(rt.heap.heap_udata, (usz)cap * uint::size);
    if (fresh == null) return false;
    mem::clear(fresh, (sz)((usz)cap * uint::size));
    uint* old = rt.atom_index;
    uint old_cap = rt.atom_index_cap;
    rt.atom_index = fresh;
    rt.atom_index_cap = cap;
    for (uint i = 0; i < old_cap; i++) {
        if (old[i] != 0) rt.atom_index[atom_probe(rt, rt.atoms[old[i] - 1].key)] = old[i];
    }
    if (old != null) rt.heap.free_func(rt.heap.heap_udata, old);
    return true;
}

// The atom for `key`, adding a reference, or 0 when memory runs out.
fn uint atom_intern(Runtime* rt, HString* key) {
    if (key == null) return 0;
    if ((rt.atom_live + 1) * 2 > rt.atom_index_cap && !atom_index_grow(rt)) return 0;
    uint slot = atom_probe(rt, key);
    if (rt.atom_index[slot] != 0) {
        rt.atoms[rt.atom_index[slot] - 1].refs++;
        return rt.atom_index[slot];
    }
    uint idx;
    if (rt.atom_free != ATOM_FREE_END) {
        idx = rt.atom_free;
        rt.atom_free = rt.atoms[idx].next_free;
    } else {
        if (rt.atom_count == rt.atom_cap) {
            uint cap = rt.atom_cap == 0 ? 16 : rt.atom_cap * 2;
            void* grown = rt.heap.realloc_func(rt.heap.heap_udata, (void*)rt.atoms, (usz)cap * AtomEntry::size);
            if (grown == null) return 0;
            rt.atoms = (AtomEntry*)grown;
            rt.atom_cap = cap;
        }
        idx = rt.atom_count++;
    }
    ((HeapHeader*)key).incref();
    TVal kv; kv.set_string_borrowed(key);
    rt.heap.shade_root_tval(kv);
    rt.atoms[idx] = { .key = key, .refs = 1, .next_free = ATOM_FREE_END };
    rt.atom_index[slot] = idx + 1;
    rt.atom_live++;
    return idx + 1;
}

// The key of a live atom, or null.
fn HString* atom_key(Runtime* rt, uint atom) @inline {
    if (atom == 0 || atom > rt.atom_count) return null;
    return rt.atoms[atom - 1].key;
}

fn bool atom_dup(Runtime* rt, uint atom) {
    if (atom_key(rt, atom) == null) return false;
    rt.atoms[atom - 1].refs++;
    return true;
}

// Drops one reference; the last one frees the entry and releases its key.
fn void atom_release(Runtime* rt, uint atom) {
    HString* key = atom_key(rt, atom);
    if (key == null) return;
    AtomEntry* e = &rt.atoms[atom - 1];
    if (--e.refs != 0) return;
    // Backward-shift deletion keeps every probe chain unbroken.
    uint mask = rt.atom_index_cap - 1;
    uint hole = atom_probe(rt, key);
    uint i = hole;
    for (;;) {
        i = (i + 1) & mask;
        uint id = rt.atom_index[i];
        if (id == 0) break;
        uint home = atom_hash(rt.atoms[id - 1].key) & mask;
        // Move the entry back unless its home lies cyclically in (hole, i].
        bool stays = hole <= i ? (hole < home && home <= i) : (hole < home || home <= i);
        if (stays) continue;
        rt.atom_index[hole] = id;
        hole = i;
    }
    rt.atom_index[hole] = 0;
    e.key = null;
    e.next_free = rt.atom_free;
    rt.atom_free = atom - 1;
    rt.atom_live--;
    TVal kv; kv.set_string_borrowed(key);
    rt.heap.decref_tval(&kv);
}

fn void atoms_destroy(Runtime* rt) {
    Heap* hp = rt.heap;
    for (uint i = 0; i < rt.atom_count; i++) {
        if (rt.atoms[i].key == null) continue;
        TVal kv; kv.set_string_borrowed(rt.atoms[i].key);
        hp.decref_tval(&kv);
    }
    if (rt.atoms != null) hp.free_func(hp.heap_udata, (void*)rt.atoms);
    if (rt.atom_index != null) hp.free_func(hp.heap_udata, (void*)rt.atom_index);
    rt.atoms = null;
    rt.atom_index = null;
}

// ============================================================================
// Error state
// ============================================================================

fn void clear_exception(Runtime* rt) {
    slot_release(rt, rt.exception);
    rt.exception = 0;
    rt.pending_code = 0;
    rt.pending_message[0] = 0;
}

fn void set_exception(Runtime* rt, TVal value) {
    ulong handle = slot_alloc(rt, value);
    clear_exception(rt);
    rt.exception = handle;
}

fn void set_err(Runtime* rt, int code, char[] msg) {
    clear_exception(rt);
    rt.pending_code = code;
    usz pending_len = min((usz)msg.len, ERRBUF - 1);
    mem::copy(&rt.pending_message, msg.ptr, (sz)pending_len);
    rt.pending_message[pending_len] = 0;
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

// Returns the current error message as a slice, excluding the trailing NUL.
fn char[] err_slice(Runtime* rt) {
    usz n = 0;
    while (n < ERRBUF && rt.errmsg[n] != 0) n++;
    return rt.errmsg[:n];
}

// Reads property `key` from `o` or its prototype chain, returning it only if
// it is a string. Walks the chain directly without invoking getters or Proxy
// traps, avoiding VM re-entry during unwind error formatting.
fn HString* str_prop(HObject* o, HString* key, Heap* h) {
    HObject* cur = o;
    int depth = 0;
    while (cur != null && depth < 16) {
        if (cur.is_proxy()) return null;
        int idx = cur.find_prop_idx((void*)key, h);
        if (idx >= 0) {
            // Accessor properties require VM execution, so treat as absent.
            if (cur.get_prop_flags((uint)idx, h).is_accessor) return null;
            TVal got = cur.prop_values()[idx].get();
            if (got.is_string()) return (HString*)got.get_heapptr();
            return null;
        }
        cur = cur.prototype;
        depth++;
    }
    return null;
}

// Formats a thrown value into the error buffer without re-entering the VM.
fn void describe_error(Runtime* rt, TVal* ev) {
    ulong held = slot_alloc(rt, *ev);
    defer {
        clear_exception(rt);
        rt.exception = held;
    }
    if (ev.is_string()) {
        char[ERRBUF] sbuf;
        HString* s = (HString*)ev.get_heapptr();
        set_err(rt, BK_ERR_THROW, sbuf[:s.utf8_copy_truncated(sbuf[..])]);
        return;
    }
    if (ev.is_undefined()) { set_err(rt, BK_ERR_THROW, "undefined"); return; }
    if (ev.is_null())      { set_err(rt, BK_ERR_THROW, "null"); return; }
    if (ev.is_boolean())   {
        set_err(rt, BK_ERR_THROW, ev.get_boolean() ? "true" : "false");
        return;
    }
    if (ev.is_numeric()) {
        // Format numbers directly into the buffer without VM re-entry or allocation.
        char[64] nbuf;
        usz n = builtins::json_number_to_string(ev.get_number_or_fastint(), &nbuf[0], 64);
        set_err(rt, BK_ERR_THROW, nbuf[:n]);
        return;
    }
    if (ev.is_object()) {
        HObject* o = (HObject*)ev.get_heapptr();
        HString* msg  = str_prop(o, rt.heap.strs[heap::BuiltinStr.MESSAGE], rt.heap);
        HString* name = str_prop(o, rt.heap.strs[heap::BuiltinStr.NAME], rt.heap);

        if (name != null && msg != null && msg.unit_len() != 0) {
            char[ERRBUF] buf;
            usz pos = 0;
            pos += name.utf8_copy_truncated(buf[:ERRBUF - 3]);
            buf[pos++] = ':';
            buf[pos++] = ' ';
            pos += msg.utf8_copy_truncated(buf[pos:ERRBUF - pos]);
            set_err(rt, BK_ERR_THROW, buf[:pos]);
            return;
        }
        char[ERRBUF] tbuf;
        HString* only = msg != null && msg.unit_len() != 0 ? msg : name;
        if (only != null && only.unit_len() != 0) {
            set_err(rt, BK_ERR_THROW, tbuf[:only.utf8_copy_truncated(tbuf[..])]);
            return;
        }
        set_err(rt, BK_ERR_THROW, "uncaught exception (object)");
        return;
    }
    set_err(rt, BK_ERR_THROW, "uncaught exception");
}

// ============================================================================
// Slot registry
// ============================================================================

// Grows the slot array. Returns false on allocation failure.
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

// Allocates a registry slot for `v` and returns its handle, or 0 on failure.
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
    // The registry can gain a handle after its current root cursor has passed.
    rt.heap.shade_root_tval(v);
    rt.slots[idx].v = v;
    rt.slots[idx].used = true;
    rt.live++;
    return ((ulong)rt.rt_id << RT_ID_SHIFT)
         | (((ulong)rt.slots[idx].gen & SLOT_GEN_MASK) << SLOT_INDEX_BITS)
         | ((ulong)idx + 1);
}

// Resolves a registry handle to its entry. Returns null if the handle is
// invalid, stale, freed, out of range, or from another runtime.
fn SlotEntry* slot_entry(Runtime* rt, ulong id) {
    if (rt == null || id == 0) return null;
    if ((id & SCOPE_HANDLE_BIT) != 0) return null;
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

// Releases a registry handle. Silently ignores scope or already-freed handles.
fn void slot_release(Runtime* rt, ulong id) {
    SlotEntry* e = slot_entry(rt, id);
    if (e == null) return;

    // A string whose only other owner is the intern table is garbage now. Small
    // strings do not count toward the GC trigger, so a host that only mints
    // strings would never reach a sweep; freeing here keeps the table bounded.
    // Inside a native frame a builtin may still borrow the raw pointer, so the
    // string is left for the sweep.
    if (e.v.is_string() && rt.heap.native_frame_depth == 0) {
        HeapHeader* hdr = (HeapHeader*)e.v.get_heapptr();
        hstring::HString* hs = (hstring::HString*)hdr;
        if (!hdr.is_pinned() && hs.flags.is_interned && hdr.refcount == 2) {
            rt.heap.str_table_remove(hs);
            rt.heap.free_string(hs);
            e.v.set_undefined();
        }
    }
    if (e.v.is_heap_allocated()) rt.heap.decref_tval(&e.v);
    e.v.set_undefined();
    e.used = false;
    if (rt.live > 0) rt.live--;

    // Retire the slot at SLOT_GEN_MAX rather than wrapping the generation.
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

// Scope handles name a rooted host frame independently of the API's target realm.
const uint SCOPE_INDEX_BITS = 17;
const ulong SCOPE_INDEX_MASK = (1ul << SCOPE_INDEX_BITS) - 1;

// The handle of slot `index` in the scope at `depth`.
fn ulong scope_handle(Runtime* rt, uint depth, ulong index) @inline {
    if (rt == null || depth >= rt.heap.host_scope_depth) return 0;
    ulong generation = (ulong)rt.heap.host_scope_generation_at(depth) & SLOT_GEN_MASK;
    return ((ulong)rt.rt_id << RT_ID_SHIFT) | SCOPE_HANDLE_BIT |
           (generation << SCOPE_INDEX_BITS) | ((ulong)depth << 32) | index;
}

fn bool resolve_handle(Runtime* rt, ulong id, TVal* out) {
    if (id <= IMM_FALSE) return immediate_get(id, out);
    if ((id & SCOPE_HANDLE_BIT) == 0) return slot_get(rt, id, out);
    if (rt == null || handle_rt_id(id) != (ulong)rt.rt_id) return false;
    uint depth = (uint)((id >> 32) & SLOT_GEN_MASK);
    uint generation = (uint)((id >> SCOPE_INDEX_BITS) & SLOT_GEN_MASK);
    if ((rt.heap.host_scope_generation_at(depth) & SLOT_GEN_MAX) != generation) return false;
    return rt.heap.host_scope_get(depth, (uint)(id & SCOPE_INDEX_MASK), out);
}

// The innermost scope when it collects local results, else null.
fn heap::HostScope* local_scope(Runtime* rt) @inline {
    Heap* h = rt.heap;
    if (h.host_scope_depth == 0) return null;
    heap::HostScope* sc = &h.host_scopes[h.host_scope_depth - 1];
    return sc.local ? sc : null;
}

// Stores `v` as a local of the innermost local scope, or as a registry root
// when there is none. Returns 0 when the scope or the registry is full.
fn ulong store_value(Runtime* rt, TVal v) {
    if (local_scope(rt) == null) return slot_alloc(rt, v);
    long index = rt.heap.host_scope_append(v);
    if (index < 0) return 0;
    return scope_handle(rt, rt.heap.host_scope_depth - 1, (ulong)index);
}

// Opens a local scope and returns its id, or 0 when the scope stack is full.
fn uint scope_open(Runtime* rt) {
    long depth = rt.heap.host_scope_push(0);
    if (depth < 0) return 0;
    heap::HostScope* sc = &rt.heap.host_scopes[depth];
    sc.local = true;
    sc.opened = true;
    return sc.generation;
}

// Closes the host-opened scope `id` and every scope opened inside it. A scope
// that is not open above the innermost host call is left alone; returns
// whether `id` was closed.
fn bool scope_close(Runtime* rt, uint id) {
    Heap* h = rt.heap;
    if (id == 0) return false;
    for (uint d = h.host_scope_depth; d > 0; d--) {
        heap::HostScope* sc = &h.host_scopes[d - 1];
        if (!sc.opened) return false;
        if (sc.generation != id) continue;
        while (h.host_scope_depth >= d) h.host_scope_pop();
        return true;
    }
    return false;
}

// Returns the Runtime associated with a BuiltinContext, or null.
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
    // Symbols share the string tag but classify as BK_TYPE_OTHER.
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

// Returns the byte length of `s` as standard UTF-8, excluding NUL.
fn usz utf8_len(HString* s) {
    return s.utf8_len();
}

// Writes `s` as standard UTF-8 into `buf`, truncated to leave room for the NUL
// the caller appends, and returns the bytes the complete text needs. Pass
// buf == null or cap == 0 to measure.
fn usz utf8_write(HString* s, char* buf, usz cap) {
    usz need = s.utf8_len();
    if (buf != null && cap > 1) {
        if (need < cap) {
            s.copy_utf8(buf);
        } else {
            s.utf8_copy_truncated(buf[:cap - 1]);
        }
    }
    return need;
}

// Reads `s` as UTF-8 for the C API, NUL-terminated on success. Sets `*length` to
// the byte count the complete text needs. A lone surrogate becomes U+FFFD, or
// fails with BK_ERR_ENCODING in strict mode.
fn int read_utf8(Runtime* rt, HString* s, bool strict, char* buf, usz cap, usz* length) {
    if (strict && !s.is_well_formed()) {
        set_err(rt, BK_ERR_ENCODING, "string holds a lone surrogate");
        return BK_ERR_ENCODING;
    }
    usz need = utf8_write(s, buf, buf == null ? 0 : cap);
    if (length != null) *length = need;
    if (buf == null) return BK_OK;
    if (need + 1 > cap) {
        set_err(rt, BK_ERR_FULL, "buffer too small for string");
        return BK_ERR_FULL;
    }
    buf[need] = 0;
    return BK_OK;
}

// Reads the code units of `s` into `buf`, with no terminator. Sets `*length` to
// the unit count, and fails with BK_ERR_FULL when `cap` is smaller.
fn int read_utf16(Runtime* rt, HString* s, ushort* buf, usz cap, usz* length) {
    uint n = s.unit_len();
    if (length != null) *length = n;
    if (buf == null) return BK_OK;
    if (n > cap) {
        set_err(rt, BK_ERR_FULL, "buffer too small for string");
        return BK_ERR_FULL;
    }
    s.copy_utf16(buf);
    return BK_OK;
}

// Builds a string from UTF-8 text. Invalid UTF-8 (overlong forms, surrogates,
// values past U+10FFFF, truncation) fails with BK_ERR_ENCODING.
fn HString* string_from_utf8(Runtime* rt, char[] utf8) {
    bool ascii = true;
    foreach (c : utf8) if (c >= 0x80) { ascii = false; break; }
    if (ascii) return intern_or_fail(rt, utf8);
    if (!hstring::utf8_valid(utf8)) {
        set_err(rt, BK_ERR_ENCODING, "invalid UTF-8");
        return null;
    }
    builtins::StrBuf sb;
    sb.init(rt.heap);
    defer sb.free();
    usz i = 0;
    while (i < utf8.len) {
        uint b0 = (uint)utf8[i];
        uint cp = b0;
        uint extra = 0;
        if (b0 >= 0xF0)      { cp = b0 & 0x07; extra = 3; }
        else if (b0 >= 0xE0) { cp = b0 & 0x0F; extra = 2; }
        else if (b0 >= 0xC0) { cp = b0 & 0x1F; extra = 1; }
        for (uint k = 1; k <= extra; k++) cp = (cp << 6) | ((uint)utf8[i + (usz)k] & 0x3F);
        sb.append_codepoint(cp);
        i += (usz)extra + 1;
    }
    return intern_builder(rt, &sb);
}

// Builds a string from ISO 8859-1 bytes, each byte being the code point of the same value.
fn HString* string_from_latin1(Runtime* rt, char[] chars) {
    HString* s = rt.heap.str_intern_latin1(chars);
    if (s == null) set_err(rt, BK_ERR_NOMEM, "out of memory");
    return s;
}

// Builds a string from UTF-16 code units, which may hold lone surrogates.
fn HString* string_from_utf16(Runtime* rt, ushort[] units) {
    HString* s = rt.heap.str_intern_utf16(units);
    if (s == null) set_err(rt, BK_ERR_NOMEM, "out of memory");
    return s;
}

// A string over the host buffer `data`, which the engine reads in place and
// hands back through `release` once the string is gone. Content that has no
// canonical external form, an empty buffer or UTF-16 holding only Latin-1
// units, is copied and the buffer released at once. Fails with BK_ERR_NOMEM
// before taking ownership of the buffer.
fn HString* string_external(Runtime* rt, hstring::Units data, hstring::ExtRelease release, void* udata) {
    HString* s;
    if (data.len == 0) {
        s = rt.heap.str(heap::BuiltinStr.EMPTY);
    } else if (data.wide && !hstring::has_unit_above_latin1(data)) {
        s = rt.heap.str_intern_utf16(((ushort*)data.ptr)[:data.len]);
    } else {
        s = rt.heap.alloc_external_string(data, release, udata);
        if (s == null) set_err(rt, BK_ERR_NOMEM, "out of memory");
        return s;
    }
    if (s == null) {
        set_err(rt, BK_ERR_NOMEM, "out of memory");
        return null;
    }
    if (release != null) release(udata, data.ptr, data.len);
    return s;
}

fn HString* intern_or_fail(Runtime* rt, char[] text) {
    HString* s = rt.heap.str_intern(text);
    if (s == null) set_err(rt, BK_ERR_NOMEM, "out of memory");
    return s;
}

fn HString* intern_builder(Runtime* rt, builtins::StrBuf* sb) {
    if (sb.failed) { set_err(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    return intern_or_fail(rt, sb.bytes());
}

// ============================================================================
// Host functions
// ============================================================================

alias BkCFunction = fn ulong(void*, ulong, uint, ulong*, void*);

struct HostPayload {
    HostPayload* next;
}

struct HostReg {
    HostPayload lifetime;
    void* cfn;
    void* udata;
}

// Arguments and the returned handle borrow the call scope or the registry.
fn void host_trampoline(builtins::BuiltinContext* bctx, void* udata) {
    HostReg* reg = (HostReg*)udata;
    if (reg == null || reg.cfn == null) return;
    Runtime* rt = ctx_runtime(bctx);
    Ctx* ctx = realm_context(rt, bctx.heap.realm);
    if (ctx == null) { builtins::host_throw_error(bctx, builtins::HOST_ERR_ERROR, "missing host context"); return; }
    Ctx* previous = rt.active;
    heap::Realm* previous_realm = rt.heap.realm;
    void* previous_call = ctx.bctx;
    select_context(ctx);
    ctx.bctx = bctx;
    // Values the callback creates are locals of its call scope.
    uint call_depth = bctx.host_scope_slot - 1;
    rt.heap.host_scopes[call_depth].local = true;
    defer {
        ctx.bctx = previous_call;
        select_context(previous);
        rt.heap.enter_realm(previous_realm);
    }
    ulong result = call_c_function(rt, ctx, bctx, reg);
    select_context(ctx);
    if (rt.heap.uncatchable_throw) {
        builtins::host_throw(bctx, rt.heap.error_value);
        return;
    }
    if (result == 0) {
        TVal thrown;
        ulong exception = take_exception(rt);
        if (slot_get(rt, exception, &thrown)) {
            builtins::host_throw(bctx, thrown);
            // The native dispatch borrows throw_value after this trampoline returns.
            if (thrown.is_refcounted()) rt.heap.@set_edge(null, rt.heap.error_value, thrown);
            slot_release(rt, exception);
        } else {
            builtins::host_throw_error(bctx, builtins::HOST_ERR_ERROR, "C function failed without an exception");
        }
        return;
    }
    TVal value;
    if (!resolve_handle(rt, result, &value)) {
        builtins::host_throw_error(bctx, builtins::HOST_ERR_TYPE, "C function returned an invalid or freed handle");
        return;
    }
    builtins::host_return(bctx, value);
}

// A bk_c_function receives this/argv as scope handles and returns a borrowed handle.
fn ulong call_c_function(Runtime* rt, Ctx* ctx, builtins::BuiltinContext* bctx, HostReg* reg) {
    uint argc = builtins::host_argc(bctx);
    ulong[16] local_args;
    ulong* args = &local_args;
    if (argc > local_args.len) {
        args = (ulong*)rt.heap.alloc_func(rt.heap.heap_udata, (usz)argc * ulong::size);
        if (args == null) { set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    }
    defer if (args != &local_args) rt.heap.free_func(rt.heap.heap_udata, args);
    uint depth = bctx.host_scope_slot - 1;
    for (uint i = 0; i < argc; i++) args[i] = scope_handle(rt, depth, (ulong)(heap::HOST_SCOPE_ARG0 + i));
    BkCFunction fnp = (BkCFunction)reg.cfn;
    return fnp(ctx, scope_handle(rt, depth, heap::HOST_SCOPE_THIS), argc, args, reg.udata);
}

// Returns a ring buffer of at least need+1 bytes for bk_cstr, or null.
fn char* cstr_slot(Runtime* rt, usz need) {
    uint i = rt.cstr_next;
    rt.cstr_next = (i + 1) % (uint)CSTR_RING;
    usz want = need + 1;
    if (rt.cstr_cap[i] < want) {
        usz cap = rt.cstr_cap[i] == 0 ? 64 : rt.cstr_cap[i];
        while (cap < want) cap *= 2;
        void* raw = rt.heap.realloc_func(rt.heap.heap_udata, (void*)rt.cstr_buf[i], cap);
        if (raw == null) return null;
        rt.cstr_buf[i] = (char*)raw;
        rt.cstr_cap[i] = cap;
    }
    return rt.cstr_buf[i];
}

fn int make_c_function(Runtime* rt, char[] name, void* cfn, void* udata,
                       int arity, bool constructable, TVal* out) {
    void* raw = rt.heap.alloc_func(rt.heap.heap_udata, HostReg::size);
    if (raw == null) { set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    HostReg* reg = (HostReg*)raw;
    *reg = { .cfn = cfn, .udata = udata };
    return make_fn_value(rt, name, (void*)&host_trampoline, reg, arity, constructable, out);
}

// ============================================================================
// Eval
// ============================================================================

// Compiles and runs `src`, writing the completion value to `*out`. Sets
// `*out_owned` when `*out` carries a reference the caller must release.
// Returns a BK_* status.
fn int eval_source(Runtime* rt, char[] src, char[] name, TVal* out, bool* out_owned, bool strict = false) {
    *out_owned = false;
    clear_err(rt);
    if (name.len != 0) set_script_name(rt, &name[0], name.len);
    // Reset interrupt state before starting execution.
    rt.heap.uncatchable_throw = false;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;

    Lexer lex = lexer::lexer_init(src, rt.heap, name.len != 0 ? name : (char[])"<eval>");
    lex.skip_hashbang();
    // Both modes capture the top-level completion value. Sloppy source runs as
    // indirect eval code. Strict source runs as a strict global Script: strict
    // eval code would give every call its own variable environment, so a
    // declared function would not outlive the call that declared it.
    CompiledFunction*? fr = strict
        ? compiler::compile(&lex, rt.heap, true, false, true)
        : compiler::compile_eval(&lex, rt.heap);
    if (catch fr) {
        // Copy compiler error message before lexer arena teardown.
        char* m = &lex.err_msg[0];
        usz n = 0;
        while (m[n] != 0 && n < ERRBUF - 1) n++;
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
    if (rt.vm.run_depth > 0) {
        // A host callback is evaluating source while a script runs. The
        // top-level entry would take over activations[0] under the running
        // script, so run it as a nested global Script, as $262.evalScript does.
        HObject* pending = null;
        TVal completion;
        completion.set_undefined();
        bool? ok = rt.vm.execute_module_nested(f, rt.vm.global_env, &pending, &completion);
        lex.free_arena();
        if (catch ok) {
            set_err(rt, BK_ERR_INTERNAL, "internal VM error");
            return BK_ERR_INTERNAL;
        }
        if (!ok) {
            rt.heap.has_error = false;
            rt.vm.has_error = false;
            if (rt.heap.uncatchable_throw) {
                return interrupt_status(rt);
            }
            return throw_status(rt);
        }
        *out = completion;
        *out_owned = true;
        return BK_OK;
    }
    TVal? res = rt.vm.execute(f);
    lex.free_arena();

    if (catch res) {
        if (rt.heap.uncatchable_throw) {
            return interrupt_status(rt);
        }
        if (rt.heap.has_error) {
            return throw_status(rt);
        }
        set_err(rt, BK_ERR_INTERNAL, "internal VM error");
        return BK_ERR_INTERNAL;
    }

    *out = res;
    return BK_OK;
}

// Compile `src` as a new top-level module named `name`, link and evaluate it,
// leaving queued jobs to the host. `*out` receives its namespace object.
fn int eval_module(Runtime* rt, char[] src, char[] name, TVal* out) {
    clear_err(rt);
    if (name.len != 0) set_script_name(rt, &name[0], name.len);
    rt.heap.uncatchable_throw = false;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
    rt.heap.has_error = false;
    rt.heap.error_value.set_undefined();

    esm::ModuleDef*? loaded = esm::load_module_source(rt.heap, name, src, true);
    if (catch err = loaded) return module_failure(rt, BK_ERR_SYNTAX);
    esm::ModuleDef* mod = loaded;
    int rc = esm::run_module(rt.heap, rt.vm, mod);
    // run_module returns 1 for a thrown value and 2 for a failed link, which
    // parks a SyntaxError when an import does not resolve.
    if (rc != 0) return module_failure(rt, rc == 1 ? BK_ERR_THROW : BK_ERR_SYNTAX);

    HObject*? ns = esm::build_namespace_object(rt.heap, mod);
    if (catch err = ns) {
        set_err(rt, BK_ERR_NOMEM, "out of memory");
        return BK_ERR_NOMEM;
    }
    out.set_object(ns);
    return BK_OK;
}

// Report a failed module load or evaluation as `code`, from whatever the heap
// error channel holds, and clear the channel.
fn int module_failure(Runtime* rt, int code) @local {
    Heap* h = rt.heap;
    if (h.uncatchable_throw) {
        finish_interrupt(rt);
        code = BK_ERR_INTERRUPT;
        set_err(rt, code, "interrupted");
    } else if (h.has_error || !h.error_value.is_undefined()) {
        describe_error(rt, &h.error_value);
        rt.errcode = code;
    } else {
        // A dependency that could not be read leaves no error value behind.
        set_err(rt, code, "could not load module");
    }
    h.error_value.set_undefined();
    h.has_error = false;
    return code;
}

// Executes pending microtasks. Returns BK_OK or BK_ERR_INTERRUPT.
fn int drain_microtasks(Runtime* rt) {
    clear_err(rt);
    rt.heap.uncatchable_throw = false;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
    rt.heap.drain_microtasks((void*)rt.vm, force: true);
    if (rt.heap.uncatchable_throw) {
        return interrupt_status(rt);
    }
    return BK_OK;
}

// ============================================================================
// String coercion
// ============================================================================

// Converts `v` to a string via JavaScript ToString coercion. Returns a BK_* status.
fn int to_string(Runtime* rt, TVal v, HString** out) {
    clear_err(rt);
    rt.heap.has_error = false;
    HString*? s = vm::vm_to_string(rt.vm, &v);
    if (catch s) {
        if (rt.heap.uncatchable_throw) {
            return interrupt_status(rt);
        }
        if (rt.heap.has_error) {
            return throw_status(rt);
        }
        set_err(rt, BK_ERR_INTERNAL, "could not convert value to string");
        return BK_ERR_INTERNAL;
    }
    *out = s;
    return BK_OK;
}

// ============================================================================
// Function values
// ============================================================================

// Creates an unbound host-function object. Returns a BK_* status.
fn int make_fn_value(Runtime* rt, char[] name, void* trampoline, void* reg_udata,
                     int arity, bool constructable, TVal* out) {
    // Registration records begin with HostPayload and transfer to the runtime.
    HostPayload* payload = (HostPayload*)reg_udata;
    payload.next = rt.host_payloads;
    rt.host_payloads = payload;
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

fn int install_fn(Runtime* rt, char[] name, void* trampoline, void* payload, int arity, bool constructable) {
    TVal value;
    int rc = make_fn_value(rt, name, trampoline, payload, arity, constructable, &value);
    return rc == BK_OK ? declare_global(rt, name, value) : rc;
}

// Declares `name` in the global environment bound to `v`.
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
        case BK_ERR_ENCODING:  return "ENCODING";
        case BK_ERR_UNSUPPORTED: return "UNSUPPORTED";
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

// Retire VM throw channels at the host boundary so the next dispatch cannot
// re-fire a termination while coercing a value or entering a builtin.
fn void finish_interrupt(Runtime* rt) {
    if (rt.vm.run_depth != 0) return;
    rt.heap.uncatchable_throw = false;
    rt.heap.has_error = false;
    rt.vm.has_error = false;
    rt.vm.throw_pending = false;
    rt.heap.decref_tval(&rt.vm.throw_value);
    rt.vm.throw_value.set_undefined();
}

// Report a watchdog timeout or uncatchable throw as a BK_ERR_INTERRUPT status,
// clearing the pending interrupt first.
fn int interrupt_status(Runtime* rt) @local {
    finish_interrupt(rt);
    set_err(rt, BK_ERR_INTERRUPT, "interrupted");
    return BK_ERR_INTERRUPT;
}

// Describe the pending heap error into the runtime and report it as a throw.
fn int throw_status(Runtime* rt) @local {
    describe_error(rt, &rt.heap.error_value);
    return BK_ERR_THROW;
}
