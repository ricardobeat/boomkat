// Native add-on ABI and loader.
//
// An add-on is a shared library exporting one symbol:
//
//     int bk_init_addon(BkAddonCtx* ctx, const BkAddonApi* api);
//
// It receives every entry point it needs through `api`, a versioned vtable, and
// links against no engine symbols. That is what makes the surface reviewable:
// the whole contract is one struct, and adding a feature to the engine cannot
// silently become part of the ABI.
//
// The design mirrors QuickJS's dlopen + js_init_module, with one addition that
// matters for anything holding state: BkAddonApi.class_register takes a
// gc_mark callback, so a payload can hold JS values safely. Without it an
// add-on can only expose stateless functions.
//
// Loading is opt-in per Runtime (see bk_addon_enable_loading); a build that
// never calls it links the loader but never opens anything.
module boomkat::addon;

import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::embed;
import boomkat::env;
import libc;

// Bump when the vtable changes shape. An add-on compiled against a different
// major version is rejected rather than called: the alternative is a wild jump
// through a moved function pointer.
const uint BK_ADDON_ABI_VERSION = 1;

const int BK_ADDON_OK          = 0;
const int BK_ADDON_ERR_OPEN    = -1;  // dlopen failed
const int BK_ADDON_ERR_SYMBOL  = -2;  // no bk_init_addon
const int BK_ADDON_ERR_VERSION = -3;  // ABI mismatch
const int BK_ADDON_ERR_INIT    = -4;  // the add-on's own init returned failure
const int BK_ADDON_ERR_DISABLED = -5; // loading not enabled for this runtime

// Opaque handle an add-on passes back to every api call. Holds the engine
// state the add-on is not allowed to see the shape of.
struct BkAddonCtx {
    heap::Heap*   heap;
    env::EnvRecord* global_env;
    void*         reserved;
}

// A method or constructor implemented by an add-on. `bctx` is the same
// BuiltinContext the engine passes its own builtins, reached through the
// accessor calls in the vtable rather than by dereferencing it.
alias BkAddonFn = fn void(void* bctx, void* udata);

// ============================================================================
// The vtable
// ============================================================================

// Function-pointer types for the vtable. Named aliases rather than inline
// signatures so the ABI is greppable and a change to one is a change to one
// line.
alias FnClassRegister    = fn long(BkAddonCtx*, char*, void*, void*, void*, void*);
alias FnProtoNew         = fn void*(BkAddonCtx*);
alias FnObjectNew        = fn void*(BkAddonCtx*);
alias FnFnNew            = fn int(BkAddonCtx*, char*, BkAddonFn, void*, int, bool, ulong*);
alias FnObjectSet        = fn int(BkAddonCtx*, void*, char*, ulong);
alias FnObjectSetByHandle = fn int(BkAddonCtx*, ulong, char*, ulong);
alias FnObjectSetGetter  = fn int(BkAddonCtx*, void*, char*, BkAddonFn, void*);
alias FnGlobalSet        = fn int(BkAddonCtx*, char*, ulong);
alias FnHandleForObject  = fn ulong(BkAddonCtx*, void*);
alias FnInstanceNew      = fn void*(BkAddonCtx*, long, void*);
alias FnInstancePayload  = fn void*(void*, long);
alias FnArgCount         = fn uint(void*);
alias FnArgString        = fn char*(void*, uint, usz*);
alias FnArgNumber        = fn double(void*, uint);
alias FnArgHandle        = fn ulong(void*, uint);
alias FnThisHandle       = fn ulong(void*);
alias FnReturnNumber     = fn void(void*, double);
alias FnReturnString     = fn void(void*, char*, usz);
alias FnReturnObject     = fn void(void*, void*);
alias FnReturnHandle     = fn void(void*, ulong);
alias FnReturnUndefined  = fn void(void*);
alias FnThrowMsg         = fn void(void*, char*);
alias FnHandleStore      = fn void(void*, ulong, void*);
alias FnHandleLoad       = fn ulong(void*, void*);
alias FnHandleObject     = fn void*(void*, ulong);
alias FnMarkValue        = fn void(void*, void*);
alias FnMemAlloc         = fn void*(BkAddonCtx*, usz);
alias FnMemRealloc       = fn void*(BkAddonCtx*, void*, usz);
alias FnMemFree          = fn void(BkAddonCtx*, void*);

