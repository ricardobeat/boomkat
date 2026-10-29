// The scope chain: runtime variable resolution through linked environment
// records, split into a var environment and a lex environment.
module boomkat::env;

import std::math;

import boomkat::types;
import boomkat::features;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::gcprofile;

// ============================================================================
// EnvRecord pool
// ============================================================================

const uint ENV_POOL_BLOCK_SIZE = 64;

// Semantic and GC state packed into one byte. `allocated` separates a live
// cell from a freelist link (only `parent` is meaningful on a free cell);
// `mark_epoch` records the collection epoch that last traced the cell; and
// `temproot` pins a freshly allocated cell until a quiescent safepoint, the
// same contract as the object temproot flag.
bitstruct EnvFlags : char {
    bool is_declarative    : 0;
    bool is_function_scope : 1;
    bool is_with           : 2;
    bool is_catch          : 3;
    bool allocated         : 4;
    bool mark_epoch        : 5;
    bool temproot          : 6;
    // A module's own environment. The module cache roots it for the life of
    // the VM, like the two global records.
    bool is_module         : 7;
}

// One link in the scope chain. `bindings` holds the binding key-value pairs;
// `parent` links the enclosing scope, or doubles as the pool freelist link on
// an unallocated cell.
struct EnvRecord {
    // Parent scope (null for the global scope).
    EnvRecord* parent;
    // Object holding binding key-value pairs.
    HObject* bindings;
    // Intrusive mark work link; null outside the gray queue.
    void* gc_gray_next;
    bool gc_gray_queued;
    // Saved incremental epoch during the full-mark verification oracle.
    bool verify_epoch;
    EnvFlags flags;
    // Owning heap for bindings and property operations.
    Heap* heap;
}

// A pool block holds ENV_POOL_BLOCK_SIZE records plus a link to the next
// block, so Heap teardown can walk and free every block from the head.
struct EnvPoolBlock {
    EnvPoolBlock* next;
    EnvRecord[ENV_POOL_BLOCK_SIZE] cells;
}

// Allocates a zeroed EnvRecord, pinned as a temporary root and stamped with the
// current epoch. Callers set parent, bindings, heap and semantic flags.
fn EnvRecord*? env_pool_alloc(Heap* h) {
    EnvRecord* env;
    if (h.env_freelist != null) {
        env = (EnvRecord*)h.env_freelist;
        h.env_freelist = env.parent;
        mem::clear(env, (sz)(EnvRecord::size));
    } else {
        usz block_sz = EnvPoolBlock::size;
        void* raw = h.alloc_func(h.heap_udata, block_sz);
        if (raw == null) return null;
        mem::clear(raw, (sz)(block_sz));

        EnvPoolBlock* block = (EnvPoolBlock*)raw;
        block.next = h.env_pool_blocks;
        h.env_pool_blocks = block;
        h.env_block_count++;
        h.env_bytes_reserved += block_sz;
        if (h.env_bytes_reserved > h.env_peak_bytes_reserved) {
            h.env_peak_bytes_reserved = h.env_bytes_reserved;
        }

        for (uint i = 1; i < ENV_POOL_BLOCK_SIZE; i++) {
            EnvRecord* e = &block.cells[i];
            e.parent = (EnvRecord*)h.env_freelist;
            h.env_freelist = e;
        }
        env = &block.cells[0];
    }
    env.flags.allocated = true;
    env.flags.temproot = true;
    env.flags.mark_epoch = h.gc_phase == heap::GcPhase.MARK
                         ? !h.env_mark_epoch : h.env_mark_epoch;
    env.gc_gray_next = null;
    env.gc_gray_queued = false;
    h.env_alloc_count++;
    h.account_auxiliary_allocation(EnvRecord::size);
    h.env_live_cells++;
    if (h.gc_phase == heap::GcPhase.MARK) h.mark_env_chain((void*)env);
    return env;
}

// Returns an unpublished EnvRecord to the pool freelist. Only usable for a cell
// no caller has published; a published cell is reclaimed only by the
// environment sweep. Clearing the cell also clears its allocated bit.
fn void env_pool_free(Heap* h, EnvRecord* env) {
    if (env == null) return;
    if (h.gc_phase == heap::GcPhase.MARK) {
        // The mark queue may still hold this cell. Leave it allocated until a
        // later sweep instead of reusing its bytes under that queue entry.
        env.parent = null;
        env.bindings = null;
        env.flags.temproot = false;
        return;
    }
    mem::clear(env, (sz)(EnvRecord::size));
    env.parent = (EnvRecord*)h.env_freelist;
    h.env_freelist = env;
    if (h.env_live_cells > 0) { h.env_live_cells--; }
}

