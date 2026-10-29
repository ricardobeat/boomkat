module boomkat::capi @feat(!BYTECODE_ONLY);

import boomkat::agent;
import boomkat::builtins;
import boomkat::embed;
import boomkat::esm;
import boomkat::features;
import boomkat::vm;
import boomkat::heap;
import boomkat::lexer;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::bytecode;
import boomkat::types;
import libc;

// C ABI marshalling over the shared embedding core. Context selection owns
// per-realm error state; the runtime owns registry roots and callback payloads.

alias Runtime = embed::Runtime;
alias Ctx     = embed::Ctx;

const int BK_OK            = embed::BK_OK;
const int BK_ERR_NOMEM     = embed::BK_ERR_NOMEM;
const int BK_ERR_SYNTAX    = embed::BK_ERR_SYNTAX;
const int BK_ERR_THROW     = embed::BK_ERR_THROW;
const int BK_ERR_INTERNAL  = embed::BK_ERR_INTERNAL;
const int BK_ERR_INVALID   = embed::BK_ERR_INVALID;
const int BK_ERR_TYPE      = embed::BK_ERR_TYPE;
const int BK_ERR_FULL      = embed::BK_ERR_FULL;
const int BK_ERR_INTERRUPT = embed::BK_ERR_INTERRUPT;
const int BK_ERR_ENCODING  = embed::BK_ERR_ENCODING;
const int BK_ERR_UNSUPPORTED = embed::BK_ERR_UNSUPPORTED;

const int BK_UTF8_REPLACE = 0;
const int BK_UTF8_STRICT  = 1;

const int BK_TYPE_UNDEFINED = embed::BK_TYPE_UNDEFINED;


// ============================================================================
// Context plumbing
// ============================================================================

// The runtime behind a context, or null if the context is null.
fn Runtime* rt_of(void* p) @inline {
    if (p == null) return null;
    Ctx* ctx = (Ctx*)p;
    embed::select_context(ctx);
    return ctx.rt;
}

// The live call behind a context, or null outside a callback.
macro void* bctx_of(void* p) => p == null ? null : ((Ctx*)p).bctx;

// Record a failure and hand back its code, so a caller can `return fail(...)`.
// Every failing entry point goes through here or through embed::set_err, which
// is what lets a host log bk_get_error_message unconditionally on a bad status.
fn int fail(Runtime* rt, int code, String msg) {
    if (rt != null) embed::set_err(rt, code, msg);
    return code;
}

// Resolve a handle against this context: the registry for an owned handle, the
// live call's scope for an argument handle.
fn bool resolve(void* ctxp, ulong id, TVal* out) {
    return embed::resolve_handle(rt_of(ctxp), id, out);
}

// Store a value and return its handle, or 0 with the failure recorded: a local
// of the innermost local scope, else a registry root. Undefined, null and
// booleans return their immediate handle. Reports exhaustion for every value kind, undefined included:
// handle 0 reads back as undefined, so returning it for a failed registration
// would be a silent wrong answer rather than an error.
fn ulong store(Runtime* rt, TVal v) {
    ulong imm = embed::immediate_of(v);
    if (imm != 0) return imm;
    ulong id = embed::store_value(rt, v);
    if (id == 0) embed::set_err(rt, BK_ERR_FULL, embed::local_scope(rt) != null ? "local scope full" : "value registry full");
    return id;
}

// Store `v` as a registry root whatever scope is open.
fn ulong store_root(Runtime* rt, TVal v) {
    ulong imm = embed::immediate_of(v);
    if (imm != 0) return imm;
    ulong id = embed::slot_alloc(rt, v);
    if (id == 0) embed::set_err(rt, BK_ERR_FULL, "value registry full");
    return id;
}

// A handle argument that did not resolve. Records the reason and yields 0, so
// the value-returning entry points can `return bad_handle(rt)`.
fn ulong fail_value(Runtime* rt, int code, String msg) {
    fail(rt, code, msg);
    return 0;
}

fn ulong bad_handle(Runtime* rt) {
    fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    return 0;
}

// ============================================================================
// Lifecycle
// ============================================================================

// Mirrors bk_runtime_options in boomkat.h.
struct BkRuntimeOptions {
    heap::AllocFunc   alloc;
    heap::ReallocFunc realloc;
    heap::FreeFunc    free;
    void*             alloc_opaque;
    heap::FatalFunc   fatal;
    ulong             heap_limit;
}

// A runtime with the given allocator and fatal handler, or the defaults when
// `options` is null. The allocator functions come as a set: all or none.
fn void* bk_new_runtime(BkRuntimeOptions* options) @export("bk_new_runtime") {
    if (options == null) return embed::create();
    bool some = options.alloc != null || options.realloc != null || options.free != null;
    bool all = options.alloc != null && options.realloc != null && options.free != null;
    if (some && !all) return null;
    return embed::create(options.alloc, options.realloc, options.free, options.alloc_opaque, options.fatal,
                         options.heap_limit);
}

fn void* bk_alloc(void* rtp, usz size) @export("bk_alloc") {
    if (rtp == null) return null;
    Heap* h = ((Runtime*)rtp).heap;
    return h.alloc_func(h.heap_udata, size);
}

fn void* bk_realloc(void* rtp, void* ptr, usz size) @export("bk_realloc") {
    if (rtp == null) return null;
    Heap* h = ((Runtime*)rtp).heap;
    if (ptr == null) return h.alloc_func(h.heap_udata, size);
    if (size == 0) { h.free_func(h.heap_udata, ptr); return null; }
    return h.realloc_func(h.heap_udata, ptr, size);
}

fn void bk_free_memory(void* rtp, void* ptr) @export("bk_free_memory") {
    if (rtp == null || ptr == null) return;
    Heap* h = ((Runtime*)rtp).heap;
    h.free_func(h.heap_udata, ptr);
}

// A context that owns its runtime; bk_destroy releases both.
fn void* bk_create() @export("bk_create") {
    Runtime* rt = embed::create();
    if (rt == null) return null;
    Ctx* ctx = embed::new_context(rt);
    if (ctx == null) { embed::destroy(rt); return null; }
    rt.owned_by_context = true;
    return ctx;
}

fn void bk_destroy(void* ctxp) @export("bk_destroy") {
    if (ctxp == null) return;
    Ctx* ctx = (Ctx*)ctxp;
    if (ctx.bctx != null) return;
    if (ctx.rt.owned_by_context) { embed::destroy(ctx.rt); return; }
    embed::free_context(ctx);
}

// Mirrors bk_context_options in boomkat.h.
struct BkContextOptions {
    uint  flags;
    uint  global_class;
    void* global_payload;
}

const uint CONTEXT_FLAGS = embed::CONTEXT_NO_EVAL | embed::CONTEXT_CANNOT_BLOCK;

// A context with `options`, or the defaults when it is null. A host-class
// global object owns `global_payload` from the moment the context exists.
fn void* bk_new_context(void* rtp, BkContextOptions* options) @export("bk_new_context") {
    if (rtp == null) return null;
    Runtime* rt = (Runtime*)rtp;
    if (options == null) return embed::new_context(rt);
    if ((options.flags & ~CONTEXT_FLAGS) != 0) return null;
    HObject* global = null;
    HObject* proto = null;
    if (options.global_class != 0) {
        heap::HostClassEntry* e = api_class(rt, options.global_class);
        if (e == null) return null;
        HObject*? raw = rt.heap.alloc_object(hobject::ObjClass.HOST);
        if (catch raw) return null;
        global = raw;
        (*global.extra_ptr()).host.class_id = options.global_class - 1;
        (*global.extra_ptr()).host.payload = options.global_payload;
        proto = e.proto;
    }
    return embed::new_context(rt, options.flags, global, proto);
}

fn void bk_free_runtime(void* rtp) @export("bk_free_runtime") => embed::destroy((Runtime*)rtp);

fn void bk_free_context(void* ctxp) @export("bk_free_context") => embed::free_context((Ctx*)ctxp);

fn void* bk_get_runtime(void* ctxp) @export("bk_get_runtime") => ctxp == null ? null : ((Ctx*)ctxp).rt;

fn void bk_set_runtime_data(void* rtp, uint slot, void* data) @export("bk_set_runtime_data") {
    if (rtp != null && slot < embed::DATA_SLOTS) ((Runtime*)rtp).data[slot] = data;
}

fn void* bk_get_runtime_data(void* rtp, uint slot) @export("bk_get_runtime_data") {
    if (rtp == null || slot >= embed::DATA_SLOTS) return null;
    return ((Runtime*)rtp).data[slot];
}

fn void bk_set_context_data(void* ctxp, uint slot, void* data) @export("bk_set_context_data") {
    Runtime* rt = rt_of(ctxp);
    if (rt != null && slot < embed::DATA_SLOTS) rt.context_data[slot] = data;
}

fn void* bk_get_context_data(void* ctxp, uint slot) @export("bk_get_context_data") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || slot >= embed::DATA_SLOTS) return null;
    return rt.context_data[slot];
}

fn char* bk_version() @export("bk_version") {
    return "0.2.0";
}

// ============================================================================
// Eval
// ============================================================================

// A compiled script is a HOST object of an internal class whose payload is the
// CompiledFunction, which the heap owns until it is destroyed.
fn ulong bk_compile(void* ctxp, char* src, usz len, char* filename, uint flags) @export("bk_compile") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (src == null || (flags & ~2u) != 0) return fail_value(rt, BK_ERR_INVALID, "invalid source or compile flags");
    Heap* hp = rt.heap;
    if (rt.script_class == 0) {
        long id = hp.register_host_class(null, null, null, (void*)hp.str(heap::BuiltinStr.EMPTY), null);
        if (id < 0) return fail_value(rt, BK_ERR_NOMEM, "host class table full");
        rt.script_class = (uint)id + 1;
    }
    char[] name = filename != null ? ((ZString)filename).str_view() : (char[])"<eval>";
    bytecode::CompiledFunction* f;
    if (embed::compile_script(rt, src[:len], name, (flags & 2u) != 0, &f) != BK_OK) return 0;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.HOST);
    if (catch raw) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    HObject* script = raw;
    hp.set_prototype(script, null);
    (*script.extra_ptr()).host.class_id = rt.script_class - 1;
    (*script.extra_ptr()).host.payload = (void*)f;
    TVal v; v.set_object(script);
    return store(rt, v);
}

// Runs a compiled script in this context, as bk_eval_ex would its source.
fn ulong bk_run_script(void* ctxp, ulong id) @export("bk_run_script") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    HObject* o = v.is_object() ? (HObject*)v.get_heapptr() : null;
    if (o == null || rt.script_class == 0 || o.get_class() != hobject::ObjClass.HOST
        || (*o.extra_ptr()).host.class_id != rt.script_class - 1) {
        return fail_value(rt, BK_ERR_TYPE, "not a compiled script");
    }
    TVal result;
    bool owned;
    if (embed::run_script(rt, (bytecode::CompiledFunction*)(*o.extra_ptr()).host.payload, &result, &owned) != BK_OK) return 0;
    ulong out = store(rt, result);
    if (owned) rt.heap.decref_tval(&result);
    return out;
}

fn ulong bk_eval_ex(void* ctxp, char* src, usz len, char* filename, uint flags) @export("bk_eval_ex") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (src == null || (flags & ~3u) != 0) { fail(rt, BK_ERR_INVALID, "invalid source or eval flags"); return 0; }
    char[] name = filename != null ? ((ZString)filename).str_view() : (char[])"<eval>";
    TVal result;
    bool owned;
    int rc;
    if ((flags & 1u) != 0) {
        rc = embed::eval_module(rt, src[:len], name, &result);
    } else {
        rc = embed::eval_source(rt, src[:len], name, &result, &owned, strict: (flags & 2u) != 0);
    }
    if (rc != BK_OK) return 0;
    ulong id = store(rt, result);
    if (owned) rt.heap.decref_tval(&result);
    return id;
}





// Copy the C string `s` (or nothing when NULL) to `*at` in the runtime's JSX buffer.
fn char[] jsx_copy(char* s, char** at) {
    if (s == null) return {};
    sz n = ((ZString)s).len();
    char[] out = (*at)[:(usz)n];
    mem::copy(*at, s, n);
    *at += n;
    return out;
}

fn int bk_set_jsx(void* ctxp, int enable, int runtime, char* import_source, char* factory, char* fragment)
        @export("bk_set_jsx") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || runtime < 0 || runtime > 2) return BK_ERR_INVALID;
    usz total = 1;
    char*[3] strings = { import_source, factory, fragment };
    foreach (s : strings) {
        if (s != null) total += (usz)((ZString)s).len();
    }
    Heap* h = rt.heap;
    char* buf = (char*)h.alloc_func(h.heap_udata, total);
    if (buf == null) return BK_ERR_NOMEM;
    char* at = buf;
    lexer::JsxOptions o;
    o.enabled = enable != 0;
    o.runtime = (lexer::JsxRuntime)runtime;
    o.import_source = jsx_copy(import_source, &at);
    o.factory = jsx_copy(factory, &at);
    o.fragment = jsx_copy(fragment, &at);
    o.imply_runtime();
    if (rt.jsx_buf != null) h.free_func(h.heap_udata, (void*)rt.jsx_buf);
    rt.jsx_buf = buf;
    h.jsx = o;
    return BK_OK;
}



fn int bk_define_module(void* ctxp, char* name, usz name_len, char* src, usz len)
        @export("bk_define_module") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    if (name == null || name_len == 0 || src == null) {
        return fail(rt, BK_ERR_INVALID, "bk_define_module: missing name or source");
    }
    if (!esm::define_module(rt.heap, name[:name_len], src[:len])) {
        return fail(rt, BK_ERR_NOMEM, "out of memory");
    }
    return BK_OK;
}

// ============================================================================
// Module loader and native modules
// ============================================================================

const uint BK_LOADER_ASYNC = 1;
const uint BK_LOADER_NO_FILESYSTEM_FALLBACK = 2;

alias BkResolveFn = fn int(void* ctx, char* referrer, char* specifier, ModuleRequest* request, void* opaque);
alias BkLoadFn    = fn int(void* ctx, char* name, ModuleRequest* request, void* opaque);

// One question to the host loader, answered through bk_module_* before the
// callback returns.
struct ModuleRequest {
    Runtime* rt;
    char[]   name;        // set by bk_module_set_name; malloc'd
    char[]   source;      // set by bk_module_provide; heap payload memory
    char[]   for_name;    // the module a load asks for
    bool     answered;
    bool     failed;
    TVal     error;
}

// `bytes` as a NUL-terminated malloc'd string, or null.
fn char* cstr_copy(char[] bytes) {
    char* out = (char*)libc::malloc(bytes.len + 1);
    if (out == null) return null;
    if (bytes.len > 0) mem::copy(out, bytes.ptr, (sz)bytes.len);
    out[bytes.len] = 0;
    return out;
}

// Parks the host's failure as the pending module error.
fn void park_module_error(Runtime* rt, ModuleRequest* req) {
    if (!req.failed) return;
    rt.heap.shade_root_tval(req.error);
    rt.heap.error_value = req.error;
    rt.heap.has_error = true;
}

fn char[]? loader_resolve(char[] base_name, char[] specifier, void* udata) {
    Runtime* rt = (Runtime*)udata;
    ModuleLoader* l = &rt.module_loader;
    bool fallback = (l.flags & BK_LOADER_NO_FILESYSTEM_FALLBACK) == 0;
    if (l.resolve == null) {
        if (!fallback) return esm::MODULE_ERROR~;
        return esm::default_resolve_name(base_name, specifier);
    }
    char* ref = cstr_copy(base_name);
    char* spec = cstr_copy(specifier);
    defer { libc::free(ref); libc::free(spec); }
    if (ref == null || spec == null) return esm::MODULE_ERROR~;
    ModuleRequest req = { .rt = rt };
    int rc = ((BkResolveFn)l.resolve)(rt.active, ref, spec, &req, l.opaque);
    if (rc == BK_OK && req.name.ptr != null) return req.name;
    if (req.name.ptr != null) libc::free(req.name.ptr);
    if (rc == BK_OK && !req.failed && fallback) return esm::default_resolve_name(base_name, specifier);
    park_module_error(rt, &req);
    return esm::MODULE_ERROR~;
}

fn char[]? loader_load(char[] name, void* udata) {
    Runtime* rt = (Runtime*)udata;
    ModuleLoader* l = &rt.module_loader;
    bool fallback = (l.flags & BK_LOADER_NO_FILESYSTEM_FALLBACK) == 0;
    if (l.load == null) {
        if (!fallback) return esm::MODULE_ERROR~;
        return esm::default_module_read(name, null);
    }
    char* n = cstr_copy(name);
    defer libc::free(n);
    if (n == null) return esm::MODULE_ERROR~;
    ModuleRequest req = { .rt = rt, .for_name = name };
    int rc = ((BkLoadFn)l.load)(rt.active, n, &req, l.opaque);
    if (rc == BK_OK && req.source.ptr != null) return req.source;
    // A native answer has defined the module; the loader finds it in the cache.
    if (rc == BK_OK && req.answered && !req.failed) return esm::MODULE_ERROR~;
    if (rc == BK_OK && !req.failed && fallback) return esm::default_module_read(name, null);
    park_module_error(rt, &req);
    return esm::MODULE_ERROR~;
}

