// The scope chain: runtime variable resolution through linked environment
// records, split into a var environment and a lex environment.
module boomkat::env;

import std::math;

import boomkat::types;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;

// ============================================================================
// EnvRecord pool
// ============================================================================

// Header of an EnvPoolBlock. Blocks link through `next` so Heap teardown
// can free all blocks.
struct EnvPoolBlock { void* next; }

const uint ENV_POOL_BLOCK_SIZE = 64;

// Allocates an EnvRecord from the heap pool.
fn EnvRecord*? env_pool_alloc(Heap* h) {
    if (h.env_freelist != null) {
        EnvRecord* env = (EnvRecord*)h.env_freelist;
        h.env_freelist = env.parent;
        mem::clear(env, (sz)(EnvRecord::size));
        return env;
    }

    usz block_sz = EnvPoolBlock::size + EnvRecord::size * ENV_POOL_BLOCK_SIZE;
    void* raw = h.alloc_func(h.heap_udata, block_sz);
    if (raw == null) return null;
    mem::clear(raw, (sz)(block_sz));

    EnvPoolBlock* block = (EnvPoolBlock*)raw;
    block.next = h.env_pool_blocks;
    h.env_pool_blocks = block;

    char* base = (char*)raw + EnvPoolBlock::size;
    for (uint i = 1; i < ENV_POOL_BLOCK_SIZE; i++) {
        EnvRecord* e = (EnvRecord*)(base + i * EnvRecord::size);
        e.parent = (EnvRecord*)h.env_freelist;
        h.env_freelist = e;
    }

    return (EnvRecord*)base;
}

// Returns an EnvRecord to the heap pool freelist.
fn void env_pool_free(Heap* h, EnvRecord* env) {
    if (env == null) return;
    mem::clear(env, (sz)(EnvRecord::size));
    env.parent = (EnvRecord*)h.env_freelist;
    h.env_freelist = env;
}

// ============================================================================
// EnvRecord, one link in the scope chain
// ============================================================================

struct EnvRecord {
    // Parent scope (null for the global scope).
    EnvRecord* parent;
    // Object holding binding key-value pairs.
    HObject* bindings;
    // True for declarative environments, false for object environments.
    bool is_declarative;
    // Function call boundary: var-scope writes do not propagate past this link.
    bool is_function_scope;
    // `with`-statement environment: lookups walk the bindings object's
    // prototype chain (ES5 §10.2.1.2.1), and unresolved assignments fall
    // through to the enclosing scope rather than landing on the with object.
    bool is_with;
    // Owning heap for bindings and property operations.
    Heap* heap;
}

// ============================================================================
// Creation / destruction
// ============================================================================

// Creates a function-scoped environment record.
fn EnvRecord*? env_create_function_scope(Heap* heap, EnvRecord* parent) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.heap = heap;
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

// Creates an object environment record.
fn EnvRecord*? env_create(Heap* heap, EnvRecord* parent) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.heap = heap;
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

// Creates a declarative environment record.
fn EnvRecord*? env_create_declarative(Heap* heap, EnvRecord* parent) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.heap = heap;
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

// Create a `with` environment record wrapping an existing HObject.
//
// Does not allocate a new bindings object: `bindings` is the user's object
// as ToObject'd by the VM. `is_with = true` tells env_get/env_has to walk
// the prototype chain, and env_put to skip this record when creating new
// bindings (unresolvable references inside `with` go to the enclosing
// non-with scope).
fn EnvRecord*? env_create_with_object(Heap* heap, EnvRecord* parent, HObject* bindings) {
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        env.bindings = bindings;
        env.heap = heap;
        env.is_declarative = false;
        env.is_with = true;
        return env;
    }
    return types::ALLOC_ERROR~;
}

// Iteratively returns an environment record and its parent chain to the pool.
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

// ToBoolean on a TVal, mirroring ES2024 §7.1.2 (used by the @@unscopables
// gate below; builtins::tval_to_boolean lives in builtins/set.c3 which env
// cannot import). undefined and null are false; NaN, +0, -0 are false; ""
// is false; everything else is true.
fn bool env_tval_to_boolean(TVal v) {
    if (v.is_undefined() || v.is_null()) return false;
    if (v.is_boolean()) return v.get_boolean();
    if (v.is_number()) {
        double d = v.get_number();
        return d != 0.0 && !math::is_nan(d);
    }
    if (v.is_fastint()) return v.get_fastint() != 0;
    if (v.is_string()) {
        void* p = v.get_heapptr();
        return p != null && ((HString*)p).blen > 0;
    }
    return true;
}