// Frees every pool block and resets the pool accounting. Shared by Heap
// destroy and reset so block layout knowledge lives here alone.
fn void env_pool_teardown(Heap* h) {
    EnvPoolBlock* b = (EnvPoolBlock*)h.env_pool_blocks;
    while (b != null) {
        EnvPoolBlock* next = b.next;
        h.free_func(h.heap_udata, (void*)b);
        b = next;
    }
    h.env_pool_blocks = null;
    h.env_freelist = null;
    h.env_alloc_count = 0;
    h.env_live_cells = 0;
    h.env_block_count = 0;
    h.env_bytes_reserved = 0;
    h.env_peak_bytes_reserved = 0;
}

// True when `env` is a cell-aligned member of one of this heap's pool blocks.
// HEAP_VERIFY uses it to confirm a traced EnvRecord* is a real member of this
// heap's pool, not a wild pointer or a cell from another heap.
fn bool env_pool_contains(Heap* h, EnvRecord* env) {
    EnvPoolBlock* b = (EnvPoolBlock*)h.env_pool_blocks;
    while (b != null) {
        char* lo = (char*)&b.cells[0];
        char* hi = lo + EnvRecord::size * ENV_POOL_BLOCK_SIZE;
        if ((char*)env >= lo && (char*)env < hi) {
            return ((usz)((char*)env - lo) % EnvRecord::size) == 0;
        }
        b = b.next;
    }
    return false;
}

// Scan every allocated cell at collection start. At a quiescent safepoint
// (`clear_pins`) each temporary-root pin is cleared so an otherwise-unreachable
// cell becomes collectable. Otherwise every pinned cell has its chain traced,
// keeping a freshly allocated scope and its parent alive while a native frame
// still holds only a raw local reference.
fn void env_pool_seed_or_clear_pins(Heap* h, bool clear_pins) {
    EnvPoolBlock* b = (EnvPoolBlock*)h.env_pool_blocks;
    while (b != null) {
        for (uint i = 0; i < ENV_POOL_BLOCK_SIZE; i++) {
            EnvRecord* e = &b.cells[i];
            if (!e.flags.allocated) continue;
            if (clear_pins) {
                e.flags.temproot = false;
            } else if (e.flags.temproot) {
                h.mark_env_chain((void*)e);
            }
        }
        b = b.next;
    }
}

// A verification mark flips the one-bit epoch before the real minor mark.
// Align all cells with that epoch so the real mark sees every chain afresh.
fn void env_pool_align_epoch(Heap* h) {
    EnvPoolBlock* b = (EnvPoolBlock*)h.env_pool_blocks;
    while (b != null) {
        for (uint i = 0; i < ENV_POOL_BLOCK_SIZE; i++) {
            EnvRecord* e = &b.cells[i];
            if (e.flags.allocated) e.flags.mark_epoch = h.env_mark_epoch;
        }
        b = b.next;
    }
}

// Reclaims every cell whose mark_epoch differs from the heap's current epoch.
// Recycling clears the cell without dereferencing its pointers, since the
// bindings object may already be freed. Blocks with no live cell are returned
// to the allocator, except one empty spare; the freelist is rebuilt from all
// retained blocks.
fn void env_pool_sweep(Heap* h) {
    h.env_freelist = null;
    uint total_live = 0;
    bool spare_kept = false;
    EnvPoolBlock* prev = null;
    EnvPoolBlock* b = (EnvPoolBlock*)h.env_pool_blocks;

    while (b != null) {
        EnvPoolBlock* next = b.next;
        uint block_live = 0;

        for (uint i = 0; i < ENV_POOL_BLOCK_SIZE; i++) {
            EnvRecord* e = &b.cells[i];
            if (!e.flags.allocated) continue;
            if (e.flags.mark_epoch == h.env_mark_epoch) {
                block_live++;
            } else {
                mem::clear(e, (sz)(EnvRecord::size));
            }
        }

        if (block_live == 0 && spare_kept) {
            // A spare empty block is already retained; release this one.
            if (prev != null) { prev.next = next; } else { h.env_pool_blocks = next; }
            h.free_func(h.heap_udata, (void*)b);
            h.env_block_count--;
            h.env_bytes_reserved -= EnvPoolBlock::size;
        } else {
            if (block_live == 0) { spare_kept = true; }
            for (uint i = 0; i < ENV_POOL_BLOCK_SIZE; i++) {
                EnvRecord* e = &b.cells[i];
                if (!e.flags.allocated) {
                    e.parent = (EnvRecord*)h.env_freelist;
                    h.env_freelist = e;
                }
            }
            prev = b;
        }
        total_live += block_live;
        b = next;
    }
    h.env_live_cells = total_live;
}