// Every entry point an add-on gets. Passed by pointer to bk_init_addon and
// valid for the life of the Runtime.
//
// Fields are append-only within a major version: adding one at the end is
// compatible, reordering or removing is not.
struct BkAddonApi {
    uint version;

    // -- registration --
    // class_register: name, finalizer, gc_mark, udata, proto -> class id or -1.
    // gc_mark must mark every JS value the payload holds (heap::HostClassMarkFn).
    FnClassRegister   class_register;
    FnProtoNew        proto_new;
    FnObjectNew       object_new;
    // fn_new: constructable allows `new`; writes a callable handle to out.
    FnFnNew           fn_new;
    FnObjectSet       object_set;
    // Same, when the target is itself a handle (e.g. a constructor just made).
    FnObjectSetByHandle object_set_by_handle;
    FnObjectSetGetter object_set_getter;
    FnGlobalSet       global_set;
    FnHandleForObject handle_for_object;

    // -- instances --
    FnInstanceNew     instance_new;
    // instance_payload is the brand check: null unless obj is of that class.
    FnInstancePayload instance_payload;

    // -- calling convention --
    FnArgCount        arg_count;
    FnArgString       arg_string;
    FnArgNumber       arg_number;
    FnArgHandle       arg_handle;
    FnThisHandle      this_handle;
    FnReturnNumber    return_number;
    FnReturnString    return_string;
    FnReturnObject    return_object;
    FnReturnHandle    return_handle;
    FnReturnUndefined return_undefined;
    FnThrowMsg        throw_type_error;
    FnThrowMsg        throw_range_error;

    // -- values held across calls --
    // A retained value lives in the payload; these only convert. The add-on
    // must still mark it from gc_mark.
    FnHandleStore     handle_store;
    FnHandleLoad      handle_load;
    // The object behind a handle, or null. Used for brand checks on `this`.
    FnHandleObject    handle_object;
    FnMarkValue       mark_value;

    // -- memory --
    FnMemAlloc        mem_alloc;
    FnMemRealloc      mem_realloc;
    FnMemFree         mem_free;
}

alias BkAddonInitFn = fn int(BkAddonCtx*, BkAddonApi*);

// ============================================================================
// Implementations behind the vtable
// ============================================================================

fn long api_class_register(BkAddonCtx* ctx, char* name, void* finalizer, void* gc_mark, void* udata, void* proto) @private {
    if (ctx == null || ctx.heap == null) return -1;
    hstring::HString* nm = ctx.heap.str_intern(cstr_slice(name));
    return ctx.heap.register_host_class(finalizer, gc_mark, udata, (void*)nm, (hobject::HObject*)proto);
}

fn void* api_proto_new(BkAddonCtx* ctx) @private {
    if (ctx == null || ctx.heap == null) return null;
    hobject::HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch raw) return null;
    hobject::HObject* o = raw;
    o.prototype = ctx.heap.object_proto;
    return (void*)o;
}

fn void* api_object_new(BkAddonCtx* ctx) @private => api_proto_new(ctx);