fn int bk_set_module_loader(void* runtime, embed::ModuleLoader* loader) @export("bk_set_module_loader") {
    if (runtime == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)runtime;
    if (loader == null) {
        rt.module_loader = {};
        rt.heap.set_module_hooks(null);
        return BK_OK;
    }
    if ((loader.flags & ~(BK_LOADER_ASYNC | BK_LOADER_NO_FILESYSTEM_FALLBACK)) != 0) return BK_ERR_INVALID;
    if ((loader.flags & BK_LOADER_ASYNC) != 0) return BK_ERR_UNSUPPORTED;
    rt.module_loader = *loader;
    rt.module_hooks = { .resolve_name = &loader_resolve, .read_source = &loader_load, .udata = (void*)rt };
    rt.heap.set_module_hooks(&rt.module_hooks);
    return BK_OK;
}

fn int bk_module_set_name(ModuleRequest* req, char* name, usz len) @export("bk_module_set_name") {
    if (req == null || name == null || len == 0 || req.answered) return BK_ERR_INVALID;
    char* copy = cstr_copy(name[:len]);
    if (copy == null) return BK_ERR_NOMEM;
    req.name = copy[:len];
    req.answered = true;
    return BK_OK;
}

// The source is copied into memory the runtime frees when it is destroyed;
// the module keeps referring to it for as long as it lives.
fn int bk_module_provide(ModuleRequest* req, char* source, usz len) @export("bk_module_provide") {
    if (req == null || (source == null && len != 0) || req.answered || req.for_name.ptr == null) return BK_ERR_INVALID;
    Runtime* rt = req.rt;
    void* raw = rt.heap.alloc_func(rt.heap.heap_udata, embed::HostPayload::size + len + 1);
    if (raw == null) return BK_ERR_NOMEM;
    embed::HostPayload* payload = (embed::HostPayload*)raw;
    payload.next = rt.host_payloads;
    rt.host_payloads = payload;
    char* text = (char*)raw + embed::HostPayload::size;
    if (len > 0) mem::copy(text, source, (sz)len);
    text[len] = 0;
    req.source = text[:len];
    req.answered = true;
    return BK_OK;
}

// Collects own enumerable string-keyed properties of `exports` (reading them
// with [[Get]]) plus `default`, and defines the module.
fn int define_native(Runtime* rt, char[] name, TVal exports) {
    if (!exports.is_object()) return fail(rt, BK_ERR_TYPE, "exports must be an object");
    Heap* hp = rt.heap;
    TVal keys;
    TVal undefined; undefined.set_undefined();
    int rc = call_builtin(rt, builtins::Builtin.OBJECT_KEYS, undefined, &exports, 1, &keys);
    if (rc != BK_OK) return rc;
    HObject* karr = (HObject*)keys.get_heapptr();
    ulong keys_held = embed::slot_alloc(rt, keys);
    defer embed::slot_release(rt, keys_held);
    ulong count;
    rc = length_of(rt, karr, &count);
    if (rc != BK_OK) return rc;
    char[][] names = mem::new_array(char[], (sz)(count + 1));
    TVal[] values = mem::new_array(TVal, (sz)(count + 1));
    // Registry roots keep values read so far alive while later getters run.
    ulong[] held = mem::new_array(ulong, (sz)(count + 1));
    defer {
        foreach (n : names) if (n.ptr != null) mem::free(n.ptr);
        foreach (h : held) if (h != 0) embed::slot_release(rt, h);
        mem::free(names.ptr);
        mem::free(values.ptr);
        mem::free(held.ptr);
    }
    usz used = 0;
    bool has_default = false;
    HObject* eo = (HObject*)exports.get_heapptr();
    for (ulong i = 0; i < count; i++) {
        TVal kv;
        hp.has_error = false;
        char[24] digits;
        usz nd = 0;
        ulong x = i;
        do { digits[23 - nd++] = (char)('0' + x % 10); x /= 10; } while (x != 0);
        HString* index = hp.str_intern(digits[24 - nd:nd]);
        if (index == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
        if (!builtins::js_get_with_receiver((void*)rt.vm, hp, karr, index, keys, &kv)) return vm_fault(rt);
        if (!kv.is_string()) continue;
        HString* key = (HString*)kv.get_heapptr();
        if (!builtins::js_get_with_receiver((void*)rt.vm, hp, eo, key, exports, &values[used])) return vm_fault(rt);
        held[used] = embed::slot_alloc(rt, values[used]);
        char[] buf = mem::new_array(char, (sz)key.unit_len() * 3 + 1);
        names[used] = buf[:key.write_cesu8(buf)];
        if (names[used] == "default") has_default = true;
        used++;
    }
    if (!has_default) {
        char[] buf = mem::new_array(char, 8);
        mem::copy(buf.ptr, "default", 7);
        names[used] = buf[:7];
        values[used] = exports;
        used++;
    }
    if (!esm::define_native_module(hp, name, names[:used], values[:used])) return fail(rt, BK_ERR_NOMEM, "out of memory");
    return BK_OK;
}

fn int bk_module_provide_native(ModuleRequest* req, ulong exports) @export("bk_module_provide_native") {
    if (req == null || req.answered || req.for_name.ptr == null) return BK_ERR_INVALID;
    Runtime* rt = req.rt;
    TVal v;
    if (!embed::resolve_handle(rt, exports, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    int rc = define_native(rt, req.for_name, v);
    if (rc == BK_OK) req.answered = true;
    return rc;
}

fn int bk_module_fail(ModuleRequest* req, ulong error) @export("bk_module_fail") {
    if (req == null || req.answered) return BK_ERR_INVALID;
    TVal v;
    if (!embed::resolve_handle(req.rt, error, &v)) return BK_ERR_INVALID;
    req.error = v;
    req.failed = true;
    req.answered = true;
    return BK_OK;
}

fn int bk_define_native_module(void* ctxp, char* name, usz len, ulong exports) @export("bk_define_native_module") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    if (name == null || len == 0) return fail(rt, BK_ERR_INVALID, "missing module name");
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, exports, &v)) { bad_handle(rt); return BK_ERR_INVALID; }
    return define_native(rt, name[:len], v);
}

fn int bk_invalidate_module(void* ctxp, char* name, usz len) @export("bk_invalidate_module") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    if (name == null || len == 0) return fail(rt, BK_ERR_INVALID, "missing module name");
    embed::clear_err(rt);
    if (!esm::invalidate_module(rt.heap, name[:len])) return fail(rt, BK_ERR_INVALID, "no module of that name is loaded");
    return BK_OK;
}

// import(specifier) from the host: a promise of the module namespace.
fn ulong bk_import(void* ctxp, char* specifier, usz len) @export("bk_import") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (specifier == null) return fail_value(rt, BK_ERR_INVALID, "missing specifier");
    embed::clear_err(rt);
    rt.heap.has_error = false;
    TVal? p = esm::dynamic_import(rt.heap, rt.vm, specifier[:len]);
    if (catch p) return fail_value(rt, BK_ERR_UNSUPPORTED, "module loading is not available in this build");
    ulong out = store(rt, p);
    rt.heap.decref_tval(&p);
    return out;
}

fn int bk_is_job_pending(void* rtp) @export("bk_is_job_pending") {
    if (rtp == null) return 0;
    Heap* h = ((Runtime*)rtp).heap;
    return h.microtask_head < h.microtask_count ? 1 : 0;
}

fn int bk_execute_pending_job(void* rtp, void** context) @export("bk_execute_pending_job") {
    if (context != null) *context = null;
    if (rtp == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    Heap* h = rt.heap;
    if (h.microtask_draining || h.microtask_head >= h.microtask_count) return 0;
    TVal handler = h.microtask_queue[h.microtask_head * 3];
    Ctx* ctx = embed::realm_context(rt, heap::function_realm(h, handler) ?? h.realm);
    if (ctx == null) ctx = rt.active;
    embed::select_context(ctx);
    if (context != null) *context = ctx;
    embed::clear_err(rt);
    h.uncatchable_throw = false;
    h.has_error = false;
    h.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
    h.drain_microtasks(rt.vm, report: false, max_jobs: 1, force: true);
    if (h.uncatchable_throw) return vm_fault(rt);
    return 1;
}

fn int bk_run_jobs(void* rtp) @export("bk_run_jobs") {
    if (rtp == null) return BK_ERR_INVALID;
    return embed::drain_microtasks((Runtime*)rtp);
}

// ============================================================================
// Value lifetime
// ============================================================================

fn void bk_free_value(void* ctxp, ulong id) @export("bk_free_value") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return;
    embed::slot_release(rt, id);
}

fn ulong bk_dup_value(void* ctxp, ulong id) @export("bk_dup_value") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    return store_root(rt, v);
}

// ============================================================================
// Local scopes
// ============================================================================

fn uint bk_scope_open(void* ctxp) @export("bk_scope_open") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    uint id = embed::scope_open(rt);
    if (id == 0) fail(rt, BK_ERR_FULL, "too many nested scopes");
    return id;
}

fn void bk_scope_close(void* ctxp, uint scope) @export("bk_scope_close") {
    Runtime* rt = rt_of(ctxp);
    if (rt != null) embed::scope_close(rt, scope);
}

fn ulong bk_scope_close_escape(void* ctxp, uint scope, ulong id) @export("bk_scope_close_escape") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) { embed::scope_close(rt, scope); return bad_handle(rt); }
    // Hold the value while the scope that may be its only owner closes.
    if (v.is_refcounted() && v.get_heapptr() != null) ((HeapHeader*)v.get_heapptr()).incref();
    defer rt.heap.decref_tval(&v);
    if (!embed::scope_close(rt, scope)) { fail(rt, BK_ERR_INVALID, "scope is not open"); return 0; }
    return store(rt, v);
}

fn ulong bk_scope_local(void* ctxp, ulong id) @export("bk_scope_local") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    return store(rt, v);
}

fn uint bk_scope_current(void* ctxp) @export("bk_scope_current") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    heap::HostScope* sc = embed::local_scope(rt);
    return sc == null ? 0 : sc.generation;
}

// ============================================================================
// Errors
// ============================================================================

fn char* bk_get_error_message(void* ctxp) @export("bk_get_error_message") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return "";
    return &rt.errmsg[0];
}

fn int bk_get_error_code(void* ctxp) @export("bk_get_error_code") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    return rt.errcode;
}

// Layout must match bk_error_info in include/boomkat.h on the target's ABI.
struct BkErrorInfo {
    int code;
    int line;
    int col;
    char* script_name;
    char* stack;
}

fn int bk_get_error_info(void* ctxp, BkErrorInfo* out) @export("bk_get_error_info") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    out.code = rt.errcode;
    out.line = rt.err_line;
    out.col = rt.err_col;
    out.script_name = rt.err_name[0] != 0 ? &rt.err_name[0] : null;
    out.stack = rt.err_stack != null && rt.err_stack[0] != 0 ? rt.err_stack : null;
    return BK_OK;
}

fn char* bk_status_str(int status) @export("bk_status_str") {
    return embed::status_name(status);
}

fn char* bk_type_str(int type) @export("bk_type_str") {
    return embed::type_name(type);
}

// ============================================================================
// Reading values
// ============================================================================

fn int bk_get_type(void* ctxp, ulong id) @export("bk_get_type") {
    if (rt_of(ctxp) == null) return BK_TYPE_UNDEFINED;
    TVal v;
    if (!resolve(ctxp, id, &v)) return BK_TYPE_UNDEFINED;
    return embed::classify(v);
}

fn int bk_read_number(void* ctxp, ulong id, double* out) @export("bk_read_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_numeric()) return fail(rt, BK_ERR_TYPE, "value is not a number");
    *out = v.get_number_or_fastint();
    return BK_OK;
}

fn int bk_read_bool(void* ctxp, ulong id, int* out) @export("bk_read_bool") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_boolean()) return fail(rt, BK_ERR_TYPE, "value is not a boolean");
    *out = v.get_boolean() ? 1 : 0;
    return BK_OK;
}

// The string behind `id`, or null with the failure recorded.
fn HString* string_of(Runtime* rt, void* ctxp, ulong id) {
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) { fail(rt, BK_ERR_INVALID, "invalid or freed value handle"); return null; }
    if (!v.is_string()) { fail(rt, BK_ERR_TYPE, "value is not a string"); return null; }
    HString* hs = (HString*)v.get_heapptr();
    // Symbols share the string tag but have no text; JS forbids implicit conversion too.
    if (hs.is_symbol()) { fail(rt, BK_ERR_TYPE, "value is a symbol"); return null; }
    return hs;
}

fn int bk_read_string(void* ctxp, ulong id, char* buf, usz cap, usz* out_len)
        @export("bk_read_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    HString* hs = string_of(rt, ctxp, id);
    return hs == null ? rt.errcode : embed::read_utf8(rt, hs, false, buf, cap, out_len);
}

fn int bk_read_string_utf8(void* ctxp, ulong id, int mode, char* buf, usz cap, usz* out_len)
        @export("bk_read_string_utf8") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    if (mode != BK_UTF8_REPLACE && mode != BK_UTF8_STRICT) {
        return fail(rt, BK_ERR_INVALID, "unknown UTF-8 mode");
    }
    HString* hs = string_of(rt, ctxp, id);
    return hs == null ? rt.errcode : embed::read_utf8(rt, hs, mode == BK_UTF8_STRICT, buf, cap, out_len);
}

fn int bk_read_string_utf16(void* ctxp, ulong id, ushort* buf, usz cap, usz* out_len)
        @export("bk_read_string_utf16") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    HString* hs = string_of(rt, ctxp, id);
    return hs == null ? rt.errcode : embed::read_utf16(rt, hs, buf, cap, out_len);
}

// The length in UTF-16 code units, or 0 with the failure recorded when `id` is
// not a string.
fn usz bk_string_length(void* ctxp, ulong id) @export("bk_string_length") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    HString* hs = string_of(rt, ctxp, id);
    return hs == null ? 0 : hs.unit_len();
}

// Mirrors bk_string_view in boomkat.h.
struct StringView {
    void* data;
    usz   length;
    char  width;
    char  ascii;
}

// The units of the string in place: Latin-1 bytes at width 1, native-endian
// UTF-16 at width 2. The view lasts until the next call into the engine.
fn int bk_string_view_get(void* ctxp, ulong id, StringView* out) @export("bk_string_view_get") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    HString* hs = string_of(rt, ctxp, id);
    if (hs == null) return rt.errcode;
    if (out == null) return fail(rt, BK_ERR_INVALID, "no view to fill");
    bool wide = hs.is_wide();
    out.data = hs.data_ptr();
    out.length = hs.unit_len();
    out.width = wide ? 2 : 1;
    // An external string is not flagged, as its buffer has no terminator.
    out.ascii = !wide && (hs.is_ascii() || (hs.has_extdata() && hstring::check_is_ascii(hs.latin1()))) ? 1 : 0;
    return BK_OK;
}

// ============================================================================
// Coercion tier
// ============================================================================

fn double bk_to_number(void* ctxp, ulong id) @export("bk_to_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return (double)(0.0 / 0.0);
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return (double)(0.0 / 0.0);
    }
    if (v.is_numeric()) return v.get_number_or_fastint();

    // Anything else may run user code (valueOf/toString) and therefore throw.
    // vm_to_number reports through the heap's error channel rather than an
    // optional, so the throw is picked up here and turned into a status.
    rt.heap.has_error = false;
    double d = vm::vm_to_number(rt.vm, &v);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) {
        vm_fault(rt);
        return (double)(0.0 / 0.0);
    }
    return d;
}

fn int bk_to_bool(void* ctxp, ulong id) @export("bk_to_bool") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return 0;
    }
    // ToBoolean never calls user code, so this cannot throw.
    return builtins::builtin_to_boolean(&v) ? 1 : 0;
}

fn ulong bk_to_string(void* ctxp, ulong id) @export("bk_to_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    HString* s;
    if (embed::to_string(rt, v, &s) != BK_OK) return 0;
    TVal sv; sv.set_string_borrowed(s);
    return store(rt, sv);
}