// [[Get]] on `obj` walking the prototype chain (ES2024 §10.1.8.1 OrdinaryGet +
// §10.5 Proxy exotic). Invokes accessor getters via heap.call_fn; routes
// proxies through heap.proxy_get_fn. Sets heap.has_error on throw. Returns
// false if a callback (getter or proxy trap) threw; in that case the caller
// treats the property as not found and the engine surfaces the pending error.
fn bool env_full_get(Heap* h, HObject* obj, void* key, TVal receiver, TVal* out) {
    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        if (cur.flags.exotic_proxyobj) {
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                return h.proxy_get_fn(h.vm_ptr, h, cur, key, receiver, out);
            }
            out.set_undefined();
            return true;
        }
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            TVal slot = cur.prop_values()[idx];
            if (cur.get_prop_flags((uint)idx, h).is_accessor) {
                TVal getter = hobject::hobject_access_getter(slot);
                if (getter.is_undefined() || getter.is_null() ||
                    h.call_fn == null || h.vm_ptr == null) {
                    out.set_undefined();
                    return true;
                }
                *out = h.call_fn(h.vm_ptr, getter, null, 0, receiver);
                return !h.has_error;
            }
            *out = slot;
            return true;
        }
        cur = cur.prototype;
        depth++;
    }
    out.set_undefined();
    return true;
}

// ES2024 §9.1.1.2.1 HasBinding step 6-9: a `with` binding is hidden by an
// @@unscopables entry whose value is true. Returns true when `name` is
// blocked; a thrown getter (scopables-get-err style) leaves the error
// pending in the heap so the VM can surface it.
fn bool with_unscopables_blocks(Heap* h, EnvRecord* with_env, void* name) {
    if (h.unscopables_symbol == null) return false;
    HObject* b = with_env.bindings;
    if (b == null) return false;
    TVal receiver; receiver.set_object(b);
    TVal usv;
    if (!env_full_get(h, b, (void*)h.unscopables_symbol, receiver, &usv)) return false;
    if (h.has_error) return false;
    if (!usv.is_object() || usv.get_heapptr() == null) return false;
    HObject* us_obj = (HObject*)usv.get_heapptr();
    TVal blocked_v;
    if (!env_full_get(h, us_obj, name, receiver, &blocked_v)) return false;
    if (h.has_error) return false;
    return env_tval_to_boolean(blocked_v);
}

// Walks outward through the scope chain to find a binding.
//
// For `with` environments (`is_with == true`) the lookup walks the
// bindings object's prototype chain via [[HasProperty]] / [[Get]]
// (ES5 §10.2.1.2.1). Declarative and other object environments only
// match own properties.
fn TVal? env_get(EnvRecord* env, void* key) {
    Heap* h = env.heap;
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.is_with) {
            TVal? result = cur.bindings.get_prop_proto(key, h);
            if (try v = result) {
                // HasBinding step 6-9: a true @@unscopables entry hides it.
                if (with_unscopables_blocks(h, cur, key)) {
                    cur = cur.parent;
                    continue;
                }
                return v;
            }
        } else {
            int idx = cur.bindings.find_prop_idx(key, h);
            if (idx >= 0) {
                return cur.bindings.prop_values()[idx];
            }
        }
        cur = cur.parent;
    }
    return hobject::PROP_NOT_FOUND~;
}

// Checks if a binding exists anywhere in the scope chain.
fn bool env_has(EnvRecord* env, void* key) @inline {
    Heap* h = env.heap;
    EnvRecord* cur = env;
    while (cur != null) {
        bool found = cur.is_with
                     ? (cur.bindings.has_prop_proto(key, h)
                        && !with_unscopables_blocks(h, cur, key))
                     : cur.bindings.has_prop(key, h);
        if (found) {
            return true;
        }
        cur = cur.parent;
    }
    return false;
}

// ============================================================================
// Mutation: set and declare
// ============================================================================

// Assigns to an existing binding anywhere in the chain, or creates a new
// binding on the first non-with record in the chain.
//
// An existing binding is updated in-place (even if it's in an outer scope).
// For `with`-envs the existing-binding check walks the prototype chain
// (matching [[HasProperty]]). A new binding never lands on a `with`-env:
// unresolvable references inside `with` go to the enclosing non-with
// scope, which is the spec-compliant behavior.
fn bool env_put(EnvRecord* env, void* key, TVal val) {
    Heap* h = env.heap;
    EnvRecord* cur = env;
    EnvRecord* first_non_with = null;
    while (cur != null) {
        bool found = cur.is_with
                     ? (cur.bindings.has_prop_proto(key, h)
                        && !with_unscopables_blocks(h, cur, key))
                     : cur.bindings.find_prop_idx(key, h) >= 0;
        if (found) {
            return cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, h);
        }
        if (!cur.is_with && first_non_with == null) {
            first_non_with = cur;
        }
        cur = cur.parent;
    }
    // Not found in the entire chain — create on the first non-with scope
    // (the function/global scope that contains the with block).
    EnvRecord* target = (first_non_with != null) ? first_non_with : env;
    return target.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, h);
}

