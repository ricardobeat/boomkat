/// The scope chain: runtime variable resolution through linked environment
/// records, split into a var environment and a lex environment.
module duktape::env;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;

// ============================================================================
// EnvRecord pool
// ============================================================================

/// Header of a pool block. Blocks link together so the heap can free them at
/// teardown, with `next` first so the Heap can hold the list as a void*.
struct EnvPoolBlock { void* next; }

const uint ENV_POOL_BLOCK_SIZE = 64;

/// Allocate an EnvRecord from the pool.
fn EnvRecord*? env_pool_alloc(Heap* h) {
    if (h.env_freelist != null) {
        EnvRecord* env = (EnvRecord*)h.env_freelist;
        h.env_freelist = env.parent;
        mem::clear(env, (sz)(EnvRecord::size));
        return env;
    }

    // The freelist is empty, so carve up a new block.
    usz block_sz = EnvPoolBlock::size + EnvRecord::size * ENV_POOL_BLOCK_SIZE;
    void* raw = h.alloc_func(h.heap_udata, block_sz);
    if (raw == null) return null;
    mem::clear(raw, (sz)(block_sz));

    EnvPoolBlock* block = (EnvPoolBlock*)raw;
    block.next = h.env_pool_blocks;
    h.env_pool_blocks = block;

    // Records 1 to N-1 go on the freelist; record 0 is returned below.
    char* base = (char*)raw + EnvPoolBlock::size;
    for (uint i = 1; i < ENV_POOL_BLOCK_SIZE; i++) {
        EnvRecord* e = (EnvRecord*)(base + i * EnvRecord::size);
        e.parent = (EnvRecord*)h.env_freelist;
        h.env_freelist = e;
    }

    return (EnvRecord*)base;
}

/// Return an EnvRecord to the pool.
fn void env_pool_free(Heap* h, EnvRecord* env) {
    if (env == null) return;
    mem::clear(env, (sz)(EnvRecord::size));
    env.parent = (EnvRecord*)h.env_freelist;
    h.env_freelist = env;
}

// ============================================================================
// EnvRecord, one link in the scope chain
// ============================================================================

/// One link in the scope chain.
struct EnvRecord {
    /// Parent scope (null for the global scope).
    EnvRecord* parent;
    /// The object holding the bindings, mapping each name to its value.
    HObject* bindings;
    /// Is this a declarative (not object) environment?
    bool is_declarative;
    /// Is this a function call boundary? When true, var-scope writes
    /// stop here and do not propagate to parent scopes.
    bool is_function_scope;
}

// ============================================================================
// Creation / destruction
// ============================================================================

/// Create a var environment at a function boundary, setting is_function_scope.
fn EnvRecord*? env_create_function_scope(Heap* heap, EnvRecord* parent) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.is_declarative = false;
        env.is_function_scope = true;
        HObject*? bindings = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bindings) {
            env_pool_free(heap, env);
            return types::ALLOC_ERROR~;
        }
        env.bindings = bindings;
        return env;
    }
    return types::ALLOC_ERROR~;
}

/// Create an object environment record.
fn EnvRecord*? env_create(Heap* heap, EnvRecord* parent) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.is_declarative = false;

        HObject*? bindings = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bindings) {
            env_pool_free(heap, env);
            return types::ALLOC_ERROR~;
        }
        env.bindings = bindings;
        return env;
    }
    return types::ALLOC_ERROR~;
}

/// Create a new declarative environment record.
fn EnvRecord*? env_create_declarative(Heap* heap, EnvRecord* parent) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.is_declarative = true;

        HObject*? bindings = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bindings) {
            env_pool_free(heap, env);
            return types::ALLOC_ERROR~;
        }
        env.bindings = bindings;
        return env;
    }
    return types::ALLOC_ERROR~;
}

/// Return an environment record and its parents to the pool. The walk is
/// iterative, so a deep scope chain cannot overflow the C stack.
fn void env_destroy(Heap* heap, EnvRecord* env) {
    EnvRecord* cur = env;
    while (cur != null) {
        EnvRecord* next = cur.parent;
        env_pool_free(heap, cur);
        cur = next;
    }
}

// ============================================================================
// Variable resolution: walking the scope chain
// ============================================================================

/// Find a binding by walking outward through the scope chain.
fn TVal? env_get(EnvRecord* env, void* key) {
    EnvRecord* cur = env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            return cur.bindings.prop_values()[idx];
        }
        cur = cur.parent;
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Check whether a binding exists anywhere in the scope chain.
fn bool env_has(EnvRecord* env, void* key) @inline {
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.bindings.has_prop(key)) {
            return true;
        }
        cur = cur.parent;
    }
    return false;
}