fn char* bk_to_cstring(void* ctxp, ulong id, usz* out_len) @export("bk_to_cstring") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal value;
    if (!resolve(ctxp, id, &value)) { bad_handle(rt); return null; }
    HString* string;
    if (embed::to_string(rt, value, &string) != BK_OK) return null;
    usz length = embed::utf8_len(string);
    char* buffer = (char*)rt.heap.alloc_func(rt.heap.heap_udata, length + 1);
    if (buffer == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    embed::utf8_write(string, buffer, length + 1);
    buffer[length] = 0;
    if (out_len != null) *out_len = length;
    return buffer;
}

fn char* bk_cstr(void* ctxp, ulong id, usz* out_len) @export("bk_cstr") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal value;
    if (!resolve(ctxp, id, &value)) { bad_handle(rt); return null; }
    HString* string;
    if (embed::to_string(rt, value, &string) != BK_OK) return null;
    usz length = embed::utf8_len(string);
    char* buffer = embed::cstr_slot(rt, length);
    if (buffer == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    embed::utf8_write(string, buffer, length + 1);
    buffer[length] = 0;
    if (out_len != null) *out_len = length;
    return buffer;
}

fn void bk_free_cstring(void* ctxp, char* string) @export("bk_free_cstring") {
    if (ctxp == null || string == null) return;
    Heap* h = ((Ctx*)ctxp).rt.heap;
    h.free_func(h.heap_udata, string);
}

fn ulong bk_get_exception(void* ctxp) @export("bk_get_exception") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    ulong id = embed::take_exception(rt);
    TVal v;
    if (!embed::slot_get(rt, id, &v)) return id;
    if (embed::immediate_of(v) == 0 && embed::local_scope(rt) == null) return id;
    ulong out = store(rt, v);
    embed::slot_release(rt, id);
    return out;
}

// ============================================================================
// Building values
// ============================================================================

fn ulong bk_new_number(void* ctxp, double d) @export("bk_new_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_number(d);
    return store(rt, v);
}

fn ulong store_string(Runtime* rt, HString* s) {
    if (s == null) return 0;
    TVal v; v.set_string_borrowed(s);
    return store(rt, v);
}

fn ulong bk_new_string(void* ctxp, char* utf8, usz len) @export("bk_new_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || (utf8 == null && len != 0)) return 0;
    embed::clear_err(rt);
    return store_string(rt, embed::string_from_utf8(rt, utf8[:len]));
}

fn ulong bk_new_string_latin1(void* ctxp, char* chars, usz len) @export("bk_new_string_latin1") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || (chars == null && len != 0)) return 0;
    embed::clear_err(rt);
    return store_string(rt, embed::string_from_latin1(rt, chars[:len]));
}

fn ulong bk_new_string_utf16(void* ctxp, ushort* units, usz len) @export("bk_new_string_utf16") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || (units == null && len != 0)) return 0;
    embed::clear_err(rt);
    return store_string(rt, embed::string_from_utf16(rt, units[:len]));
}

fn ulong bk_new_external_string_latin1(void* ctxp, char* chars, usz len, hstring::ExtRelease release,
        void* opaque) @export("bk_new_external_string_latin1") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || (chars == null && len != 0)) return 0;
    embed::clear_err(rt);
    if (hstring::length_exceeds_max((ulong)len)) { embed::set_err(rt, BK_ERR_NOMEM, "string too long"); return 0; }
    hstring::Units data = { .ptr = chars, .len = (uint)len, .wide = false };
    return store_string(rt, embed::string_external(rt, data, release, opaque));
}

fn ulong bk_new_external_string_utf16(void* ctxp, ushort* units, usz len, hstring::ExtRelease release,
        void* opaque) @export("bk_new_external_string_utf16") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || (units == null && len != 0)) return 0;
    embed::clear_err(rt);
    if (hstring::length_exceeds_max((ulong)len)) { embed::set_err(rt, BK_ERR_NOMEM, "string too long"); return 0; }
    hstring::Units data = { .ptr = (char*)units, .len = (uint)len, .wide = true };
    return store_string(rt, embed::string_external(rt, data, release, opaque));
}

fn ulong bk_new_object(void* ctxp) @export("bk_new_object") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject*? oraw = rt.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch oraw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    HObject* o = oraw;
    o.prototype = rt.heap.object_proto;
    TVal v; v.set_object(o);
    return store(rt, v);
}

// Fresh empty array. Shared by bk_new_array, bk_new_array_from and bk_get_own_property_keys.
fn HObject* new_array(Runtime* rt) {
    HObject*? araw = rt.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch araw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    HObject* a = araw;
    a.prototype = rt.heap.array_proto;
    return a;
}

fn ulong bk_new_array(void* ctxp) @export("bk_new_array") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject* a = new_array(rt);
    if (a == null) return 0;
    TVal v; v.set_object(a);
    return store(rt, v);
}

fn ulong bk_new_array_from(void* ctxp, ulong* elems, uint n) @export("bk_new_array_from") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (n > 0 && elems == null) { embed::set_err(rt, BK_ERR_INVALID, "null element array"); return 0; }
    HObject* a = new_array(rt);
    if (a == null) return 0;
    for (uint i = 0; i < n; i++) {
        TVal ev;
        if (!resolve(ctxp, elems[i], &ev)) ev.set_undefined();
        builtins::array_set_elem(a, i, ev, rt.heap);
    }
    TVal len_tv; len_tv.set_fastint((long)n);
    a.put_prop(rt.heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, rt.heap);
    TVal v; v.set_object(a);
    return store(rt, v);
}

fn ulong bk_get_global_object(void* ctxp) @export("bk_get_global_object") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal g;
    if (rt.vm.global_env != null && rt.vm.global_env.bindings != null) {
        g.set_object(rt.vm.global_env.bindings);
    } else {
        g.set_undefined();
    }
    return store(rt, g);
}

// ============================================================================
// Properties
// ============================================================================

// Resolve a handle that must name an object, recording the failure otherwise.
fn HObject* as_object(void* ctxp, ulong id, TVal* out) {
    Runtime* rt = rt_of(ctxp);
    if (!resolve(ctxp, id, out)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return null;
    }
    if (!out.is_object()) {
        fail(rt, BK_ERR_TYPE, "value is not an object");
        return null;
    }
    return (HObject*)out.get_heapptr();
}

// Surface a VM failure (heap error channel) as a status, distinguishing an
// interrupt from an ordinary throw.
fn int vm_fault(Runtime* rt) {
    if (rt.heap.uncatchable_throw) return embed::interrupt_status(rt);
    embed::describe_error(rt, &rt.heap.error_value);
    return BK_ERR_THROW;
}

// Shared by the named and indexed getters. A primitive base reads through its
// wrapper with the primitive as receiver (GetV, ECMA-262 §7.3.3).
fn ulong get_key(void* ctxp, ulong obj_id, HString* k) {
    Runtime* rt = rt_of(ctxp);
    TVal ov;
    if (!resolve(ctxp, obj_id, &ov)) return bad_handle(rt);
    if (ov.is_undefined() || ov.is_null()) {
        fail(rt, BK_ERR_TYPE, "cannot read properties of null or undefined");
        return 0;
    }
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    HObject* obj = builtins::to_object_for_lookup(rt.heap, ov);
    if (obj == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    // A fresh wrapper is unreachable from JS; hold it while getters run.
    ulong wrapper = 0;
    if (!ov.is_object()) {
        TVal wv;
        wv.set_object(obj);
        wrapper = store_root(rt, wv);
        if (wrapper == 0) return 0;
    }
    defer if (wrapper != 0) embed::slot_release(rt, wrapper);
    TVal got;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, obj, k, ov, &got)) {
        vm_fault(rt);
        return 0;
    }
    return store(rt, got);
}

fn ulong bk_get_property(void* ctxp, ulong obj_id, char* key, usz key_len) @export("bk_get_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null) return 0;
    embed::clear_err(rt);
    return get_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]));
}

fn ulong bk_get_property_uint32(void* ctxp, ulong obj_id, uint idx) @export("bk_get_property_uint32") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    return get_key(ctxp, obj_id, rt.heap.int_to_hstring((long)idx));
}

// Shared by the named and indexed setters.
fn int set_key(void* ctxp, ulong obj_id, HString* k, ulong val_id) {
    Runtime* rt = rt_of(ctxp);
    TVal ov, vv;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    if (!resolve(ctxp, val_id, &vv)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    bool res;
    if (!builtins::js_set_with_receiver((void*)rt.vm, rt.heap, obj, k, vv, ov, &res)) {
        return vm_fault(rt);
    }
    // Strict-only engine: a Set that returns false throws a TypeError.
    if (!res) return fail(rt, BK_ERR_THROW, "Cannot assign to read only property");
    return BK_OK;
}

fn int bk_set_property(void* ctxp, ulong obj_id, char* key, usz key_len, ulong val_id)
        @export("bk_set_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return set_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]), val_id);
}

fn int bk_set_property_uint32(void* ctxp, ulong obj_id, uint idx, ulong val_id)
        @export("bk_set_property_uint32") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return set_key(ctxp, obj_id, rt.heap.int_to_hstring((long)idx), val_id);
}

fn int bk_has_property(void* ctxp, ulong obj_id, char* key, usz key_len, int* out)
        @export("bk_has_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return has_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]), out);
}

// Shared by the named and atom-keyed `in` checks.
fn int has_key(void* ctxp, ulong obj_id, HString* k, int* out) {
    Runtime* rt = rt_of(ctxp);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    bool b;
    if (!builtins::js_has_property((void*)rt.vm, rt.heap, obj, k, &b)) return vm_fault(rt);
    *out = b ? 1 : 0;
    return BK_OK;
}

fn int bk_delete_property(void* ctxp, ulong obj_id, char* key, usz key_len, int* out)
        @export("bk_delete_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return delete_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]), out);
}

// Shared by the named and atom-keyed deletes.
fn int delete_key(void* ctxp, ulong obj_id, HString* k, int* out) {
    Runtime* rt = rt_of(ctxp);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    // Absent own property: report 0 and succeed. A proxy reports its trap's
    // answer, since only the trap knows whether the key existed.
    // A module namespace is probed by key so a TDZ export does not throw.
    if (obj.flags.exotic_module_ns) {
        if (obj.find_prop_idx((void*)k, rt.heap) < 0) { *out = 0; return BK_OK; }
    } else if (!obj.is_proxy()) {
        builtins::ProxyDesc own;
        builtins::ordinary_own_desc(rt.heap, obj, k, &own);
        if (!own.found) { *out = 0; return BK_OK; }
    }
    bool res;
    if (!builtins::object_mop_delete((void*)rt.vm, rt.heap, obj, k, &res)) return vm_fault(rt);
    // Strict-only engine: deleting a non-configurable property throws.
    if (!res) return fail(rt, BK_ERR_THROW, "Cannot delete property");
    *out = 1;
    return BK_OK;
}

// ============================================================================
// Atoms
// ============================================================================

// The atom for `key`, recording a failure when the table cannot grow.
fn uint intern_atom(Runtime* rt, HString* key) {
    if (key == null) return 0;
    uint atom = embed::atom_intern(rt, key);
    if (atom == 0) fail(rt, BK_ERR_NOMEM, "out of memory");
    return atom;
}

fn uint bk_new_atom(void* ctxp, char* utf8, usz len) @export("bk_new_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (utf8 == null && len != 0) { fail(rt, BK_ERR_INVALID, "null key"); return 0; }
    embed::clear_err(rt);
    return intern_atom(rt, embed::string_from_utf8(rt, utf8[:len]));
}

fn uint bk_new_atom_index(void* ctxp, uint index) @export("bk_new_atom_index") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HString* key = rt.heap.int_to_hstring((long)index);
    if (key == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    return intern_atom(rt, key);
}

// ToPropertyKey of a resolved value: a string or symbol key, interned.
fn HString* property_key(Runtime* rt, TVal v) {
    builtins::BuiltinContext call = { .heap = rt.heap, .vm = rt.vm };
    rt.heap.has_error = false;
    HString* key = builtins::builtin_to_property_key_vm(&call, &v);
    if (rt.heap.uncatchable_throw) { vm_fault(rt); return null; }
    if (call.should_throw) { embed::describe_error(rt, &call.throw_value); return null; }
    if (rt.heap.has_error) { vm_fault(rt); return null; }
    if (key == null) fail(rt, BK_ERR_NOMEM, "out of memory");
    return key;
}

fn uint bk_value_to_atom(void* ctxp, ulong id) @export("bk_value_to_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return 0; }
    HString* key = property_key(rt, v);
    return key == null ? 0 : intern_atom(rt, key);
}

fn ulong bk_atom_to_value(void* ctxp, uint atom) @export("bk_atom_to_value") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail_value(rt, BK_ERR_INVALID, "invalid or freed atom");
    TVal v; v.set_string_borrowed(key);
    return store(rt, v);
}

fn uint bk_dup_atom(void* ctxp, uint atom) @export("bk_dup_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (!embed::atom_dup(rt, atom)) { fail(rt, BK_ERR_INVALID, "invalid or freed atom"); return 0; }
    return atom;
}

fn void bk_free_atom(void* ctxp, uint atom) @export("bk_free_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt != null) embed::atom_release(rt, atom);
}

fn ulong bk_get_property_atom(void* ctxp, ulong obj_id, uint atom) @export("bk_get_property_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail_value(rt, BK_ERR_INVALID, "invalid or freed atom");
    return get_key(ctxp, obj_id, key);
}

fn int bk_set_property_atom(void* ctxp, ulong obj_id, uint atom, ulong val_id) @export("bk_set_property_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail(rt, BK_ERR_INVALID, "invalid or freed atom");
    return set_key(ctxp, obj_id, key, val_id);
}

fn int bk_has_property_atom(void* ctxp, ulong obj_id, uint atom, int* out) @export("bk_has_property_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail(rt, BK_ERR_INVALID, "invalid or freed atom");
    return has_key(ctxp, obj_id, key, out);
}

fn int bk_delete_property_atom(void* ctxp, ulong obj_id, uint atom, int* out) @export("bk_delete_property_atom") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail(rt, BK_ERR_INVALID, "invalid or freed atom");
    return delete_key(ctxp, obj_id, key, out);
}

// ============================================================================
// Property descriptors
// ============================================================================

const uint BK_PROP_WRITABLE         = 1;
const uint BK_PROP_ENUMERABLE       = 2;
const uint BK_PROP_CONFIGURABLE     = 4;
const uint BK_PROP_HAS_VALUE        = 8;
const uint BK_PROP_HAS_GET          = 16;
const uint BK_PROP_HAS_SET          = 32;
const uint BK_PROP_HAS_WRITABLE     = 64;
const uint BK_PROP_HAS_ENUMERABLE   = 128;
const uint BK_PROP_HAS_CONFIGURABLE = 256;
const uint BK_PROP_ALL              = 511;

// Layout must match bk_property_descriptor in include/boomkat.h.
struct BkPropertyDescriptor {
    uint  flags;
    ulong value;
    ulong get;
    ulong set;
}

// Resolves an accessor half: undefined or a callable.
fn int accessor_of(void* ctxp, Runtime* rt, ulong id, TVal* out) {
    if (!resolve(ctxp, id, out)) { bad_handle(rt); return BK_ERR_INVALID; }
    if (out.is_undefined()) return BK_OK;
    if (out.is_object()) {
        HObject* f = (HObject*)out.get_heapptr();
        if (f != null && f.flags.callable) return BK_OK;
    }
    if (out.is_lightfunc()) return BK_OK;
    return fail(rt, BK_ERR_TYPE, "accessor must be a function or undefined");
}

// Converts a C descriptor, whose handles `ctxp` resolves, to an engine one.
fn int desc_from_bk(void* ctxp, Runtime* rt, BkPropertyDescriptor* desc, builtins::ProxyDesc* out) {
    uint f = desc.flags;
    if ((f & ~BK_PROP_ALL) != 0) return fail(rt, BK_ERR_INVALID, "unknown property flags");
    bool data = (f & (BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE)) != 0;
    bool accessor = (f & (BK_PROP_HAS_GET | BK_PROP_HAS_SET)) != 0;
    if (data && accessor) return fail(rt, BK_ERR_INVALID, "descriptor is both data and accessor");
    builtins::ProxyDesc pd;
    pd.found = true;
    pd.getter.set_undefined();
    pd.setter.set_undefined();
    if ((f & BK_PROP_HAS_VALUE) != 0) {
        if (!resolve(ctxp, desc.value, &pd.value)) { bad_handle(rt); return BK_ERR_INVALID; }
        pd.has_value = true;
    }
    if ((f & BK_PROP_HAS_GET) != 0) {
        int rc = accessor_of(ctxp, rt, desc.get, &pd.getter);
        if (rc != BK_OK) return rc;
        pd.has_get = true;
    }
    if ((f & BK_PROP_HAS_SET) != 0) {
        int rc = accessor_of(ctxp, rt, desc.set, &pd.setter);
        if (rc != BK_OK) return rc;
        pd.has_set = true;
    }
    pd.has_writable     = (f & BK_PROP_HAS_WRITABLE) != 0;
    pd.writable         = pd.has_writable && (f & BK_PROP_WRITABLE) != 0;
    pd.has_enumerable   = (f & BK_PROP_HAS_ENUMERABLE) != 0;
    pd.enumerable       = pd.has_enumerable && (f & BK_PROP_ENUMERABLE) != 0;
    pd.has_configurable = (f & BK_PROP_HAS_CONFIGURABLE) != 0;
    pd.configurable     = pd.has_configurable && (f & BK_PROP_CONFIGURABLE) != 0;
    *out = pd;
    return BK_OK;
}