// Declares a binding in this environment alone.
fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, env.heap);
}

// Declares a non-writable, enumerable binding (CreateImmutableBinding,
// ES2015 §8.1.1.1.3; used by namespace imports, §16.2.1.6.2).
fn bool env_declare_const(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_EC, env.heap);
}

// Declares a `var` binding in this environment alone (CreateGlobalVarBinding,
// ES2015 §8.1.1.4.15).
//
// Script global vars are non-configurable ({ writable: true, enumerable: true,
// configurable: false }), while eval global vars (`is_eval_code = true`) remain
// configurable. Function scopes always use standard WEC flags.
//
// `is_bare` marks initializer-less `var x;`, skipped when the property already
// exists (CanDeclareGlobalVar steps 4-5).
fn bool env_declare_var(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code, bool is_bare) @inline {
    Heap* h = env.heap;
    if (is_global && is_bare && env.bindings.has_prop(key, h)) {
        return true;
    }
    hobject::PropFlags flags = !is_global ? hobject::PROP_FLAGS_WEC
        : (is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE);
    return env.bindings.put_prop(key, val, flags, h);
}

// Instantiates a top-level FunctionDeclaration binding
// (CreateGlobalFunctionBinding, ES2024 §9.1.1.4.18).
//
// In non-global scopes this creates an ordinary WEC binding. On the global
// object, absent or configurable properties receive { value, W, E, C: D }
// (where D is true for eval code), while existing non-configurable properties
// update only their value and retain existing attributes.
fn bool env_declare_global_func(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code) @inline {
    Heap* h = env.heap;
    if (!is_global) {
        // Function declarations inside a function body are bound with
        // DeletableBinding=false in BOTH strict and sloppy (Annex B.3.3
        // Instantiation + §10.2.1.1.6 CreateMutableBinding), so a sloppy
        // \`delete f\` returns false for an inner function declaration.
        return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WE, h);
    }
    int idx = env.bindings.find_prop_idx(key, h);
    hobject::PropFlags flags = is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE;
    if (idx >= 0) {
        hobject::PropFlags existing = env.bindings.get_prop_flags((uint)idx, h);
        if (!existing.configurable) { flags = existing; }
    }
    return env.bindings.put_prop(key, val, flags, h);
}

// Declares a built-in global property ({ W: true, E: false, C: true }, ES §17).
fn bool env_declare_nonenum(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WC, env.heap);
}

// Declares an immutable global constant: undefined, NaN, Infinity (ES5 §15.1).
fn bool env_declare_immutable(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_NNC, env.heap);
}

// Declares an accessor binding in this environment alone, used for live module
// imports (accessor_value holds a boxed getter/setter pair).
fn bool env_declare_accessor(EnvRecord* env, void* key, TVal accessor_value) @inline {
    hobject::PropFlags flags = { .writable = false, .enumerable = true, .configurable = false, .is_accessor = true };
    return env.bindings.put_prop(key, accessor_value, flags, env.heap);
}

// ============================================================================
// TDZ sentinel for let/const declarations
// ============================================================================

// Temporal dead zone sentinel for uninitialized `let` and `const` bindings.
fn TVal tdz_sentinel() {
    TVal tv;
$if types::USE_NANBOX:
    // Encoded as TAG_UNDEFINED with payload 1 (standard undefined uses payload 0).
    tv.bits = types::nanbox_encode_tagged(types::TAG_UNDEFINED, 1);
$else
    tv.tag     = UNDEFINED;
    tv.pointer = (void*)(usz)1;
$endif
    return tv;
}

// Returns true if `tv` is the TDZ sentinel.
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

// Declares a lexical binding in `lex_env` without traversing parent scopes.
fn bool env_declare_lex(EnvRecord* lex_env, void* key, TVal val) @inline {
    return lex_env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, lex_env.heap);
}