fn int api_fn_new(BkAddonCtx* ctx, char* name, BkAddonFn cfn, void* udata, int arity, bool constructable, ulong* out_handle) @private {
    if (ctx == null || ctx.heap == null || out_handle == null) return BK_ADDON_ERR_INIT;
    hstring::HString* nm = ctx.heap.str_intern(cstr_slice(name));
    if (nm == null) return BK_ADDON_ERR_INIT;
    long slot = ctx.heap.register_host_fn((void*)cfn, udata, (void*)nm, arity, constructable);
    if (slot < 0) return BK_ADDON_ERR_INIT;
    hobject::HObject*? fo = builtins::make_host_function(ctx.heap, (uint)slot);
    if (catch fo) return BK_ADDON_ERR_INIT;
    types::TVal v;
    v.set_object(fo);
    *out_handle = tval_to_handle(ctx.heap, v);
    return BK_ADDON_OK;
}

fn int api_object_set(BkAddonCtx* ctx, void* obj, char* name, ulong h) @private {
    if (ctx == null || obj == null) return BK_ADDON_ERR_INIT;
    hobject::HObject* o = (hobject::HObject*)obj;
    hstring::HString* key = ctx.heap.str_intern(cstr_slice(name));
    if (key == null) return BK_ADDON_ERR_INIT;
    o.put_prop(key, handle_to_tval(ctx.heap, h), hobject::PROP_FLAGS_WC, ctx.heap);
    return BK_ADDON_OK;
}

fn int api_object_set_by_handle(BkAddonCtx* ctx, ulong target, char* name, ulong h) @private {
    if (ctx == null) return BK_ADDON_ERR_INIT;
    types::TVal tv = handle_to_tval(ctx.heap, target);
    if (!tv.is_object()) return BK_ADDON_ERR_INIT;
    return api_object_set(ctx, tv.get_heapptr(), name, h);
}

fn int api_object_set_getter(BkAddonCtx* ctx, void* obj, char* name, BkAddonFn cfn, void* udata) @private {
    if (ctx == null || obj == null) return BK_ADDON_ERR_INIT;
    hobject::HObject* o = (hobject::HObject*)obj;
    char[] nm_slice = cstr_slice(name);
    hstring::HString* nm = ctx.heap.str_intern(nm_slice);
    if (nm == null) return BK_ADDON_ERR_INIT;
    long slot = ctx.heap.register_host_fn((void*)cfn, udata, (void*)nm, 0, false);
    if (slot < 0) return BK_ADDON_ERR_INIT;
    hobject::HObject*? getter_raw = builtins::make_host_function(ctx.heap, (uint)slot);
    if (catch getter_raw) return BK_ADDON_ERR_INIT;
    return builtins::define_host_accessor(ctx.heap, o, nm, getter_raw)
        ? BK_ADDON_OK : BK_ADDON_ERR_INIT;
}

fn int api_global_set(BkAddonCtx* ctx, char* name, ulong h) @private {
    if (ctx == null || ctx.global_env == null) return BK_ADDON_ERR_INIT;
    hstring::HString* key = ctx.heap.str_intern(cstr_slice(name));
    if (key == null) return BK_ADDON_ERR_INIT;
    env::env_declare_nonenum(ctx.global_env, key, handle_to_tval(ctx.heap, h));
    return BK_ADDON_OK;
}

fn ulong api_handle_for_object(BkAddonCtx* ctx, void* obj) @private {
    if (ctx == null) return 0;
    types::TVal v;
    v.set_object((hobject::HObject*)obj);
    return tval_to_handle(ctx.heap, v);
}

fn void* api_instance_new(BkAddonCtx* ctx, long class_id, void* payload) @private {
    if (ctx == null || ctx.heap == null || class_id < 0) return null;
    heap::HostClassEntry* hc = ctx.heap.host_class_at((uint)class_id);
    if (hc == null) return null;
    hobject::HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.HOST);
    if (catch raw) return null;
    hobject::HObject* o = raw;
    (*o.extra_ptr()).host.payload  = payload;
    (*o.extra_ptr()).host.class_id = (uint)class_id;
    o.prototype = hc.proto;
    return (void*)o;
}