fn int bk_define_property(void* ctxp, ulong obj_id, uint atom, BkPropertyDescriptor* desc, int* ok) @export("bk_define_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || desc == null || ok == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail(rt, BK_ERR_INVALID, "invalid or freed atom");
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    builtins::ProxyDesc pd;
    int rc = desc_from_bk(ctxp, rt, desc, &pd);
    if (rc != BK_OK) return rc;
    bool res;
    rt.heap.has_error = false;
    if (!builtins::object_define_own((void*)rt.vm, rt.heap, obj, key, &pd, &res)) return vm_fault(rt);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) return vm_fault(rt);
    *ok = res ? 1 : 0;
    return BK_OK;
}

fn int bk_get_own_property(void* ctxp, ulong obj_id, uint atom, BkPropertyDescriptor* out, int* found) @export("bk_get_own_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null || found == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    *out = { .value = embed::IMM_UNDEFINED, .get = embed::IMM_UNDEFINED, .set = embed::IMM_UNDEFINED };
    *found = 0;
    HString* key = embed::atom_key(rt, atom);
    if (key == null) return fail(rt, BK_ERR_INVALID, "invalid or freed atom");
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    builtins::ProxyDesc pd;
    rt.heap.has_error = false;
    if (!builtins::own_property_desc((void*)rt.vm, rt.heap, obj, key, &pd)) return vm_fault(rt);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) return vm_fault(rt);
    if (!pd.found) return BK_OK;
    pd.complete();
    uint f = BK_PROP_HAS_ENUMERABLE | BK_PROP_HAS_CONFIGURABLE;
    if (pd.enumerable) f |= BK_PROP_ENUMERABLE;
    if (pd.configurable) f |= BK_PROP_CONFIGURABLE;
    if (pd.is_accessor_desc()) {
        f |= BK_PROP_HAS_GET | BK_PROP_HAS_SET;
        ulong g = store(rt, pd.getter);
        if (g == 0) return rt.errcode;
        ulong st = store(rt, pd.setter);
        if (st == 0) { bk_free_value(ctxp, g); return rt.errcode; }
        out.get = g;
        out.set = st;
    } else {
        f |= BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE;
        if (pd.writable) f |= BK_PROP_WRITABLE;
        ulong v = store(rt, pd.value);
        if (v == 0) return rt.errcode;
        out.value = v;
    }
    out.flags = f;
    *found = 1;
    return BK_OK;
}

// ============================================================================
// Intrinsics, symbols and BigInt
// ============================================================================

// bk_intrinsic, append-only.
enum Intrinsic : int {
    OBJECT_PROTOTYPE, FUNCTION_PROTOTYPE, ARRAY_PROTOTYPE, ERROR_PROTOTYPE,
    TYPE_ERROR_PROTOTYPE, PROMISE_PROTOTYPE, ITERATOR_PROTOTYPE,
    RANGE_ERROR_PROTOTYPE, REFERENCE_ERROR_PROTOTYPE, SYNTAX_ERROR_PROTOTYPE,
    ASYNC_ITERATOR_PROTOTYPE, GENERATOR_PROTOTYPE, STRING_PROTOTYPE,
    NUMBER_PROTOTYPE, BOOLEAN_PROTOTYPE, SYMBOL_PROTOTYPE, BIGINT_PROTOTYPE,
    DATE_PROTOTYPE, REGEXP_PROTOTYPE, MAP_PROTOTYPE, SET_PROTOTYPE,
    ARRAY_BUFFER_PROTOTYPE, TYPED_ARRAY_PROTOTYPE, GLOBAL_OBJECT,
}

fn ulong bk_get_intrinsic(void* ctxp, int which) @export("bk_get_intrinsic") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (which < 0 || which > Intrinsic.GLOBAL_OBJECT.ordinal) return fail_value(rt, BK_ERR_INVALID, "unknown intrinsic");
    Heap* hp = rt.heap;
    HObject* o;
    switch ((Intrinsic)which) {
        case OBJECT_PROTOTYPE:          o = hp.object_proto;
        case FUNCTION_PROTOTYPE:        o = hp.function_proto;
        case ARRAY_PROTOTYPE:           o = hp.array_proto;
        case ERROR_PROTOTYPE:           o = hp.err_proto;
        case TYPE_ERROR_PROTOTYPE:      o = hp.type_err_proto;
        case PROMISE_PROTOTYPE:         o = hp.promise_proto;
        case ITERATOR_PROTOTYPE:        o = hp.iterator_proto;
        case RANGE_ERROR_PROTOTYPE:     o = hp.range_err_proto;
        case REFERENCE_ERROR_PROTOTYPE: o = hp.ref_err_proto;
        case SYNTAX_ERROR_PROTOTYPE:    o = hp.syntax_err_proto;
        case ASYNC_ITERATOR_PROTOTYPE:  o = hp.async_iterator_proto;
        case GENERATOR_PROTOTYPE:       o = hp.generator_proto;
        case STRING_PROTOTYPE:          o = hp.string_proto;
        case NUMBER_PROTOTYPE:          o = hp.number_proto;
        case BOOLEAN_PROTOTYPE:         o = hp.bool_proto;
        case SYMBOL_PROTOTYPE:          o = hp.symbol_proto;
        case BIGINT_PROTOTYPE:          o = hp.bigint_proto;
        case DATE_PROTOTYPE:            o = hp.date_proto;
        case REGEXP_PROTOTYPE:          o = hp.regexp_proto;
        case MAP_PROTOTYPE:             o = hp.map_proto;
        case SET_PROTOTYPE:             o = hp.set_proto;
        case ARRAY_BUFFER_PROTOTYPE:    o = hp.arraybuffer_proto;
        case TYPED_ARRAY_PROTOTYPE:     o = hp.typedarray_proto;
        case GLOBAL_OBJECT:             o = (HObject*)rt.vm.global_env.bindings;
    }
    if (o == null) return fail_value(rt, BK_ERR_UNSUPPORTED, "intrinsic not available in this build");
    TVal v; v.set_object(o);
    return store(rt, v);
}

// bk_well_known_symbol, append-only.
enum WellKnownSymbol : int {
    ITERATOR, ASYNC_ITERATOR, TO_STRING_TAG, TO_PRIMITIVE, HAS_INSTANCE,
    IS_CONCAT_SPREADABLE, MATCH, MATCH_ALL, REPLACE, SEARCH, SPECIES, SPLIT,
    UNSCOPABLES, DISPOSE, ASYNC_DISPOSE,
}

fn ulong bk_get_well_known_symbol(void* ctxp, int which) @export("bk_get_well_known_symbol") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (which < 0 || which > WellKnownSymbol.ASYNC_DISPOSE.ordinal) return fail_value(rt, BK_ERR_INVALID, "unknown well-known symbol");
    Heap* hp = rt.heap;
    HString* s;
    switch ((WellKnownSymbol)which) {
        case ITERATOR:             s = builtins::ensure_iterator_symbol(hp);
        case ASYNC_ITERATOR:       s = builtins::ensure_asynciterator_symbol(hp);
        case TO_STRING_TAG:        s = builtins::ensure_tostringtag_symbol(hp);
        case TO_PRIMITIVE:         s = builtins::ensure_toprimitive_symbol(hp);
        case HAS_INSTANCE:         s = builtins::ensure_hasinstance_symbol(hp);
        case IS_CONCAT_SPREADABLE: s = builtins::ensure_concatspreadable_symbol(hp);
        case MATCH:                s = builtins::ensure_match_symbol(hp);
        case MATCH_ALL:            s = builtins::ensure_matchall_symbol(hp);
        case REPLACE:              s = builtins::ensure_replace_symbol(hp);
        case SEARCH:               s = builtins::ensure_search_symbol(hp);
        case SPECIES:              s = builtins::ensure_species_symbol(hp);
        case SPLIT:                s = builtins::ensure_split_symbol(hp);
        case UNSCOPABLES:          s = builtins::ensure_unscopables_symbol(hp);
        case DISPOSE:              s = builtins::ensure_dispose_symbol(hp);
        case ASYNC_DISPOSE:        s = builtins::ensure_asyncdispose_symbol(hp);
    }
    if (s == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    return store_string(rt, s);
}

// A new unique symbol; a NULL description gives Symbol().
fn ulong bk_new_symbol(void* ctxp, char* desc, usz len) @export("bk_new_symbol") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HString* d = desc == null ? rt.heap.str(heap::BuiltinStr.EMPTY) : embed::string_from_utf8(rt, desc[:len]);
    if (d == null) return 0;
    HString* sym = builtins::create_symbol_string(rt.heap, d, desc != null);
    if (sym == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    return store_string(rt, sym);
}

// Symbol.for(key).
fn ulong bk_symbol_for(void* ctxp, char* key, usz len) @export("bk_symbol_for") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (key == null && len != 0) return fail_value(rt, BK_ERR_INVALID, "null key");
    embed::clear_err(rt);
    HString* k = embed::string_from_utf8(rt, key == null ? (char[])"" : key[:len]);
    if (k == null) return 0;
    HString* sym = builtins::symbol_registry_get(rt.heap, k);
    if (sym == null) {
        sym = builtins::create_symbol_string(rt.heap, k);
        if (sym == null || !builtins::symbol_registry_put(rt.heap, k, sym)) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    }
    return store_string(rt, sym);
}

// The description of a symbol as a string, or undefined for Symbol().
fn ulong bk_symbol_description(void* ctxp, ulong id) @export("bk_symbol_description") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    if (!v.is_string() || !((HString*)v.get_heapptr()).is_symbol()) return fail_value(rt, BK_ERR_TYPE, "not a symbol");
    HString* sym = (HString*)v.get_heapptr();
    if (!builtins::symbol_has_description(sym)) return embed::IMM_UNDEFINED;
    HString* d = rt.heap.str_slice(sym, 0, sym.unit_len());
    if (d == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    return store_string(rt, d);
}

macro ulong @store_bigint(Runtime* rt, #b) {
    HBigInt*? made = #b;
    if (catch err = made) {
        $if $feat(NO_BIGINT):
            return fail_value(rt, BK_ERR_UNSUPPORTED, "BigInt is not available in this build");
        $else
            return fail_value(rt, BK_ERR_NOMEM, "could not allocate BigInt");
        $endif
    }
    TVal v; v.set_bigint(made);
    return store(rt, v);
}

fn ulong bk_new_bigint_int64(void* ctxp, long value) @export("bk_new_bigint_int64") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    return @store_bigint(rt, hbigint::hbigint_alloc(rt.heap, (int128)value));
}

fn ulong bk_new_bigint_uint64(void* ctxp, ulong value) @export("bk_new_bigint_uint64") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    return @store_bigint(rt, hbigint::hbigint_alloc(rt.heap, (int128)value));
}

// The BigInt behind `id`, or null with BK_ERR_TYPE recorded.
fn HBigInt* bigint_of(void* ctxp, Runtime* rt, ulong id) {
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return null; }
    if (!v.is_bigint()) { fail(rt, BK_ERR_TYPE, "not a BigInt"); return null; }
    return v.get_bigint();
}

// BigInt.asIntN(64, value) in *out; `lossless` reports whether that is the
// value itself.
fn int bk_read_bigint_int64(void* ctxp, ulong id, long* out, int* lossless) @export("bk_read_bigint_int64") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HBigInt* b = bigint_of(ctxp, rt, id);
    if (b == null) return rt.errcode;
    Limb* l = b.limbs();
    ulong low = (ulong)l[0];
    if (b.len > 1) {
        low |= (ulong)l[1] << 32;
    } else if ((l[0] >> 31) != 0) {
        low |= 0xFFFF_FFFF_0000_0000;
    }
    *out = (long)low;
    if (lossless != null) *lossless = b.len <= 2 ? 1 : 0;
    return BK_OK;
}

// Magnitude words, least significant first, and a sign.
fn ulong bk_new_bigint_words(void* ctxp, int negative, ulong* words, usz count) @export("bk_new_bigint_words") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (words == null && count != 0) return fail_value(rt, BK_ERR_INVALID, "null words");
    embed::clear_err(rt);
    $if $feat(NO_BIGINT):
        return fail_value(rt, BK_ERR_UNSUPPORTED, "BigInt is not available in this build");
    $else
        if (count > (usz)hbigint::BIGINT_MAX_LIMBS / 2) return fail_value(rt, BK_ERR_INVALID, "BigInt too large");
        int len = (int)count * 2 + 1;
        HBigInt*? raw = hbigint::hbigint_alloc_len(rt.heap, len);
        if (catch raw) return fail_value(rt, BK_ERR_NOMEM, "could not allocate BigInt");
        HBigInt* b = raw;
        Limb* l = b.limbs();
        for (usz i = 0; i < count; i++) {
            l[2 * i] = (Limb)words[i];
            l[2 * i + 1] = (Limb)(words[i] >> 32);
        }
        l[len - 1] = 0;
        if (negative != 0) {
            // Two's complement: invert and add one.
            ulong carry = 1;
            for (int i = 0; i < len; i++) {
                ulong sum = (ulong)(Limb)~l[i] + carry;
                l[i] = (Limb)sum;
                carry = sum >> 32;
            }
        }
        b.normalize();
        TVal v; v.set_bigint(b);
        return store(rt, v);
    $endif
}

// Writes the magnitude in 64-bit words and the sign. `count` receives the
// words needed; BK_ERR_FULL when `capacity` is smaller.
fn int bk_read_bigint_words(void* ctxp, ulong id, int* negative, ulong* words, usz capacity, usz* count) @export("bk_read_bigint_words") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HBigInt* b = bigint_of(ctxp, rt, id);
    if (b == null) return rt.errcode;
    Limb* l = b.limbs();
    bool neg = (l[b.len - 1] >> 31) != 0;
    // Magnitude limbs, negated on the fly for a negative value.
    usz n = (usz)b.len;
    usz nwords = (n + 1) / 2;
    ulong carry = 1;
    usz used = 0;
    for (usz i = 0; i < nwords; i++) {
        ulong w = 0;
        for (usz half = 0; half < 2; half++) {
            usz k = 2 * i + half;
            ulong limb = k < n ? (ulong)l[k] : (neg ? 0xFFFF_FFFF : 0);
            if (neg) {
                ulong sum = (ulong)(Limb)~(Limb)limb + carry;
                limb = sum & 0xFFFF_FFFF;
                carry = sum >> 32;
            }
            w |= limb << (32 * half);
        }
        if (w != 0) used = i + 1;
        if (words != null && i < capacity) words[i] = w;
    }
    if (negative != null) *negative = neg ? 1 : 0;
    if (count != null) *count = used;
    if (words != null && used > capacity) return fail(rt, BK_ERR_FULL, "buffer too small for BigInt");
    return BK_OK;
}

// ============================================================================
// Promises
// ============================================================================

const int BK_PROMISE_PENDING   = 0;
const int BK_PROMISE_FULFILLED = 1;
const int BK_PROMISE_REJECTED  = 2;

// The promise behind `id`, or null with BK_ERR_TYPE recorded.
fn HObject* promise_of(void* ctxp, Runtime* rt, ulong id) {
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return null; }
    if (v.is_object()) {
        HObject* o = (HObject*)v.get_heapptr();
        if (o.get_class() == hobject::ObjClass.PROMISE) return o;
    }
    fail(rt, BK_ERR_TYPE, "not a promise");
    return null;
}

fn ulong bk_new_promise(void* ctxp, ulong* resolve_out, ulong* reject_out) @export("bk_new_promise") {
    if (resolve_out != null) *resolve_out = 0;
    if (reject_out != null) *reject_out = 0;
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject*? made = builtins::promise_create(rt.heap);
    if (catch made) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    builtins::PromiseCapability cap = builtins::promise_new_capability(rt.heap, made);
    if (cap.promise == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    TVal pv; pv.set_object(cap.promise);
    TVal rv; rv.set_object(cap.resolve_func);
    TVal jv; jv.set_object(cap.reject_func);
    ulong p = store(rt, pv);
    if (p == 0) return 0;
    if (resolve_out != null) {
        *resolve_out = store(rt, rv);
        if (*resolve_out == 0) return 0;
    }
    if (reject_out != null) {
        *reject_out = store(rt, jv);
        if (*reject_out == 0) return 0;
    }
    return p;
}

fn int bk_promise_state_get(void* ctxp, ulong id, int* out) @export("bk_promise_state_get") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HObject* p = promise_of(ctxp, rt, id);
    if (p == null) return rt.errcode;
    switch (builtins::promise_get_state(p, builtins::PROMISE_PENDING)) {
        case builtins::PROMISE_FULFILLED: *out = BK_PROMISE_FULFILLED;
        case builtins::PROMISE_REJECTED:  *out = BK_PROMISE_REJECTED;
        default:                          *out = BK_PROMISE_PENDING;
    }
    return BK_OK;
}