// Marks the chain of every allocated cell, one budgeted slice at a time.
fn bool env_pool_mark_step(Heap* h, heap::EnvSweepCursor* cursor, uint budget) {
    if (!cursor.started) {
        cursor.block = h.env_pool_blocks;
        cursor.index = 0;
        cursor.started = true;
    }
    while (cursor.block != null && budget > 0) {
        EnvPoolBlock* block = (EnvPoolBlock*)cursor.block;
        EnvRecord* e = &block.cells[cursor.index++];
        if (e.flags.allocated) {
            e.flags.temproot = false;
            h.mark_env_chain(e);
        }
        budget--;
        if (cursor.index == ENV_POOL_BLOCK_SIZE) {
            cursor.block = block.next;
            cursor.index = 0;
        }
    }
    return cursor.block == null;
}

// Recycle at most `budget` cells. Blocks remain reserved for reuse because
// mutator allocations can take cells from the global freelist between slices.
// A block cannot be freed while any of its cells may be on that list.
fn bool env_pool_sweep_step(Heap* h, heap::EnvSweepCursor* cursor, uint budget) {
    if (!cursor.started) {
        cursor.block = h.env_pool_blocks;
        cursor.index = 0;
        cursor.started = true;
    }
    while (cursor.block != null && budget > 0) {
        EnvPoolBlock* block = (EnvPoolBlock*)cursor.block;
        EnvRecord* e = &block.cells[cursor.index];
        if (e.flags.allocated && !h.gc_keep_temproots) e.flags.temproot = false;
        if (e.flags.allocated && e.flags.mark_epoch != h.env_mark_epoch) {
            mem::clear(e, (sz)(EnvRecord::size));
            e.parent = (EnvRecord*)h.env_freelist;
            h.env_freelist = e;
            h.env_live_cells--;
        }
        cursor.index++;
        budget--;
        if (cursor.index == ENV_POOL_BLOCK_SIZE) {
            cursor.block = block.next;
            cursor.index = 0;
        }
    }
    return cursor.block == null;
}

// Sets every cell to the unmarked epoch so the verification mark rediscovers
// all live environments. env_pool_verify_restore puts the epochs back.
fn void env_pool_verify_save(Heap* h) @feat(GC_VERIFY) {
    EnvPoolBlock* block = (EnvPoolBlock*)h.env_pool_blocks;
    while (block != null) {
        for (uint i = 0; i < ENV_POOL_BLOCK_SIZE; i++) {
            EnvRecord* e = &block.cells[i];
            if (!e.flags.allocated) continue;
            e.verify_epoch = e.flags.mark_epoch;
            e.flags.mark_epoch = !h.env_mark_epoch;
            e.gc_gray_next = null;
            e.gc_gray_queued = false;
        }
        block = block.next;
    }
}

fn void env_pool_verify_restore(Heap* h) @feat(GC_VERIFY) {
    EnvPoolBlock* block = (EnvPoolBlock*)h.env_pool_blocks;
    while (block != null) {
        for (uint i = 0; i < ENV_POOL_BLOCK_SIZE; i++) {
            EnvRecord* e = &block.cells[i];
            if (!e.flags.allocated) continue;
            if (e.flags.mark_epoch == h.env_mark_epoch && e.verify_epoch != h.env_mark_epoch) {
                h.fatal("GC_VERIFY: incremental mark missed a live environment");
            }
            e.flags.mark_epoch = e.verify_epoch;
            e.gc_gray_next = null;
            e.gc_gray_queued = false;
        }
        block = block.next;
    }
}

// ============================================================================
// Creation / destruction
// ============================================================================

// Creates a function-scoped environment record.
fn EnvRecord*? env_create_function_scope(Heap* heap, EnvRecord* parent, uint capacity = 0) {
    gcprofile::gcprof_env(true, false);
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        heap.shade_root_env((void*)parent);
        env.heap = heap;
        env.flags.is_declarative = false;
        env.flags.is_function_scope = true;
        HObject*? bindings = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bindings) {
            env_pool_free(heap, env);
            return types::ALLOC_ERROR~;
        }
        bindings.reserve_props(heap, capacity);
        env.bindings = bindings;
        heap.shade_root_object(bindings);
        return env;
    }
    return types::ALLOC_ERROR~;
}