// ============================================================================
// Mutation: set and declare
// ============================================================================

/// Assign to a binding. An existing one is updated wherever in the chain it
/// lives; if the name is bound nowhere, a new binding appears in the immediate
/// environment.
fn bool env_put(EnvRecord* env, void* key, TVal val) {
    EnvRecord* cur = env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            TVal* pv = &cur.bindings.prop_values()[idx];
            if (hobject::_active_heap != null) {
                heap::Heap* h = (heap::Heap*)hobject::_active_heap;
                if (pv.is_string() || pv.is_bigint()) { h.decref_tval(pv); }
                *pv = val;
                if (val.is_string() || val.is_bigint()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
            } else {
                *pv = val;
            }
            return true;
        }
        cur = cur.parent;
    }
    // Unbound everywhere, so create it here.
    EnvRecord* target = env;
    return target.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a binding in the given environment only (no chain walk).
fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a non-writable, enumerable binding (CreateImmutableBinding, ES2015
/// §8.1.1.1.3). `import * as ns` uses this (§16.2.1.6.2 step 8.b.ii): the
/// namespace object is bound once, and assigning to the local name afterwards
/// must throw a TypeError, as it would for a `const`.
fn bool env_declare_const(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_EC);
}

/// Declare a `var` binding in this environment alone, with no chain walk.
///
/// On the global environment record the binding is non-configurable, per ES2015
/// §8.1.1.4.15 CreateGlobalVarBinding: a script-level var on the global object
/// is { writable: true, enumerable: true, configurable: false }, unlike a bare
/// `x = 1` assignment, which stays configurable. Function-scope var
/// environments are not observable as object properties, so configurability
/// there is immaterial and they keep the ordinary WEC flags.
///
/// `is_eval_code` is CreateGlobalVarBinding's `D` argument. eval's
/// EvalDeclarationInstantiation passes true (§18.2.1.2 step 16.a) and a Script's
/// GlobalDeclarationInstantiation passes false (§15.1.11 step 18.a), so
/// eval-created global bindings stay configurable and script-level ones do not.
///
/// `is_bare` marks an initializer-less `var x;`, which CanDeclareGlobalVar steps
/// 4 and 5 skip once the property exists. It comes from the opcode, DECLVAR_HOIST
/// against DECLVAR, rather than from testing `val`, because a declaration can
/// legitimately store `undefined`, as `for (var v of [1, , 3])` does on a hole.
///
/// FunctionDeclaration hoisting uses `env_declare_global_func` instead, since
/// CreateGlobalFunctionBinding treats an existing property differently.
fn bool env_declare_var(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code, bool is_bare) @inline {
    if (is_global && is_bare && env.bindings.has_prop(key)) {
        return true;
    }
    hobject::PropFlags flags = !is_global ? hobject::PROP_FLAGS_WEC
        : (is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE);
    return env.bindings.put_prop(key, val, flags);
}

/// Instantiate a top-level FunctionDeclaration binding
/// (CreateGlobalFunctionBinding, ES2024 §9.1.1.4.18).
///
/// Outside a global Environment Record this is an ordinary declarative
/// binding, identical to `env_declare_var`. On the global object the
/// existing own property decides the descriptor:
///
///   - Absent, or present and configurable: define the whole descriptor as
///     { value, writable: true, enumerable: true, configurable: D }, where D is
///     true for eval code (§19.2.1.3) and false for Script code (§16.1.7), the
///     same distinction `env_declare_var` draws with `is_eval_code`.
///   - Present and non-configurable: replace the value alone and keep the
///     current attributes, which is step 6's PropertyDescriptor{[[Value]]: V}.
///     CanDeclareGlobalFunction, emitted as CHKGLOBALFUNC, has already rejected
///     the illegal redefinitions, so anything arriving here is writable and
///     enumerable.
fn bool env_declare_global_func(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code) @inline {
    if (!is_global) {
        return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
    }
    int idx = env.bindings.find_prop_idx(key);
    hobject::PropFlags flags = is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE;
    if (idx >= 0) {
        hobject::PropFlags existing = env.bindings.get_prop_flags((uint)idx);
        if (!existing.configurable) { flags = existing; }
    }
    return env.bindings.put_prop(key, val, flags);
}

/// Declare a built-in global, which ES §17 requires to be
/// { writable: true, enumerable: false, configurable: true }.
fn bool env_declare_nonenum(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WC);
}

/// Declare an immutable global: `undefined`, `NaN`, and `Infinity` (ES5 §15.1).
fn bool env_declare_immutable(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_NNC);
}