// The fulfillment value or rejection reason; undefined while pending.
fn ulong bk_promise_result(void* ctxp, ulong id) @export("bk_promise_result") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject* p = promise_of(ctxp, rt, id);
    if (p == null) return 0;
    if (builtins::promise_get_state(p, builtins::PROMISE_PENDING) == builtins::PROMISE_PENDING) return embed::IMM_UNDEFINED;
    return store(rt, builtins::promise_get_result(p));
}

fn int bk_promise_mark_handled(void* ctxp, ulong id) @export("bk_promise_mark_handled") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HObject* p = promise_of(ctxp, rt, id);
    if (p == null) return rt.errcode;
    builtins::promise_mark_handled(p, rt.heap);
    return BK_OK;
}

// Promise.resolve(value) with the realm's %Promise%.
fn ulong bk_promise_resolve(void* ctxp, ulong id) @export("bk_promise_resolve") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    TVal ctor; ctor.set_object(rt.heap.promise_ctor);
    TVal out;
    if (call_builtin(rt, builtins::Builtin.PROMISE_RESOLVE, ctor, &v, 1, &out) != BK_OK) return 0;
    return store(rt, out);
}

// Promise.prototype.then; either reaction may be 0 for none.
fn ulong bk_promise_then(void* ctxp, ulong id, ulong on_fulfilled, ulong on_rejected) @export("bk_promise_then") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal p;
    if (!resolve(ctxp, id, &p)) return bad_handle(rt);
    TVal[2] args;
    args[0].set_undefined();
    args[1].set_undefined();
    if (on_fulfilled != 0 && !resolve(ctxp, on_fulfilled, &args[0])) return bad_handle(rt);
    if (on_rejected != 0 && !resolve(ctxp, on_rejected, &args[1])) return bad_handle(rt);
    TVal out;
    if (call_builtin(rt, builtins::Builtin.PROMISE_PROTO_THEN, p, &args, 2, &out) != BK_OK) return 0;
    return store(rt, out);
}

// ============================================================================
// Host classes
// ============================================================================

const uint BK_CLASS_DEFER_FINALIZE = 1;

// Layout must match bk_class_def in include/boomkat.h.
struct BkClassDef {
    char* name;
    uint  parent;
    void* finalize;
    void* trace;
    void* construct;
    int   arity;
    uint  flags;
    void* opaque;
    BkExoticHooks* exotic;
}

// The entry of a class defined through bk_define_class, or null.
fn heap::HostClassEntry* api_class(Runtime* rt, uint cls) {
    if (cls == 0) return null;
    heap::HostClassEntry* e = rt.heap.host_class_at(cls - 1);
    if (e == null || (e.flags & heap::HOST_CLASS_C_API) == 0) return null;
    return e;
}

// The class instance behind `v`: the object itself, or the target of a host
// exotic object. Null for anything else.
fn HObject* host_instance(TVal v) {
    if (!v.is_object()) return null;
    HObject* o = (HObject*)v.get_heapptr();
    if (o.is_proxy() && builtins::proxy_host_hooks(o) != null) o = builtins::proxy_target(o);
    return o.get_class() == hobject::ObjClass.HOST ? o : null;
}

// The class of a C API host instance, as id + 1, or 0.
fn uint instance_class(Runtime* rt, TVal v) {
    HObject* o = host_instance(v);
    if (o == null) return 0;
    uint cls = (*o.extra_ptr()).host.class_id + 1;
    return api_class(rt, cls) != null ? cls : 0;
}

// True when class `cls` is `want` or inherits from it.
fn bool class_is_a(Runtime* rt, uint cls, uint want) {
    for (uint depth = 0; cls != 0 && depth < 1024; depth++) {
        if (cls == want) return true;
        heap::HostClassEntry* e = api_class(rt, cls);
        if (e == null) return false;
        cls = e.parent;
    }
    return false;
}

// The constructor of a class with no construct callback.
fn ulong illegal_constructor(void* ctxp, ulong this_value, uint argc, ulong* argv, void* opaque) {
    return bk_throw_error(ctxp, abi::BK_ERROR_TYPE, "Illegal constructor");
}

fn uint bk_define_class(void* ctxp, BkClassDef* def, ulong* ctor_out, ulong* proto_out) @export("bk_define_class") {
    if (ctor_out != null) *ctor_out = 0;
    if (proto_out != null) *proto_out = 0;
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (def == null || def.name == null) { fail(rt, BK_ERR_INVALID, "class needs a name"); return 0; }
    if ((def.flags & ~BK_CLASS_DEFER_FINALIZE) != 0) { fail(rt, BK_ERR_INVALID, "unknown class flags"); return 0; }
    embed::clear_err(rt);
    Heap* hp = rt.heap;
    heap::HostClassEntry* parent = null;
    if (def.parent != 0) {
        parent = api_class(rt, def.parent);
        if (parent == null) { fail(rt, BK_ERR_INVALID, "unknown parent class"); return 0; }
    }
    char[] name = ((ZString)def.name).str_view();
    HString* nm = embed::string_from_utf8(rt, name);
    if (nm == null) return 0;
    HObject*? proto_raw = hp.alloc_object(hobject::ObjClass.OBJECT);
    if (catch proto_raw) { fail(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    HObject* proto = proto_raw;
    hp.set_prototype(proto, parent != null ? parent.proto : hp.object_proto);
    // A trace callback has the shape of a host class mark function: the tracer
    // it receives is the marking heap.
    long id = hp.register_host_class(def.finalize, def.trace, def.opaque, (void*)nm, proto);
    if (id < 0) { fail(rt, BK_ERR_NOMEM, "host class table full"); return 0; }
    uint cls = (uint)id + 1;
    // Registration may have grown the table; re-read entries by id from here.
    hp.host_class_at((uint)id).parent = def.parent;
    hp.host_class_at((uint)id).flags = heap::HOST_CLASS_C_API | (def.flags & BK_CLASS_DEFER_FINALIZE);
    if (def.exotic != null) {
        BkExoticHooks* hooks = (BkExoticHooks*)hp.alloc_func(hp.heap_udata, BkExoticHooks::size);
        if (hooks == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
        *hooks = *def.exotic;
        hp.host_class_at((uint)id).exotic = hooks;
        if (hooks.call != null) hp.host_class_at((uint)id).flags |= heap::HOST_CLASS_EXOTIC_CALL;
        hp.host_exotic_ops = &exotic_ops;
    }
    void* construct = def.construct != null ? def.construct : (void*)&illegal_constructor;
    TVal ctor_tv;
    if (embed::make_c_function(rt, name, construct, def.opaque, null, null, def.arity, true, &ctor_tv, cls) != BK_OK) return 0;
    HObject* ctor = (HObject*)ctor_tv.get_heapptr();
    TVal proto_tv; proto_tv.set_object(proto);
    ctor.put_prop(hp.str(heap::BuiltinStr.PROTOTYPE), proto_tv, (hobject::PropFlags){}, hp);
    proto.put_prop(hp.str(heap::BuiltinStr.CONSTRUCTOR), ctor_tv, hobject::PROP_FLAGS_WC, hp);
    if (def.parent != 0) hp.set_prototype(ctor, hp.host_class_at(def.parent - 1).ctor);
    hp.host_class_at((uint)id).ctor = ctor;
    hp.shade_root_object(ctor);
    if (ctor_out != null) {
        *ctor_out = store(rt, ctor_tv);
        if (*ctor_out == 0) return 0;
    }
    if (proto_out != null) {
        *proto_out = store(rt, proto_tv);
        if (*proto_out == 0) return 0;
    }
    return cls;
}

fn ulong bk_new_instance(void* ctxp, uint cls, void* payload, ulong new_target) @export("bk_new_instance") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    heap::HostClassEntry* e = api_class(rt, cls);
    if (e == null) return fail_value(rt, BK_ERR_INVALID, "unknown class");
    Heap* hp = rt.heap;
    HObject* proto = e.proto;
    if (new_target != 0) {
        TVal nt;
        if (!resolve(ctxp, new_target, &nt)) return bad_handle(rt);
        if (!nt.is_object() || !((HObject*)nt.get_heapptr()).is_constructable()) {
            return fail_value(rt, BK_ERR_TYPE, "new_target is not a constructor");
        }
        HObject* nto = (HObject*)nt.get_heapptr();
        TVal pv;
        hp.has_error = false;
        if (!builtins::js_get_with_receiver((void*)rt.vm, hp, nto, hp.str(heap::BuiltinStr.PROTOTYPE), nt, &pv)) {
            vm_fault(rt);
            return 0;
        }
        if (pv.is_object()) proto = (HObject*)pv.get_heapptr();
        // GetPrototypeFromConstructor may have run JS; reload the entry.
        e = api_class(rt, cls);
    }
    HObject*? inst_raw = hp.alloc_object(hobject::ObjClass.HOST);
    if (catch inst_raw) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    HObject* inst = inst_raw;
    (*inst.extra_ptr()).host.class_id = cls - 1;
    (*inst.extra_ptr()).host.payload = payload;
    hp.set_prototype(inst, proto);
    TVal v; v.set_object(inst);
    if (e.exotic != null) {
        HObject* wrapped = builtins::host_exotic_create(hp, inst, e.exotic, (e.flags & heap::HOST_CLASS_EXOTIC_CALL) != 0);
        if (wrapped == null) {
            // The collector frees the instance; the caller keeps the payload.
            (*inst.extra_ptr()).host.payload = null;
            return fail_value(rt, BK_ERR_NOMEM, "out of memory");
        }
        v.set_object(wrapped);
    }
    return store(rt, v);
}

fn void* bk_get_instance_payload(void* ctxp, ulong id, uint cls) @export("bk_get_instance_payload") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal v;
    if (!resolve(ctxp, id, &v)) return null;
    uint have = instance_class(rt, v);
    if (have == 0 || !class_is_a(rt, have, cls)) return null;
    return (*host_instance(v).extra_ptr()).host.payload;
}

fn int bk_set_instance_payload(void* ctxp, ulong id, uint cls, void* payload) @export("bk_set_instance_payload") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return BK_ERR_INVALID; }
    uint have = instance_class(rt, v);
    if (have == 0 || !class_is_a(rt, have, cls)) return fail(rt, BK_ERR_TYPE, "not an instance of the class");
    HObject* o = host_instance(v);
    if (payload != null && (*o.extra_ptr()).host.payload != null) {
        return fail(rt, BK_ERR_INVALID, "instance already has a payload");
    }
    (*o.extra_ptr()).host.payload = payload;
    return BK_OK;
}

fn uint bk_get_instance_class(void* ctxp, ulong id) @export("bk_get_instance_class") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return 0;
    return instance_class(rt, v);
}

// ============================================================================
// Exotic hooks and Proxy creation
// ============================================================================

alias BkExoticGetOwn  = fn int(void* ctx, ulong self, uint key, BkPropertyDescriptor* desc, void* opaque);
alias BkExoticDefine  = fn int(void* ctx, ulong self, uint key, BkPropertyDescriptor* desc, int* ok, void* opaque);
alias BkExoticRemove  = fn int(void* ctx, ulong self, uint key, int* ok, void* opaque);
alias BkExoticOwnKeys = fn int(void* ctx, ulong self, ulong* keys_out, void* opaque);
alias BkExoticCall    = fn ulong(void* ctx, ulong self, ulong this_value, uint argc, ulong* argv, void* opaque);

// Layout must match bk_exotic_hooks in include/boomkat.h.
struct BkExoticHooks {
    BkExoticGetOwn  get_own;
    BkExoticDefine  define_own;
    BkExoticRemove  remove;
    BkExoticOwnKeys own_keys;
    BkExoticCall    call;
}

builtins::HostExoticOps exotic_ops = {
    .get_own  = &exotic_get_own,
    .define   = &exotic_define,
    .remove   = &exotic_remove,
    .own_keys = &exotic_own_keys,
    .call     = &exotic_call,
};

// The state a hook call runs in: the context of the current realm, a local
// scope for the values it creates, and `self` as a local.
struct HookFrame {
    Runtime*     rt;
    Ctx*         ctx;
    Ctx*         previous;
    heap::Realm* realm;
    uint         scope;
    ulong        self;
    BkExoticHooks* hooks;
    void*        opaque;
}

fn bool hook_enter(Heap* hp, HObject* self, HookFrame* f) {
    Runtime* rt = (Runtime*)hp.capi_runtime;
    HObject* inst = builtins::proxy_target(self);
    heap::HostClassEntry* e = hp.host_class_at((*inst.extra_ptr()).host.class_id);
    Ctx* ctx = embed::realm_context(rt, hp.realm);
    if (ctx == null) { builtins::proxy_throw_type(hp, "missing host context"); return false; }
    *f = { .rt = rt, .ctx = ctx, .previous = rt.active, .realm = hp.realm,
           .hooks = (BkExoticHooks*)e.exotic, .opaque = e.udata };
    embed::select_context(ctx);
    f.scope = embed::scope_open(rt);
    if (f.scope == 0) { hook_leave(f); builtins::proxy_throw_type(hp, "local scope full"); return false; }
    TVal sv; sv.set_object(self);
    f.self = embed::store_value(rt, sv);
    if (f.self == 0) { hook_leave(f); builtins::proxy_throw_type(hp, "local scope full"); return false; }
    return true;
}

fn void hook_leave(HookFrame* f) {
    if (f.scope != 0) embed::scope_close(f.rt, f.scope);
    f.scope = 0;
    embed::select_context(f.previous);
    f.rt.heap.enter_realm(f.realm);
}

// Turns a hook's -1 into the engine's pending error: the exception it threw,
// or a TypeError when it threw nothing.
fn int hook_threw(HookFrame* f) {
    Runtime* rt = f.rt;
    Heap* hp = rt.heap;
    if (hp.uncatchable_throw) return -1;
    if (rt.exception == 0 && rt.pending_code == 0) {
        builtins::proxy_throw_type(hp, "exotic hook failed without an exception");
        return -1;
    }
    ulong exception = embed::take_exception(rt);
    TVal thrown;
    if (!embed::slot_get(rt, exception, &thrown)) {
        builtins::proxy_throw_type(hp, "exotic hook failed without an exception");
        return -1;
    }
    hp.has_error = true;
    hp.@set_edge(null, hp.error_value, thrown);
    embed::slot_release(rt, exception);
    return -1;
}

// An atom for `key` that the hook borrows, released by the caller.
fn uint hook_atom(HookFrame* f, HString* key) {
    uint atom = embed::atom_intern(f.rt, key);
    if (atom == 0) builtins::proxy_throw_type(f.rt.heap, "out of memory");
    return atom;
}

// Keeps a hook result alive past its scope, until the next hook call.
fn void hold(Heap* hp, uint i, TVal v) {
    hp.@set_edge(null, hp.host_exotic_hold[i], v);
}

fn int exotic_get_own(void* vm, Heap* hp, HObject* self, HString* key, builtins::ProxyDesc* out) {
    HookFrame f;
    if (!hook_enter(hp, self, &f)) return -1;
    defer hook_leave(&f);
    if (f.hooks.get_own == null) return 0;
    uint atom = hook_atom(&f, key);
    if (atom == 0) return -1;
    defer embed::atom_release(f.rt, atom);
    BkPropertyDescriptor desc = { .value = embed::IMM_UNDEFINED, .get = embed::IMM_UNDEFINED, .set = embed::IMM_UNDEFINED };
    int r = f.hooks.get_own(f.ctx, f.self, atom, &desc, f.opaque);
    if (r < 0) return hook_threw(&f);
    if (r == 0) return 0;
    *out = {};
    if (desc.flags == 0) return 1;   // handled: no such property
    builtins::ProxyDesc pd;
    if (desc_from_bk(f.ctx, f.rt, &desc, &pd) != BK_OK) {
        builtins::proxy_throw_type(hp, "get_own hook returned an invalid descriptor");
        return -1;
    }
    pd.complete();
    hold(hp, 0, pd.value);
    hold(hp, 1, pd.getter);
    hold(hp, 2, pd.setter);
    *out = pd;
    return 1;
}