// An object environment over a fresh ordinary object, or over `object` when
// given (a host-class global object).
fn EnvRecord*? env_create(Heap* heap, EnvRecord* parent, HObject* object = null) {
    gcprofile::gcprof_env(false, false);
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        heap.shade_root_env((void*)parent);
        env.heap = heap;
        env.flags.is_declarative = false;

        HObject*? bindings = object != null ? object : heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bindings) {
            env_pool_free(heap, env);
            return types::ALLOC_ERROR~;
        }
        env.bindings = bindings;
        heap.shade_root_object(bindings);
        return env;
    }
    return types::ALLOC_ERROR~;
}

fn EnvRecord*? env_create_declarative(Heap* heap, EnvRecord* parent) {
    gcprofile::gcprof_env(false, true);
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        heap.shade_root_env((void*)parent);
        env.heap = heap;
        env.flags.is_declarative = true;

        HObject*? bindings = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bindings) {
            env_pool_free(heap, env);
            return types::ALLOC_ERROR~;
        }
        env.bindings = bindings;
        heap.shade_root_object(bindings);
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
    gcprofile::gcprof_env(false, false);
    EnvRecord*? raw = env_pool_alloc(heap);
    if (try env = raw) {
        env.parent = parent;
        heap.shade_root_env((void*)parent);
        env.bindings = bindings;
        heap.shade_root_object(bindings);
        env.heap = heap;
        env.flags.is_declarative = false;
        env.flags.is_with = true;
        // A `with` env allocates no bindings object, so the object budget does
        // not see it. Charge the environment budget so repeated `with` scopes
        // still request collections.
        heap.env_alloc_budget--;
        if (heap.env_alloc_budget <= 0) {
            heap.request_gc();
        }
        return env;
    }
    return types::ALLOC_ERROR~;
}

// ============================================================================
// Variable resolution: walking the scope chain
// ============================================================================

// ECMA-262 ToBoolean (https://tc39.es/ecma262/#sec-toboolean) for the
// @@unscopables gate. The builtins copy cannot be imported here.
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
        return p != null && ((HString*)p).is_truthy();
    }
    return true;
}

// [[Get]] on `obj` along the prototype chain (ECMA-262 OrdinaryGet, and proxy [[Get]]). Accessor
// getters run through heap.call_fn; proxies go through heap.proxy_get_fn.
// Returns false if a getter or trap threw, leaving the error pending for the
// engine to surface.
fn bool env_full_get(Heap* h, HObject* obj, void* key, TVal receiver, TVal* out) {
    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        if (cur.is_proxy()) {
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                return h.proxy_get_fn(h.vm_ptr, h, cur, key, receiver, out);
            }
            out.set_undefined();
            return true;
        }
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            TVal slot = cur.prop_values()[idx].get();
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

// ECMA-262 HasBinding for Object Environment Records: a `with` binding is
// hidden by a true @@unscopables entry. Returns true when `name` is blocked.
// A thrown getter leaves the error pending in the heap for the VM to surface.
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

// Walks outward through the scope chain to find a binding. A `with` record
// searches the bindings object's prototype chain (ECMA-262 Object Environment
// Records); other records match own properties only.
fn TVal? env_get(EnvRecord* env, void* key) {
    Heap* h = env.heap;
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.is_with()) {
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
                return cur.bindings.prop_values()[idx].get();
            }
        }
        cur = cur.parent;
    }
    return hobject::PROP_NOT_FOUND~;
}

fn bool env_has(EnvRecord* env, void* key) @inline {
    Heap* h = env.heap;
    EnvRecord* cur = env;
    while (cur != null) {
        bool found = cur.is_with()
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
        bool found = cur.is_with()
                     ? (cur.bindings.has_prop_proto(key, h)
                        && !with_unscopables_blocks(h, cur, key))
                     : cur.bindings.find_prop_idx(key, h) >= 0;
        if (found) {
            return cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, h);
        }
        if (!cur.is_with() && first_non_with == null) {
            first_non_with = cur;
        }
        cur = cur.parent;
    }
    // Not found in the entire chain — create on the first non-with scope
    // (the function/global scope that contains the with block).
    EnvRecord* target = (first_non_with != null) ? first_non_with : env;
    return target.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, h);
}

fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC, env.heap);
}

