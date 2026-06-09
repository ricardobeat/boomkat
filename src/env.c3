/// Environment / scope-chain module for the Duktape C3 port.
///
/// Provides runtime variable resolution via a scope chain, matching
/// Duktape's var_env / lex_env architecture.
module duktape::env;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;

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
        libc::memset(env, 0, EnvRecord::size);
        return env;
    }

    // Allocate a new block
    usz block_sz = EnvPoolBlock::size + EnvRecord::size * ENV_POOL_BLOCK_SIZE;
    void* raw = libc::malloc(block_sz);
    if (raw == null) return null;
    libc::memset(raw, 0, block_sz);

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
    libc::memset(env, 0, EnvRecord::size);
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
    /// Is this a `with`-statement environment? When true, env_put
    /// skips this record when creating new bindings (unresolvable
    /// references go to the enclosing non-with scope).
    bool is_with;
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

/// Create a new `with` environment record wrapping an existing HObject.
///
/// Unlike `env_create`, this does NOT allocate a new bindings object —
/// it uses the caller-supplied object directly. The `is_with` flag is
/// set so that `env_put` skips this record when creating *new* bindings
/// (spec-compliant: unresolvable references inside `with` go to the
/// enclosing scope, not to the with-object).
fn EnvRecord*? env_create_with_object(Heap* heap, EnvRecord* parent, HObject* bindings) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.bindings = bindings;
        env.is_declarative = false;
        env.is_with = true;
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
/// For `with`-env records (`is_with == true`) we walk the prototype
/// chain of the bindings object (ES5 §10.2.1.2.1 — HasBinding uses
/// [[HasProperty]]).  For declarative envs we only check own properties.
/// Optimized: single find_prop_idx per scope level for non-with envs.
fn TVal? env_get(EnvRecord* env, void* key) {
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.is_with) {
            TVal? result = cur.bindings.get_prop_proto(key);
            if (try v = result) {
                return v;
            }
        } else {
            int idx = cur.bindings.find_prop_idx(key);
            if (idx >= 0) {
                return cur.bindings.prop_values()[idx].data.value;
            }
        }
        cur = cur.parent;
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Check whether a binding exists anywhere in the scope chain.
fn bool env_has(EnvRecord* env, void* key) @inline {
    EnvRecord* cur = env;
    while (cur != null) {
        bool found = cur.is_with
                     ? cur.bindings.has_prop_proto(key)
                     : cur.bindings.has_prop(key);
        if (found) {
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
/// When the variable is found in an existing env record (including
/// with-envs), it is updated in-place.  When the variable is NOT found
/// anywhere, the new binding is created in the first *non-with* record
/// (the function/global scope) — this is the ES5-spec-compliant
/// behaviour for unresolvable references inside `with` blocks.
///
/// For `with`-envs (`is_with == true`) we walk the prototype chain
/// when checking for existing bindings (matching [[HasProperty]]).
/// Optimized: single find_prop_idx per scope level for non-with envs.
fn bool env_put(EnvRecord* env, void* key, TVal val) {
    EnvRecord* cur = env;
    EnvRecord* first_non_with = null;
    while (cur != null) {
        if (cur.is_with) {
            if (cur.bindings.has_prop_proto(key)) {
                return cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
            }
        } else {
            int idx = cur.bindings.find_prop_idx(key);
            if (idx >= 0) {
                // Found the binding — update it here (even if it's in an outer scope).
                hobject::PropValue* pv = &cur.bindings.prop_values()[idx];
                if (cur.bindings.heap_ptr != null) {
                    heap::Heap* h = (heap::Heap*)cur.bindings.heap_ptr;
                    if (pv.data.value.is_string()) { h.decref_tval(&pv.data.value); }
                    pv.data.value = val;
                    if (val.is_string()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
                } else {
                    pv.data.value = val;
                }
                return true;
            }
        }
        if (!cur.is_with && first_non_with == null) {
            first_non_with = cur;
        }
        cur = cur.parent;
    }
    // Not found in the entire chain — create in the first non-with scope
    // (which is the function/global scope that contains the with block).
    EnvRecord* target = (first_non_with != null) ? first_non_with : env;
    return target.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a binding in the given environment only (no chain walk).
fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a non-enumerable binding (for built-in globals per ES spec §17).
/// Built-in properties must be { writable: true, enumerable: false, configurable: true }.
fn bool env_declare_nonenum(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WC);
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

/// Look up a binding in the lexical environment chain only.
/// Returns PROP_NOT_FOUND if not found.
/// Optimized: single find_prop_idx per scope level (not has_prop + get_prop).
fn TVal? env_get_lex(EnvRecord* lex_env, void* key) {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            return cur.bindings.prop_values()[idx].data.value;
        }
        cur = cur.parent;
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Store a binding in the topmost lexical environment record only.
/// Used for let/const declarations via PUTLEX — creates the binding
/// in the current block's scope without walking the parent chain.
fn bool env_declare_lex(EnvRecord* lex_env, void* key, TVal val) @inline {
    return lex_env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Store a binding in the lexical environment chain, creating or updating
/// in the first record that already has the binding, or in the topmost record
/// if the binding doesn't exist yet.
/// Used by PUTVAR for assignments to let/const variables.
/// Optimized: single find_prop_idx per scope level (not has_prop + is_prop_writable + put_prop).
fn bool env_put_lex(EnvRecord* lex_env, void* key, TVal val) {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            if (!cur.bindings.prop_values()[idx].flags.writable) {
                return false;
            }
            hobject::PropValue* pv = &cur.bindings.prop_values()[idx];
            if (cur.bindings.heap_ptr != null) {
                heap::Heap* h = (heap::Heap*)cur.bindings.heap_ptr;
                if (pv.data.value.is_string()) { h.decref_tval(&pv.data.value); }
                pv.data.value = val;
                if (val.is_string()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
            } else {
                pv.data.value = val;
            }
            return true;
        }
        cur = cur.parent;
    }
    // Not found in chain — create in the topmost record
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
        return cur.bindings.prop_values()[idx].data.value;
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Store a binding at a specific depth in the scope chain.
fn bool env_put_at_depth(EnvRecord* env, uint depth, void* key, TVal val) {
    EnvRecord* cur = env;
    for (uint i = 0; i < depth && cur != null; i++) {
        cur = cur.parent;
    }
    if (cur == null) return false;
    int idx = cur.bindings.find_prop_idx(key);
    if (idx >= 0) {
        if (!cur.bindings.prop_values()[idx].flags.writable) return false;
        hobject::PropValue* pv = &cur.bindings.prop_values()[idx];
        if (cur.bindings.heap_ptr != null) {
            heap::Heap* h = (heap::Heap*)cur.bindings.heap_ptr;
            if (pv.data.value.is_string()) { h.decref_tval(&pv.data.value); }
            pv.data.value = val;
            if (val.is_string()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
        } else {
            pv.data.value = val;
        }
        return true;
    }
    return cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
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
            return cur.bindings.prop_values()[idx].flags.writable;
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
/// Check whether a key is a const binding in the lex chain.
/// Returns -1 if the key exists and is const, 0 otherwise.
/// Does NOT write any value.
fn int env_check_const(EnvRecord* lex_env, void* key) {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            if (!cur.bindings.prop_values()[idx].flags.writable) {
                return -1;
            }
            return 0;
        }
        cur = cur.parent;
    }
    return 0;
}

fn int env_try_put_lex(EnvRecord* lex_env, void* key, TVal val) {
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key);
        if (idx >= 0) {
            if (!cur.bindings.prop_values()[idx].flags.writable) {
                return -1;
            }
            hobject::PropValue* pv = &cur.bindings.prop_values()[idx];
            if (cur.bindings.heap_ptr != null) {
                heap::Heap* h = (heap::Heap*)cur.bindings.heap_ptr;
                bool old_is_str = pv.data.value.is_string();
                if (old_is_str) {
                    h.decref_tval(&pv.data.value);
                }
                pv.data.value = val;
                if (val.is_string()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
            } else {
                pv.data.value = val;
            }
            return 1;
        }
        cur = cur.parent;
    }
    return 0;
}