// The C form of an engine descriptor, with its values as locals.
fn bool desc_to_bk(Runtime* rt, builtins::ProxyDesc* pd, BkPropertyDescriptor* out) {
    *out = { .value = embed::IMM_UNDEFINED, .get = embed::IMM_UNDEFINED, .set = embed::IMM_UNDEFINED };
    uint fl;
    if (pd.has_value) {
        fl |= BK_PROP_HAS_VALUE;
        out.value = store(rt, pd.value);
        if (out.value == 0) return false;
    }
    if (pd.has_get) {
        fl |= BK_PROP_HAS_GET;
        out.get = store(rt, pd.getter);
        if (out.get == 0) return false;
    }
    if (pd.has_set) {
        fl |= BK_PROP_HAS_SET;
        out.set = store(rt, pd.setter);
        if (out.set == 0) return false;
    }
    if (pd.has_writable) fl |= BK_PROP_HAS_WRITABLE | (pd.writable ? BK_PROP_WRITABLE : 0);
    if (pd.has_enumerable) fl |= BK_PROP_HAS_ENUMERABLE | (pd.enumerable ? BK_PROP_ENUMERABLE : 0);
    if (pd.has_configurable) fl |= BK_PROP_HAS_CONFIGURABLE | (pd.configurable ? BK_PROP_CONFIGURABLE : 0);
    out.flags = fl;
    return true;
}

fn int exotic_define(void* vm, Heap* hp, HObject* self, HString* key, builtins::ProxyDesc* desc, bool* res) {
    HookFrame f;
    if (!hook_enter(hp, self, &f)) return -1;
    defer hook_leave(&f);
    if (f.hooks.define_own == null) return 0;
    uint atom = hook_atom(&f, key);
    if (atom == 0) return -1;
    defer embed::atom_release(f.rt, atom);
    BkPropertyDescriptor bd;
    if (!desc_to_bk(f.rt, desc, &bd)) { builtins::proxy_throw_type(hp, "local scope full"); return -1; }
    int ok = 0;
    int r = f.hooks.define_own(f.ctx, f.self, atom, &bd, &ok, f.opaque);
    if (r < 0) return hook_threw(&f);
    if (r > 0) *res = ok != 0;
    return r;
}

fn int exotic_remove(void* vm, Heap* hp, HObject* self, HString* key, bool* res) {
    HookFrame f;
    if (!hook_enter(hp, self, &f)) return -1;
    defer hook_leave(&f);
    if (f.hooks.remove == null) return 0;
    uint atom = hook_atom(&f, key);
    if (atom == 0) return -1;
    defer embed::atom_release(f.rt, atom);
    int ok = 0;
    int r = f.hooks.remove(f.ctx, f.self, atom, &ok, f.opaque);
    if (r < 0) return hook_threw(&f);
    if (r > 0) *res = ok != 0;
    return r;
}

fn int exotic_own_keys(void* vm, Heap* hp, HObject* self, TVal* list_out) {
    HookFrame f;
    if (!hook_enter(hp, self, &f)) return -1;
    defer hook_leave(&f);
    if (f.hooks.own_keys == null) return 0;
    ulong keys = 0;
    int r = f.hooks.own_keys(f.ctx, f.self, &keys, f.opaque);
    if (r < 0) return hook_threw(&f);
    if (r == 0) return 0;
    if (!embed::resolve_handle(f.rt, keys, list_out)) {
        builtins::proxy_throw_type(hp, "own_keys hook returned an invalid handle");
        return -1;
    }
    hold(hp, 0, *list_out);
    return 1;
}

fn void exotic_call(builtins::BuiltinContext* bctx, HObject* self) {
    Heap* hp = bctx.heap;
    HookFrame f;
    if (!hook_enter(hp, self, &f)) {
        builtins::host_throw(bctx, hp.error_value);
        hp.has_error = false;
        return;
    }
    defer hook_leave(&f);
    Runtime* rt = f.rt;
    uint argc = bctx.argc;
    ulong[16] local_args;
    ulong* args = &local_args;
    if (argc > local_args.len) {
        args = (ulong*)hp.alloc_func(hp.heap_udata, (usz)argc * ulong::size);
        if (args == null) { builtins::host_throw_error(bctx, builtins::HOST_ERR_ERROR, "out of memory"); return; }
    }
    defer if (args != &local_args) hp.free_func(hp.heap_udata, args);
    ulong this_h = store(rt, bctx.this_val);
    if (this_h == 0) { builtins::host_throw_error(bctx, builtins::HOST_ERR_RANGE, "local scope full"); return; }
    for (uint i = 0; i < argc; i++) {
        args[i] = store(rt, bctx.regs[bctx.base_reg + i]);
        if (args[i] == 0) { builtins::host_throw_error(bctx, builtins::HOST_ERR_RANGE, "local scope full"); return; }
    }
    ulong result = f.hooks.call(f.ctx, f.self, this_h, argc, args, f.opaque);
    embed::select_context(f.ctx);
    if (hp.uncatchable_throw) { builtins::host_throw(bctx, hp.error_value); return; }
    if (result == 0) {
        hook_threw(&f);
        hp.has_error = false;
        builtins::host_throw(bctx, hp.error_value);
        return;
    }
    TVal value;
    if (!embed::resolve_handle(rt, result, &value)) {
        builtins::host_throw_error(bctx, builtins::HOST_ERR_TYPE, "call hook returned an invalid or freed handle");
        return;
    }
    bctx.copy_result(value);
}

fn ulong bk_new_proxy(void* ctxp, ulong target, ulong handler) @export("bk_new_proxy") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal t;
    TVal h;
    if (!resolve(ctxp, target, &t) || !resolve(ctxp, handler, &h)) return bad_handle(rt);
    TVal result;
    builtins::BuiltinContext call = { .heap = rt.heap, .vm = rt.vm, .result = builtins::result_slot(&result) };
    HObject* p = builtins::proxy_create(&call, t, h);
    if (call.should_throw) { embed::describe_error(rt, &call.throw_value); return 0; }
    if (p == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    TVal pv; pv.set_object(p);
    return store(rt, pv);
}

// ============================================================================
// Traced slots
// ============================================================================

// bk_slot is two 64-bit words, which holds a TVal in either value layout.
const usz BK_SLOT_SIZE = 16;
$assert(TVal::size <= BK_SLOT_SIZE);

fn void bk_slot_init(void* slot) @export("bk_slot_init") {
    if (slot == null) return;
    mem::clear(slot, BK_SLOT_SIZE);
    ((TVal*)slot).set_undefined();
}

// Stores `id` with a reference. The value is shaded, so an owner traced
// earlier in an incremental cycle cannot hide it from the collector.
fn int bk_slot_set(void* ctxp, void* slot, ulong id) @export("bk_slot_set") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || slot == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return BK_ERR_INVALID; }
    rt.heap.tval_copy_ref((TVal*)slot, &v);
    return BK_OK;
}

fn ulong bk_slot_get(void* ctxp, void* slot) @export("bk_slot_get") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (slot == null) return fail_value(rt, BK_ERR_INVALID, "null slot");
    embed::clear_err(rt);
    return store(rt, *(TVal*)slot);
}

fn void bk_slot_clear(void* ctxp, void* slot) @export("bk_slot_clear") {
    Runtime* rt = rt_of(ctxp);
    if (slot == null) return;
    if (rt != null && !rt.heap.tearing_down) rt.heap.decref_tval((TVal*)slot);
    ((TVal*)slot).set_undefined();
}

fn void bk_trace_slot(void* tracer, void* slot) @export("bk_trace_slot") {
    if (tracer == null || slot == null) return;
    ((Heap*)tracer).mark_tval((TVal*)slot);
}

fn void bk_set_root_tracer(void* runtime, void* callback, void* opaque) @export("bk_set_root_tracer") {
    if (runtime == null) return;
    Runtime* rt = (Runtime*)runtime;
    rt.root_tracer = (embed::BkRootTracer)callback;
    rt.root_tracer_opaque = opaque;
}

// ============================================================================
// Job hook, wait and wake
// ============================================================================

fn void bk_set_job_hook(void* runtime, void* hook, void* opaque) @export("bk_set_job_hook") {
    if (runtime == null) return;
    Heap* hp = ((Runtime*)runtime).heap;
    hp.job_hook = (heap::JobHookFn)hook;
    hp.job_hook_runtime = runtime;
    hp.job_hook_opaque = opaque;
}

fn int bk_wait_events(void* runtime, double timeout_ms) @export("bk_wait_events") {
    if (runtime == null) return 0;
    return agent::wait_host_events(((Runtime*)runtime).heap, timeout_ms) ? 1 : 0;
}

fn void bk_wake(void* runtime) @export("bk_wake") {
    if (runtime == null) return;
    agent::port_post_event(agent::port_for(((Runtime*)runtime).heap));
}

fn uint bk_run_finalizers(void* runtime) @export("bk_run_finalizers") {
    if (runtime == null) return 0;
    return ((Runtime*)runtime).heap.run_deferred_finalizers();
}

// ============================================================================
// Builtin calls
// ============================================================================

fn bool has_builtin(builtins::Builtin which) @inline => builtins::builtin_dispatch_table[which.ordinal] != null;

// Run builtin `which` of the context's realm on `args` with `this_value`,
// writing its result to `out`. Returns a BK_* status with the failure
// recorded; BK_ERR_UNSUPPORTED when the build leaves the builtin out.
fn int call_builtin(Runtime* rt, builtins::Builtin which, TVal this_value, TVal* args, uint argc, TVal* out) {
    if (!has_builtin(which)) return fail(rt, BK_ERR_UNSUPPORTED, "not available in this build");
    TVal function;
    function.set_builtin(rt.heap, which.ordinal);
    rt.heap.has_error = false;
    *out = rt.heap.call_fn(rt.vm, function, args, argc, this_value);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) {
        int rc = vm_fault(rt);
        rt.heap.has_error = false;
        rt.vm.has_error = false;
        rt.vm.throw_pending = false;
        return rc;
    }
    return BK_OK;
}

// LengthOfArrayLike (ECMA-262 §7.3.18): ToLength(Get(obj, "length")).
fn int length_of(Runtime* rt, HObject* obj, ulong* out) {
    TVal ov; ov.set_object(obj);
    TVal got;
    rt.heap.has_error = false;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, obj, rt.heap.str(heap::BuiltinStr.LENGTH), ov, &got)) {
        return vm_fault(rt);
    }
    double d = got.is_numeric() ? got.get_number_or_fastint() : vm::vm_to_number(rt.vm, &got);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) return vm_fault(rt);
    // ToLength: NaN and negatives clamp to 0, the rest truncate up to 2^53 - 1.
    if (!(d > 0)) { *out = 0; return BK_OK; }
    if (d >= 9007199254740991.0) { *out = 9007199254740991; return BK_OK; }
    *out = (ulong)d;
    return BK_OK;
}

// ============================================================================
// Own keys
// ============================================================================

const uint BK_KEYS_STRINGS = 1;
const uint BK_KEYS_SYMBOLS = 2;
const uint BK_KEYS_ENUMERABLE_ONLY = 4;
const uint BK_KEYS_SKIP_INDICES = 8;

// The object's [[OwnPropertyKeys]] in order, filtered by `flags`. Strings and
// symbols are both included unless one kind is asked for. Enumerability is
// read through [[GetOwnProperty]], so a proxy sees its traps called in the
// order Object.keys calls them.
fn ulong bk_get_own_property_keys(void* ctxp, ulong obj_id, uint flags) @export("bk_get_own_property_keys") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if ((flags & ~15u) != 0) return fail_value(rt, BK_ERR_INVALID, "unknown key flags");
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return 0;
    Heap* h = rt.heap;
    bool want_strings = (flags & (BK_KEYS_STRINGS | BK_KEYS_SYMBOLS)) == 0 || (flags & BK_KEYS_STRINGS) != 0;
    bool want_symbols = (flags & (BK_KEYS_STRINGS | BK_KEYS_SYMBOLS)) == 0 || (flags & BK_KEYS_SYMBOLS) != 0;

    // Reflect.ownKeys runs [[OwnPropertyKeys]] once; a build without it lists
    // the two kinds, strings first, as [[OwnPropertyKeys]] orders them.
    TVal all;
    TVal undefined; undefined.set_undefined();
    builtins::Builtin source_fn = want_strings && want_symbols && has_builtin(builtins::Builtin.REFLECT_OWNKEYS)
        ? builtins::Builtin.REFLECT_OWNKEYS
        : want_symbols && !want_strings ? builtins::Builtin.OBJECT_GETOWNPROPERTYSYMBOLS
        : builtins::Builtin.OBJECT_GETOWNPROPERTYNAMES;
    if (call_builtin(rt, source_fn, undefined, &ov, 1, &all) != BK_OK) return 0;
    if (want_strings && want_symbols && source_fn != builtins::Builtin.REFLECT_OWNKEYS) {
        TVal symbols;
        ulong strings_root = embed::slot_alloc(rt, all);
        if (strings_root == 0) return fail_value(rt, BK_ERR_FULL, "value registry full");
        defer embed::slot_release(rt, strings_root);
        if (call_builtin(rt, builtins::Builtin.OBJECT_GETOWNPROPERTYSYMBOLS, undefined, &ov, 1, &symbols) != BK_OK) return 0;
        HObject* dst = (HObject*)all.get_heapptr();
        HObject* src = (HObject*)symbols.get_heapptr();
        ulong have, extra;
        if (length_of(rt, dst, &have) != BK_OK || length_of(rt, src, &extra) != BK_OK) return 0;
        for (uint i = 0; i < (uint)extra; i++) {
            builtins::array_set_elem(dst, (uint)have + i, builtins::array_get_elem(src, i, h), h);
        }
        TVal total; total.set_fastint((long)(have + extra));
        dst.put_prop(h.str(heap::BuiltinStr.LENGTH), total, hobject::PROP_FLAGS_WC, h);
    }
    if ((flags & (BK_KEYS_ENUMERABLE_ONLY | BK_KEYS_SKIP_INDICES)) == 0) return store(rt, all);
    // Both arrays stay rooted while descriptor traps run.
    ulong all_root = embed::slot_alloc(rt, all);
    if (all_root == 0) return fail_value(rt, BK_ERR_FULL, "value registry full");
    defer embed::slot_release(rt, all_root);
    HObject* source = (HObject*)all.get_heapptr();
    HObject* result = new_array(rt);
    if (result == null) return 0;
    TVal rv; rv.set_object(result);
    ulong result_root = embed::slot_alloc(rt, rv);
    if (result_root == 0) return fail_value(rt, BK_ERR_FULL, "value registry full");
    defer embed::slot_release(rt, result_root);

    HString* length_key = h.str(heap::BuiltinStr.LENGTH);
    ulong count;
    if (length_of(rt, source, &count) != BK_OK) return 0;
    uint written = 0;
    for (uint i = 0; i < (uint)count; i++) {
        TVal kv = builtins::array_get_elem(source, i, h);
        if (!kv.is_string()) continue;
        HString* key = (HString*)kv.get_heapptr();
        if (key.is_symbol() ? !want_symbols : !want_strings) continue;
        if ((flags & BK_KEYS_SKIP_INDICES) != 0 && !key.is_symbol() && key.is_arridx()) continue;
        if ((flags & BK_KEYS_ENUMERABLE_ONLY) != 0) {
            builtins::ProxyDesc desc;
            if (!builtins::own_property_desc(rt.vm, h, obj, key, &desc)) { vm_fault(rt); return 0; }
            if (!desc.found || !desc.enumerable) continue;
        }
        builtins::array_set_elem(result, written++, kv, h);
    }
    TVal written_tv; written_tv.set_fastint((long)written);
    result.put_prop(length_key, written_tv, hobject::PROP_FLAGS_WC, h);
    return store(rt, rv);
}

// ============================================================================
// Calls
// ============================================================================

fn ulong bk_call(void* ctxp, ulong fn_id, ulong this_id, ulong* argv, uint argc) @export("bk_call") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (argc > 0xFFFFu) return bk_throw_error(ctxp, builtins::HOST_ERR_RANGE, "too many arguments");
    TVal function;
    if (!resolve(ctxp, fn_id, &function)) return bad_handle(rt);
    if (!builtins::is_callable_tval(function)) { fail(rt, BK_ERR_TYPE, "value is not a function"); return 0; }
    if (argc != 0 && argv == null) { fail(rt, BK_ERR_INVALID, "null argument array"); return 0; }
    TVal this_value;
    if (this_id == 0) { this_value.set_undefined(); }
    else if (!resolve(ctxp, this_id, &this_value)) { return bad_handle(rt); }
    TVal[16] local_args;
    TVal* args = &local_args;
    if (argc > local_args.len) {
        args = (TVal*)rt.heap.alloc_func(rt.heap.heap_udata, (usz)argc * TVal::size);
        if (args == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    }
    defer if (args != &local_args) rt.heap.free_func(rt.heap.heap_udata, args);
    for (uint i = 0; i < argc; i++) {
        if (!resolve(ctxp, argv[i], &args[i])) return bad_handle(rt);
    }
    rt.heap.has_error = false;
    TVal result = rt.heap.call_fn(rt.vm, function, args, argc, this_value);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) {
        vm_fault(rt);
        rt.heap.has_error = false;
        rt.vm.has_error = false;
        rt.vm.throw_pending = false;
        return 0;
    }
    return store(rt, result);
}