fn void* api_instance_payload(void* obj, long class_id) @private {
    if (obj == null || class_id < 0) return null;
    hobject::HObject* o = (hobject::HObject*)obj;
    if (o.flags.obj_class != hobject::ObjClass.HOST) return null;
    if ((*o.extra_ptr()).host.class_id != (uint)class_id) return null;
    return (*o.extra_ptr()).host.payload;
}

fn uint api_arg_count(void* bctx) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    return (uint)c.argc;
}

fn char* api_arg_string(void* bctx, uint i, usz* out_len) @private {
    if (out_len != null) *out_len = 0;
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    if ((uint)c.argc <= i) return null;
    types::TVal v = c.regs[c.base_reg + i];
    if (!v.is_string()) return null;
    hstring::HString* hs = (hstring::HString*)v.get_heapptr();
    if (hs == null) return null;
    if (out_len != null) *out_len = (usz)hs.blen;
    return hs.get_cstr();
}

fn double api_arg_number(void* bctx, uint i) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    if ((uint)c.argc <= i) return 0.0;
    types::TVal v = c.regs[c.base_reg + i];
    if (v.is_fastint()) return (double)v.get_fastint();
    if (v.is_number()) return v.get_number();
    return 0.0;
}

fn ulong api_arg_handle(void* bctx, uint i) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    if ((uint)c.argc <= i) return 0;
    return tval_to_handle(c.heap, c.regs[c.base_reg + i]);
}

fn ulong api_this_handle(void* bctx) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    return tval_to_handle(c.heap, c.this_val);
}

fn void api_return_number(void* bctx, double v) @private {
    ((builtins::BuiltinContext*)bctx).result.set_number(v);
}

fn void api_return_string(void* bctx, char* bytes, usz len) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    if (bytes == null) { c.result.set_undefined(); return; }
    hstring::HString* s = builtins::builtin_intern_string(c.heap, bytes[:len]);
    if (s == null) { c.result.set_undefined(); return; }
    c.result.set_string(s);
}

fn void api_return_object(void* bctx, void* obj) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    if (obj == null) { c.result.set_undefined(); return; }
    c.result.set_object((hobject::HObject*)obj);
}

fn void api_return_handle(void* bctx, ulong h) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    *c.result = handle_to_tval(c.heap, h);
}

fn void api_return_undefined(void* bctx) @private {
    ((builtins::BuiltinContext*)bctx).result.set_undefined();
}

fn void api_throw_type_error(void* bctx, char* msg) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    builtins::builtin_throw(c, c.heap.type_err_proto, cstr_slice(msg));
}

fn void api_throw_range_error(void* bctx, char* msg) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    builtins::builtin_throw(c, c.heap.range_err_proto, cstr_slice(msg));
}

fn void api_handle_store(void* bctx, ulong h, void* out_tval) @private {
    if (out_tval == null || bctx == null) return;
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    *((types::TVal*)out_tval) = handle_to_tval(c.heap, h);
}

fn ulong api_handle_load(void* bctx, void* tval) @private {
    if (tval == null || bctx == null) return 0;
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    return tval_to_handle(c.heap, *((types::TVal*)tval));
}

fn void* api_handle_object(void* bctx, ulong h) @private {
    if (bctx == null) return null;
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    types::TVal v = handle_to_tval(c.heap, h);
    if (!v.is_object()) return null;
    return v.get_heapptr();
}

fn void api_mark_value(void* h, void* tval) @private {
    if (h == null || tval == null) return;
    ((heap::Heap*)h).mark_tval((types::TVal*)tval);
}

fn void* api_mem_alloc(BkAddonCtx* ctx, usz n) @private {
    if (ctx == null || ctx.heap == null) return null;
    return ctx.heap.alloc_func(ctx.heap.heap_udata, n);
}

fn void* api_mem_realloc(BkAddonCtx* ctx, void* p, usz n) @private {
    if (ctx == null || ctx.heap == null) return null;
    return ctx.heap.realloc_func(ctx.heap.heap_udata, p, n);
}