// CreateMutableBinding(N, false): the binding cannot be deleted or redefined.
// Used for `arguments` so sloppy `delete arguments` reports false.
fn bool env_declare_nondeletable(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WE, env.heap);
}

// Declares a non-writable, enumerable binding (ECMA-262 CreateImmutableBinding). Used by namespace imports.
fn bool env_declare_const(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_EC, env.heap);
}

// Declares a `var` binding (ECMA-262 CreateGlobalVarBinding). Script global vars are
// non-configurable; eval global vars (`is_eval_code`) stay configurable.
// Function scopes use WEC flags.
//
// `is_bare` marks initializer-less `var x;`, skipped when the property already
// exists (CanDeclareGlobalVar steps 4-5).
fn bool env_declare_var(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code, bool is_bare) @inline {
    Heap* h = env.heap;
    int existing = env.bindings.find_prop_idx(key, h);
    if (is_eval_code && existing < 0) {
        h.invalidate_var_ic_entries();
    }
    // An existing binding stays untouched: CreateGlobalVarBinding steps 4-5
    // for the global object, and an initializer-less eval-code `var` is a
    // redundant re-stub (ECMA-262 EvalDeclarationInstantiation). is_bare marks
    // exactly those stubs; DECLVAR (a per-iteration write, e.g. a for-of head)
    // must keep writing even when the binding exists.
    if (is_bare && existing >= 0 && (is_global || is_eval_code)) {
        return true;
    }
    // A binding created at call entry keeps its attributes; this opcode only
    // assigns. Re-applying WEC would make the `arguments` binding deletable and
    // drop the non-writability of any reused binding.
    hobject::PropFlags flags;
    if (existing >= 0 && !is_global) {
        flags = env.bindings.get_prop_flags((uint)existing, h);
    } else {
        // Configurability follows who created the binding. An eval-code `var`
        // is configurable (ECMA-262 EvalDeclarationInstantiation); an ordinary
        // function-scope or Script `var` is not (Annex B.3.2). A sloppy direct
        // eval shares its caller's var_env, so is_eval_code is what separates
        // them. Making a function's own `var` configurable let
        // `eval("delete x")` delete a live binding.
        flags = is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE;
    }
    return env.bindings.put_prop(key, val, flags, h);
}

// ECMA-262 CanDeclareGlobalFunction (https://tc39.es/ecma262/#sec-candeclareglobalfunction).
// True when the global binding is absent, configurable or a writable data
// property. Non-configurable, non-writable built-ins (`NaN`, `Infinity`,
// `undefined`) fail the throw in EvalDeclarationInstantiation.
fn bool env_can_declare_global_func(EnvRecord* env, void* key) @inline {
    Heap* h = env.heap;
    int idx = env.bindings.find_prop_idx(key, h);
    if (idx < 0) { return true; }
    hobject::PropFlags existing = env.bindings.get_prop_flags((uint)idx, h);
    if (existing.configurable) { return true; }
    if (!existing.is_accessor && existing.writable) { return true; }
    return false;
}

// Instantiates a top-level FunctionDeclaration binding (ECMA-262
// CreateGlobalFunctionBinding, https://tc39.es/ecma262/#sec-createglobalfunctionbinding).
//
// A FunctionDeclaration inside a function body is non-deletable in strict and
// sloppy code (ECMA-262 FunctionDeclarationInstantiation), so sloppy `delete f`
// returns false. Eval-created bindings are configurable (ECMA-262
// EvalDeclarationInstantiation), so `delete f` removes them. `is_eval_code`
// (FuncFlags.is_eval, passed by the opcode handler) selects between the two.
fn bool env_declare_global_func(EnvRecord* env, void* key, TVal val, bool is_global, bool is_eval_code) @inline {
    Heap* h = env.heap;
    int idx = env.bindings.find_prop_idx(key, h);
    if (is_eval_code && idx < 0) {
        h.invalidate_var_ic_entries();
    }
    if (!is_global) {
        hobject::PropFlags flags = is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE;
        return env.bindings.put_prop(key, val, flags, h);
    }
    hobject::PropFlags flags = is_eval_code ? hobject::PROP_FLAGS_WEC : hobject::PROP_FLAGS_WE;
    if (idx >= 0) {
        hobject::PropFlags existing = env.bindings.get_prop_flags((uint)idx, h);
        if (!existing.configurable) { flags = existing; }
    }
    return env.bindings.put_prop(key, val, flags, h);
}

// Declares a built-in global property ({ W: true, E: false, C: true }).
fn bool env_declare_nonenum(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WC, env.heap);
}