// ============================================================================
// Object model
// ============================================================================

// Resolves `argc` handles into `args`, which holds 16 values; larger lists are
// allocated and must be released with free_args. Returns null on failure.
fn TVal* resolve_args(void* ctxp, Runtime* rt, ulong* argv, uint argc, TVal* local) {
    if (argc != 0 && argv == null) { fail(rt, BK_ERR_INVALID, "null argument array"); return null; }
    TVal* args = local;
    if (argc > 16) {
        args = (TVal*)rt.heap.alloc_func(rt.heap.heap_udata, (usz)argc * TVal::size);
        if (args == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    }
    for (uint i = 0; i < argc; i++) {
        if (!resolve(ctxp, argv[i], &args[i])) {
            free_args(rt, args, local);
            bad_handle(rt);
            return null;
        }
    }
    return args;
}

fn void free_args(Runtime* rt, TVal* args, TVal* local) @inline {
    if (args != null && args != local) rt.heap.free_func(rt.heap.heap_udata, args);
}

fn bool constructable(TVal v) @inline {
    return v.is_object() && v.get_heapptr() != null && ((HObject*)v.get_heapptr()).is_constructable();
}

fn ulong bk_construct(void* ctxp, ulong ctor_id, ulong* argv, uint argc, ulong new_target_id) @export("bk_construct") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (argc > 0xFFFFu) return bk_throw_error(ctxp, builtins::HOST_ERR_RANGE, "too many arguments");
    TVal ctor, new_target;
    if (!resolve(ctxp, ctor_id, &ctor)) return bad_handle(rt);
    if (!constructable(ctor)) return fail_value(rt, BK_ERR_TYPE, "value is not a constructor");
    if (new_target_id == 0) {
        new_target = ctor;
    } else {
        if (!resolve(ctxp, new_target_id, &new_target)) return bad_handle(rt);
        if (!constructable(new_target)) return fail_value(rt, BK_ERR_TYPE, "new.target is not a constructor");
    }
    TVal[16] local_args;
    TVal* args = resolve_args(ctxp, rt, argv, argc, &local_args);
    if (args == null && argc != 0) return 0;
    defer free_args(rt, args, &local_args);
    rt.heap.has_error = false;
    TVal result = rt.heap.construct_fn(rt.vm, ctor, args, argc, new_target);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) {
        vm_fault(rt);
        rt.heap.has_error = false;
        rt.vm.has_error = false;
        rt.vm.throw_pending = false;
        return 0;
    }
    if (!result.is_object()) return fail_value(rt, BK_ERR_NOMEM, "construction failed");
    return store(rt, result);
}

fn ulong bk_new_object_with_proto(void* ctxp, ulong proto_id) @export("bk_new_object_with_proto") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal proto;
    if (!resolve(ctxp, proto_id, &proto)) return bad_handle(rt);
    if (!proto.is_object() && !proto.is_null()) return fail_value(rt, BK_ERR_TYPE, "prototype must be an object or null");
    HObject*? oraw = rt.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch oraw) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    HObject* o = oraw;
    rt.heap.set_prototype(o, proto.is_null() ? null : (HObject*)proto.get_heapptr());
    TVal v; v.set_object(o);
    return store(rt, v);
}

fn ulong bk_get_prototype(void* ctxp, ulong obj_id) @export("bk_get_prototype") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return 0;
    TVal proto;
    rt.heap.has_error = false;
    if (!builtins::object_get_proto(rt.vm, rt.heap, obj, &proto)) { vm_fault(rt); return 0; }
    return store(rt, proto);
}

// Object.setPrototypeOf: a refusal (non-extensible object, cycle, immutable
// prototype, proxy trap) throws a TypeError.
fn int bk_set_prototype(void* ctxp, ulong obj_id, ulong proto_id) @export("bk_set_prototype") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal[2] args;
    if (as_object(ctxp, obj_id, &args[0]) == null) return rt.errcode;
    if (!resolve(ctxp, proto_id, &args[1])) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!args[1].is_object() && !args[1].is_null()) return fail(rt, BK_ERR_TYPE, "prototype must be an object or null");
    TVal undefined; undefined.set_undefined();
    TVal out;
    return call_builtin(rt, builtins::Builtin.OBJECT_SETPROTOTYPEOF, undefined, &args, 2, &out);
}

// InstanceofOperator (ECMA-262 §13.10.2): @@hasInstance when present, else
// OrdinaryHasInstance.
fn int bk_instanceof(void* ctxp, ulong value_id, ulong ctor_id, int* out) @export("bk_instanceof") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal value, ctor;
    if (!resolve(ctxp, value_id, &value) || !resolve(ctxp, ctor_id, &ctor)) {
        return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    }
    if (!ctor.is_object()) return fail(rt, BK_ERR_TYPE, "right-hand side of instanceof is not an object");
    HObject* target = (HObject*)ctor.get_heapptr();
    TVal method;
    rt.heap.has_error = false;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, target, rt.heap.hasinstance_symbol, ctor, &method)) {
        return vm_fault(rt);
    }
    TVal result;
    if (!method.is_undefined() && !method.is_null()) {
        if (!builtins::is_callable_tval(method)) return fail(rt, BK_ERR_TYPE, "Symbol.hasInstance is not callable");
        rt.heap.has_error = false;
        result = rt.heap.call_fn(rt.vm, method, &value, 1, ctor);
        if (rt.heap.has_error || rt.heap.uncatchable_throw) {
            int rc = vm_fault(rt);
            rt.heap.has_error = false;
            rt.vm.has_error = false;
            rt.vm.throw_pending = false;
            return rc;
        }
    } else {
        if (!builtins::is_callable_tval(ctor)) return fail(rt, BK_ERR_TYPE, "right-hand side of instanceof is not callable");
        int rc = call_builtin(rt, builtins::Builtin.FUNCTION_PROTO_HASINSTANCE, ctor, &value, 1, &result);
        if (rc != BK_OK) return rc;
    }
    *out = builtins::builtin_to_boolean(&result) ? 1 : 0;
    return BK_OK;
}

// IsStrictlyEqual. A handle that does not resolve compares unequal.
fn int bk_strict_equals(void* ctxp, ulong a_id, ulong b_id) @export("bk_strict_equals") {
    TVal a, b;
    if (rt_of(ctxp) == null || !resolve(ctxp, a_id, &a) || !resolve(ctxp, b_id, &b)) return 0;
    return vm::strict_eq(&a, &b) ? 1 : 0;
}

// SameValue. A handle that does not resolve compares unequal.
fn int bk_same_value(void* ctxp, ulong a_id, ulong b_id) @export("bk_same_value") {
    TVal a, b;
    if (rt_of(ctxp) == null || !resolve(ctxp, a_id, &a) || !resolve(ctxp, b_id, &b)) return 0;
    return builtins::same_value(a, b) ? 1 : 0;
}

// IsArray: 1 or 0, or -1 when a revoked proxy makes it throw.
fn int bk_is_array(void* ctxp, ulong id) @export("bk_is_array") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return -1;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return -1; }
    TVal undefined; undefined.set_undefined();
    TVal result;
    if (call_builtin(rt, builtins::Builtin.ARRAY_ISARRAY, undefined, &v, 1, &result) != BK_OK) return -1;
    return result.is_boolean() && result.get_boolean() ? 1 : 0;
}

fn int bk_get_length(void* ctxp, ulong obj_id, ulong* out) @export("bk_get_length") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    return length_of(rt, obj, out);
}

fn ulong bk_json_parse(void* ctxp, char* utf8, usz len) @export("bk_json_parse") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (utf8 == null && len != 0) return fail_value(rt, BK_ERR_INVALID, "null text");
    embed::clear_err(rt);
    HString* text = embed::string_from_utf8(rt, utf8[:len]);
    if (text == null) return 0;
    TVal arg; arg.set_string_borrowed(text);
    // The text is unreachable from JS while the parser allocates.
    ulong held = embed::slot_alloc(rt, arg);
    if (held == 0) return fail_value(rt, BK_ERR_FULL, "value registry full");
    defer embed::slot_release(rt, held);
    TVal undefined; undefined.set_undefined();
    TVal result;
    if (call_builtin(rt, builtins::Builtin.JSON_PARSE, undefined, &arg, 1, &result) != BK_OK) return 0;
    return store(rt, result);
}

// The JSON text of `value`, or undefined for a value JSON cannot represent.
fn ulong bk_json_stringify(void* ctxp, ulong id) @export("bk_json_stringify") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    TVal undefined; undefined.set_undefined();
    TVal result;
    if (call_builtin(rt, builtins::Builtin.JSON_STRINGIFY, undefined, &v, 1, &result) != BK_OK) return 0;
    return store(rt, result);
}

// ============================================================================
// Host functions
// ============================================================================

// Layout must match bk_fn_def in include/boomkat.h on the target's ABI.
struct BkFnDef {
    char* name;
    void* cfn;
    int   arity;
    uint  flags;
    void* udata;
    void* finalize;
    void* finalize_opaque;
}

const uint BK_CTOR = 1;

// Install a table of host functions, ending at the first entry with a null
// name. `target_id` 0 means globalThis, which is an environment binding rather
// than a property write, so the two cases stay separate below.
// Runs the finalizers of the entries from `from` on, which a failed
// bk_set_function_list never created.
fn void finalize_entries(BkFnDef* defs, usz from) {
    for (usz i = from; defs[i].name != null; i++) {
        embed::BkFinalizer fin = (embed::BkFinalizer)defs[i].finalize;
        if (fin != null) fin(defs[i].udata, defs[i].finalize_opaque);
    }
}

fn int bk_set_function_list(void* ctxp, ulong target_id, BkFnDef* defs) @export("bk_set_function_list") {
    if (defs == null) return BK_ERR_INVALID;
    Runtime* rt = rt_of(ctxp);
    if (rt == null) { finalize_entries(defs, 0); return BK_ERR_INVALID; }
    embed::clear_err(rt);

    TVal ov;
    HObject* target = null;
    if (target_id != 0) {
        target = as_object(ctxp, target_id, &ov);
        if (target == null) { finalize_entries(defs, 0); return rt.errcode; }
    }

    for (usz i = 0; defs[i].name != null; i++) {
        BkFnDef* d = &defs[i];
        if (d.cfn == null) {
            finalize_entries(defs, i);
            return fail(rt, BK_ERR_INVALID, "table entry has no function");
        }
        usz nlen = 0;
        while (d.name[nlen] != 0) nlen++;

        // A failed entry has been finalized by install_function.
        int rc = install_function(rt, target, d.name[:nlen], d.cfn, d.udata,
                                  (embed::BkFinalizer)d.finalize, d.finalize_opaque, d.arity, d.flags);
        if (rc != BK_OK) { finalize_entries(defs, i + 1); return rc; }
    }
    return BK_OK;
}

// Install one host function on `target`, or as a global when it is null.
fn int install_function(Runtime* rt, HObject* target, char[] name, void* cfn, void* udata,
                        embed::BkFinalizer finalize, void* finalize_opaque, int arity, uint flags) {
    TVal fv;
    int rc = embed::make_c_function(rt, name, cfn, udata, finalize, finalize_opaque, arity, (flags & BK_CTOR) != 0, &fv);
    if (rc != BK_OK) return rc;
    if (target == null) return embed::declare_global(rt, name, fv);
    HString* k = rt.heap.str_intern(name);
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    if (!target.put_prop(k, fv, hobject::PROP_FLAGS_WC, rt.heap)) {
        return fail(rt, BK_ERR_INTERNAL, "could not install function on target");
    }
    return BK_OK;
}

fn int bk_register_fn(void* ctxp, ulong target_id, char* name, void* fn_ptr, int arity, uint flags, void* udata)
        @export("bk_register_fn") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || name == null || fn_ptr == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal ov;
    HObject* target = null;
    if (target_id != 0) {
        target = as_object(ctxp, target_id, &ov);
        if (target == null) return rt.errcode;
    }
    return install_function(rt, target, ((ZString)name).str_view(), fn_ptr, udata, null, null, arity, flags);
}

fn uint bk_argc(void* ctxp) @export("bk_argc") {
    void* bctx = bctx_of(ctxp);
    return bctx == null ? 0 : builtins::host_argc((builtins::BuiltinContext*)bctx);
}

// The scope depth of the live call behind a context.
macro uint call_depth(void* bctx) => ((builtins::BuiltinContext*)bctx).host_scope_slot - 1;

fn ulong bk_arg(void* ctxp, uint i) @export("bk_arg") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    if (i >= builtins::host_argc((builtins::BuiltinContext*)bctx)) return embed::IMM_UNDEFINED;
    return embed::scope_handle(rt_of(ctxp), call_depth(bctx), (ulong)heap::HOST_SCOPE_ARG0 + i);
}

fn ulong bk_this(void* ctxp) @export("bk_this") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    return embed::scope_handle(rt_of(ctxp), call_depth(bctx), (ulong)heap::HOST_SCOPE_THIS);
}

fn int bk_set_global_property(void* ctxp, char* name, usz name_len, ulong val_id)
        @export("bk_set_global_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || name == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, val_id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    return embed::declare_global(rt, name[:name_len], v);
}

fn ulong bk_get_new_target(void* ctxp) @export("bk_get_new_target") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    return embed::scope_handle(rt_of(ctxp), call_depth(bctx), (ulong)heap::HOST_SCOPE_NEW_TARGET);
}

fn int bk_is_constructor_call(void* ctxp) @export("bk_is_constructor_call") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    return builtins::host_is_construct((builtins::BuiltinContext*)bctx) ? 1 : 0;
}



// Set a pending exception without unwinding through C.
fn ulong bk_throw_error(void* ctxp, int kind, char* msg) @export("bk_throw_error") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    builtins::BuiltinContext call = { .heap = rt.heap, .vm = rt.vm };
    builtins::host_throw_error(&call, kind, msg == null ? (char[])"" : ((ZString)msg).str_view());
    embed::describe_error(rt, &call.throw_value);
    return 0;
}

// An Error of `kind` with the current stack, returned rather than thrown.
fn ulong bk_new_error(void* ctxp, int kind, char* msg) @export("bk_new_error") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (kind < abi::BK_ERROR || kind > abi::BK_ERROR_SYNTAX) return fail_value(rt, BK_ERR_INVALID, "unknown error kind");
    embed::clear_err(rt);
    HString* text = null;
    if (msg != null) {
        text = embed::string_from_utf8(rt, ((ZString)msg).str_view());
        if (text == null) return 0;
    }
    TVal err;
    if (!builtins::host_new_error(rt.heap, rt.vm, kind, text, &err)) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    return store(rt, err);
}

// Describes `id` without running JS and without touching the context's
// diagnostics or pending exception, except to report an invalid handle.
fn int bk_describe(void* ctxp, ulong id, char* buf, usz cap, usz* out_len) @export("bk_describe") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return BK_ERR_INVALID; }
    embed::TextOut out = { .buf = buf, .cap = buf == null || cap == 0 ? 0 : cap - 1 };
    embed::describe_value(rt, &v, &out);
    if (out_len != null) *out_len = out.need;
    if (buf == null) return BK_OK;
    if (cap > 0) buf[out.len] = 0;
    return out.full ? BK_ERR_FULL : BK_OK;
}

fn ulong bk_throw(void* ctxp, ulong id) @export("bk_throw") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal value;
    if (!resolve(ctxp, id, &value)) return bad_handle(rt);
    embed::describe_error(rt, &value);
    return 0;
}

fn ulong bk_new_c_function(void* ctxp, void* callback, char* name, int arity, uint flags, void* data,
                           void* finalize, void* finalize_opaque) @export("bk_new_c_function") {
    Runtime* rt = rt_of(ctxp);
    embed::BkFinalizer fin = (embed::BkFinalizer)finalize;
    if (rt == null) {
        if (fin != null) fin(data, finalize_opaque);
        return 0;
    }
    if (callback == null) {
        if (fin != null) fin(data, finalize_opaque);
        fail(rt, BK_ERR_INVALID, "null C function");
        return 0;
    }
    TVal function;
    char[] fname = name == null ? (char[])"" : ((ZString)name).str_view();
    if (embed::make_c_function(rt, fname, callback, data, fin, finalize_opaque, arity, (flags & BK_CTOR) != 0, &function) != BK_OK) return 0;
    return store(rt, function);
}

// ============================================================================
// Interrupt
// ============================================================================