fn void api_mem_free(BkAddonCtx* ctx, void* p) @private {
    if (ctx == null || ctx.heap == null || p == null) return;
    ctx.heap.free_func(ctx.heap.heap_udata, p);
}

// ============================================================================
// Handles
// ============================================================================

// Handles are indices into a per-heap table of TVals, not raw value bits.
//
// The obvious encoding -- bitcast the TVal into a ulong -- works only in the
// NaN-boxed build, where TVal is 8 bytes. The NONANBOX build (see
// types::USE_NANBOX) uses a 16-byte tagged union, so raw bits would silently
// truncate. Indices are the same width either way, which keeps one add-on
// binary working against both builds.
//
// The table is a GC root, so a handle also keeps its value alive for the
// duration of a call without the add-on doing anything. Handles are reset at
// the end of each add-on call rather than individually released: an add-on
// that wants to keep a value stores it in its payload and marks it from
// gc_mark, which is the contract the payload already has.
fn ulong tval_to_handle(heap::Heap* h, types::TVal v) @private {
    if (h == null) return 0;
    long slot = h.addon_handle_push(v);
    if (slot < 0) return 0;
    // 1-based so 0 is always "no value".
    return (ulong)(slot + 1);
}

fn types::TVal handle_to_tval(heap::Heap* h, ulong handle) @private {
    types::TVal undef;
    undef.set_undefined();
    if (h == null || handle == 0) return undef;
    return h.addon_handle_at((usz)(handle - 1)) ?? undef;
}

fn char[] cstr_slice(char* p) @private {
    if (p == null) return {};
    usz n = 0;
    while (p[n] != 0) n++;
    return p[:n];
}

// ============================================================================
// The vtable instance
// ============================================================================

BkAddonApi g_addon_api = {
    .version             = BK_ADDON_ABI_VERSION,
    .class_register      = &api_class_register,
    .proto_new           = &api_proto_new,
    .object_new          = &api_object_new,
    .fn_new              = &api_fn_new,
    .object_set          = &api_object_set,
    .object_set_by_handle = &api_object_set_by_handle,
    .object_set_getter   = &api_object_set_getter,
    .global_set          = &api_global_set,
    .handle_for_object   = &api_handle_for_object,
    .instance_new        = &api_instance_new,
    .instance_payload    = &api_instance_payload,
    .arg_count           = &api_arg_count,
    .arg_string          = &api_arg_string,
    .arg_number          = &api_arg_number,
    .arg_handle          = &api_arg_handle,
    .this_handle         = &api_this_handle,
    .return_number       = &api_return_number,
    .return_string       = &api_return_string,
    .return_object       = &api_return_object,
    .return_handle       = &api_return_handle,
    .return_undefined    = &api_return_undefined,
    .throw_type_error    = &api_throw_type_error,
    .throw_range_error   = &api_throw_range_error,
    .handle_store        = &api_handle_store,
    .handle_load         = &api_handle_load,
    .handle_object       = &api_handle_object,
    .mark_value          = &api_mark_value,
    .mem_alloc           = &api_mem_alloc,
    .mem_realloc         = &api_mem_realloc,
    .mem_free            = &api_mem_free,
};

// ============================================================================
// Loading
// ============================================================================

