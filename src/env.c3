/// Environment / scope-chain module for the Duktape C3 port.
///
/// Provides runtime variable resolution via a scope chain, matching
/// Duktape's var_env / lex_env architecture.
module duktape::env;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;

// ============================================================================
// EnvRecord pool
// ============================================================================

/// A pool block header — allocated blocks are linked so the heap can
/// free them on teardown.  The first field is the `next` pointer (void*
/// for opaque storage in the Heap struct).
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

    // Allocate a new block
    usz block_sz = EnvPoolBlock::size + EnvRecord::size * ENV_POOL_BLOCK_SIZE;
    void* raw = h.alloc_func(h.heap_udata, block_sz);
    if (raw == null) return null;
    mem::clear(raw, (sz)(block_sz));

    // Link into block list
    EnvPoolBlock* block = (EnvPoolBlock*)raw;
    block.next = h.env_pool_blocks;
    h.env_pool_blocks = block;

    // Thread records 1..N-1 into the freelist
    char* base = (char*)raw + EnvPoolBlock::size;
    for (uint i = 1; i < ENV_POOL_BLOCK_SIZE; i++) {
        EnvRecord* e = (EnvRecord*)(base + i * EnvRecord::size);
        e.parent = (EnvRecord*)h.env_freelist;
        h.env_freelist = e;
    }

    // Return the first record in the block
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
// EnvRecord — a single link in the scope chain
// ============================================================================