// Checks if a binding exists in the lexical environment chain.
fn bool env_has_lex(EnvRecord* lex_env, void* key) @inline {
    Heap* h = lex_env.heap;
    EnvRecord* cur = lex_env;
    while (cur != null) {
        bool found = cur.is_with
                     ? (cur.bindings.has_prop_proto(key, h)
                        && !with_unscopables_blocks(h, cur, key))
                     : cur.bindings.has_prop(key, h);
        if (found) {
            return true;
        }
        cur = cur.parent;
    }
    return false;
}

// Looks up a binding at a known static ancestor depth.
fn TVal? env_get_at_depth(EnvRecord* env, uint depth, void* key) {
    EnvRecord* cur = env;
    for (uint i = 0; i < depth && cur != null; i++) {
        cur = cur.parent;
    }
    if (cur == null) return hobject::PROP_NOT_FOUND~;
    int idx = cur.bindings.find_prop_idx(key, env.heap);
    if (idx >= 0) {
        return cur.bindings.prop_values()[idx];
    }
    return hobject::PROP_NOT_FOUND~;
}

// Checks if a binding in the lexical chain is writable (false for `const`).
fn bool env_is_lex_writable(EnvRecord* lex_env, void* key) {
    Heap* h = lex_env.heap;
    EnvRecord* cur = lex_env;
    while (cur != null) {
        int idx = cur.bindings.find_prop_idx(key, h);
        if (idx >= 0) {
            return cur.bindings.get_prop_flags((uint)idx, h).writable;
        }
        cur = cur.parent;
    }
    return true;
}

// Stores `val` in the nearest existing lexical binding matching `key`.
// Returns 1 on success, 0 if unbound (fall back to var environment),
// -1 on const assignment violation, or -2 on TDZ access (when check_tdz is true).
//
// For `with` environments (`is_with == true`) the existing-binding check
// walks the prototype chain; on a hit the value goes through put_prop, which
// handles both own-property update and reference refcounting. Writable/read-
// only/TDZ flags are not applicable to with-object lookups, so the const/TDZ
// guards are skipped on a with record.
//
// Per ES2024 §9.1.1.2.5 SetMutableBinding step 2, the spec re-checks
// HasProperty AFTER any observable unscopables getter has run — if the
// binding was deleted by the getter (or by RHS code that ran before this
// call), SetMutableBinding must NOT fall through to a parent env. The
// caller (PUTVAR_ASSIGN) distinguishes "with-env had it, now gone" from
// "with-env never had it" by inspecting the RESOLVEVAR probe's stored env
// pointer. PUTVAR (sloppy `var x = …`) treats -3 as fall-through because it
// has no with-env context to protect.
fn int env_try_put_lex(EnvRecord* lex_env, void* key, TVal val, bool check_tdz) {
    Heap* h = lex_env.heap;
    EnvRecord* cur = lex_env;
    while (cur != null) {
        if (cur.is_with) {
            bool first_has = cur.bindings.has_prop_proto(key, h);
            if (h.has_error) return 0;
            if (!first_has) {
                // Binding never on this with-env; the walk continues to
                // the parent env (§9.1.1.2.5 step 4 falls through when
                // stillExists is false, and the parent may declare it).
                cur = cur.parent;
                continue;
            }
            // @@unscopables HIDES the binding from this with-env
            // (§9.1.1.2.2 HasBinding step 5), so a block-flag from the
            // getter is "skip this with-env" — the binding is still on
            // the object (no deletion), just hidden from the lookup.
            // Continue to parent.
            if (!with_unscopables_blocks(h, cur, key)) {
                // Getter returned a falsish flag, but it may have
                // DELETED the binding as a side effect. Re-check
                // HasProperty; if gone, return -3 so the caller can
                // distinguish "deleted on this env" from "not on this
                // env, walk past" (test262
                // set-mutable-binding-binding-deleted-in-get-unscopables-
                // strict-mode.js).
                if (h.has_error) return 0;
                if (!cur.bindings.has_prop_proto(key, h)) return -3;
                cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, h);
                return 1;
            }
            if (h.has_error) return 0;
            cur = cur.parent;
            continue;
        }
        int idx = cur.bindings.find_prop_idx(key, h);
        if (idx >= 0) {
            TVal* pv = &cur.bindings.prop_values()[idx];
            if (check_tdz && is_tdz_sentinel(pv)) {
                return -2;
            }
            if (!cur.bindings.get_prop_flags((uint)idx, h).writable) {
                return -1;
            }
            if (pv.is_string() || pv.is_bigint()) { h.decref_tval(pv); }
            *pv = val;
            if (val.is_string() || val.is_bigint()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
            return 1;
        }
        cur = cur.parent;
    }
    return 0;
}