/// Declare an accessor binding in this environment alone. `accessor_value` must
/// be a boxed getter and setter pair from `hobject::hobject_create_accessors` or
/// the module-binding helper above it. Live module imports use this so a read
/// reaches the exporting module's current value rather than a snapshot.
fn bool env_declare_accessor(EnvRecord* env, void* key, TVal accessor_value) @inline {
    hobject::PropFlags flags = { .writable = false, .enumerable = true, .configurable = false, .is_accessor = true };
    return env.bindings.put_prop(key, accessor_value, flags);
}

// ============================================================================
// TDZ sentinel for let/const declarations
// ============================================================================

/// Marks a `let` or `const` binding that has not been initialized yet. GETVAR
/// throws a ReferenceError when it reads one, which is the temporal dead zone.
fn TVal tdz_sentinel() {
    TVal tv;
$if types::USE_NANBOX:
    // UNDEFINED with a payload of 1, which real undefined never has, since its
    // payload is 0.
    tv.bits = types::nanbox_encode_tagged(types::TAG_UNDEFINED, 1);
$else
    tv.tag     = UNDEFINED;
    tv.pointer = (void*)(usz)1;  // any non-null pointer marks the sentinel
$endif
    return tv;
}

/// Returns true if the value is the TDZ sentinel.
fn bool is_tdz_sentinel(TVal* tv) @inline {
$if types::USE_NANBOX:
    return !types::nanbox_is_double(tv.bits)
        && types::nanbox_get_tag(tv.bits) == types::TAG_UNDEFINED
        && types::nanbox_get_payload(tv.bits) != 0;
$else
    return tv.get_tag() == UNDEFINED && tv.get_heapptr() != null;
$endif
}

// ============================================================================
// Lexical environment helpers (for let/const)
// ============================================================================

/// Bind a name in this lexical record alone, leaving the parent chain untouched.
/// PUTLEX uses this for `let` and `const` declarations in the current block.
fn bool env_declare_lex(EnvRecord* lex_env, void* key, TVal val) @inline {
    return lex_env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Check if a binding exists in the lexical environment chain.
fn bool env_has_lex(EnvRecord* lex_env, void* key) @inline {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        if (cur.bindings.has_prop(key)) {
            return true;
        }
        cur = cur.parent;
    }
    return false;
}

/// Look up a binding `depth` records out from `env`, following that many parent
/// pointers and then looking the name up once. GETBOUND uses it for captures the
/// compiler already resolved.
fn TVal? env_get_at_depth(EnvRecord* env, uint depth, void* key) {
    EnvRecord* cur = env;
    for (uint i = 0; i < depth && cur != null; i++) {
        cur = cur.parent;
    }
    if (cur == null) return hobject::PROP_NOT_FOUND~;
    int idx = cur.bindings.find_prop_idx(key);
    if (idx >= 0) {
        return cur.bindings.prop_values()[idx];
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Whether assigning to this name in the lexical chain is allowed. An unbound
/// name can be created, so it is writable; a bound one answers with its own
/// flag, which is false for a `const`.
fn bool env_is_lex_writable(EnvRecord* lex_env, void* key) {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            return cur.bindings.get_prop_flags((uint)idx).writable;
        }
        cur = cur.parent;
    }
    return true;
}

/// Combined lookup for PUTVAR: walks the lexical chain once.
/// Returns:
/// Store `val` into the nearest lexical binding named `key`, in one walk.
///
/// Returns 1 when it updated the binding, 0 when the name is unbound here and
/// the caller should fall through to the var environment, -1 on a const
/// violation, and -2 for a TDZ read.
///
/// -2 only happens under `check_tdz`, which PUTVAR_ASSIGN passes for a user
/// assignment. Ordinary PUTVAR leaves it false so it can initialize a binding
/// still holding the sentinel.
fn int env_try_put_lex(EnvRecord* lex_env, void* key, TVal val, bool check_tdz) {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            TVal* pv0 = &cur.bindings.prop_values()[idx];
            if (check_tdz && is_tdz_sentinel(pv0)) {
                return -2;
            }
            if (!cur.bindings.get_prop_flags((uint)idx).writable) {
                return -1;
            }
            TVal* pv = &cur.bindings.prop_values()[idx];
            if (hobject::_active_heap != null) {
                heap::Heap* h = (heap::Heap*)hobject::_active_heap;
                // Strings and BigInts are refcounted, so the old value is
                // released and the new one taken.
                if (pv.is_string() || pv.is_bigint()) { h.decref_tval(pv); }
                *pv = val;
                if (val.is_string() || val.is_bigint()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
            } else {
                *pv = val;
            }
            return 1;
        }
        cur = cur.parent;
    }
    return 0;
}