/// An environment record — a single link in the scope chain.
struct EnvRecord {
    /// Parent scope (null for the global scope).
    EnvRecord* parent;
    /// The object that holds bindings (property name → TVal).
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

/// Create a new object environment record.
/// Create a fresh function-scope var environment (marks is_function_scope).
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

/// Destroy an environment record and all its owned resources.
/// Iterative traversal — avoids C-stack overflow on deep scope chains.
fn void env_destroy(Heap* heap, EnvRecord* env) {
    EnvRecord* cur = env;
    while (cur != null) {
        EnvRecord* next = cur.parent;
        env_pool_free(heap, cur);
        cur = next;
    }
}

// ============================================================================
// Variable resolution — scope-chain walk
// ============================================================================

/// Look up a binding by walking the scope chain.
///
/// Optimized: single find_prop_idx per scope level.
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
// Mutation — set / declare
// ============================================================================

/// Set a binding value, updating an existing one or creating a new one.
///
/// When the variable is found in an existing env record, it is updated
/// in-place.  When the variable is NOT found anywhere in the chain, a new
/// binding is created in the immediate env (the function/global scope).
/// Optimized: single find_prop_idx per scope level.
fn bool env_put(EnvRecord* env, void* key, TVal val) {
    EnvRecord* cur = env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            // Found the binding — update it here (even if it's in an outer scope).
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
    // Not found anywhere — create in the immediate (function/global) scope.
    EnvRecord* target = env;
    return target.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a binding in the given environment only (no chain walk).
fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a non-writable, enumerable binding (CreateImmutableBinding,
/// ES2015 §8.1.1.1.3). Used for `import * as ns` module namespace bindings
/// (§16.2.1.6.2 ModuleDeclarationInstantiation step 8.b.ii): the binding is
/// initialized once with the namespace object and any later assignment to
/// the local name must throw a TypeError, matching `const`-style semantics.
fn bool env_declare_const(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_EC);
}

/// Declare a `var`/FunctionDeclaration binding in the given environment
/// only (no chain walk), using non-configurable flags when `env` is the
/// global environment record. Per ES2015 §8.1.1.4.15
/// CreateGlobalVarBinding / §8.1.1.4.17 CreateGlobalFunctionBinding, a
/// script-level var/function binding installed directly on the global
/// object is { writable: true, enumerable: true, configurable: false } —
/// distinct from ordinary assignment (`x = 1` with no declaration), which
/// remains configurable. Bindings in non-global (function-scope) var
/// environments are never directly observable as object properties, so
/// their configurability is immaterial; they keep the ordinary WEC flags.
///
/// `is_eval_code` distinguishes eval's EvalDeclarationInstantiation
/// (§18.2.1.2 step 16.a: `CreateGlobalVarBinding(vn, true)`) from a real
/// Script's GlobalDeclarationInstantiation (§15.1.11 step 18.a:
/// `CreateGlobalVarBinding(vn, false)`) — the boolean is the `D`
/// (configurable) argument in both: eval-created global var/function
/// bindings stay configurable; script-level ones do not.
///
/// CreateGlobalVarBinding only installs a binding (with a fresh descriptor)
/// when the global object doesn't already have an own property of that name.
/// `is_bare` marks an initializer-less `var x;` — a pure declaration with no
/// value to assign — which is skipped entirely once the property exists
/// (CanDeclareGlobalVar steps 4-5). The caller passes it from the opcode
/// (DECLVAR_HOIST vs DECLVAR) rather than testing `val`: a declaration can
/// legitimately assign `undefined`, as `for (var v of [1, , 3])` does on a
/// hole, and such a store must take effect.
///
/// FunctionDeclaration hoisting goes through `env_declare_global_func`
/// instead — CreateGlobalFunctionBinding's existing-property rules differ
/// from CreateGlobalVarBinding's, so the compiler emits DECLGLOBALFUNC for
/// those and DECLVAR only for genuine `var` declarations.
fn bool env_declare_var(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code, bool is_bare = false) @inline {
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
///   - absent, or present and configurable → define the full descriptor
///     { value, writable: true, enumerable: true, configurable: D }, where
///     D is true for eval code (§19.2.1.3) and false for Script code
///     (§16.1.7), matching `env_declare_var`'s `is_eval_code` argument.
///   - present and non-configurable → replace only the value and leave the
///     current attributes alone (step 6's `PropertyDescriptor{[[Value]]: V}`).
///     CanDeclareGlobalFunction (CHKGLOBALFUNC) has already rejected the
///     cases where that would be an illegal redefinition, so any property
///     reaching here is writable and enumerable.
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

/// Declare a non-enumerable binding (for built-in globals per ES spec §17).
/// Built-in properties must be { writable: true, enumerable: false, configurable: true }.
fn bool env_declare_nonenum(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WC);
}

/// Declare a non-enumerable, non-writable, non-configurable binding (ES5 §15.1).
/// Used for `undefined`, `NaN`, `Infinity` which are immutable globals.
fn bool env_declare_immutable(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_NNC);
}

/// Declare an accessor binding in the given environment (no chain walk).
/// `accessor_value` must be a boxed getter/setter pair as produced by
/// `hobject::hobject_create_accessors` (or the module-binding helper built
/// on top of it). Used for live module import bindings, which must resolve
/// through to the exporting module's current value rather than a snapshot.
fn bool env_declare_accessor(EnvRecord* env, void* key, TVal accessor_value) @inline {
    hobject::PropFlags flags = { .writable = false, .enumerable = true, .configurable = false, .is_accessor = true };
    return env.bindings.put_prop(key, accessor_value, flags);
}

// ============================================================================
// TDZ sentinel for let/const declarations
// ============================================================================

/// Sentinel value used to mark uninitialized `let`/`const` bindings.
/// When GETVAR encounters this in lex_env, it throws a ReferenceError
/// for temporal dead zone access.
fn TVal tdz_sentinel() {
    TVal tv;
$if types::USE_NANBOX:
    // Encode as UNDEFINED with payload=1 — distinguishable from real
    // undefined (which has payload=0) and from any tagged value (which
    // uses a non-zero tag field).
    tv.bits = types::nanbox_encode_tagged(types::TAG_UNDEFINED, 1);
$else
    tv.tag     = UNDEFINED;
    tv.pointer = (void*)(usz)1;  // TDZ sentinel: non-null marker
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

/// Store a binding in the topmost lexical environment record only.
/// Used for let/const declarations via PUTLEX — creates the binding
/// in the current block's scope without walking the parent chain.
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

/// Look up a binding at a specific depth in the scope chain.
/// Walks `depth` parent pointers from `env`, then does a single
/// hash lookup by name.  Used by GETBOUND for pre-resolved captures.
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

/// Check if a binding in the lexical environment chain is writable.
/// Returns true if the binding does not exist anywhere in the chain
/// (it can be created), or if it exists and is writable.
/// Returns false only if the binding exists and is not writable (const).
/// Optimized: single find_prop_idx per scope level (not has_prop + is_prop_writable).
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
///    1 = found and updated successfully
///    0 = not found in lex_env (caller should fall through to env_put)
///   -1 = found but not writable (const violation — caller throws TypeError)
/// This replaces the triple-walk pattern: env_has_lex + env_is_lex_writable + env_put_lex.
/// Store `val` into the nearest lexical binding named `key`.
/// Returns: 1 = updated, 0 = not found (caller falls through to var_env),
/// -1 = const violation, -2 = TDZ (only when `check_tdz` and the binding still
/// holds the TDZ sentinel — used by PUTVAR_ASSIGN for user assignment; ordinary
/// PUTVAR passes check_tdz=false so it can initialize a sentinel binding).
fn int env_try_put_lex(EnvRecord* lex_env, void* key, TVal val, bool check_tdz = false) {
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
                // Strings and BigInts are reference-counted primitives held by
                // bindings; release the old value and incref the new one.
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