// Declares an immutable global constant: undefined, NaN, Infinity (ECMA-262 value
// properties of the global object).
// The immut_nonstrict bit gives these ordinary-property semantics on
// assignment: sloppy code silently drops the write, strict throws TypeError.
fn bool env_declare_immutable(EnvRecord* env, void* key, TVal val) @inline {
    hobject::PropFlags flags = hobject::PROP_FLAGS_NNC;
    flags.immut_nonstrict = true;
    return env.bindings.put_prop(key, val, flags, env.heap);
}

// Declares an accessor binding for live module imports (accessor_value holds a
// boxed getter/setter pair).
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

// Declares a lexical binding in `lex_env` without walking parent scopes. The
// binding is non-deletable (CreateMutableBinding(N, false)), so `delete` on a
// let/const/catch binding returns false (ECMA-262 DeleteBinding for Declarative
// Environment Records).
fn bool env_declare_lex(EnvRecord* lex_env, void* key, TVal val) @inline {
    return lex_env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WE, lex_env.heap);
}

fn bool env_has_lex(EnvRecord* lex_env, void* key) @inline {
    Heap* h = lex_env.heap;
    EnvRecord* cur = lex_env;
    while (cur != null) {
        bool found = cur.is_with()
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
        return cur.bindings.prop_values()[idx].get();
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

// Stores `val` in the nearest existing lexical binding for `key`. Returns:
//   1   success
//   0   unbound; the caller falls back to the var environment
//  -1   assignment to a const binding
//  -2   TDZ access (only when check_tdz is set)
//  -3   a @@unscopables getter deleted the with-object binding
//  -4   non-strict-immutable binding (a named function expression's own name)
// For -1 and -4 the caller decides by the assigning code's strictness whether
// to throw or drop the write (ECMA-262 SetMutableBinding for Declarative
// Environment Records).
//
// A `with` record checks the prototype chain and writes through put_prop, which
// handles refcounting. Writability and TDZ do not apply to with objects.
//
// After an observable @@unscopables getter, HasProperty is re-checked (ECMA-262
// SetMutableBinding for Object Environment Records). A binding deleted by the
// getter must not fall through to a parent. The caller (PUTVAR_ASSIGN) tells
// this apart from "never on the with-env" using the RESOLVEVAR probe's stored
// env pointer. PUTVAR (sloppy `var x = ...`) treats -3 as fall-through because
// it has no with-env context.
fn int env_try_put_lex(EnvRecord* lex_env, void* key, TVal val, bool check_tdz) {
    Heap* h = lex_env.heap;
    EnvRecord* cur = lex_env;
    while (cur != null) {
        if (cur.is_with()) {
            bool first_has = cur.bindings.has_prop_proto(key, h);
            if (h.has_error) return 0;
            if (!first_has) {
                // Never on this with-env: continue to the parent, which may declare it.
                cur = cur.parent;
                continue;
            }
            // @@unscopables hides the binding from this with-env but leaves it
            // on the object, so continue to the parent.
            if (!with_unscopables_blocks(h, cur, key)) {
                // The getter may have deleted the binding. Re-check HasProperty
                // and return -3 if it is gone, so the caller can tell that from
                // "not on this env" (test262
                // set-mutable-binding-binding-deleted-in-get-unscopables-strict-mode.js).
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
            hobject::PropValue* pv = &cur.bindings.prop_values()[idx];
            TVal current = pv.get();
            if (check_tdz && is_tdz_sentinel(&current)) {
                return -2;
            }
            if (!cur.bindings.get_prop_flags((uint)idx, h).writable) {
                // -1 is a const binding, which throws in sloppy code too. A
                // non-writable property of the global object is an ordinary
                // [[Set]] failure (ECMA-262 SetMutableBinding for Global
                // Environment Records), so only strict code throws. -4 carries
                // that rule.
                if (!cur.flags.is_declarative) return -4;
                return cur.bindings.get_prop_flags((uint)idx, h).immut_nonstrict ? -4 : -1;
            }
            TVal old = pv.get();
            if (old.is_string() || old.is_bigint()) { pv.release_ref(h); }
            h.store_slot(cur.bindings, pv, val);
            if (val.is_string() || val.is_bigint()) { void* p = val.get_heapptr(); if (p != null) ((types::HeapHeader*)p).incref(); }
            return 1;
        }
        cur = cur.parent;
    }
    return 0;
}

macro bool EnvRecord.is_with(self) {
    return !features::STRICT_ONLY && self.flags.is_with;
}