// Open `path`, find bk_init_addon, check the ABI version, and run it.
//
// The library is intentionally never dlclose()d on success: its code stays
// mapped for as long as any object it registered can be reached, and the
// engine has no way to know when that is. Closing on failure is safe because
// nothing was registered.
fn int load_addon(heap::Heap* h, env::EnvRecord* global_env, char[] path) {
    if (h == null || global_env == null) return BK_ADDON_ERR_INIT;

    char[512] pathbuf;
    if (path.len >= pathbuf.len) return BK_ADDON_ERR_OPEN;
    for (usz i = 0; i < path.len; i++) pathbuf[i] = path[i];
    pathbuf[path.len] = 0;

    void* handle = libc::dlopen((ZString)&pathbuf[0], libc::RTLD_NOW | libc::RTLD_LOCAL);
    if (handle == null) return BK_ADDON_ERR_OPEN;

    char[16] sym = "bk_init_addon\0";
    void* init_raw = libc::dlsym(handle, (ZString)&sym[0]);
    if (init_raw == null) {
        libc::dlclose(handle);
        return BK_ADDON_ERR_SYMBOL;
    }

    // The context must outlive this call: an add-on is expected to stash it and
    // use it from its callbacks, so a stack BkAddonCtx would dangle the moment
    // load_addon returns. Heap-allocated and never freed, like the library
    // itself -- both live as long as anything the add-on registered can run.
    void* ctx_raw = h.alloc_func(h.heap_udata, BkAddonCtx::size);
    if (ctx_raw == null) {
        libc::dlclose(handle);
        return BK_ADDON_ERR_INIT;
    }
    BkAddonCtx* ctx = (BkAddonCtx*)ctx_raw;
    ctx.heap = h;
    ctx.global_env = global_env;
    ctx.reserved = null;

    BkAddonInitFn init = (BkAddonInitFn)init_raw;
    int rc = init(ctx, &g_addon_api);
    if (rc != BK_ADDON_OK) {
        h.free_func(h.heap_udata, ctx_raw);
        libc::dlclose(handle);
        return BK_ADDON_ERR_INIT;
    }
    return BK_ADDON_OK;
}

// ============================================================================
// Opt-in JS entry point
// ============================================================================

// The `loadAddon(path)` global. Registered only when a host calls
// enable_loading, so a sandboxed embedder never exposes dlopen to script.
fn void builtin_load_addon(void* bctx, void* udata) @private {
    builtins::BuiltinContext* c = (builtins::BuiltinContext*)bctx;
    heap::Heap* h = c.heap;
    if (c.argc < 1) {
        builtins::builtin_throw(c, h.type_err_proto, "loadAddon requires a path");
        return;
    }
    types::TVal v = c.regs[c.base_reg];
    if (!v.is_string()) {
        builtins::builtin_throw(c, h.type_err_proto, "loadAddon requires a string path");
        return;
    }
    hstring::HString* hs = (hstring::HString*)v.get_heapptr();
    if (hs == null) { c.result.set_undefined(); return; }

    int rc = load_addon(h, c.global_env, hs.get_cstr()[:hs.blen]);
    if (rc != BK_ADDON_OK) {
        switch (rc) {
            case BK_ADDON_ERR_OPEN:
                builtins::builtin_throw(c, h.err_proto, "could not open add-on");
            case BK_ADDON_ERR_SYMBOL:
                builtins::builtin_throw(c, h.err_proto, "add-on has no bk_init_addon");
            case BK_ADDON_ERR_VERSION:
                builtins::builtin_throw(c, h.err_proto, "add-on ABI version mismatch");
            default:
                builtins::builtin_throw(c, h.err_proto, "add-on initialisation failed");
        }
        return;
    }
    c.result.set_undefined();
}

// Expose `loadAddon` as a global. Opt-in: an embedder that never calls this
// has no way to reach dlopen from script.
fn bool enable_loading(heap::Heap* h, env::EnvRecord* global_env) {
    hstring::HString* nm = h.str_intern("loadAddon");
    if (nm == null) return false;
    long slot = h.register_host_fn((void*)&builtin_load_addon, null, (void*)nm, 1, false);
    if (slot < 0) return false;
    hobject::HObject*? fo = builtins::make_host_function(h, (uint)slot);
    if (catch fo) return false;
    types::TVal fv;
    fv.set_object(fo);
    env::env_declare_nonenum(global_env, nm, fv);
    return true;
}