// Install, replace, or clear the interrupt handler. The callback runs on the
// engine thread at VM safepoints; it must not call back into the engine. A
// host interrupting from another thread sets a flag in `opaque` and returns it
// here.
fn void bk_set_interrupt(void* rtp, void* cb, void* opaque) @export("bk_set_interrupt") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    rt.heap.capi_interrupt_fn = cb;
    rt.heap.capi_interrupt_opaque = opaque;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
}

// ============================================================================
// GC and resource control
// ============================================================================

const int BK_GC_MINOR = 0;
const int BK_GC_FULL = 1;

// Mirrors bk_heap_stats in boomkat.h.
struct BkHeapStats {
    ulong heap_bytes;
    ulong external_bytes;
    ulong heap_limit;
    uint  live_handles;
    uint  gc_cycles;
}

fn void bk_gc(void* rtp, int kind) @export("bk_gc") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    rt.heap.host_collect(kind == BK_GC_MINOR);
}

fn int bk_gc_step(void* rtp, ulong budget_ns) @export("bk_gc_step") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return 0;
    return rt.heap.host_gc_step(budget_ns) ? 1 : 0;
}

fn void bk_gc_inhibit(void* rtp, int inhibit) @export("bk_gc_inhibit") {
    Runtime* rt = (Runtime*)rtp;
    if (rt != null) rt.heap.gc_set_inhibit(inhibit != 0);
}

fn void bk_add_external_memory(void* rtp, long delta) @export("bk_add_external_memory") {
    Runtime* rt = (Runtime*)rtp;
    if (rt != null) rt.heap.add_external_memory(delta);
}

fn int bk_set_heap_limit(void* rtp, ulong bytes) @export("bk_set_heap_limit") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return BK_ERR_INVALID;
    if (!rt.heap.accounting) return fail(rt, BK_ERR_INVALID, "the runtime was created without a heap limit");
    rt.heap.set_heap_limit(bytes);
    return BK_OK;
}

fn int bk_get_heap_stats(void* rtp, BkHeapStats* out) @export("bk_get_heap_stats") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null || out == null) return BK_ERR_INVALID;
    out.heap_bytes = rt.heap.heap_bytes;
    out.external_bytes = (ulong)rt.heap.external_bytes;
    out.heap_limit = rt.heap.accounting && rt.heap.heap_limit != heap::HEAP_UNLIMITED ? rt.heap.heap_limit : 0;
    out.live_handles = rt.live;
    out.gc_cycles = rt.heap.gc_cycles;
    return BK_OK;
}

fn void bk_request_interrupt(void* rtp) @export("bk_request_interrupt") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    mem::@atomic_store(rt.heap.interrupt_requested, 1u);
    // A thread blocked in Atomics.wait sleeps on a condition, not on this flag.
    agent::wake_interrupt(rt.heap);
}

fn void bk_clear_interrupt(void* rtp) @export("bk_clear_interrupt") {
    Runtime* rt = (Runtime*)rtp;
    if (rt != null) mem::@atomic_store(rt.heap.interrupt_requested, 0u);
}

alias BkPromiseRejectionFn = fn void(void* ctx, ulong promise_id, ulong promise, ulong reason, int handled, void* opaque);

fn void capi_rejection_tracker(void* heap_raw, TVal promise, TVal reason, bool handled, void* udata) {
    Runtime* rt = (Runtime*)udata;
    ulong p = embed::slot_alloc(rt, promise);
    if (p == 0) return;
    defer embed::slot_release(rt, p);
    ulong r = embed::slot_alloc(rt, reason);
    if (r == 0) return;
    defer embed::slot_release(rt, r);
    BkPromiseRejectionFn cb = (BkPromiseRejectionFn)rt.promise_rejection_fn;
    cb(rt.active, (ulong)promise.get_heapptr(), p, r, handled ? 1 : 0, rt.promise_rejection_udata);
}

fn void bk_set_promise_rejection_tracker(void* rtp, void* cb, void* opaque)
        @export("bk_set_promise_rejection_tracker") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    rt.promise_rejection_fn = cb;
    rt.promise_rejection_udata = opaque;
    rt.heap.promise_rejection_fn = cb != null ? &capi_rejection_tracker : null;
    rt.heap.promise_rejection_udata = rt;
}

// ============================================================================
// Binary data
// ============================================================================

// Mirrors bk_typed_array_info in boomkat.h.
struct BkTypedArrayInfo {
    int   type;
    void* data;
    usz   length;
    usz   byte_offset;
    ulong buffer;
}

const uint ELEMENT_TYPE_COUNT = 12;

// The ArrayBuffer or SharedArrayBuffer behind `id`, or null with the failure
// recorded.
fn HObject* buffer_of(void* ctxp, Runtime* rt, ulong id) {
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return null; }
    if (!v.is_object() || v.get_heapptr() == null
        || ((HObject*)v.get_heapptr()).flags.obj_class != hobject::ObjClass.ARRAYBUFFER) {
        fail(rt, BK_ERR_TYPE, "not an ArrayBuffer or SharedArrayBuffer");
        return null;
    }
    return (HObject*)v.get_heapptr();
}

// The current realm's prototype for a typed array class, or null when the
// build leaves that kind out.
fn HObject* typed_array_proto(Heap* heap, hobject::ObjClass cls) {
    switch (cls) {
        case INT8ARRAY:         return heap.int8array_proto;
        case UINT8ARRAY:        return heap.uint8array_proto;
        case UINT8CLAMPEDARRAY: return heap.uint8clampedarray_proto;
        case INT16ARRAY:        return heap.int16array_proto;
        case UINT16ARRAY:       return heap.uint16array_proto;
        case INT32ARRAY:        return heap.int32array_proto;
        case UINT32ARRAY:       return heap.uint32array_proto;
        case FLOAT16ARRAY:      return heap.float16array_proto;
        case FLOAT32ARRAY:      return heap.float32array_proto;
        case FLOAT64ARRAY:      return heap.float64array_proto;
        case BIGINT64ARRAY:     return heap.bigint64array_proto;
        case BIGUINT64ARRAY:    return heap.biguint64array_proto;
        default:                return null;
    }
}

// A fresh fixed-length ArrayBuffer with no data, or null after recording the
// failure.
fn HObject* new_buffer_object(Runtime* rt, HObject* proto) {
    HObject*? raw = rt.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
    if (catch raw) { fail(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    HObject* buf = raw;
    rt.heap.set_prototype(buf, proto);
    (*buf.extra_ptr()).ab.data = null;
    (*buf.extra_ptr()).ab.byte_length = 0;
    (*buf.extra_ptr()).ab.views_head = null;
    return buf;
}

fn ulong bk_new_array_buffer(void* ctxp, usz length, void** data_out) @export("bk_new_array_buffer") {
    if (data_out != null) *data_out = null;
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (!features::BUFFERS || rt.heap.arraybuffer_proto == null) {
        return fail_value(rt, BK_ERR_UNSUPPORTED, "ArrayBuffer is not available in this build");
    }
    if (length > 0x7FFF_FFFF) return fail_value(rt, BK_ERR_INVALID, "ArrayBuffer length too large");
    char* data = null;
    if (length > 0) {
        data = (char*)rt.heap.alloc_func(rt.heap.heap_udata, length);
        if (data == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
        mem::clear(data, (sz)length);
    }
    HObject* buf = new_buffer_object(rt, rt.heap.arraybuffer_proto);
    if (buf == null) {
        if (data != null) rt.heap.free_func(rt.heap.heap_udata, data);
        return 0;
    }
    (*buf.extra_ptr()).ab.data = data;
    (*buf.extra_ptr()).ab.byte_length = (uint)length;
    TVal v; v.set_object(buf);
    ulong id = store(rt, v);
    if (id != 0 && data_out != null) *data_out = data;
    return id;
}

fn ulong bk_new_external_array_buffer(void* ctxp, void* data, usz length, heap::ExternalReleaseFn release,
                                      void* opaque) @export("bk_new_external_array_buffer") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    // Every failure below hands the data back, so the caller never has to
    // tell a refused buffer from an accepted one.
    int code = BK_OK;
    String msg;
    if (!features::BUFFERS || rt.heap.arraybuffer_proto == null) {
        code = BK_ERR_UNSUPPORTED; msg = "ArrayBuffer is not available in this build";
    } else if (data == null && length != 0) {
        code = BK_ERR_INVALID; msg = "null data";
    } else if (length > 0x7FFF_FFFF) {
        code = BK_ERR_INVALID; msg = "ArrayBuffer length too large";
    }
    HObject* buf = null;
    if (code == BK_OK) {
        buf = new_buffer_object(rt, rt.heap.arraybuffer_proto);
        if (buf == null) { code = BK_ERR_NOMEM; msg = "out of memory"; }
    }
    if (code == BK_OK && !rt.heap.make_external_buffer(buf, (char*)data, (uint)length, release, opaque)) {
        code = BK_ERR_NOMEM; msg = "out of memory";
    }
    if (code != BK_OK) {
        if (release != null) release(data, opaque);
        return fail_value(rt, code, msg);
    }
    TVal v; v.set_object(buf);
    return store(rt, v);
}

fn int bk_get_array_buffer(void* ctxp, ulong id, void** data, usz* length) @export("bk_get_array_buffer") {
    if (data != null) *data = null;
    if (length != null) *length = 0;
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HObject* buf = buffer_of(ctxp, rt, id);
    if (buf == null) return rt.errcode;
    if ((*buf.extra_ptr()).ab.byte_length == 0xFFFF_FFFF) return BK_OK;
    if (data != null) *data = (*buf.extra_ptr()).ab.data;
    if (length != null) *length = builtins::buffer_byte_length(buf);
    return BK_OK;
}

fn int bk_detach_array_buffer(void* ctxp, ulong id) @export("bk_detach_array_buffer") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    HObject* buf = buffer_of(ctxp, rt, id);
    if (buf == null) return rt.errcode;
    if ((*buf.extra_ptr()).ab.is_shared) return fail(rt, BK_ERR_TYPE, "a SharedArrayBuffer cannot be detached");
    if ((*buf.extra_ptr()).ab.immutable) return fail(rt, BK_ERR_TYPE, "an immutable ArrayBuffer cannot be detached");
    builtins::arraybuffer_detach(rt.heap, buf);
    return BK_OK;
}

fn ulong bk_new_typed_array(void* ctxp, int type, ulong buffer, usz byte_offset, usz length)
        @export("bk_new_typed_array") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (type < 0 || (uint)type >= ELEMENT_TYPE_COUNT) return fail_value(rt, BK_ERR_INVALID, "unknown element type");
    hobject::ObjClass cls = (hobject::ObjClass)((int)hobject::ObjClass.INT8ARRAY + type);
    HObject* proto = features::BUFFERS ? typed_array_proto(rt.heap, cls) : null;
    if (proto == null) return fail_value(rt, BK_ERR_UNSUPPORTED, "this typed array kind is not available in this build");
    HObject* buf = buffer_of(ctxp, rt, buffer);
    if (buf == null) return 0;
    if ((*buf.extra_ptr()).ab.byte_length == 0xFFFF_FFFF) return fail_value(rt, BK_ERR_TYPE, "ArrayBuffer is detached");
    usz elem = (usz)builtins::ta_elem_size(cls);
    if (byte_offset % elem != 0) return fail_value(rt, BK_ERR_INVALID, "byte offset is not a multiple of the element size");
    usz available = (usz)builtins::buffer_byte_length(buf);
    if (byte_offset > available || length > (available - byte_offset) / elem) {
        return fail_value(rt, BK_ERR_INVALID, "view does not fit in the buffer");
    }
    HObject*? raw = rt.heap.alloc_object(cls);
    if (catch raw) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    HObject* view = raw;
    rt.heap.set_prototype(view, proto);
    (*view.extra_ptr()).view.byte_offset = (uint)byte_offset;
    (*view.extra_ptr()).view.byte_length = (uint)(length * elem);
    (*view.extra_ptr()).view.length_tracking = false;
    builtins::typedarray_link_view(rt.heap, buf, view);
    TVal v; v.set_object(view);
    return store(rt, v);
}

fn int bk_get_typed_array(void* ctxp, ulong id, BkTypedArrayInfo* out) @export("bk_get_typed_array") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    *out = {};
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) { bad_handle(rt); return BK_ERR_INVALID; }
    if (!v.is_object() || v.get_heapptr() == null
        || !builtins::is_typed_array_class(((HObject*)v.get_heapptr()).flags.obj_class)) {
        return fail(rt, BK_ERR_TYPE, "not a typed array");
    }
    HObject* view = (HObject*)v.get_heapptr();
    HObject* buf = (*view.extra_ptr()).view.buffer;
    TVal bv; bv.set_object(buf);
    ulong bid = store(rt, bv);
    if (bid == 0) return rt.errcode;
    out.type = (int)view.flags.obj_class - (int)hobject::ObjClass.INT8ARRAY;
    out.byte_offset = (*view.extra_ptr()).view.byte_offset;
    out.buffer = bid;
    if (!builtins::ta_is_detached(view)) {
        out.data = (*buf.extra_ptr()).ab.data + (*view.extra_ptr()).view.byte_offset;
        out.length = builtins::ta_element_count(view);
    }
    return BK_OK;
}

fn ulong bk_new_shared_array_buffer(void* ctxp, usz length, void** data_out) @export("bk_new_shared_array_buffer") {
    if (data_out != null) *data_out = null;
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (!features::SHARED_MEMORY || !features::BUFFERS || rt.heap.sharedarraybuffer_proto == null) {
        return fail_value(rt, BK_ERR_UNSUPPORTED, "SharedArrayBuffer is not available in this build");
    }
    if (length > 0x7FFF_FFFF) return fail_value(rt, BK_ERR_INVALID, "SharedArrayBuffer length too large");
    char* block = agent::block_alloc((uint)length, (uint)length);
    if (block == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    HObject* buf = builtins::sab_adopt(rt.heap, block);
    // The buffer holds its own reference now, or none was taken.
    agent::block_release(block);
    if (buf == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    TVal v; v.set_object(buf);
    ulong id = store(rt, v);
    if (id != 0 && data_out != null) *data_out = block;
    return id;
}

fn ulong bk_adopt_shared_block(void* ctxp, void* data) @export("bk_adopt_shared_block") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (data == null) return fail_value(rt, BK_ERR_INVALID, "null shared block");
    if (!features::SHARED_MEMORY || !features::BUFFERS || rt.heap.sharedarraybuffer_proto == null) {
        return fail_value(rt, BK_ERR_UNSUPPORTED, "SharedArrayBuffer is not available in this build");
    }
    HObject* buf = builtins::sab_adopt(rt.heap, (char*)data);
    if (buf == null) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    TVal v; v.set_object(buf);
    return store(rt, v);
}

fn void bk_shared_block_retain(void* data) @export("bk_shared_block_retain") {
    if (data != null) agent::block_retain((char*)data);
}

fn void bk_shared_block_release(void* data) @export("bk_shared_block_release") {
    if (data != null) agent::block_release((char*)data);
}

// ============================================================================
// Weak handles
// ============================================================================

fn bool symbol_is_registered(Heap* heap, HString* sym) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        if (heap.symbol_registry_syms[i] == sym) return true;
    }
    return false;
}

fn ulong bk_new_weak(void* ctxp, ulong id) @export("bk_new_weak") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    HeapHeader* target = null;
    if (v.is_object() && v.get_heapptr() != null) {
        target = (HeapHeader*)v.get_heapptr();
    } else if (v.is_string() && ((HString*)v.get_heapptr()).is_symbol()) {
        // A registered symbol can be recreated by Symbol.for, so it can never
        // be observed to die, and the spec keeps it out of weak collections.
        if (symbol_is_registered(rt.heap, (HString*)v.get_heapptr())) {
            return fail_value(rt, BK_ERR_TYPE, "a registered symbol cannot be held weakly");
        }
        target = (HeapHeader*)v.get_heapptr();
    } else {
        return fail_value(rt, BK_ERR_TYPE, "only objects and symbols can be held weakly");
    }
    ulong weak = rt.heap.weak_new(target);
    if (weak == 0) return fail_value(rt, BK_ERR_NOMEM, "out of memory");
    return weak;
}

fn ulong bk_weak_get(void* ctxp, ulong weak) @export("bk_weak_get") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (rt.heap.weak_entry(weak) == null) return fail_value(rt, BK_ERR_INVALID, "invalid or freed weak handle");
    HeapHeader* target = rt.heap.weak_get(weak);
    if (target == null) return embed::IMM_UNDEFINED;
    TVal v;
    if (target.flags.htype == HType.STRING) {
        v.set_string_borrowed((HString*)target);
    } else {
        v.set_object((HObject*)target);
    }
    return store(rt, v);
}

fn void bk_free_weak(void* ctxp, ulong weak) @export("bk_free_weak") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return;
    rt.heap.weak_free_handle(weak);
}
