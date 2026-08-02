module duktape::heap;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::bytecode;
import duktape::re_bindings;
import duktape::esm;
import std::io;
import std::core::mem::mempool;
import std::core::mem::allocators;

// ============================================================================
// Heap management: allocator, GC bookkeeping, string table
// ============================================================================

// --- Allocator callback signatures ---

alias AllocFunc   = fn void*(void* udata, usz size);
alias ReallocFunc = fn void*(void* udata, void* ptr, usz size);
alias FreeFunc    = fn void(void* udata, void* ptr);
alias FatalFunc   = fn void(void* udata, char* msg);

/// Calls a JS handler function from a builtin, passing one argument.
/// The VM pointer is opaque here to keep heap independent of the vm module.
alias VmCallHandlerFn = fn TVal(void* vm, TVal handler, TVal* arg);
/// Marks activation-record env bindings during the GC mark phase.
alias MarkActivationsFn = fn void(void* vm, void* heap);

/// Walks a Catcher chain head, which the heap holds only as an opaque `void*`
/// (Catcher lives in the vm module, which depends on this one). A suspended
/// generator's chain needs marking during GC and freeing at teardown, and the
/// heap can do neither without knowing the layout. Set by vm_create.
alias CatcherChainFn = fn void(void* heap, void* cat_head, int mode);

/// Mark the chain's values for the GC and leave the chain intact.
const int CATCHER_CHAIN_MARK             = 0;
/// Release the owned values and free every node.
const int CATCHER_CHAIN_FREE             = 1;
/// Free every node without releasing what it points at, for heap teardown,
/// where the referents are already gone.
const int CATCHER_CHAIN_FREE_NODES_ONLY  = 2;

/// Runs after a microtask handler completes, with the handler's return value
/// and the downstream promise to resolve.
alias MicrotaskAfterFn = fn void(void* heap, void* vm, TVal result, TVal downstream);

/// Calls a JS function with an argument array and an explicit `this`.
alias VmCallFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal this_val);

/// Invokes a JS function as a constructor and returns the resulting `this`.
/// `new_target` is the value seen as `new.target` inside the constructor,
/// which is the subclass for super() calls.
alias VmConstructFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal new_target);

/// Proxy MOP bridges, set by vm_create. They let the hobject prototype-chain
/// walkers route through Proxy traps without depending on the builtins layer.
/// On error the callee sets heap.has_error/error_value and returns false.
alias ProxyGetFn = fn bool(void* vm, void* heap, void* proxy, void* key, TVal receiver, TVal* out);
alias ProxyHasFn = fn bool(void* vm, void* heap, void* proxy, void* key, bool* out);

// --- Faults ---

faultdef HEAP_ALLOC_FAULT;

// --- Constants ---

const uint  INITIAL_STR_TABLE_SIZE  = 256;
const float STR_TABLE_LOAD_FACTOR   = 0.70;
const long  GC_INITIAL_TRIGGER      = 1;
const long  GC_TRIGGER_GROW_FACTOR  = 1;
const uint  MEGA_CACHE_SIZE         = 512;
/// Initial capacity for the gray object stack, which grows as needed.
const uint  GRAY_STACK_INITIAL_CAP  = 64;
/// Initial capacity for Array.prototype.join's in-progress set, allocated on
/// first use (most programs never nest a join) and grown as needed.
const uint  JOIN_VISITED_INITIAL_CAP = 16;
const usz   STRS_CACHE_SIZE         = 256;
const uint  GC_MAX_ROOTS            = 64;

/// Marks an embedder-owned root set that is not an HObject. Called during
/// mark_roots with the pointer stored in Heap.capi_roots.
alias CapiMarkFn = fn void(void*);
/// How many backward jumps between GC checks. Spacing them out stops loops
/// from thrashing the collector.
const uint  BWD_GC_INTERVAL        = 1024;
/// Strings longer than this are never interned. They are very rarely property
/// keys, and interned copies pile up in the table until the next GC, which
/// gives O(n^2) memory growth in loops like `s += chunk`.
const uint  MAX_INTERN_BYTES        = 256;

// Lightfunc deleted-property bitset sizing.
// Each builtin index occupies 3 bits: name, length, and prototype deleted flags.
const uint LF_DELETED_WORDS   = 32;                          // ulong words in lf_deleted_props
const uint LF_MAX_TRACKED     = (LF_DELETED_WORDS * 64) / 3; // 682, the highest trackable builtin index
/// Sentinel marking a deleted string table entry, so open addressing can probe past it.
const HString* STR_TABLE_TOMBSTONE = (HString*)1;

// --- LongjmpState ---

enum LjType : char {
    UNKNOWN,
    THROW,
    YIELD,
    RESUME,
    BREAK,
    CONTINUE,
    RETURN,
    NORMAL,
}

struct LongjmpState {
    LjType   lj_type;
    TVal     value1;
    TVal     value2;
    bool     iserror;
}

// --- GeneratorState (ES6 §25.3) ---

/// Generator execution state, per ES6 §25.3.3.1 GeneratorState.
enum GeneratorStateType : char {
    GEN_SUSPENDED_START,
    GEN_SUSPENDED_YIELD,
    GEN_EXECUTING,
    GEN_COMPLETED,
    /// Async generators only (ES2018 §27.6). The generator is working through
    /// the §27.6.3.7 await-return steps for a `.return()` request, and holds
    /// off draining further requests until that settles.
    GEN_AWAITING_RETURN,
}

/// One entry in an async generator's request queue (ES2018 §27.6.3.1
/// AsyncGeneratorRequest). Concurrent next/return/throw calls each push a
/// request and get their own promise. The queue drains FIFO.
struct AsyncGenRequest {
    ResumeKind        completion_kind; // NEXT, RETURN, or THROW
    TVal              value;           // completion value, or the thrown value
    void*             capability;      // HObject* of the promise to settle, opaque to avoid a module cycle
    AsyncGenRequest*  next;            // FIFO link; null at the tail
}

/// How a generator was resumed, which tells the YIELD opcode what to do when
/// execution reaches a yield point.
enum ResumeKind : char {
    NEXT,     /// .next(): yield returns an IteratorResult as usual
    THROW,    /// .throw(): inject an exception at the yield point
    RETURN,   /// .return(): inject a return at the yield point
}

/// How an async-generator body last suspended. The AWAIT and YIELD opcodes
/// record this so async_gen_drain knows what to do with the value coming back
/// from the body. YIELD and RETURN settle the current request. AWAIT means the
/// body suspended on an internal `await`, so a microtask re-drives it and the
/// current request's promise stays untouched.
enum GenSuspendKind : char {
    AG_SUSPEND_NONE,   /// idle, or this is not an async-gen resume
    AG_SUSPEND_AWAIT,  /// body suspended at an internal `await`, invisible to the caller
    AG_SUSPEND_YIELD,  /// body reached a `yield`, so settle the current request with {v, false}
}

// ============================================================================
// For-in enumeration state
// ============================================================================

/// Runtime state for a for-in loop iteration.  Created by INITFOR.
///
/// OWNERSHIP: the state is owned by the *activation that created it*, via the
/// intrusive `parent` chain rooted at `Activation.forin`, exactly like the
/// Catcher chain hanging off `Activation.cat`. The `iter_state` register that
/// INITFOR writes holds a BORROWED pointer, read by NEXTFOR to advance the
/// enumeration; it is never the owner.
///
/// The register cannot be the owner because a for-in has many abrupt exits
/// (break, labeled break, return, throw, labeled continue to an outer loop)
/// and the compiler frees the register after the loop, so a state left behind
/// by an early exit becomes unreachable. Making the *frame* the owner means
/// no exit edge has to remember anything: every one of them either re-runs
/// INITFOR (which releases the state its own output register still names) or
/// pops the activation (which drains the whole chain). See free_forin_chain.
///
/// `keys` holds a flat array of interned HString* pointers collected from
/// the object and its prototype chain (omitting duplicates). The array and
/// the struct itself are plain-malloc'd; forin_state_free releases both.
///
/// `target` is the original for-in target (a borrowed pointer to the
/// heap-allocated HObject). It is temproot-pinned for the lifetime of the
/// enumeration so the target stays reachable even when the loop body
/// doesn't reference it, and so NEXTFOR can re-check property existence
/// at yield time per EnumerateObjectProperties, so a property deleted from
/// the target before its turn is skipped (plan 062 group N).
///
/// `keys` holds raw HString* with no incref of its own, and NEXTFOR
/// dereferences them long after collection. Two things could root them, and
/// only one actually does:
///
///  - Interning does NOT. sweep_strings frees any table entry whose refcount is
///    1 and which the mark phase did not reach, so the string table is a weak
///    reference. "The keys are interned" is not a lifetime argument.
///  - The target's property table DOES, for an ordinary object: the pin keeps
///    the target alive, the target's live property keys are marked through it,
///    and every key in the snapshot came from some level of that prototype
///    chain. This is the real guarantee.
///
/// The second argument does not cover a Proxy, whose keys are virtual: they
/// exist only as [[OwnPropertyKeys]] trap results and appear in no property
/// table anywhere. What covers them instead is that they are still referenced
/// by the trap's own result array while it is being partitioned, and
/// proxy_partitioned_own_keys holds a native frame across that whole window, so
/// no safepoint inside a [[GetOwnProperty]] trap can clear the array's pin. By
/// the time the snapshot is handed to the enumeration the keys are ordinary
/// interned strings whose refcount the surrounding JS values hold above the
/// sweep threshold; instrumenting the minimum refcount seen at every snapshot
/// across the proxy and for-in corpus of test262 gave 5, against a sweep
/// threshold of 1, with zero observations at or below 2.
///
/// Marking `keys` here would make that a proof rather than a measurement, but
/// it is not free: the snapshot is walked on every GC for every live
/// enumeration, and the strings are already reachable by the argument above.
/// If a future exotic key source can produce a key that neither a property
/// table nor a live trap result references, mark the array instead of
/// extending this comment.
struct ForInState {
    HString** keys;      /// Array of interned property-name HString* pointers
    HObject* target;     /// Borrowed pointer to the for-in target (NOT owned)
    ForInState* parent;  /// Next state on the owning activation's chain
    uint count;          /// Number of keys in the array
    uint index;          /// Current position (next key to return)
}

/// Saved execution context for a generator.
///
/// Calling a generator function saves the initial execution state here and
/// returns a generator object. Later calls to .next(), .throw(), or .return()
/// resume the body from this state.
struct GeneratorState {
    GeneratorStateType state;
    void* func;               // CompiledFunction*, opaque to avoid a circular dependency
    void* func_obj;           // HObject* of the generator function itself, opaque.
                              // Read at GEN_START, after param-init, to resolve the
                              // instance's [[Prototype]] per ES2015 §25.3.3. A default
                              // parameter's side effect can mutate functionObject.prototype
                              // right up to that point, so the read has to happen late.
    void* gen_obj;            // HObject* of the generator instance this state backs, opaque.
                              // The instance owns the state, so the state cannot mark it as
                              // a child. This back-pointer roots the instance while it has
                              // in-flight async work. See Heap.mark_roots.
    TVal* saved_regs;         // malloc'd array of register values
    uint num_regs;
    void* saved_pc;           // Instruction* (opaque)
    void* var_env;            // EnvRecord* (opaque)
    void* lex_env;            // EnvRecord* (opaque)
    void* cat;                // Catcher* chain head, opaque; saved across yields
    /// ForInState* chain head, opaque and saved across yields exactly like
    /// `cat`. A generator can suspend in the middle of a for-in, and the
    /// suspend pops the activation, so ownership of the frame's live for-in
    /// states moves here. Otherwise the pop would free states that saved_regs
    /// still points at, and resuming would read freed memory. Resume moves them
    /// back, and gs_release frees them if the generator never resumes.
    void* forin;
    TVal this_binding;
    TVal resume_value;        // value passed by .next()
    ResumeKind resume_kind;   // how the generator was resumed
    TVal throw_value;         // exception to inject (when resume_kind == THROW)
    TVal return_value;        // value to return (when resume_kind == RETURN)
    // yield* delegation state
    void* delegated_iter;     // HObject* of the iterator being delegated to
    // Async yield* delegation sub-state (ES2018 §14.4.14 and §27.6.3.8). The
    // YIELD_STAR_ASYNC opcode is a resumable state machine: every spec Await is a
    // real suspension that re-enters the same opcode, so the delegation's program
    // counter lives here. See AsyncYieldStarStep in vm_generators.c3.
    // AYS_INACTIVE (0) means no async yield* is in progress on this gs.
    uint ays_step;
    TVal ays_received;        // value to forward into the next inner call
    TVal ays_next_method;     // cached delegate [[NextMethod]]. §14.4.14 GetIterator reads
                              // iterator.next once, and every iteration reuses it.
    // async state
    void* async_promise;      // HObject* of the async function's outer Promise; null for generators
    // Async-generator state (ES2018 §27.6). True for `async function*` bodies.
    // The request queue holds pending next/return/throw calls and drains FIFO.
    bool  is_async_gen;
    AsyncGenRequest* agr_head; // FIFO queue head (current in-flight request)
    AsyncGenRequest* agr_tail; // FIFO queue tail
    // The promise of the request being serviced right now, dequeued from
    // agr_head when the resume starts. This is a GC root only: the settle
    // allocates an IteratorResult and triggers reactions, so the promise must
    // stay marked all the way through that. It cannot double as the
    // re-entrancy guard, which has to be released *before* the settle.
    void* ag_root_promise;     // HObject* of the promise the in-flight request settles
    // The in-flight request's completion value. It lives here, rather than only
    // in the caller's copy of the dequeued struct, so the mark phase can see it
    // for as long as the request is being serviced.
    TVal ag_current_value;
    // True while a body resume is outstanding: the body suspended on an
    // internal await, or a `.return()` value is being awaited. This is the
    // re-entrancy guard only, so async_gen_drain refuses to start a second
    // request. It is cleared before a settle runs its reactions, since a
    // reaction may legitimately queue and drain a new request.
    bool ag_body_in_flight;
    // Cached callable wrapper that re-enters this suspended body (see
    // builtins::async_resume_wrapper). Resuming drops native_frame_depth to 0,
    // re-enabling temproot clearing, so a bare local would be swept mid-call.
    // Held here, it is a real root that mark_generator_state marks.
    void* resume_wrapper;     // HObject*, opaque
    // How the async-gen body last suspended (ES2018 §27.6). AWAIT means the body
    // suspended on an internal await, so the drain leaves the current request
    // alone and a microtask resume re-drives it. YIELD, RETURN, and THROW settle it.
    GenSuspendKind ag_suspend_kind;
    // Yield-through state. When a yield fires inside a non-generator inner
    // function, such as a default expression thunk, the resume value goes into a
    // specific register of the generator's frame. 0xFFFF means unused.
    uint pending_resume_reg;
    /// How many HObjects currently hold this GeneratorState: the generator
    /// instance, plus every `is_async_state` reaction closure that parks the
    /// pointer in func.var_env. Maintained by gs_acquire and gs_release.
    uint ref_count;
}

/// Register one more HObject holder of `gs`. Every store of a GeneratorState*
/// into an HObject (gen.generator_data or an is_async_state func.var_env) must
/// be paired with this, and with a gs_release when that HObject is torn down.
fn void gs_acquire(GeneratorState* gs) {
    if (gs != null) { gs.ref_count++; }
}

/// Drop one HObject's hold on `gs`, freeing the state and its saved registers
/// once the last holder is gone.
///
/// The count is the only ownership signal. Sweep tears down every dying node in
/// one pass, so deciding ownership by reading a gs field would race siblings in
/// that same pass: the first free recycles the struct, and the next holder reads
/// whatever landed there.
///
/// `heap_ptr` is always required, including during full-heap teardown, which
/// clears the `_active_heap` global but still frees through the heap's own
/// allocator. With an embedder allocator, freeing to libc instead would be a
/// cross-allocator free.
///
/// `run_decref` is false during teardown, where the heap is already coming apart.
fn void gs_release(GeneratorState* gs, void* heap_ptr, bool run_decref) {
    if (gs == null) { return; }
    if (gs.ref_count > 0) { gs.ref_count--; }
    if (gs.ref_count != 0) { return; }
    if (heap_ptr == null) {
        // No heap at all (defensive): nothing sensible to free through.
        return;
    }
    Heap* h = (Heap*)heap_ptr;
    // `saved_regs` and `this_binding` are the only fields holding an owned
    // (incref'd) reference; every other field is transient or borrowed, and is
    // cleared or superseded before teardown.
    if (run_decref) {
        if (gs.saved_regs != null) {
            for (uint i = 0; i < gs.num_regs; i++) {
                h.decref_tval(&gs.saved_regs[i]);
            }
        }
        h.decref_tval(&gs.this_binding);
    }
    if (gs.saved_regs != null) { h.free_func(h.heap_udata, gs.saved_regs); }
    // A generator abandoned mid-for-in (never resumed to exhaustion, then
    // collected) still owns the states its body was enumerating, which were
    // MOVED here when the body suspended. Nothing else can reach them now, so
    // this is their last chance to be freed. In teardown mode the target
    // HObjects are already gone, so the pin must not be touched through them.
    ForInState* fi = (ForInState*)gs.forin;
    while (fi != null) {
        ForInState* fi_parent = fi.parent;
        if (run_decref && fi.target != null) { ((HeapHeader*)fi.target).clear_temproot(); }
        if (fi.keys != null) { h.free_func(h.heap_udata, fi.keys); }
        h.free_func(h.heap_udata, fi);
        fi = fi_parent;
    }
    gs.forin = null;
    // Same last-chance reasoning for the catcher chain: a generator abandoned
    // while suspended inside a try (`var it = g(); it.next();` and no more) has
    // no activation left to run a frame pop, so nothing else will ever free the
    // Catchers its body allocated, nor the exception a parked finally still
    // holds in thrown_val. gs.cat is only non-null while the body is suspended
    // (chains_restore_from_gen clears it on resume, handing ownership back to
    // the activation), so this cannot double-free a chain a pop already took.
    // In teardown mode (run_decref false) the thrown_val targets are already
    // gone, exactly as for the for-in targets above, so the nodes are freed
    // without releasing what they point at.
    if (gs.cat != null && h.catcher_chain_fn != null) {
        h.catcher_chain_fn(h, gs.cat, run_decref ? CATCHER_CHAIN_FREE : CATCHER_CHAIN_FREE_NODES_ONLY);
    }
    gs.cat = null;
    h.free_func(h.heap_udata, gs);
}

/// One parked Atomics.waitAsync waiter. `byte_index` is an absolute offset into
/// `buffer`, and Atomics.notify resolves `promise` with "ok".
struct AtomicsWaiter {
    hobject::HObject* buffer;
    hobject::HObject* promise;
    uint              byte_index;
    bool              active;
}

/// One registered host function.
///
/// `handler` is the host trampoline; it is called with the BuiltinContext the
/// VM already staged, so no argument copying happens at the boundary itself.
/// `udata` is opaque and passed through untouched. `name` is an interned
/// HString backing Function.prototype.name, and `arity` backs .length.
struct HostFnEntry {
    void* handler;
    void* udata;
    void* name;          // HString*, interned
    int   arity;
    bool  constructable;
}

/// One host-call scope: the values a single host callback can address.
///
/// `values` is a real JS Array allocated through alloc_object, so it carries a
/// temproot flag and its elements are marked transitively. That is what keeps
/// arguments alive without spending one of the 64 GC_MAX_ROOTS entries, and
/// without referencing ctx.regs — a nested jse_call can realloc the valstack
/// and leave a register pointer dangling (see vm_calls.c3:1331).
///
/// `generation` is bumped every time a scope is popped, so a handle used after
/// its callback returned fails the check and reads no freed memory.
struct HostScope {
    hobject::HObject* values;
    uint              generation;
}

// --- Heap struct ---

struct Heap {
    // Allocator callbacks
    AllocFunc    alloc_func;
    ReallocFunc  realloc_func;
    FreeFunc     free_func;
    void*        heap_udata;
    FatalFunc    fatal_func;

    // Flags
    uint flags;

    // Object lists (doubly-linked via HeapHeader.next/.prev)
    HeapHeader*  heap_allocated;
    HeapHeader*  finalize_list;

    // String interning table (open-addressing)
    HString**    str_table;
    uint         str_table_size;
    uint         str_table_used;

    // Registry of strings over MAX_INTERN_BYTES, which are absent from str_table
    // and so invisible to the table sweep and to reset(). Each is appended at
    // allocation and removed at free. Entries store their own slot index in
    // HString.hash, unused for non-interned strings, so removal is an O(1) swap
    // with the last element.
    HString**    large_strings;
    uint         large_string_count;
    uint         large_string_capacity;

    // Built-in strings cache (indexed by string constant IDs)
    void*[STRS_CACHE_SIZE]  strs;

    // GC state
    long  gc_trigger_counter;
    bool  gc_pending;            /// Deferred GC requested by alloc/realloc
    uint  bwd_gc_budget;         /// Countdown to the next backward-jump GC safepoint
    /// Nesting depth of native builtin frames on the C3 stack. Non-zero means a
    /// builtin may hold a fresh object in a raw local that no GC root can see,
    /// so temproot flags must survive a safepoint collection. See mark_and_sweep.
    uint  native_frame_depth;
    uint  live_obj_count;
    uint  peak_live_obj_count;   /// High-water mark for live objects

    /// Host function registry. A host function is an ordinary FUNCTION object
    /// whose builtin_fn_index is HOST_FN_BASE + slot, so every existing call
    /// site treats it as a builtin and dispatch_builtin's out-of-range branch
    /// routes it here. See builtins::HOST_FN_BASE.
    ///
    /// Not a GC root and does not need to be: the only heap pointer stored is
    /// an interned HString for the name, which the intern table already keeps
    /// alive for the heap's lifetime. No TVal lives here, so the 64-root
    /// budget is untouched.
    HostFnEntry* host_fns;
    uint         host_fn_count;
    uint         host_fn_capacity;

    /// Stack of live host-call scopes; index host_scope_depth-1 is the
    /// innermost. Scopes nest exactly as the C3 call stack does, so a
    /// host -> JS -> host chain pushes one per level.
    HostScope* host_scopes;
    uint       host_scope_depth;
    uint       host_scope_capacity;
    /// Monotonic counter stamped into each handle. Never reset, so a handle
    /// from a popped scope can never collide with a live one.
    uint       host_scope_generation;

    // Sweeping the string table is only safe when no raw HString* pointers sit
    // in C3 locals (see mark_and_sweep phase 3b). Off by default; callers at a
    // true safe point may set it around a GC.
    bool  string_sweep_safe;

    // Gray set for the iterative mark phase. A heap array avoids C-stack
    // overflow on deep object graphs.
    void** gray_objects;
    uint   gray_count;
    uint   gray_capacity;

    // Arrays currently being rendered by Array.prototype.join, innermost last.
    // The set spans nested join calls rather than living in one invocation's
    // frame, because a cycle re-enters join through a separate call (directly,
    // or via a user toString that joins the outer array again). An array found
    // already on the stack contributes the empty string instead of recursing,
    // which is what V8 does and is the only thing standing between a cyclic
    // array and unbounded recursion. Grown on demand like gray_objects.
    void** join_visited;
    uint   join_visited_count;
    uint   join_visited_capacity;

    // Current execution thread (HThread*)
    void* curr_thread;

    // Longjmp state for error handling
    LongjmpState lj;

    // Set by the VM on an unhandled throw, cleared before each top-level call.
    // Builtins that call back into JS, such as JSON, check it after call_fn.
    bool has_error;
    TVal error_value;

    // Simple xorshift32 PRNG state
    uint rnd_state;

    // Fixed hash seed (set at heap creation, never changes)
    uint hash_seed;

    // Built-in error prototypes (for builtin constructor dispatch)
    HObject* err_proto;
    HObject* type_err_proto;
    HObject* range_err_proto;
    HObject* ref_err_proto;
    HObject* syntax_err_proto;
    HObject* eval_err_proto;
    HObject* uri_err_proto;
    HObject* aggregate_err_proto;

    // Object.prototype.__proto__ accessors. register_object_constructor creates
    // them before Function.prototype exists, then register_function_constructor
    // back-patches their [[Prototype]] once `function_proto` is allocated, so
    // they can resolve Function.prototype.apply, .call, .bind and .toString.
    HObject* object_proto___proto___getter;
    HObject* object_proto___proto___setter;

    // Built-in constructor prototypes
    HObject* object_proto;
    HObject* bool_proto;
    HObject* string_proto;
    HObject* number_proto;
    HObject* array_proto;
    HObject* function_proto;
    HObject* date_proto;
    HObject* regexp_proto;
    HObject* map_proto;
    HObject* set_proto;
    HObject* weakmap_proto;
    HObject* weakset_proto;
    HObject* weakref_proto;
    HObject* finalization_registry_proto;
    HObject* symbol_proto;
    HObject* bigint_proto;
    HObject* promise_proto;
    /// Promise constructor, cached lazily and rooted through this field.
    HObject* promise_ctor;
    /// %Function% (ES2015 §19.2.2). Kept so the later GeneratorFunction,
    /// AsyncFunction, and AsyncGeneratorFunction passes can point their
    /// [[Prototype]] at it, since the spec makes those subclasses of Function.
    HObject* function_ctor;
    HObject* generator_proto;
    HObject* generator_func_proto; // GeneratorFunction.prototype (ES6 §25.2.3)
    HObject* async_func_proto;     // AsyncFunction.prototype (ES2017 §25.7.3)
    HObject* iterator_proto;   // %IteratorPrototype% (ES6 §25.1.2)
    HObject* iterator_ctor;    // %Iterator% constructor (ES2025 §27.1.3.1), for Iterator.from's OrdinaryHasInstance check
    HObject* iterator_helper_proto; // %IteratorHelperPrototype% (ES2025 §27.1.2.1)
    HObject* wrap_for_valid_iterator_proto; // %WrapForValidIteratorPrototype% (ES2025 §27.1.3.2.2.1)
    HObject* async_from_sync_iter_proto; // %AsyncFromSyncIteratorPrototype% (ES2018 §27.1.4)
    HObject* async_iterator_proto;       // %AsyncIteratorPrototype% (ES2018 §27.1.3), has @@asyncIterator
    HObject* async_generator_proto;      // %AsyncGeneratorPrototype% (ES2018 §27.6.1), next/return/throw
    HObject* async_generator_func_proto; // %AsyncGeneratorFunction.prototype% = %AsyncGenerator% (ES2018 §27.4.3)
    HObject* array_iterator_proto; // %ArrayIteratorPrototype% (ES6 §22.1.5)
    HObject* map_iterator_proto;   // %MapIteratorPrototype% (ES6 §23.1.5)
    HObject* set_iterator_proto;   // %SetIteratorPrototype% (ES6 §23.2.5)
    HObject* string_iterator_proto; // %StringIteratorPrototype% (ES6 §22.1.5 for strings)
    HObject* regexp_string_iterator_proto; // %RegExpStringIteratorPrototype% (ES2020 §22.2.9.2)
    HObject* typedarray_proto; // Shared %TypedArray%.prototype
    HObject* typedarray_intrinsic; // %TypedArray% abstract constructor
    HObject* uint8array_proto; // %Uint8Array%.prototype (for fromBase64/fromHex result protos)
    HObject* arraybuffer_proto; // ArrayBuffer.prototype
    HObject* sharedarraybuffer_proto; // SharedArrayBuffer.prototype
    HObject* dataview_proto; // DataView.prototype

    // Generator resume state (set by .next()/.throw()/.return() builtins,
    // read by the VM CALL handler and YIELD/RET opcodes).
    GeneratorState* resume_gen;
    TVal yield_value;          /// Value yielded by YIELD opcode
    bool did_yield;            /// True when YIELD was just executed
    /// Set by AWAIT when it suspends an async-generator body on an internal
    /// await (ES2018 §27.6.3.8, §27.6.3.9). The drain then leaves the current
    /// request's promise alone and a microtask ASYNC_GEN resume re-drives the
    /// body. The drain clears this before each body resume.
    bool ag_did_await;

    // Initial generator call state. The initial-call path in vm_calls sets these
    // before eagerly running the frame, and the GEN_START handler clears them.
    // They stay non-null while a generator body runs its parameter
    // initialization, up to the first GEN_START.
    GeneratorState* gen_initial_gs;     /// GeneratorState pre-allocated for this call
    void*           gen_initial_obj;    /// HObject* of the generator object being initialized
    TVal*           gen_initial_retval; /// Where the generator object goes in the caller's frame

    // Stack for generator functions whose parameter initialization calls other
    // generator functions, such as `*outer([[,] = innerGen()])`. Each entry saves
    // the outer gen_initial_* state before an inner call overwrites it, and
    // GEN_START pops one entry per generator finishing its initial-call phase.
    GeneratorState*[8] gen_init_stack_gs;
    void*[8]           gen_init_stack_obj;
    TVal*[8]           gen_init_stack_retval;
    uint               gen_init_stack_depth;

    // Symbol.for and Symbol.keyFor registry, as two parallel arrays.
    HString** symbol_registry_keys;
    HString** symbol_registry_syms;
    uint      symbol_registry_count;
    uint      symbol_registry_cap;

    // Initial global state that __resetGlobals() restores, as parallel arrays.
    void**    checkpoint_keys;   /// HString* pointers
    TVal*     checkpoint_vals;
    uint      checkpoint_count;
    uint      checkpoint_cap;

    void*     env_freelist;     /// EnvRecord* freelist, chained through .parent
    void*     env_pool_blocks;  /// EnvPoolBlock* list, walked at cleanup

    // Every CompiledFunction the compiler allocates. Freed in Heap.destroy.
    void**    compiled_funcs;
    uint      compiled_func_cap;
    uint      compiled_func_count;

    // Registered GC roots: HeapHeader* that are always reachable.
    void*[GC_MAX_ROOTS] gc_roots;
    uint                gc_root_count;

    // The C ABI's value registry is a plain array rather than an HObject, so
    // the mark phase cannot reach it transitively. capi_mark, when set, is
    // called with capi_roots during mark_roots to mark every host-held value.
    void*               capi_roots;
    CapiMarkFn          capi_mark;

    // Valstack window the GC scans for roots. valstack_base is refreshed on VM
    // create and resize. valstack_top_ptr points at vm.valstack_top so the GC
    // reads the live value and push/pop need no synchronization.
    TVal*      valstack_base;
    TVal**     valstack_top_ptr;

    // GC re-entrancy guard
    bool                gc_running;

    // True for the duration of Heap.sweep(). The sweep loop frees every unmarked
    // object and bigint itself, so decref skips unmarked non-string targets while
    // it runs. Following a reference into a dying node from a sibling's
    // hobject_free would be a use-after-free or a double free.
    bool                sweeping;

    // VM callbacks, all set by vm_create.
    VmCallHandlerFn     call_handler_fn;
    VmCallFn            call_fn;
    VmConstructFn       construct_fn;
    /// Proxy trap bridges and the owning VM. See ProxyGetFn and ProxyHasFn.
    ProxyGetFn          proxy_get_fn;
    ProxyHasFn          proxy_has_fn;
    void*               vm_ptr;
    /// Marks activation-record env bindings during GC.
    MarkActivationsFn   mark_activations_fn;
    /// Marks or frees a suspended generator's Catcher chain. See CatcherChainFn.
    CatcherChainFn      catcher_chain_fn;

    // Well-known symbols. Each is created on first use and rooted by its field.
    HString*            iterator_symbol;
    HString*            tostringtag_symbol;
    HString*            toprimitive_symbol;
    HString*            concatspreadable_symbol;
    HString*            hasinstance_symbol;
    HString*            match_symbol;
    HString*            search_symbol;
    HString*            replace_symbol;
    HString*            split_symbol;
    HString*            species_symbol;
    HString*            unscopables_symbol;
    HString*            matchall_symbol;
    HString*            asynciterator_symbol;

    /// Resolves downstream promises once a microtask handler finishes. Set by builtins init.
    MicrotaskAfterFn    microtask_after_fn;

    // Microtask queue, filled by promise_trigger_reactions and drained after
    // each top-level script execution and after vm_call_fn_impl returns. Every
    // entry occupies 3 TVal slots: handler, arg, and the downstream promise to
    // resolve with the handler's return value, or undefined.
    TVal*     microtask_queue;
    uint      microtask_count;
    uint      microtask_capacity;
    bool      microtask_draining;  // re-entrancy guard

    // Parked Atomics.waitAsync waiters. Each holds a pending Promise against a
    // SharedArrayBuffer and byte index, and Atomics.notify resolves matching
    // waiters with "ok" in FIFO order. Active waiters act as GC roots.
    AtomicsWaiter[64] async_waiters;
    uint      async_waiter_count;

    // Shapes (hidden classes) backing the inline caches.
    hobject::Shape**    shapes;    // each element points to one shape allocation
    uint                shape_count;
    uint                shape_capacity;
    // Counts how many times a shape id has been handed back out for reuse.
    // A variable inline cache stores the value it saw and compares it instead
    // of loading the per-shape generation, which lets it skip a dependent load
    // into the shapes table on every access. Property storage growing is the
    // other reason a shape generation moves, and that one a variable cache does
    // not care about, because it addresses values by index and re-reads the
    // base pointer every time.
    uint                shape_recycle_epoch;
    // Head of the reclaimed-slot list, or SHAPE_NONE when empty. Only private
    // shapes are ever freed, so a slot on this list has no live referent. The
    // link is threaded through the shapes array itself: a free slot holds
    // (next_free + 1) cast to a pointer, which is never a valid shape address.
    uint                shape_free_head;
    // Generation the next shape stored in the just-allocated slot must start
    // at, so a recycled id never re-presents an (id, generation) pair that a
    // live inline cache still matches. Set by alloc_shape_slot.
    uint                shape_reuse_gen;

    // Set for the duration of destroy() and reset(), which free every object
    // directly instead of refcounting them down. Object teardown reads it to
    // skip its decref loop: releasing references while the sweep runs would
    // corrupt the string table it is walking, and every node is about to be
    // freed regardless.
    //
    // This is state about the heap, so it lives on the heap. It used to be
    // inferred from the process-global active-heap pointer being null, which
    // conflated "we are tearing down" with "there is no heap to allocate from"
    // and left teardown behaviour depending on a global that a second runtime
    // would overwrite.
    bool                tearing_down;

    // Maps (parent_shape_id, key_pointer) to child_shape_id, so objects that add
    // properties in the same order share one Shape.
    TransitionEntry*    trans_table;
    uint                trans_mask;   // the table holds mask+1 entries
    uint                trans_count;

    // Megamorphic property cache mapping (shape_id, key) to (proto, prop_idx,
    // value), shared by all call sites to skip repeated prototype-chain walks.
    // A lossy single-slot hash table: a collision evicts the old entry. It is
    // allocated separately to keep the hot Heap struct small.
    hobject::MegamorphicEntry* mega_cache;

    // Pinned HString* for the integer keys 0 to 255, filled in on first use.
    // Pinning (HeapHeader.set_pinned) keeps them alive through RC and GC sweep
    // and makes incref and decref no-ops.
    HString*[256] small_int_strs;

    // Which lightfunc virtual properties have been deleted. Three bits per
    // builtin index at fn_idx * 3 + prop_bit: 0 name, 1 length, 2 prototype.
    ulong[LF_DELETED_WORDS] lf_deleted_props;

    // Pooled HObject headers, avoiding a malloc per object. The three size
    // classes match alloc_size_for_class():
    //   plain: OBJECT and ARGUMENTS, which need no HObjectExtra
    //   array: ARRAY, whose array_length lives in the union
    //   func:  everything else, including ERROR and PROXY
    mempool::FixedBlockPool obj_pool_plain;
    mempool::FixedBlockPool obj_pool_array;
    mempool::FixedBlockPool obj_pool_func;

    // Module cache and host hooks.
    void*       module_cache;       // growable ModuleDef** array
    uint        module_cache_count;
    uint        module_cache_cap;
    void*       module_hooks;       // ModuleHostHooks*, the pluggable host callbacks
    // Module whose body is currently executing, empty outside a module
    // evaluation. Relative dynamic-import specifiers resolve against it when the
    // importing function has no filename of its own.
    char[]      current_module_name;
}

// ============================================================================
// Built-in string cache, pre-interned at heap creation
// ============================================================================

/// Indices into Heap.strs[] for frequently-used interned strings.
/// Eliminates repeated hash+lookup for these strings on every property
/// access, typeof, and error path.
enum BuiltinStr : uint {
    UNDEFINED,   // "undefined"
    OBJECT,      // "object"
    BOOLEAN,     // "boolean"
    NUMBER,      // "number"
    STRING,      // "string"
    FUNCTION,    // "function"
    TRUE,        // "true"
    FALSE,       // "false"
    NULL_STR,    // "null"
    MESSAGE,     // "message"
    PROTOTYPE,   // "prototype"
    CONSTRUCTOR, // "constructor"
    LENGTH,      // "length"
    VALUE,       // "value"
    DONE,        // "done"
    ARGUMENTS,   // "arguments"
    SYMBOL,      // "symbol"
    NAME,        // "name"
    EMPTY,       // ""
    NAN_STR,     // "NaN"
    POSITIVE_INFINITY, // "Infinity"
    NEGATIVE_INFINITY, // "-Infinity"
    TO_STRING,   // "toString"
    VALUE_OF,    // "valueOf"
    OBJECT_OBJECT, // "[object Object]"
    FUNCTION_STR,  // "[function]"
    STACK,         // "stack"
    CALLEE,        // "callee"
    BIGINT,        // "bigint"
}

// ============================================================================
// Default allocator functions
// ============================================================================
//
// heap::create installs these when passed null callbacks. They keep the
// (void* udata, ...) function-pointer shape so embedders can supply their own
// malloc/realloc/free, and route through the C3 thread allocator `mem`, which
// defaults to the libc-backed LIBC_ALLOCATOR. The `_try ?? null` form returns
// null on OOM, which the heap's GC-retry paths rely on; bare mem::malloc panics.

fn void* default_alloc(void* udata, usz size) {
    if (size == 0) { return null; }
    return alloc::malloc_try(mem, (sz)size) ?? null;
}

fn void* default_realloc(void* udata, void* ptr, usz size) {
    if (size == 0) {
        mem::free(ptr);
        return null;
    }
    return alloc::realloc_try(mem, ptr, (sz)size) ?? null;
}

fn void default_free(void* udata, void* ptr) {
    mem::free(ptr);
}

fn void default_fatal(void* udata, char* msg) {
    io::eprintfn("DUKTAPE FATAL: %s", msg);
    abort("duktape fatal error");
}

// The FixedBlockPools draw from `allocators::LIBC_ALLOCATOR`.

// ============================================================================
// Heap creation / destruction
// ============================================================================

/**
 * Allocate and initialise a Heap.
 *
 * A null allocator callback falls back to the libc default above. Returns a
 * fault if allocation fails.
 */
fn Heap*? create(
    AllocFunc    a,
    ReallocFunc  r,
    FreeFunc     f,
    void*        udata,
    FatalFunc    fatal
) {
    // Resolve defaults
    AllocFunc   afn   = a     != null ? a     : &default_alloc;
    ReallocFunc rfn   = r     != null ? r     : &default_realloc;
    FreeFunc    ffn   = f     != null ? f     : &default_free;
    FatalFunc   fatfn = fatal != null ? fatal : &default_fatal;

    // Allocate the Heap struct itself through the chosen allocator
    void* raw = afn(udata, Heap::size);
    if (raw == null) {
        return HEAP_ALLOC_FAULT~;
    }

    Heap* h = (Heap*)raw;

    // Zero-fill the whole struct
    mem::clear(raw, (sz)(Heap::size));

    // Store allocator pointers
    h.alloc_func   = afn;
    h.realloc_func = rfn;
    h.free_func    = ffn;
    h.heap_udata   = udata;
    h.fatal_func   = fatfn;

    // GC tunables
    h.gc_trigger_counter    = GC_INITIAL_TRIGGER;
    h.gc_pending            = false;
    h.bwd_gc_budget         = BWD_GC_INTERVAL;
    h.native_frame_depth    = 0;
    h.host_fns              = null;
    h.host_fn_count         = 0;
    h.host_fn_capacity      = 0;
    h.host_scopes           = null;
    h.host_scope_depth      = 0;
    h.host_scope_capacity   = 0;
    h.host_scope_generation = 0;

    // Allocate gray object stack
    void* gray_raw = afn(udata, void*::size * GRAY_STACK_INITIAL_CAP);
    if (gray_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    h.gray_objects   = (void**)gray_raw;
    h.gray_count     = 0;
    h.gray_capacity  = GRAY_STACK_INITIAL_CAP;

    // xorshift32 requires a non-zero seed.
    h.rnd_state = 0xDEAD_BEEF;

    // Fixed for the heap's lifetime.
    h.hash_seed = h.rnd_state;

    // Allocate the initial string table
    usz tbl_bytes = HString*::size * INITIAL_STR_TABLE_SIZE;
    void* tbl_raw = afn(udata, tbl_bytes);
    if (tbl_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    mem::clear(tbl_raw, (sz)(tbl_bytes));

    h.str_table      = (HString**)tbl_raw;
    h.str_table_size = INITIAL_STR_TABLE_SIZE;
    h.str_table_used = 0;

    // Pre-intern well-known strings
    h.init_builtin_strs();

    // Initialize shape system
    h.init_shapes();

    // Allocated apart from the Heap struct to keep that struct compact.
    h.mega_cache = (hobject::MegamorphicEntry*)alloc::malloc_try(mem, (sz)(MEGA_CACHE_SIZE * hobject::MegamorphicEntry::size)) ?? null;
    if (h.mega_cache != null) {
        mem::clear(h.mega_cache, (sz)(MEGA_CACHE_SIZE * hobject::MegamorphicEntry::size));
    }

    // 16 entries of (handler, arg, downstream), so 48 TVal slots.
    h.microtask_capacity = 16;
    h.microtask_queue = (TVal*)afn(udata, TVal::size * 48);
    if (h.microtask_queue != null) {
        mem::clear(h.microtask_queue, (sz)(TVal::size * 48));
    }
    h.microtask_count = 0;
    h.microtask_draining = false;
    h.async_waiter_count = 0;

    {
        h.obj_pool_plain.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_PLAIN, 512);
        h.obj_pool_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARRAY, 512);
        h.obj_pool_func.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_FUNC, 512);
    }

    // Activate this heap for RC operations and shape transitions.
    hobject::hobject_set_active_heap((void*)h);

    return h;
}

/// Pre-intern frequently-used strings into Heap.strs[], once at heap creation.
/// Each string is allocated only if the table does not already hold it, so
/// repeat calls are harmless.
fn void Heap.init_builtin_strs(&self) {
    // Each entry: (ZString literal, byte length)
    ZString[29] literals = {
        "undefined", "object", "boolean", "number", "string", "function",
        "true", "false", "null", "message", "prototype", "constructor",
        "length", "value", "done", "arguments", "symbol", "name", "",
        "NaN", "Infinity", "-Infinity",
        "toString", "valueOf", "[object Object]", "[function]",
        "stack", "callee", "bigint"
    };
    uint[29] lengths = { 9, 6, 7, 6, 6, 8, 4, 5, 4, 7, 9, 11, 6, 5, 4, 9, 6, 4, 0, 3, 8, 9, 8, 7, 15, 10, 5, 6, 6 };
    for (uint i = 0; i < 29; i++) {
        char* ptr = (char*)literals[i];
        self.strs[i] = self.str_intern(ptr[:lengths[i]]);
    }
    // Pinning keeps these alive through refcounting and sweep, and makes every
    // incref and decref against them a no-op. See HeapHeader.set_pinned.
    for (uint i = 0; i < 29; i++) {
        if (self.strs[i] != null) {
            ((HeapHeader*)self.strs[i]).set_pinned();
        }
    }
    // Cache the "length" pointer for HObject.put_prop array_length sync.
    hobject::builtin_length_key = self.strs[BuiltinStr.LENGTH];
}

/// Convert an integer to an interned HString*. Values from 0 to 255 come from
/// the small-integer cache; anything else is formatted and interned.
///
/// As with Heap.str_intern, the result is a borrowed reference: use it directly
/// as a property key, or incref it to anchor it in a TVal or register. Cached
/// entries are pinned like the builtin strings above, so incref and decref
/// against them do nothing and they never need releasing.
fn HString* Heap.int_to_hstring(&self, long val) {
    if (val >= 0 && val <= 255) {
        usz idx = (usz)val;
        if (self.small_int_strs[idx] != null) {
            return self.small_int_strs[idx];
        }
        char[4] buf;
        int len = hstring::int_to_buf(val, &buf, 4);
        if (len <= 0) return null;
        HString* s = self.str_intern(buf[:len]);
        if (s == null) return null;
        ((HeapHeader*)s).set_pinned();
        self.small_int_strs[idx] = s;
        return s;
    }
    char[24] buf;
    int len = hstring::int_to_buf(val, &buf, 24);
    if (len <= 0) return null;
    return self.str_intern(buf[:len]);
}

// ============================================================================
// Shape (hidden class) system
// ============================================================================

const uint SHAPE_INITIAL_CAP   = 64;
/// The one value that is never a valid shape ID. It means "not a shape" in
/// every context: no parent shape, no transition found, and no slot available.
/// alloc_shape_slot() refuses to hand it out, so no live shape can equal it.
const uint SHAPE_NONE          = 0xFFFF_FFFF;
const uint SHAPE_TRANS_INITIAL = 16;   // must be a power of 2
const uint SHAPE_TRANS_LOAD    = 70;   // percent load that triggers a grow

/// Set on a shapes[] entry that is a free-list link rather than a shape
/// pointer. The top address bit is never set on a real allocation.
const uptr SHAPE_FREE_TAG      = (uptr)1 << (uptr)(uptr::size * 8 - 1);
/// A free-list link packs the next free id in the low bits and the retired
/// generation above it, so reuse can resume past the generation that inline
/// caches may still hold. Ids stop at 0xFFFE, so 16 bits cover them.
const uint SHAPE_FREE_LINK_BITS = 16;
const uint SHAPE_FREE_LINK_MASK = 0xFFFF;
const uint SHAPE_FREE_GEN_MASK  = 0x7FFF;
/// End-of-list marker inside a link. Slot ids stop at 0xFFFE, so 0xFFFF is free
/// to mean "no next".
const uint SHAPE_FREE_END       = 0xFFFF;

struct TransitionEntry {
    uint parent_id;
    void* key;
    uint shape_id;
    /// Raw PropFlags byte this transition installs. It is part of the dedup key:
    /// objects that reach the same parent and add the same key with the same
    /// flags share a shape, while differing flags need their own shape so
    /// readers see the right attributes.
    char flags;
}

fn void Heap.init_transition_table(&self) {
    self.trans_mask = SHAPE_TRANS_INITIAL - 1;
    self.trans_count = 0;
    usz bytes = (usz)SHAPE_TRANS_INITIAL * TransitionEntry::size;
    self.trans_table = (TransitionEntry*)self.alloc_func(self.heap_udata, bytes);
    mem::set(self.trans_table, 0xFF, (sz)(bytes));
}

fn uint hash_transition(uint parent_id, void* key, char flags) @inline {
    uint h = parent_id;
    h ^= (uint)((usz)key);
    h ^= (uint)flags;
    h = ((h >> 16) ^ h) * 0x45D9_F3B;
    h = ((h >> 16) ^ h) * 0x45D9_F3B;
    h = (h >> 16) ^ h;
    return h;
}

fn uint Heap.lookup_transition(&self, uint parent_id, void* key, char flags) {
    uint h = hash_transition(parent_id, key, flags);
    uint mask = self.trans_mask;
    uint slot = h & mask;
    TransitionEntry* table = self.trans_table;
    for (uint i = 0; i <= mask; i++) {
        TransitionEntry* e = &table[slot];
        if (e.parent_id == SHAPE_NONE) return SHAPE_NONE;
        if (e.parent_id == parent_id && e.key == key && e.flags == flags) return e.shape_id;
        slot = (slot + 1) & mask;
    }
    return SHAPE_NONE;
}

fn void Heap.transition_table_grow(&self) {
    uint old_mask = self.trans_mask;
    uint new_cap = (old_mask + 1) * 2;
    uint new_mask = new_cap - 1;
    usz bytes = (usz)new_cap * TransitionEntry::size;
    TransitionEntry* new_table = (TransitionEntry*)self.alloc_func(self.heap_udata, bytes);
    mem::set(new_table, 0xFF, (sz)(bytes));
    TransitionEntry* old_table = self.trans_table;
    for (uint i = 0; i <= old_mask; i++) {
        TransitionEntry* e = &old_table[i];
        if (e.parent_id == SHAPE_NONE) continue;
        uint h = hash_transition(e.parent_id, e.key, e.flags);
        uint slot = h & new_mask;
        while (new_table[slot].parent_id != SHAPE_NONE) slot = (slot + 1) & new_mask;
        new_table[slot] = *e;
    }
    self.free_func(self.heap_udata, old_table);
    self.trans_table = new_table;
    self.trans_mask = new_mask;
}

fn void Heap.insert_transition(&self, uint parent_id, void* key, char flags, uint shape_id) {
    if ((self.trans_count + 1) * 100 > (self.trans_mask + 1) * SHAPE_TRANS_LOAD) {
        self.transition_table_grow();
    }
    uint h = hash_transition(parent_id, key, flags);
    uint mask = self.trans_mask;
    uint slot = h & mask;
    TransitionEntry* table = self.trans_table;
    while (table[slot].parent_id != SHAPE_NONE) slot = (slot + 1) & mask;
    table[slot].parent_id = parent_id;
    table[slot].key = key;
    if (key != null) {
        ((HeapHeader*)key).incref();
    }
    table[slot].flags = flags;
    table[slot].shape_id = shape_id;
    self.trans_count++;
}

fn void Heap.init_shapes(&self) {
    self.shape_capacity = SHAPE_INITIAL_CAP;
    self.shape_count    = 1;  // slot 0 holds the root shape
    self.shape_recycle_epoch = 0;
    self.shape_free_head = SHAPE_FREE_END;
    usz bytes = (usz)SHAPE_INITIAL_CAP * (void*::size);
    self.shapes = (hobject::Shape**)self.alloc_func(self.heap_udata, bytes);
    mem::clear(self.shapes, (sz)(bytes));
    // Root shape: no properties, smallest hash (mask 0, so 2 slots).
    self.shapes[0] = hobject::shape_create(0, 0, SHAPE_NONE, null);
    self.init_transition_table();
}

/// Reserve a slot in the shapes array and return its ID. The caller is
/// responsible for storing the shape at shapes[id]. Returns SHAPE_NONE when no
/// slot could be reserved, in which case no slot is consumed. The array grows on
/// demand, so the only bound is what the allocator will hand out.
fn uint Heap.alloc_shape_slot(&self) {
    // Reuse a reclaimed slot before growing. Without this the pool is a pure
    // bump allocator and a delete/insert loop exhausts the id space.
    //
    // Inline caches key on (shape_id, shape.generation), so a recycled id must
    // never come back with a generation an existing cache entry still matches:
    // that entry would then read properties at the previous shape's offsets.
    // The reclaimed generation is carried in the free-list link and handed to
    // the next shape stored here, so the pair is never reused.
    if (self.shape_free_head != SHAPE_FREE_END) {
        uint id = self.shape_free_head;
        uint link = (uint)((uptr)self.shapes[id] & ~SHAPE_FREE_TAG);
        self.shape_free_head = link & SHAPE_FREE_LINK_MASK;
        self.shape_reuse_gen = (link >> SHAPE_FREE_LINK_BITS) + 1;
        self.shapes[id] = null;
        // This id is about to name a different shape, so every variable cache
        // holding it is now stale even though the id itself is unchanged.
        self.shape_recycle_epoch++;
        return id;
    }
    self.shape_reuse_gen = 0;
    // SHAPE_NONE is reserved so that no live shape ever compares equal to it.
    if (self.shape_count >= SHAPE_NONE) return SHAPE_NONE;
    if (self.shape_count >= self.shape_capacity) {
        uint new_cap = self.shape_capacity * 2;
        void* new_raw = self.realloc_func(self.heap_udata, self.shapes, (usz)new_cap * (void*::size));
        if (new_raw == null) return SHAPE_NONE;
        // Zero new slots
        usz old_bytes = (usz)self.shape_capacity * (void*::size);
        mem::clear((char*)new_raw + old_bytes, (sz)((usz)new_cap * (void*::size) - old_bytes));
        self.shapes = (hobject::Shape**)new_raw;
        self.shape_capacity = new_cap;
    }
    uint id = self.shape_count;
    self.shape_count++;
    return id;
}

/// Release a slot holding a *private* shape, freeing the shape and putting the
/// id back on the free list.
///
/// Only private shapes may be passed here. A private shape has
/// parent == PRIVATE_SHAPE_PARENT, is absent from the transition table, and is
/// referenced by exactly one object -- the one replacing it right now. Freeing
/// a transition-table shape instead would be a use-after-free, since other
/// objects and cached transitions still point at it, so that case is rejected
/// rather than trusted to the caller.
/// Store a freshly created shape in a slot just returned by alloc_shape_slot,
/// stamping the generation that keeps recycled ids from colliding with live
/// inline-cache entries.
fn void Heap.store_new_shape(&self, uint id, hobject::Shape* sh) {
    sh.generation = self.shape_reuse_gen;
    self.shapes[id] = sh;
}

/// True when shapes[id] holds a real shape rather than a free-list link.
/// Free slots store SHAPE_FREE_TAG | next_free; the tag is bit 63 (bit 31 on a
/// 32-bit host), which no live allocation carries, so teardown can skip those
/// entries instead of freeing an integer as a pointer.
fn bool Heap.shape_slot_live(&self, uint id) {
    hobject::Shape* sh = self.shapes[id];
    if (sh == null) return false;
    return ((uptr)sh & SHAPE_FREE_TAG) == 0;
}

/// `release_keys` must be false when the replacement shape copied this shape's
/// key pointers without increfing them: the references move to the new shape,
/// so decrefing here would leave it holding freed keys.
fn void Heap.free_shape_slot(&self, uint id, bool release_keys = true) {
    if (id == 0 || id >= self.shape_count) return;
    if (self.shape_free_head == id) return;         // already free
    hobject::Shape* sh = self.shapes[id];
    if (sh == null) return;
    if (sh.parent != hobject::PRIVATE_SHAPE_PARENT) return;   // shared: not ours to free
    // Carry the dead shape's generation in the link so the next occupant of
    // this slot starts past it and no live inline-cache entry can match.
    uint gen = sh.generation & SHAPE_FREE_GEN_MASK;
    hobject::shape_free(sh, (void*)self, release_keys);
    uint link = (gen << SHAPE_FREE_LINK_BITS) | (self.shape_free_head & SHAPE_FREE_LINK_MASK);
    self.shapes[id] = (hobject::Shape*)(SHAPE_FREE_TAG | (uptr)link);
    self.shape_free_head = id;
}


/// Transition to a new shape that includes the given property key, using the
/// default WEC data-property flags.  Thin wrapper over
/// transition_shape_new_flags() for the overwhelmingly common case.
fn uint Heap.transition_shape_new(&self, uint cur_shape_id, void* key) {
    return self.transition_shape_new_flags(cur_shape_id, key, hobject::PROP_FLAGS_WEC);
}

/// Transition to a shape that adds `key` with `flags`.
///
/// The key must be absent from the object; callers confirm that with
/// find_prop_idx() first, which lets this skip the O(N) chain walk.
///
/// The transition table is keyed on (parent shape, key, flags), so two objects
/// that reach the same parent and add the same key with the same flags converge
/// on one shape. That holds for non-default flags too, such as every instance of
/// a class installing the same private field. Differing flags for the same key
/// produce separate shapes.
/// Returns SHAPE_NONE when no shape could be produced. The caller must treat
/// that as a hard failure: continuing with the unchanged shape would store a
/// value the shape does not describe, which reads back as a missing property.
fn uint Heap.transition_shape_new_flags(&self, uint cur_shape_id, void* key, hobject::PropFlags flags) {
    if (cur_shape_id >= self.shape_count || !self.shape_slot_live(cur_shape_id)) {
        return cur_shape_id;
    }

    hobject::Shape* cur = self.shapes[cur_shape_id];
    char raw_flags = (char)flags;

    // Another object may already have taken this transition.
    uint existing = self.lookup_transition(cur_shape_id, key, raw_flags);
    if (existing != SHAPE_NONE) {
        return existing;
    }

    hobject::Shape* ns = hobject::shape_extend(cur, cur_shape_id, key, flags);
    if (ns == null) return SHAPE_NONE;

    uint new_id = self.alloc_shape_slot();
    if (new_id == SHAPE_NONE) {
        hobject::shape_free(ns, (void*)self, true);
        return SHAPE_NONE;
    }

    self.store_new_shape(new_id, ns);
    self.insert_transition(cur_shape_id, key, raw_flags, new_id);
    return new_id;
}

fn void Heap.bump_shape_gen(&self, uint shape_id) {
    if (shape_id < self.shape_count && self.shape_slot_live(shape_id)) {
        self.shapes[shape_id].generation++;
    }
}

/// Get a shape pointer by ID. Returns null if invalid or reclaimed.
fn hobject::Shape* Heap.get_shape(&self, uint shape_id) {
    if (shape_id >= self.shape_count) return null;
    if (!self.shape_slot_live((uint)shape_id)) return null;
    return self.shapes[shape_id];
}

/**
 * Free every tracked CompiledFunction and its sub-arrays, leaving the
 * `compiled_funcs` array itself alone. For teardown only, called by destroy()
 * and reset(): decref is unnecessary because the str_table sweep releases the
 * interned strings.
 */
fn void Heap.free_compiled_funcs(&self) {
    for (uint i = 0; i < self.compiled_func_count; i++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[i];
        if (cf == null) continue;
        if (cf.code != null) { self.free_func(self.heap_udata, cf.code); }
        if (cf.constants != null) { self.free_func(self.heap_udata, cf.constants); }
        if (cf.inner_funcs != null) { self.free_func(self.heap_udata, cf.inner_funcs); }
        if (cf.line_table != null) { self.free_func(self.heap_udata, cf.line_table); }
        if (cf.ic_entries != null) { self.free_func(self.heap_udata, cf.ic_entries); }
        if (cf.var_ic_entries != null) { self.free_func(self.heap_udata, cf.var_ic_entries); }
        if (cf.regexp_cache != null) {
            for (uint ri = 0; ri < cf.regexp_cache_count; ri++) {
                if (cf.regexp_cache[ri] != null) { re_bindings::re_free(cf.regexp_cache[ri]); }
            }
            self.free_func(self.heap_udata, cf.regexp_cache);
        }
        // Private-name snapshot from compiler/context.c3 finish(), tracked when
        // a function used direct eval and inherited names from a parent class.
        if (cf.eval_private_names != null) { self.free_func(self.heap_udata, cf.eval_private_names); }
        // The function's name and retained source text, copied out of the
        // compiler's scratch buffers so they outlive the compile. Both come from
        // `mem` rather than the heap allocator. `filename_ptr` stays untouched:
        // stamp_module_filename hands every nested function the module's
        // normalized specifier, so it is borrowed.
        if (cf.name_ptr != null) { mem::free(cf.name_ptr); cf.name_ptr = null; }
        if (cf.src_ptr != null) { mem::free(cf.src_ptr); cf.src_ptr = null; }
        self.free_func(self.heap_udata, cf);
    }
}

/**
 * Release every managed object, then free the heap struct itself.
 */
fn void Heap.destroy(&self) {
    // Teardown frees everything directly, so object teardown must skip its RC
    // decref loop: mixing decref with the str_table backshift-delete would
    // corrupt the table for the sweep below.
    self.tearing_down = true;
    hobject::hobject_clear_active_heap();

    HeapHeader* cur = self.heap_allocated;
    while (cur != null) {
        HeapHeader* next = cur.next;
        if (cur.is_object()) {
            hobject::hobject_free((HObject*)cur, (void*)self);
        } else if (cur.is_bigint()) {
            // HBigInt boxes are the only non-object node on heap_allocated, and
            // they hold no children, so a plain free is enough.
            self.free_func(self.heap_udata, cur);
        }
        cur = next;
    }
    self.heap_allocated = null;

    {
        void* b = self.env_pool_blocks;
        while (b != null) {
            void* next = *(void**)b;  // the next pointer is the block's first field
            self.free_func(self.heap_udata, b);
            b = next;
        }
        self.env_pool_blocks = null;
        self.env_freelist = null;
    }

    if (self.compiled_funcs != null) {
        self.free_compiled_funcs();
        self.free_func(self.heap_udata, self.compiled_funcs);
        self.compiled_funcs = null;
    }

    // The entries hold no owned allocations: `name` is an interned HString
    // freed by the string-table sweep below, and `udata` belongs to the host.
    if (self.host_fns != null) {
        self.free_func(self.heap_udata, (void*)self.host_fns);
        self.host_fns = null;
        self.host_fn_count = 0;
        self.host_fn_capacity = 0;
    }

    // The scope array objects themselves are ordinary heap objects, already
    // freed by the sweep above; only the stack that pointed at them is ours.
    if (self.host_scopes != null) {
        self.free_func(self.heap_udata, (void*)self.host_scopes);
        self.host_scopes = null;
        self.host_scope_depth = 0;
        self.host_scope_capacity = 0;
    }

    // Interned HStrings are refcounted in normal operation; teardown frees them
    // directly through the table.
    if (self.str_table != null) {
        for (uint i = 0; i < self.str_table_size; i++) {
            hstring::HString* s = self.str_table[i];
            if (s != null && s != STR_TABLE_TOMBSTONE) {
                self.free_string(s);
                self.str_table[i] = null;
            }
        }
        self.free_func(self.heap_udata, self.str_table);
        self.str_table = null;
    }

    // The large-string registry and everything it tracks.
    for (uint i = 0; i < self.large_string_count; i++) {
        self.free_string(self.large_strings[i]);
    }
    self.large_string_count = 0;
    if (self.large_strings != null) {
        self.free_func(self.heap_udata, self.large_strings);
        self.large_strings = null;
        self.large_string_capacity = 0;
    }

    if (self.microtask_queue != null) {
        self.free_func(self.heap_udata, self.microtask_queue);
        self.microtask_queue = null;
    }

    if (self.gray_objects != null) {
        self.free_func(self.heap_udata, self.gray_objects);
        self.gray_objects = null;
    }

    if (self.join_visited != null) {
        self.free_func(self.heap_udata, self.join_visited);
        self.join_visited = null;
        self.join_visited_count = 0;
        self.join_visited_capacity = 0;
    }

    if (self.trans_table != null) {
        self.free_func(self.heap_udata, self.trans_table);
        self.trans_table = null;
    }
    if (self.shapes != null) {
        for (uint i = 0; i < self.shape_count; i++) {
            if (self.shape_slot_live(i)) {
                hobject::shape_free(self.shapes[i], (void*)self, false);
            }
        }
        self.free_func(self.heap_udata, self.shapes);
        self.shapes = null;
    }

    // Free megamorphic property cache
    if (self.mega_cache != null) {
        mem::free(self.mega_cache);
        self.mega_cache = null;
    }

    // Free module cache
    self.free_module_cache();

    // Releases every pool page back to libc.
    self.obj_pool_plain.free();
    self.obj_pool_array.free();
    self.obj_pool_func.free();

    FreeFunc    ffn   = self.free_func;
    void*       udata = self.heap_udata;
    ffn(udata, self);
}

/**
 * Return the heap to a clean state, keeping the heap struct itself. Frees the
 * GC objects, compiled functions, interned strings, symbol registry, and
 * checkpoint data, then reinitialises the string table and builtin string cache
 * in place, reusing backing arrays where it can.
 *
 * The heap can then host a fresh VM holding nothing from the previous run.
 * Repeated create/destroy cycles fragment the allocator and grow RSS, which
 * this avoids for batch runs.
 */
fn void Heap.reset(&self) {
    // Decref the string and bigint TVals held by live objects before teardown
    // mode starts. BigInt boxes have no list of their own to drain later, so
    // this pass is what releases them. Strings driven to zero here unregister
    // themselves, leaving the registry drain below only those still referenced.
    {
        HeapHeader* cur = self.heap_allocated;
        while (cur != null) {
            if (cur.is_object()) {
                hobject::HObject* obj = (hobject::HObject*)cur;
                hobject::PropValue* pvs = obj.prop_values();
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (pvs[i].is_string() || pvs[i].is_bigint()) { self.decref_tval(&pvs[i]); }
                }
                types::TVal* arr = obj.array_part();
                if (arr != null) {
                    uint used = obj.array_used;
                    for (uint i = 0; i < used; i++) {
                        if (arr[i].is_string() || arr[i].is_bigint()) { self.decref_tval(&arr[i]); }
                    }
                }
            }
            cur = cur.next;
        }
    }
    // Strings can also still be on the valstack after an aborted or thrown run.
    if (self.valstack_base != null && self.valstack_top_ptr != null) {
        types::TVal* top = *self.valstack_top_ptr;
        types::TVal* base = self.valstack_base;
        while (base < top) {
            if (base.is_string() || base.is_bigint()) { self.decref_tval(base); }
            base++;
        }
    }

    // Same teardown mode as destroy(): object teardown skips its RC decref loop.
    self.tearing_down = true;
    hobject::hobject_clear_active_heap();

    HeapHeader* cur = self.heap_allocated;
    while (cur != null) {
        HeapHeader* next = cur.next;
        if (cur.is_object()) {
            hobject::hobject_free((HObject*)cur, (void*)self);
        } else if (cur.is_bigint()) {
            // HBigInt boxes are the only non-object node on heap_allocated, and
            // they hold no children, so a plain free is enough.
            self.free_func(self.heap_udata, cur);
        }
        cur = next;
    }
    self.heap_allocated = null;

    self.free_compiled_funcs();
    self.compiled_func_count = 0;  // the array itself stays allocated for reuse

    // Large strings are in neither str_table nor heap_allocated, so the registry
    // is the only list that can reach them. Skipping this pass would leave them
    // ownerless and accumulating across batch runs.
    for (uint i = 0; i < self.large_string_count; i++) {
        self.free_string(self.large_strings[i]);
    }
    self.large_string_count = 0;

    if (self.str_table != null) {
        for (uint i = 0; i < self.str_table_size; i++) {
            hstring::HString* s = self.str_table[i];
            if (s != null && s != STR_TABLE_TOMBSTONE) {
                self.free_string(s);
                self.str_table[i] = null;
            }
        }
        // Shrink a table that grew far past its starting size.
        if (self.str_table_size > INITIAL_STR_TABLE_SIZE * 8) {
            self.free_func(self.heap_udata, self.str_table);
            usz tbl_bytes = HString*::size * INITIAL_STR_TABLE_SIZE;
            void* new_tbl = self.alloc_func(self.heap_udata, tbl_bytes);
            if (new_tbl != null) {
                mem::clear(new_tbl, (sz)(tbl_bytes));
                self.str_table      = (HString**)new_tbl;
                self.str_table_size = INITIAL_STR_TABLE_SIZE;
            }
        }
        self.str_table_used = 0;
    }

    if (self.symbol_registry_keys != null) {
        self.free_func(self.heap_udata, self.symbol_registry_keys);
        self.symbol_registry_keys = null;
    }
    if (self.symbol_registry_syms != null) {
        self.free_func(self.heap_udata, self.symbol_registry_syms);
        self.symbol_registry_syms = null;
    }
    self.symbol_registry_count = 0;
    self.symbol_registry_cap   = 0;

    // Env nodes hold TVal bindings pointing into the heap that was just freed,
    // so a stale freelist node reused in the next run would make tval_copy_ref
    // decref through dangling memory.
    {
        void* b = self.env_pool_blocks;
        while (b != null) {
            void* next = *(void**)b;
            self.free_func(self.heap_udata, b);
            b = next;
        }
        self.env_pool_blocks = null;
    }
    self.env_freelist = null;

    if (self.checkpoint_keys != null) {
        self.free_func(self.heap_udata, self.checkpoint_keys);
        self.checkpoint_keys = null;
    }
    if (self.checkpoint_vals != null) {
        self.free_func(self.heap_udata, self.checkpoint_vals);
        self.checkpoint_vals = null;
    }
    self.checkpoint_count = 0;
    self.checkpoint_cap   = 0;

    // The objects these TVals referenced were freed wholesale above, so clear
    // the stale bits without decrefing.
    if (self.microtask_queue != null) {
        mem::clear(self.microtask_queue,
            (sz)((usz)self.microtask_capacity * TVal::size * 3));
    }
    self.microtask_count    = 0;
    self.microtask_draining = false;
    self.async_waiter_count = 0;
    self.sweeping           = false;
    mem::clear(&self.async_waiters, (sz)(AtomicsWaiter::size * 64));

    // Remaining heap state: GC roots, execution state, prototypes.
    self.heap_allocated   = null;
    self.finalize_list    = null;
    self.flags            = 0;
    self.curr_thread      = null;
    self.valstack_base    = null;
    self.valstack_top_ptr = null;
    self.resume_gen       = null;
    self.did_yield        = false;
    self.ag_did_await     = false;
    self.gc_root_count    = 0;
    self.capi_roots       = null;
    self.capi_mark        = null;
    self.gc_running       = false;
    self.gc_trigger_counter = GC_INITIAL_TRIGGER;
    self.gc_pending       = false;
    self.bwd_gc_budget    = BWD_GC_INTERVAL;
    self.native_frame_depth = 0;
    self.gray_count       = 0;

    // The cache holds HObject* and HString* from the previous run. Pool
    // allocators restart at the same addresses, so leaving those entries in
    // place would let new objects hit them and read wrong property values.
    if (self.mega_cache != null) {
        mem::clear(self.mega_cache, (sz)(MEGA_CACHE_SIZE * hobject::MegamorphicEntry::size));
    }

    self.err_proto        = null;
    self.type_err_proto   = null;
    self.range_err_proto  = null;
    self.ref_err_proto    = null;
    self.syntax_err_proto = null;
    self.eval_err_proto   = null;
    self.uri_err_proto    = null;
    self.aggregate_err_proto = null;
    self.object_proto     = null;
    self.object_proto___proto___getter = null;
    self.object_proto___proto___setter = null;
    self.bool_proto       = null;
    self.string_proto     = null;
    self.number_proto     = null;
    self.array_proto      = null;
    self.function_proto   = null;
    self.date_proto       = null;
    self.regexp_proto     = null;
    self.map_proto        = null;
    self.set_proto        = null;
    self.weakmap_proto    = null;
    self.weakset_proto    = null;
    self.weakref_proto    = null;
    self.finalization_registry_proto = null;
    self.symbol_proto     = null;
    self.bigint_proto     = null;
    self.promise_proto    = null;
    self.promise_ctor     = null;
    self.function_ctor    = null;
    self.generator_proto      = null;
    self.generator_func_proto = null;
    self.async_func_proto     = null;
    self.async_iterator_proto = null;
    self.async_generator_proto = null;
    self.async_generator_func_proto = null;
    self.iterator_proto       = null;
    self.iterator_ctor        = null;
    self.iterator_helper_proto = null;
    self.wrap_for_valid_iterator_proto = null;
    self.async_from_sync_iter_proto = null;
    self.array_iterator_proto = null;
    self.map_iterator_proto = null;
    self.set_iterator_proto = null;
    self.string_iterator_proto = null;
    self.regexp_string_iterator_proto = null;
    self.typedarray_proto = null;
    self.typedarray_intrinsic = null;
    self.uint8array_proto = null;
    self.arraybuffer_proto = null;
    self.sharedarraybuffer_proto = null;
    self.dataview_proto = null;

    for (usz i = 0; i < STRS_CACHE_SIZE; i++) {
        self.strs[i] = null;
    }

    // Small-integer strings refill lazily once init_builtin_strs() has rebuilt
    // the string table.
    for (usz i = 0; i < 256; i++) {
        self.small_int_strs[i] = null;
    }

    mem::clear(&self.lf_deleted_props[0], (sz)(LF_DELETED_WORDS * 8));

    self.lj.lj_type = LjType.UNKNOWN;
    self.lj.iserror = false;
    self.lj.value1.set_undefined();
    self.lj.value2.set_undefined();

    // These TVals can hold heap pointers.
    self.error_value.set_undefined();
    self.yield_value.set_undefined();
    self.has_error = false;

    // gen_initial_obj points into the freed heap, and the GC mark phase
    // dereferences it whenever it is non-null. A run aborted mid-generator-init
    // would otherwise poison every later run in the same worker.
    self.gen_initial_gs = null;
    self.gen_initial_obj = null;
    self.gen_initial_retval = null;
    self.gen_init_stack_depth = 0;

    // These point into the string table that was just freed. The ensure_*_symbol
    // helpers recreate them on demand.
    self.iterator_symbol = null;
    self.tostringtag_symbol = null;
    self.toprimitive_symbol = null;
    self.concatspreadable_symbol = null;
    self.hasinstance_symbol = null;
    self.match_symbol = null;
    self.search_symbol = null;
    self.replace_symbol = null;
    self.split_symbol = null;
    self.species_symbol = null;
    self.unscopables_symbol = null;
    self.matchall_symbol = null;
    self.asynciterator_symbol = null;

    // Free the shapes and transition table, then build both again.
    if (self.trans_table != null) {
        self.free_func(self.heap_udata, self.trans_table);
        self.trans_table = null;
    }
    if (self.shapes != null) {
        for (uint i = 0; i < self.shape_count; i++) {
            if (self.shape_slot_live(i)) {
                hobject::shape_free(self.shapes[i], (void*)self, false);
            }
        }
        // The pointer array is reused, so zeroing it is enough.
        mem::clear(self.shapes, (sz)((usz)self.shape_capacity * (void*::size)));
    }
    self.shape_count = 1;
    self.shape_recycle_epoch = 0;
    self.shape_free_head = SHAPE_FREE_END;
    self.shapes[0]   = hobject::shape_create(0, 0, SHAPE_NONE, null);
    self.init_transition_table();

    self.free_module_cache();
    self.module_hooks = null;
    self.current_module_name = {};

    // Every pool page goes back to libc, and the fresh pools start with a clean
    // bump pointer and an empty freelist.
    self.obj_pool_plain.free();
    self.obj_pool_array.free();
    self.obj_pool_func.free();
    {
        self.obj_pool_plain.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_PLAIN, 512);
        self.obj_pool_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARRAY, 512);
        self.obj_pool_func.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_FUNC, 512);
    }

    self.init_builtin_strs();

    // The sweep is over and the heap is usable again, so object teardown must
    // resume decrefing rather than assuming everything is about to be freed.
    self.tearing_down = false;

    hobject::hobject_set_active_heap((void*)self);
}

// ============================================================================
// Host function registry
// ============================================================================

/// Record a host function and return its slot, or -1 if the table cannot grow.
///
/// The slot is an index into host_fns; callers turn it into a callable object
/// through builtins::make_host_function, which adds HOST_FN_BASE. Slots are
/// never reused: a registration is permanent for the heap's lifetime, so an
/// index captured in a function object can never come to mean a different
/// function.
fn long Heap.register_host_fn(&self, void* handler, void* udata, void* name, int arity, bool constructable) {
    if (handler == null) return -1;
    if (self.host_fn_count >= self.host_fn_capacity) {
        uint new_cap = self.host_fn_capacity == 0 ? 8 : self.host_fn_capacity * 2;
        usz new_bytes = (usz)new_cap * HostFnEntry::size;
        void* grown = self.realloc_func(self.heap_udata, (void*)self.host_fns, new_bytes);
        if (grown == null) return -1;
        self.host_fns = (HostFnEntry*)grown;
        self.host_fn_capacity = new_cap;
    }
    uint slot = self.host_fn_count;
    self.host_fns[slot].handler       = handler;
    self.host_fns[slot].udata         = udata;
    self.host_fns[slot].name          = name;
    self.host_fns[slot].arity         = arity;
    self.host_fns[slot].constructable = constructable;
    self.host_fn_count++;
    return (long)slot;
}

/// Entry for `slot`, or null when the slot was never registered. Every caller
/// treats null as "not a host function" rather than faulting, so a stale or
/// forged index degrades to a TypeError instead of a wild jump.
fn HostFnEntry* Heap.host_fn_at(&self, uint slot) {
    if (slot >= self.host_fn_count) return null;
    return &self.host_fns[slot];
}

// ============================================================================
// Host call scopes
// ============================================================================

/// Slot 0 of every scope holds `this`; slot 1 holds new.target; arguments
/// start at HOST_SCOPE_ARG0. Fixed offsets keep jse_this/jse_arg branch-free.
const uint HOST_SCOPE_THIS = 0;
const uint HOST_SCOPE_NEW_TARGET = 1;
const uint HOST_SCOPE_ARG0 = 2;

/// Push a scope for one host callback and return its depth index, or -1.
///
/// The backing store is an ARRAY object, which alloc_object temproot-pins for
/// the duration of the surrounding native frame, so its elements survive any
/// collection the host triggers without consuming a GC root.
fn long Heap.host_scope_push(&self) {
    if (self.host_scope_depth >= self.host_scope_capacity) {
        uint new_cap = self.host_scope_capacity == 0 ? 4 : self.host_scope_capacity * 2;
        usz new_bytes = (usz)new_cap * HostScope::size;
        void* grown = self.realloc_func(self.heap_udata, (void*)self.host_scopes, new_bytes);
        if (grown == null) return -1;
        self.host_scopes = (HostScope*)grown;
        self.host_scope_capacity = new_cap;
    }
    HObject*? arr_raw = self.alloc_object(hobject::ObjClass.ARRAY);
    if (catch arr_raw) return -1;
    HObject* arr = arr_raw;
    arr.prototype = self.array_proto;

    uint depth = self.host_scope_depth;
    self.host_scope_generation++;
    self.host_scopes[depth].values = arr;
    self.host_scopes[depth].generation = self.host_scope_generation;
    self.host_scope_depth++;
    return (long)depth;
}

/// Pop the innermost scope. Its values become unreachable and its generation
/// is retired, so any handle still held by the host now fails validation.
fn void Heap.host_scope_pop(&self) {
    if (self.host_scope_depth == 0) return;
    self.host_scope_depth--;
    self.host_scopes[self.host_scope_depth].values = null;
    self.host_scopes[self.host_scope_depth].generation = 0;
}

/// Store `v` in the innermost scope at `index`, returning success.
fn bool Heap.host_scope_set(&self, uint depth, uint index, TVal v) {
    if (depth >= self.host_scope_depth) return false;
    HObject* arr = self.host_scopes[depth].values;
    if (arr == null) return false;
    HString* key = self.int_to_hstring((long)index);
    if (key == null) return false;
    return arr.put_prop(key, v, hobject::PROP_FLAGS_WEC);
}

/// Read the value at `index` in scope `depth`. Returns false when the scope is
/// gone or the index was never populated.
fn bool Heap.host_scope_get(&self, uint depth, uint index, TVal* out) {
    if (depth >= self.host_scope_depth) return false;
    HObject* arr = self.host_scopes[depth].values;
    if (arr == null) return false;
    HString* key = self.int_to_hstring((long)index);
    if (key == null) return false;
    TVal? v = arr.get_prop(key);
    if (catch v) return false;
    *out = v;
    return true;
}

/// Generation stamp of scope `depth`, or 0 when that depth is not live.
fn uint Heap.host_scope_generation_at(&self, uint depth) {
    if (depth >= self.host_scope_depth) return 0;
    return self.host_scopes[depth].generation;
}

// ============================================================================
// CompiledFunction tracking
// ============================================================================

/**
 * Register a CompiledFunction* to be freed when the heap is destroyed. The
 * compiler allocates them through the heap's alloc_func, and the GC object
 * array does not track them, so they need this separate list.
 */
fn void Heap.track_compiled_func(&self, void* cf) {
    if (cf == null) { return; }
    if (self.compiled_func_count >= self.compiled_func_cap) {
        uint new_cap = self.compiled_func_cap == 0 ? 64 : self.compiled_func_cap * 2;
        usz new_bytes = (usz)new_cap * void*::size;
        void* new_arr = self.realloc_func(self.heap_udata, self.compiled_funcs, new_bytes);
        if (new_arr == null) { return; }
        self.compiled_funcs = (void**)new_arr;
        self.compiled_func_cap = new_cap;
    }
    self.compiled_funcs[self.compiled_func_count] = cf;
    self.compiled_func_count++;
}

// ============================================================================
// Module system: hooks and cache management
// ============================================================================

/// Register module host hooks, before any module loading happens. Null selects
/// the defaults. The pointer must stay valid for the lifetime of the Heap.
fn void Heap.set_module_hooks(&self, void* hooks) {
    self.module_hooks = hooks;
}

/// Free the module cache and all ModuleDef entries.
fn void Heap.free_module_cache(&self) {
    if (self.module_cache != null) {
        void** cache = (void**)self.module_cache;
        for (uint i = 0; i < self.module_cache_count; i++) {
            if (cache[i] != null) {
                self.free_func(self.heap_udata, cache[i]);
            }
        }
        self.free_func(self.heap_udata, self.module_cache);
        self.module_cache = null;
        self.module_cache_count = 0;
        self.module_cache_cap = 0;
    }
}

// ============================================================================
// Low-level allocation with GC trigger
// ============================================================================

/**
 * Allocate `size` bytes through the heap's allocator, counting down the GC
 * trigger and flagging a deferred collection when it hits zero.
 */
fn void*? Heap.alloc(&self, usz size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.gc_pending = true;
    }

    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        // Collect and retry once before giving up.
        self.trigger_gc();
        ptr = self.alloc_func(self.heap_udata, size);
        if (ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return ptr;
}

/// Allocate without running a collection. Used for refcounted allocations such
/// as strings, which the mark-and-sweep heap_allocated list does not hold.
///
/// A synchronous GC from inside this allocator would be unsafe: it can free an
/// in-flight object or string that a C3 local still points to but no GC root can
/// see, such as the gap between alloc_object and the put_prop that anchors it,
/// which corrupts the pool through a double free. Allocations here only ever set
/// gc_pending, and the collection runs at the next safepoint.
fn void*? Heap.alloc_no_gc(&self, usz size) {
    // Large strings still count toward GC pressure. A program building many
    // multi-KB concat results held by short-lived objects would never burn the
    // trigger down, and the objects holding those strings would pile up unswept.
    // Small strings stay uncounted: they are interned, so the string table backs
    // them, and counting them shifts GC cadence for every property-key
    // allocation without reclaiming more.
    if (size > 1024) {
        self.gc_trigger_counter -= (long)(size >> 10);
        if (self.gc_trigger_counter <= 0) {
            self.gc_pending = true;
        }
    }
    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        // Out of memory. Reclaim what mark-and-sweep can, then retry once.
        self.trigger_gc();
        ptr = self.alloc_func(self.heap_udata, size);
        if (ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return ptr;
}

/**
 * Allocate an HObject and add it to the heap's GC tracking list. Use this
 * rather than hobject::hobject_alloc() directly, which leaves the object off
 * heap_allocated and therefore invisible to mark-and-sweep.
 *
 * Returns the new HObject, or a fault if allocation fails.
 */
fn HObject*? Heap.alloc_object(&self, hobject::ObjClass cls) {
    HObject*? result = hobject::hobject_alloc((void*)self, cls);
    if (try obj = result) {
        // Keeps the flags hobject_alloc already set.
        self.insert_into_heap_allocated_preserve_flags((HeapHeader*)obj);
        // As a temporary root, a GC outside a safepoint cannot free this object
        // while a C3 local holds its only reference.
        ((HeapHeader*)obj).set_temproot();
        self.live_obj_count++;
        if (self.live_obj_count > self.peak_live_obj_count) {
            self.peak_live_obj_count = self.live_obj_count;
        }
        self.gc_trigger_counter--;
        if (self.gc_trigger_counter <= 0) {
            self.gc_pending = true;
        }
    }
    return result;
}

/**
 * Reallocate a block through the heap's allocator, counting down the GC trigger.
 */
fn void*? Heap.realloc(&self, void* ptr, usz new_size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.gc_pending = true;
    }

    void* new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
    if (new_ptr == null && new_size > 0) {
        self.trigger_gc();
        new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
        if (new_ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return new_ptr;
}

fn void Heap.free(&self, void* ptr) {
    self.free_func(self.heap_udata, ptr);
}

/**
 * Store a string in a VM register, releasing whatever the register held.
 */
fn void Heap.set_reg_string(&self, TVal* reg, hstring::HString* s) @inline {
    self.decref_tval(reg);
    reg.set_string(s);
}

/**
 * Free an HString through the heap's allocator, matching Heap.alloc.
 */
fn void Heap.free_string(&self, hstring::HString* s) {
    if (s == null) { return; }
    self.free_func(self.heap_udata, s);
}



// ============================================================================
// Reference counting: decref, and free at zero
// ============================================================================

/**
 * Drop a reference to a heap object, buffer, or interned string. At zero,
 * objects and buffers are unlinked from heap_allocated and freed, and strings
 * are freed directly.
 *
 * The sweep phase never sees anything freed here, since it is already off the
 * list. Mark-and-sweep exists to collect cycles: objects with a non-zero
 * refcount that no root can reach.
 */
fn void Heap.decref(&self, HeapHeader* hdr) {
    // While Heap.sweep() frees unmarked garbage, a dying object's hobject_free
    // can decref a neighbour it references, such as a getter, captured_this, a
    // promise result, or a bigint leaf. An unmarked neighbour belongs to the
    // same sweep and may already be freed, so touching its header would be a
    // use-after-free or a double free. Strings are purely refcounted and never
    // on heap_allocated, so they stay safe to decref.
    if (self.sweeping && !hdr.is_string() && !hdr.is_reachable() && !hdr.is_temproot()) {
        return;
    }
    // Pinned headers, meaning builtin strings, well-known symbols, and the
    // small-int cache, keep a fixed refcount. See HeapHeader.set_pinned.
    if (hdr.is_pinned()) {
        return;
    }
    if (--hdr.refcount == 0) {
        if (hdr.is_string()) {
            hstring::HString* s = (hstring::HString*)hdr;
            if (s.flags.is_interned) {
                self.str_table_remove(s);
            } else {
                self.large_string_unregister(s);
            }
            self.free_string(s);
        } else {
            hdr.unlink(&self.heap_allocated);
            if (hdr.is_object()) {
                hobject::hobject_free((HObject*)hdr, (void*)self);
            } else {
                // A buffer or BigInt box, both leaves.
                self.free_func(self.heap_udata, hdr);
            }
        }
    }
}

/**
 * Drop a reference to whatever heap object, buffer, or string a TVal holds.
 * Any TVal is acceptable, since primitives are ignored. Call this before
 * overwriting a register or slot that may hold a heap pointer.
 */
fn void Heap.decref_tval(&self, TVal* tv) @inline {
    if (tv.is_heap_allocated()) {
        void* ptr = tv.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
}

/// Copy a TVal from src to dst, keeping refcounts balanced. Increfs src, then
/// decrefs the old dst value, then copies the bits. Does nothing when dst == src.
fn void Heap.tval_copy_ref(&self, TVal* dst, TVal* src) @inline {
    if (dst != src) {
        // The incref comes first so that when src and dst hold the same object
        // at refcount 1, such as assigning one global to another, the decref
        // below cannot free it before the new reference is anchored.
        if (src.is_heap_allocated()) {
            void* ptr = src.get_heapptr();
            if (ptr != null) {
                ((HeapHeader*)ptr).incref();
            }
        }
        self.decref_tval(dst);
        *dst = *src;
    }
}

/// Move a builtin's result from its transient local TVal, such as the slot
/// `ctx.result` points at, into a VM register.
///
/// Builtins fill that slot with increffing setters like `set_string`, whether
/// the value is brand new or an existing one passing through. `tval_copy_ref`
/// gives the register its own reference either way, which leaves the transient's
/// claim outstanding. Most heap values have a backstop: mark-and-sweep reclaims
/// objects, and the string table keeps interned strings alive at any refcount.
/// Releasing those here would be pointless at best, and a use-after-free at
/// worst, since a Symbol's backing string can sit at refcount 1 while other code
/// still uses it.
///
/// A large, non-interned, non-symbol string has no such backstop. It is a
/// refcounted leaf, so an unbalanced setter reference leaks it permanently, and
/// that alone is what this releases. Requiring refcount == 1 confirms the
/// setter's claim is the only one, as it is for a value just created.
fn void Heap.store_builtin_result(&self, TVal* dst, TVal* transient) @inline {
    bool release_transient = false;
    if (transient.is_string()) {
        void* ptr = transient.get_heapptr();
        // When the same string already sits in the destination, tval_copy_ref is
        // refcount-neutral, so releasing the transient would drop a live reference.
        if (ptr != null && ptr != dst.get_heapptr()) {
            hstring::HString* hs = (hstring::HString*)ptr;
            if (!hs.flags.is_interned && !hs.flags.is_symbol
                && ((HeapHeader*)ptr).refcount == 1) {
                release_transient = true;
            }
        }
    }
    self.tval_copy_ref(dst, transient);
    if (release_transient) {
        self.decref((HeapHeader*)transient.get_heapptr());
    }
}

/// Move a TVal from a register into a heap slot, handing src's reference to dst.
/// The old dst value is decref'd and src's bits are moved in with no incref,
/// since ownership transfers; the caller then clears src to undefined. A
/// primitive already in dst needs no decref, so the branch skips it. This is the
/// hot global-slot write path used by PUTGLOBAL.
///
/// Only the overwritten dst value decides whether a decref is owed. The move
/// preserves src's refcount whether src is a heap value or a primitive.
fn void Heap.tval_move_slot_fast(&self, TVal* dst, TVal* src) @inline {
    if (dst.is_heap_allocated()) {
        void* ptr = dst.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
    *dst = *src;
}

// ============================================================================
// Managed-object lists, doubly linked through HeapHeader
// ============================================================================

/**
 * Insert `hdr` at the head of heap_allocated.
 */
fn void Heap.insert_into_heap_allocated(&self, HeapHeader* hdr) {
    hdr.init(hdr.get_type(), &self.heap_allocated);
}

/**
 * Remove `hdr` from heap_allocated in O(1) via HeapHeader.unlink().
 */
fn void Heap.remove_from_heap_allocated(&self, HeapHeader* hdr) {
    hdr.unlink(&self.heap_allocated);
}

/**
 * Insert `hdr` at the head of heap_allocated without calling HeapHeader.init(),
 * so flags the caller already set survive.
 *
 * Use this when the subtype, HObject or HString, has set its own flags and only
 * the list wiring is missing. Raw HeapHeader allocations that need a full header
 * init should use insert_into_heap_allocated() instead.
 */
fn void Heap.insert_into_heap_allocated_preserve_flags(&self, HeapHeader* hdr) {
    hdr.prev = null;
    hdr.next = self.heap_allocated;
    if (self.heap_allocated != null) {
        self.heap_allocated.prev = hdr;
    }
    self.heap_allocated = hdr;
}

/**
 * Insert `hdr` at the head of finalize_list and flag it finalizable.
 */
fn void Heap.insert_into_finalize_list(&self, HeapHeader* hdr) {
    hdr.set_finalizable();
    hdr.next = self.finalize_list;
    hdr.prev = null;
    if (self.finalize_list != null) {
        self.finalize_list.prev = hdr;
    }
    self.finalize_list = hdr;
}

/**
 * Remove `hdr` from finalize_list.
 */
fn void Heap.remove_from_finalize_list(&self, HeapHeader* hdr) {
    hdr.unlink(&self.finalize_list);
}

// ============================================================================
// GC root registration
// ============================================================================

/**
 * Register a heap object as a GC root. Mark-and-sweep always treats roots as
 * reachable, so they are never freed.
 */
fn void Heap.register_gc_root(&self, HeapHeader* hdr) {
    if (self.gc_root_count < GC_MAX_ROOTS) {
        self.gc_roots[self.gc_root_count] = (void*)hdr;
        self.gc_root_count++;
    }
}

// ============================================================================
// Array.prototype.join cycle detection
// ============================================================================

/// True when `obj` is already being joined further up the call stack, i.e.
/// recursing into it would not terminate.
fn bool Heap.join_visited_has(&self, HObject* obj) {
    for (uint i = 0; i < self.join_visited_count; i++) {
        if (self.join_visited[i] == (void*)obj) return true;
    }
    return false;
}

/// Mark `obj` as being joined. Returns false when the stack cannot grow, which
/// callers must treat as a failure to enter rather than as "no cycle": pushing
/// nothing would let the next level re-enter the same array unnoticed.
fn bool Heap.join_visited_push(&self, HObject* obj) {
    if (self.join_visited_count >= self.join_visited_capacity) {
        usz new_cap = self.join_visited_capacity > 0
                      ? (usz)self.join_visited_capacity * 2
                      : (usz)JOIN_VISITED_INITIAL_CAP;
        void* new_arr = self.realloc_func(self.heap_udata, self.join_visited, void*::size * new_cap);
        if (new_arr == null) return false;
        self.join_visited          = (void**)new_arr;
        self.join_visited_capacity = (uint)new_cap;
    }
    self.join_visited[self.join_visited_count++] = (void*)obj;
    return true;
}

/// Unmark the innermost array being joined.
fn void Heap.join_visited_pop(&self) {
    if (self.join_visited_count > 0) self.join_visited_count--;
}

// ============================================================================
// GC marking: tri-color marking over an explicit gray stack
// ============================================================================

/**
 * Push an object onto the gray stack so its children are visited later,
 * growing the stack when it is full.
 */
fn void Heap.gray_push(&self, HObject* obj) {
    if (self.gray_count >= self.gray_capacity) {
        usz new_cap = self.gray_capacity > 0
                      ? (usz)self.gray_capacity * 2
                      : (usz)GRAY_STACK_INITIAL_CAP;
        void* new_arr = self.realloc_func(self.heap_udata, self.gray_objects, void*::size * new_cap);
        if (new_arr == null) {
            self.fatal_func(self.heap_udata, "gray stack OOM during GC marking");
            return;
        }
        self.gray_objects  = (void**)new_arr;
        self.gray_capacity = (uint)new_cap;
    }
    self.gray_objects[self.gray_count++] = obj;
}

/**
 * Pop an object from the gray stack.  Returns null when the stack
 * is empty.
 */
fn HObject* Heap.gray_pop(&self) {
    if (self.gray_count == 0) { return null; }
    self.gray_count--;
    return (HObject*)self.gray_objects[self.gray_count];
}

/**
 * Mark the value a TVal holds as reachable. An object is marked and pushed onto
 * the gray stack so its children are visited. Strings and bigints have no
 * outgoing edges, so they are only marked.
 */
fn void Heap.mark_tval(&self, TVal* v) {
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null) {
            HeapHeader* hdr = (HeapHeader*)obj;
            if (!hdr.is_reachable()) {
                hdr.set_reachable();
                self.gray_push(obj);
            }
        }
    } else if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null) {
            ((HeapHeader*)s).set_reachable();
        }
    } else if (v.is_bigint()) {
        HeapHeader* b = (HeapHeader*)v.get_heapptr();
        if (b != null) {
            b.set_reachable();
        }
    }
}

/**
 * Mark the `bindings` HObject of every EnvRecord in a scope chain.
 *
 * An EnvRecord is pool-allocated and never collected itself, but its `bindings`
 * object is an ordinary heap node. Marking only the innermost link roots one
 * scope and leaves every enclosing one collectible: a closure suspended over
 * `outer -> middle -> inner` survives a sweep with `inner.bindings` intact and
 * `outer.bindings` freed, and the first GETVAR walking past `inner` reads a
 * recycled pool block, which surfaces as HObject.get_shape under find_prop_idx.
 *
 * Whoever roots a scope chain roots the whole chain, so callers must never mark
 * `env.bindings` directly. mark_activation_envs in vm_core.c3 does this walk for
 * live frames; this is the counterpart for closures, generator objects, and
 * suspended GeneratorStates.
 *
 * `env_ptr` is an opaque EnvRecord*, since heap.c3 cannot import env.c3, which
 * imports heap.c3. The typed field reads happen in hobject.c3.
 */
fn void Heap.mark_env_chain(&self, void* env_ptr) {
    void* cur = env_ptr;
    while (cur != null) {
        HObject* bindings = hobject::env_record_bindings(cur);
        if (bindings != null) { self.mark_hobject(bindings); }
        cur = hobject::env_record_parent(cur);
    }
}

/// Mark everything a suspended GeneratorState references. Both generator objects
/// and the async/await resume and reject builtins go through here.
fn void Heap.mark_generator_state(&self, GeneratorState* gs) {
    if (gs == null) return;
    if (gs.saved_regs != null) {
        for (uint i = 0; i < gs.num_regs; i++) {
            self.mark_tval(&gs.saved_regs[i]);
        }
    }
    // The suspended body's scope chains in full: it resumes with these as its
    // environment and will read enclosing scopes.
    self.mark_env_chain(gs.var_env);
    self.mark_env_chain(gs.lex_env);
    self.mark_tval(&gs.this_binding);
    self.mark_tval(&gs.resume_value);
    self.mark_tval(&gs.throw_value);
    self.mark_tval(&gs.return_value);
    // Async yield* delegation state, held across suspensions.
    self.mark_tval(&gs.ays_received);
    self.mark_tval(&gs.ays_next_method);
    // A body suspended inside a for-in owns the enumeration state, which moves
    // here at every yield, and the target's temproot pin does not survive a
    // safepoint GC. Marking it here is the same reason mark_activation_fields
    // marks a running frame's chain: otherwise the object being enumerated is
    // swept while the generator sleeps, and resuming reads freed memory.
    ForInState* gfi = (ForInState*)gs.forin;
    while (gfi != null) {
        if (gfi.target != null) { self.mark_hobject(gfi.target); }
        gfi = gfi.parent;
    }
    // Same for the catcher chain, for the same reason mark_activation_fields
    // marks a running frame's. A body suspended inside a finally that is routing
    // a throw parks the exception in Catcher.thrown_val, where nothing else
    // references it: the registers are saved but the value is not among them,
    // and the frame that owned the chain is gone. Without this it is swept while
    // the generator sleeps.
    if (gs.cat != null && self.catcher_chain_fn != null) {
        self.catcher_chain_fn(self, gs.cat, CATCHER_CHAIN_MARK);
    }
    if (gs.delegated_iter != null) {
        self.mark_hobject((HObject*)gs.delegated_iter);
    }
    if (gs.async_promise != null) {
        self.mark_hobject((HObject*)gs.async_promise);
    }
    // The instance owns the state and normally marks it, so this back-edge runs
    // the other way. An async generator driven only by its own machinery has no
    // JS-visible reference left, since `g().next()` drops the instance at once
    // and the only remaining path is a reaction closure on the awaited promise.
    // Without this the instance is swept while its request queue is still being
    // serviced, and the recycled memory reads back as a live promise.
    if (gs.gen_obj != null) {
        self.mark_hobject((HObject*)gs.gen_obj);
    }
    // The in-flight request is already off the queue, so the loop below misses
    // it. Between the dequeue and the settle this field is its only root apart
    // from a C3 local, and losing it frees the promise about to be settled.
    if (gs.ag_root_promise != null) {
        self.mark_hobject((HObject*)gs.ag_root_promise);
    }
    self.mark_tval(&gs.ag_current_value);
    if (gs.resume_wrapper != null) {
        self.mark_hobject((HObject*)gs.resume_wrapper);
    }
    // Every queued request holds a completion value and the promise it will
    // settle, both of which stay reachable while it waits.
    AsyncGenRequest* req = gs.agr_head;
    while (req != null) {
        self.mark_tval(&req.value);
        if (req.capability != null) {
            self.mark_hobject((HObject*)req.capability);
        }
        req = req.next;
    }
}

/**
 * Mark an HObject reachable and push it onto the gray stack. Does nothing if it
 * is already marked.
 */
fn void Heap.mark_hobject(&self, HObject* obj) {
    if (obj == null) { return; }
    HeapHeader* hdr = (HeapHeader*)obj;
    if (!hdr.is_reachable()) {
        hdr.set_reachable();
        self.gray_push(obj);
    }
}

/**
 * Pop objects off the gray stack and follow their outgoing references: the
 * prototype, named properties, array elements, wrapped primitive, and
 * environment bindings.
 *
 * mark_tval and mark_hobject push each newly discovered object back onto the
 * stack, so the loop reaches every reachable object. Being iterative, it has no
 * depth limit and cannot overflow the C stack.
 */
fn void Heap.drain_gray(&self) {
    while (self.gray_count > 0) {
        HObject* obj = self.gray_pop();

        if (obj.prototype != null) {
            self.mark_hobject(obj.prototype);
        }

        // Named properties.
        TVal* pv = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key != null) {
                ((HeapHeader*)key).set_reachable();
            }
            self.mark_tval(&pv[i]);
        }

        TVal* ap = obj.array_part();
        if (ap != null && obj.array_used > 0) {
            for (uint i = 0; i < obj.array_size; i++) {
                self.mark_tval(&ap[i]);
            }
        }

        // Fields that only some subtypes have.
        switch (obj.flags.obj_class) {
            case ObjClass.FUNCTION:
            case ObjClass.THREAD:
                // Bound functions leave var_env, lex_env, captured_this, and
                // captured_new_target unset, so only the bound_* fields matter.
                if (obj.flags.is_bound) {
                    self.mark_tval(&(*obj.extra_ptr()).func.bound_target);
                    self.mark_tval(&(*obj.extra_ptr()).func.bound_this);
                    if ((*obj.extra_ptr()).func.bound_args != null) {
                        self.mark_hobject((*obj.extra_ptr()).func.bound_args);
                    }
                    break;
                }
                // The async/await resume and reject builtins keep a
                // GeneratorState* in var_env rather than an EnvRecord*. Walking
                // it as an EnvRecord would read gs.func, a CompiledFunction*,
                // through the bindings offset and mark a non-HObject pointer.
                // Marking the GeneratorState covers the real var_env and lex_env.
                if (obj.flags.is_async_state) {
                    GeneratorState* gs = (GeneratorState*)(*obj.extra_ptr()).func.var_env;
                    self.mark_generator_state(gs);
                    break;
                }
                // A closure's captured scope chain, in full: reading an outer
                // variable after a sweep that only rooted the innermost link
                // dereferences a recycled EnvRecord.bindings.
                self.mark_env_chain((void*)(*obj.extra_ptr()).func.var_env);
                self.mark_env_chain((void*)(*obj.extra_ptr()).func.lex_env);
                self.mark_tval(&(*obj.extra_ptr()).func.captured_this);
                if ((*obj.extra_ptr()).func.captured_new_target != null) {
                    self.mark_hobject((*obj.extra_ptr()).func.captured_new_target);
                }
                break;
            case ObjClass.GENERATOR:
                self.mark_env_chain((void*)(*obj.extra_ptr()).gen.var_env);
                self.mark_env_chain((void*)(*obj.extra_ptr()).gen.lex_env);
                // Mark GeneratorState fields for suspended generators
                GeneratorState* gs = (GeneratorState*)(*obj.extra_ptr()).gen.generator_data;
                self.mark_generator_state(gs);
                break;
            case ObjClass.PROXY:
                // Keep [[ProxyTarget]] and [[ProxyHandler]] alive.
                if ((*obj.extra_ptr()).proxy.target != null) {
                    self.mark_hobject((*obj.extra_ptr()).proxy.target);
                }
                if ((*obj.extra_ptr()).proxy.handler != null) {
                    self.mark_hobject((*obj.extra_ptr()).proxy.handler);
                }
                break;
            case ObjClass.PROMISE:
                // The settled value and the list of pending reaction records.
                // A reaction's link to the next one is a hidden TVal property
                // (hobject::promise_reaction_next_key, written by
                // builtins::reaction_set_next). HeapHeader.next threads the
                // heap_allocated GC list instead, so walking it here would
                // follow unrelated objects.
                self.mark_tval(&(*obj.extra_ptr()).promise.result);
                HObject* reaction = (*obj.extra_ptr()).promise.reactions_head;
                while (reaction != null) {
                    self.mark_hobject(reaction);
                    HObject* next_reaction = null;
                    if (hobject::promise_reaction_next_key != null) {
                        if (try nv = reaction.get_prop((void*)hobject::promise_reaction_next_key)) {
                            if (nv.is_object() && nv.get_heapptr() != null) {
                                next_reaction = (HObject*)nv.get_heapptr();
                            }
                        }
                    }
                    reaction = next_reaction;
                }
                break;
            case ObjClass.ARRAYBUFFER:
                // Views chained off the buffer live as long as it does.
                HObject* view_walk = (*obj.extra_ptr()).ab.views_head;
                while (view_walk != null) {
                    self.mark_hobject(view_walk);
                    view_walk = (*view_walk.extra_ptr()).view.next_view;
                }
                break;
            case ObjClass.DATAVIEW:
            case ObjClass.INT8ARRAY:
            case ObjClass.UINT8ARRAY:
            case ObjClass.UINT8CLAMPEDARRAY:
            case ObjClass.INT16ARRAY:
            case ObjClass.UINT16ARRAY:
            case ObjClass.INT32ARRAY:
            case ObjClass.UINT32ARRAY:
            case ObjClass.FLOAT16ARRAY:
            case ObjClass.FLOAT32ARRAY:
            case ObjClass.FLOAT64ARRAY:
            case ObjClass.BIGINT64ARRAY:
            case ObjClass.BIGUINT64ARRAY:
                if ((*obj.extra_ptr()).view.buffer != null) {
                    self.mark_hobject((*obj.extra_ptr()).view.buffer);
                }
                break;
            case ObjClass.BOOLEAN:
            case ObjClass.NUMBER:
            case ObjClass.STRING:
            case ObjClass.DATE:
                self.mark_tval(&(*obj.extra_ptr()).prim.primitive_value);
                break;
            case ObjClass.ARRAY_ITERATOR:
            case ObjClass.MAP_ITERATOR:
            case ObjClass.SET_ITERATOR:
                // extra.iter.target holds the iterated object for these three
                // classes. STRING_ITERATOR uses extra.prim instead.
                if ((*obj.extra_ptr()).iter.target != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter.target);
                }
                break;
            case ObjClass.STRING_ITERATOR:
                self.mark_tval(&(*obj.extra_ptr()).prim.primitive_value);
                break;
            case ObjClass.REGEXP_STRING_ITERATOR:
                self.mark_tval(&(*obj.extra_ptr()).regexp_iter.string_val);
                if ((*obj.extra_ptr()).regexp_iter.regexp != null) {
                    self.mark_hobject((*obj.extra_ptr()).regexp_iter.regexp);
                }
                break;
            case ObjClass.WRAP_FOR_VALID_ITERATOR:
                if ((*obj.extra_ptr()).wrap_iter.iterated != null) {
                    self.mark_hobject((*obj.extra_ptr()).wrap_iter.iterated);
                }
                self.mark_tval(&(*obj.extra_ptr()).wrap_iter.next_method);
                break;
            case ObjClass.ITERATOR_HELPER:
                if ((*obj.extra_ptr()).iter_helper.underlying != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter_helper.underlying);
                }
                self.mark_tval(&(*obj.extra_ptr()).iter_helper.next_method);
                self.mark_tval(&(*obj.extra_ptr()).iter_helper.callback);
                if ((*obj.extra_ptr()).iter_helper.inner_iter != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter_helper.inner_iter);
                }
                self.mark_tval(&(*obj.extra_ptr()).iter_helper.inner_next);
                break;
            case ObjClass.GETTER_SETTER:
                self.mark_tval(&(*obj.extra_ptr()).gs.getter);
                self.mark_tval(&(*obj.extra_ptr()).gs.setter);
                break;
            case ObjClass.ERROR:
                self.mark_tval(&(*obj.extra_ptr()).err.captured_stack);
                break;
            default:
                break;
        }

    }
}

/**
 * Mark every GC root: the registered roots, built-in prototypes, the VM value
 * stack, and the string references found along the way. Transitive marking runs
 * through the gray stack, so there is no recursion or depth limit.
 */
fn void Heap.mark_roots(&self) {
    for (uint i = 0; i < self.gc_root_count; i++) {
        HeapHeader* hdr = (HeapHeader*)self.gc_roots[i];
        if (hdr != null) {
            if (hdr.is_object()) {
                self.mark_hobject((HObject*)hdr);
            } else {
                hdr.set_reachable();
            }
        }
    }

    // Values the C ABI's host holds handles to.
    if (self.capi_mark != null) self.capi_mark(self.capi_roots);

    // Built-in error prototypes.
    if (self.err_proto != null) { self.mark_hobject(self.err_proto); }
    if (self.type_err_proto != null) { self.mark_hobject(self.type_err_proto); }
    if (self.range_err_proto != null) { self.mark_hobject(self.range_err_proto); }
    if (self.ref_err_proto != null) { self.mark_hobject(self.ref_err_proto); }
    if (self.syntax_err_proto != null) { self.mark_hobject(self.syntax_err_proto); }
    if (self.eval_err_proto != null) { self.mark_hobject(self.eval_err_proto); }
    if (self.uri_err_proto != null) { self.mark_hobject(self.uri_err_proto); }
    if (self.aggregate_err_proto != null) { self.mark_hobject(self.aggregate_err_proto); }

    // Built-in constructor prototypes and intrinsics.
    if (self.object_proto != null) { self.mark_hobject(self.object_proto); }
    if (self.array_proto != null) { self.mark_hobject(self.array_proto); }
    if (self.function_proto != null) { self.mark_hobject(self.function_proto); }
    if (self.string_proto != null) { self.mark_hobject(self.string_proto); }
    if (self.number_proto != null) { self.mark_hobject(self.number_proto); }
    if (self.bool_proto != null) { self.mark_hobject(self.bool_proto); }
    if (self.date_proto != null) { self.mark_hobject(self.date_proto); }
    if (self.regexp_proto != null) { self.mark_hobject(self.regexp_proto); }
    if (self.map_proto != null) { self.mark_hobject(self.map_proto); }
    if (self.set_proto != null) { self.mark_hobject(self.set_proto); }
    if (self.weakmap_proto != null) { self.mark_hobject(self.weakmap_proto); }
    if (self.weakset_proto != null) { self.mark_hobject(self.weakset_proto); }
    if (self.weakref_proto != null) { self.mark_hobject(self.weakref_proto); }
    if (self.finalization_registry_proto != null) { self.mark_hobject(self.finalization_registry_proto); }
    if (self.symbol_proto != null) { self.mark_hobject(self.symbol_proto); }
    if (self.bigint_proto != null) { self.mark_hobject(self.bigint_proto); }
    if (self.promise_proto != null) { self.mark_hobject(self.promise_proto); }
    if (self.promise_ctor != null)  { self.mark_hobject(self.promise_ctor); }
    if (self.function_ctor != null) { self.mark_hobject(self.function_ctor); }
    if (self.generator_proto != null) { self.mark_hobject(self.generator_proto); }
    if (self.generator_func_proto != null) { self.mark_hobject(self.generator_func_proto); }
    if (self.async_func_proto != null) { self.mark_hobject(self.async_func_proto); }
    if (self.iterator_proto != null) { self.mark_hobject(self.iterator_proto); }
    if (self.iterator_ctor != null) { self.mark_hobject(self.iterator_ctor); }
    if (self.iterator_helper_proto != null) { self.mark_hobject(self.iterator_helper_proto); }
    if (self.wrap_for_valid_iterator_proto != null) { self.mark_hobject(self.wrap_for_valid_iterator_proto); }
    if (self.async_from_sync_iter_proto != null) { self.mark_hobject(self.async_from_sync_iter_proto); }
    if (self.async_iterator_proto != null) { self.mark_hobject(self.async_iterator_proto); }
    if (self.async_generator_proto != null) { self.mark_hobject(self.async_generator_proto); }
    if (self.async_generator_func_proto != null) { self.mark_hobject(self.async_generator_func_proto); }
    if (self.array_iterator_proto != null) { self.mark_hobject(self.array_iterator_proto); }
    if (self.map_iterator_proto != null) { self.mark_hobject(self.map_iterator_proto); }
    if (self.set_iterator_proto != null) { self.mark_hobject(self.set_iterator_proto); }
    if (self.string_iterator_proto != null) { self.mark_hobject(self.string_iterator_proto); }
    if (self.regexp_string_iterator_proto != null) { self.mark_hobject(self.regexp_string_iterator_proto); }
    if (self.typedarray_proto != null) { self.mark_hobject(self.typedarray_proto); }
    if (self.typedarray_intrinsic != null) { self.mark_hobject(self.typedarray_intrinsic); }
    if (self.uint8array_proto != null) { self.mark_hobject(self.uint8array_proto); }
    if (self.arraybuffer_proto != null) { self.mark_hobject(self.arraybuffer_proto); }
    if (self.sharedarraybuffer_proto != null) { self.mark_hobject(self.sharedarraybuffer_proto); }
    if (self.dataview_proto != null) { self.mark_hobject(self.dataview_proto); }

    // Every live slot on the VM value stack, from base to top, can reference a
    // heap object or string.
    if (self.valstack_base != null && self.valstack_top_ptr != null) {
        TVal* top = *self.valstack_top_ptr;
        TVal* scan = self.valstack_base;
        while (scan < top) {
            self.mark_tval(scan);
            scan++;
        }
    }

    // A queued promise job holds its handler, argument, and downstream promise
    // until the drain. None of those sit on the VM stack, so each live triplet
    // is marked here.
    if (self.microtask_queue != null) {
        uint queued_values = self.microtask_count * 3;
        for (uint i = 0; i < queued_values; i++) {
            self.mark_tval(&self.microtask_queue[i]);
        }
    }

    // Atomics.waitAsync waiters keep their parked buffer + pending promise alive.
    for (uint i = 0; i < self.async_waiter_count; i++) {
        if (self.async_waiters[i].active) {
            if (self.async_waiters[i].buffer != null) self.mark_hobject(self.async_waiters[i].buffer);
            if (self.async_waiters[i].promise != null) self.mark_hobject(self.async_waiters[i].promise);
        }
    }

    for (uint i = 0; i < self.symbol_registry_count; i++) {
        HString* key = self.symbol_registry_keys[i];
        HString* sym = self.symbol_registry_syms[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
        if (sym != null) { ((HeapHeader*)sym).set_reachable(); }
    }

    for (uint i = 0; i < STRS_CACHE_SIZE; i++) {
        HString* s = (HString*)self.strs[i];
        if (s != null) {
            ((HeapHeader*)s).set_reachable();
        }
    }

    // CompiledFunctions live in their own tracking array rather than the GC
    // heap, so the strings and objects their constant pools and inline caches
    // reference are rooted here.
    for (uint fi = 0; fi < self.compiled_func_count; fi++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[fi];
        if (cf == null || cf.constants == null) { continue; }
        for (uint ci = 0; ci < cf.const_count; ci++) {
            self.mark_tval(&cf.constants[ci]);
        }
        // Property IC entries cache a proto object and a key string.
        if (cf.ic_entries != null && cf.ic_count > 0) {
            hobject::ICEntry* ics = (hobject::ICEntry*)cf.ic_entries;
            for (uint ii = 0; ii < cf.ic_count; ii++) {
                hobject::ICEntry* ie = &ics[ii];
                if (ie.key != null) { ((HeapHeader*)ie.key).set_reachable(); }
                if (ie.proto != null) { self.mark_hobject((HObject*)ie.proto); }
            }
        }
        // Variable IC entries cache a bindings object and a key string.
        if (cf.var_ic_entries != null && cf.var_ic_count > 0) {
            hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
            for (uint vi = 0; vi < cf.var_ic_count; vi++) {
                hobject::VarICEntry* vie = &vics[vi];
                if (vie.key != null) { ((HeapHeader*)vie.key).set_reachable(); }
                if (vie.bindings != null) { self.mark_hobject((HObject*)vie.bindings); }
            }
        }
    }

    // Cached well-known symbols. They appear in neither strs[] nor the symbol
    // registry, so this is the only place that roots them.
    if (self.iterator_symbol != null)        { ((HeapHeader*)self.iterator_symbol).set_reachable(); }
    if (self.tostringtag_symbol != null)     { ((HeapHeader*)self.tostringtag_symbol).set_reachable(); }
    if (self.toprimitive_symbol != null)     { ((HeapHeader*)self.toprimitive_symbol).set_reachable(); }
    if (self.concatspreadable_symbol != null){ ((HeapHeader*)self.concatspreadable_symbol).set_reachable(); }
    if (self.hasinstance_symbol != null)     { ((HeapHeader*)self.hasinstance_symbol).set_reachable(); }
    if (self.match_symbol != null)           { ((HeapHeader*)self.match_symbol).set_reachable(); }
    if (self.search_symbol != null)          { ((HeapHeader*)self.search_symbol).set_reachable(); }
    if (self.replace_symbol != null)         { ((HeapHeader*)self.replace_symbol).set_reachable(); }
    if (self.split_symbol != null)           { ((HeapHeader*)self.split_symbol).set_reachable(); }
    if (self.species_symbol != null)         { ((HeapHeader*)self.species_symbol).set_reachable(); }
    if (self.unscopables_symbol != null)     { ((HeapHeader*)self.unscopables_symbol).set_reachable(); }
    if (self.matchall_symbol != null)        { ((HeapHeader*)self.matchall_symbol).set_reachable(); }
    if (self.asynciterator_symbol != null)   { ((HeapHeader*)self.asynciterator_symbol).set_reachable(); }

    for (uint i = 0; i < self.checkpoint_count; i++) {
        HString* key = (HString*)self.checkpoint_keys[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
    }

    // Per-call activation envs, which nothing else roots.
    if (self.mark_activations_fn != null && self.curr_thread != null) {
        self.mark_activations_fn(self.curr_thread, self);
    }

    // In-flight error and generator state held directly on the heap.
    self.mark_tval(&self.error_value);
    self.mark_tval(&self.yield_value);
    self.mark_generator_state(self.resume_gen);
    self.mark_generator_state(self.gen_initial_gs);

    // While param-init runs, the generator object under construction is not yet
    // in any register or stack slot, so this field is its only root.
    if (self.gen_initial_obj != null) {
        self.mark_hobject((HObject*)self.gen_initial_obj);
    }
    // Outer generators whose param-init is paused on an inner generator call.
    for (uint gsi = 0; gsi < self.gen_init_stack_depth; gsi++) {
        if (self.gen_init_stack_obj[gsi] != null) {
            self.mark_hobject((HObject*)self.gen_init_stack_obj[gsi]);
        }
    }

    // ModuleDefs are in a malloc'd cache the sweep never scans, so the values
    // they hold are rooted here. `eval_error` is an ERRORED module's cached
    // [[EvaluationError]], re-rejected on every later import, and `json_value`
    // is a JSON module's default export.
    if (self.module_cache != null) {
        esm::ModuleDef** cache = (esm::ModuleDef**)self.module_cache;
        for (uint i = 0; i < self.module_cache_count; i++) {
            esm::ModuleDef* mod = cache[i];
            if (mod == null) continue;
            if (mod.has_eval_error) { self.mark_tval(&mod.eval_error); }
            if (mod.is_json)        { self.mark_tval(&mod.json_value); }
            // The cached import.meta object (§16.2.1.10 [[ImportMeta]]) carries
            // user-visible state such as added properties and a changed
            // prototype, and lives as long as the module.
            if (mod.import_meta_obj != null) { self.mark_hobject(mod.import_meta_obj); }
        }
    }

    self.drain_gray();
}

// ============================================================================
// Heap verification, built only with `-D HEAP_VERIFY`
// ============================================================================

/// Check that a HeapHeader is live and carries a valid htype. Objects and
/// buffers are looked up by walking `heap_allocated`, which is O(n). Strings,
/// symbols included, are checked by htype alone, since not all of them are in
/// str_table. Returns false and writes a diagnostic to stderr on failure.
fn bool Heap.validate_hobject(&self, HeapHeader* hdr, ZString where) {
$if $feature(HEAP_VERIFY):
    if (hdr == null) {
        io::eprintf("[HEAP_VERIFY]   ERROR at %s: null pointer\n", where);
        return false;
    }

    HType ht = hdr.get_type();
    if (ht != HType.OBJECT && ht != HType.STRING && ht != HType.BUFFER) {
        io::eprintf("[HEAP_VERIFY]   ERROR at %s: invalid htype %d for pointer %p\n",
                    where, (int)ht, hdr);
        return false;
    }

    // Strings and symbols come from alloc_no_gc and are not always in
    // str_table, so htype is all that can be checked.
    if (ht == HType.STRING) {
        return true;
    }

    HeapHeader* walk = self.heap_allocated;
    while (walk != null) {
        if (walk == hdr) return true;
        walk = walk.next;
    }

    io::eprintf("[HEAP_VERIFY]   ERROR at %s: pointer %p (htype=%d) not in heap_allocated\n",
                where, hdr, (int)ht);
    return false;
$else
    return true;
$endif
}

/// Validate every heap pointer in a TVal array such as saved_regs, returning
/// the number of errors found.
fn uint Heap.verify_tval_array(&self, TVal* arr, uint count, ZString context) {
$if $feature(HEAP_VERIFY):
    uint errors = 0;
    for (uint i = 0; i < count; i++) {
        TVal* tv = &arr[i];
        if (tv.is_object()) {
            HObject* obj = (HObject*)tv.get_heapptr();
            if (obj != null && !self.validate_hobject((HeapHeader*)obj, context)) {
                errors++;
            }
        } else if (tv.is_string()) {
            HString* s = (HString*)tv.get_heapptr();
            if (s != null && !self.validate_hobject((HeapHeader*)s, context)) {
                errors++;
            }
        } else if (tv.is_buffer()) {
            void* buf = tv.get_heapptr();
            if (buf != null && !self.validate_hobject((HeapHeader*)buf, context)) {
                errors++;
            }
        }
    }
    return errors;
$else
    return 0;
$endif
}

/// Check that every GC root set points at a live heap object, returning true
/// when all of them do. Built only with `-D HEAP_VERIFY`.
fn bool Heap.verify_roots(&self, ZString context) {
$if $feature(HEAP_VERIFY):
    io::eprintf("[HEAP_VERIFY] %s: checking roots...\n", context);

    uint live_count = 0;
    HeapHeader* h = self.heap_allocated;
    while (h != null) {
        live_count++;
        h = h.next;
    }
    io::eprintf("[HEAP_VERIFY]   live objects: %d\n", (int)live_count);

    uint checked = 0;
    uint errors = 0;

    for (uint i = 0; i < self.gc_root_count; i++) {
        void* root = self.gc_roots[i];
        if (root != null) {
            if (!self.validate_hobject((HeapHeader*)root, "gc_root")) errors++;
            checked++;
        }
    }

    ZString[8] err_names = {
        "err_proto", "type_err_proto", "range_err_proto", "ref_err_proto",
        "syntax_err_proto", "eval_err_proto", "uri_err_proto", "aggregate_err_proto"
    };
    HObject*[8] err_protos = {
        self.err_proto, self.type_err_proto, self.range_err_proto, self.ref_err_proto,
        self.syntax_err_proto, self.eval_err_proto, self.uri_err_proto, self.aggregate_err_proto
    };
    for (uint i = 0; i < 8; i++) {
        if (err_protos[i] != null) {
            if (!self.validate_hobject((HeapHeader*)err_protos[i], err_names[i])) errors++;
            checked++;
        }
    }

    ZString[32] ctor_names = {
        "object_proto", "bool_proto", "string_proto", "number_proto",
        "array_proto", "function_proto", "date_proto", "regexp_proto",
        "map_proto", "set_proto", "weakmap_proto", "weakset_proto",
        "symbol_proto", "bigint_proto", "promise_proto", "generator_proto", "generator_func_proto",
        "async_func_proto",
        "iterator_proto", "array_iterator_proto", "typedarray_proto", "typedarray_intrinsic", "arraybuffer_proto", "dataview_proto",
        "async_from_sync_iter_proto", "iterator_ctor", "iterator_helper_proto", "wrap_for_valid_iterator_proto",
        "map_iterator_proto", "set_iterator_proto", "string_iterator_proto", "regexp_string_iterator_proto"
    };
    HObject*[32] ctor_protos = {
        self.object_proto, self.bool_proto, self.string_proto, self.number_proto,
        self.array_proto, self.function_proto, self.date_proto, self.regexp_proto,
        self.map_proto, self.set_proto, self.weakmap_proto, self.weakset_proto,
        self.symbol_proto, self.bigint_proto, self.promise_proto, self.generator_proto, self.generator_func_proto,
        self.async_func_proto,
        self.iterator_proto, self.array_iterator_proto, self.typedarray_proto, self.typedarray_intrinsic, self.arraybuffer_proto, self.dataview_proto,
        self.async_from_sync_iter_proto, self.iterator_ctor, self.iterator_helper_proto, self.wrap_for_valid_iterator_proto,
        self.map_iterator_proto, self.set_iterator_proto, self.string_iterator_proto, self.regexp_string_iterator_proto
    };
    for (uint i = 0; i < 32; i++) {
        if (ctor_protos[i] != null) {
            if (!self.validate_hobject((HeapHeader*)ctor_protos[i], ctor_names[i])) errors++;
            checked++;
        }
    }

    if (self.valstack_base != null && self.valstack_top_ptr != null) {
        TVal* top = *self.valstack_top_ptr;
        TVal* scan = self.valstack_base;
        while (scan < top) {
            if (scan.is_object()) {
                HObject* obj = (HObject*)scan.get_heapptr();
                if (obj != null) {
                    if (!self.validate_hobject((HeapHeader*)obj, "valstack")) errors++;
                    checked++;
                }
            } else if (scan.is_string()) {
                HString* s = (HString*)scan.get_heapptr();
                if (s != null) {
                    if (!self.validate_hobject((HeapHeader*)s, "valstack")) errors++;
                    checked++;
                }
            } else if (scan.is_buffer()) {
                void* buf = scan.get_heapptr();
                if (buf != null) {
                    if (!self.validate_hobject((HeapHeader*)buf, "valstack")) errors++;
                    checked++;
                }
            }
            scan++;
        }
    }

    for (uint i = 0; i < self.symbol_registry_count; i++) {
        HString* key = self.symbol_registry_keys[i];
        HString* sym = self.symbol_registry_syms[i];
        if (key != null) {
            if (!self.validate_hobject((HeapHeader*)key, "symbol_registry_key")) errors++;
            checked++;
        }
        if (sym != null) {
            if (!self.validate_hobject((HeapHeader*)sym, "symbol_registry_sym")) errors++;
            checked++;
        }
    }

    for (uint i = 0; i < STRS_CACHE_SIZE; i++) {
        HString* s = (HString*)self.strs[i];
        if (s != null) {
            if (!self.validate_hobject((HeapHeader*)s, "strs_cache")) errors++;
            checked++;
        }
    }

    HString*[12] cached_syms = {
        self.iterator_symbol, self.toprimitive_symbol,
        self.concatspreadable_symbol, self.hasinstance_symbol,
        self.match_symbol, self.search_symbol,
        self.replace_symbol, self.split_symbol,
        self.species_symbol, self.unscopables_symbol,
        self.matchall_symbol, self.asynciterator_symbol
    };
    ZString[12] cached_sym_names = {
        "iterator_symbol", "toprimitive_symbol",
        "concatspreadable_symbol", "hasinstance_symbol",
        "match_symbol", "search_symbol",
        "replace_symbol", "split_symbol",
        "species_symbol", "unscopables_symbol",
        "matchall_symbol", "asynciterator_symbol"
    };
    for (uint i = 0; i < 12; i++) {
        if (cached_syms[i] != null) {
            if (!self.validate_hobject((HeapHeader*)cached_syms[i], cached_sym_names[i])) errors++;
            checked++;
        }
    }

    for (uint i = 0; i < self.checkpoint_count; i++) {
        HString* key = (HString*)self.checkpoint_keys[i];
        if (key != null) {
            if (!self.validate_hobject((HeapHeader*)key, "checkpoint_key")) errors++;
            checked++;
        }
    }

    // Generator saved_regs, found by walking the heap for GENERATOR objects.
    HeapHeader* gen_walk = self.heap_allocated;
    uint gen_count = 0;
    while (gen_walk != null) {
        if (gen_walk.is_object()) {
            HObject* gen_obj = (HObject*)gen_walk;
            if (gen_obj.flags.obj_class == ObjClass.GENERATOR) {
                GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
                if (gs != null && gs.saved_regs != null && gs.num_regs > 0) {
                    gen_count++;
                    uint gs_errors = self.verify_tval_array(gs.saved_regs, gs.num_regs, "gen_saved_regs");
                    if (gs_errors > 0) {
                        io::eprintf("[HEAP_VERIFY]   generator %p: %d saved_regs errors\n", gen_obj, (int)gs_errors);
                        errors += gs_errors;
                    }
                    checked += gs.num_regs;
                }
            }
        }
        gen_walk = gen_walk.next;
    }
    io::eprintf("[HEAP_VERIFY]   generators checked: %d\n", (int)gen_count);

    io::eprintf("[HEAP_VERIFY]   checked: %d, errors: %d\n", (int)checked, (int)errors);
    if (errors > 0) {
        io::eprintf("[HEAP_VERIFY]   *** VERIFICATION FAILED ***\n");
    }
    return errors == 0;
$else
    return true;
$endif
}

/// Report whether any suspended generator's saved_regs still references `ptr`,
/// which would make freeing it leave a dangling pointer. The sweep calls this
/// before freeing an object.
fn bool Heap.is_in_generator_saved_regs(&self, HeapHeader* ptr) {
$if $feature(HEAP_VERIFY):
    HeapHeader* walk = self.heap_allocated;
    while (walk != null) {
        if (walk.is_object()) {
            HObject* obj = (HObject*)walk;
            if (obj.flags.obj_class == ObjClass.GENERATOR) {
                GeneratorState* gs = (GeneratorState*)(*obj.extra_ptr()).gen.generator_data;
                if (gs != null && gs.saved_regs != null) {
                    for (uint i = 0; i < gs.num_regs; i++) {
                        TVal* tv = &gs.saved_regs[i];
                        if (tv.is_object() || tv.is_string() || tv.is_buffer()) {
                            void* hp = tv.get_heapptr();
                            if (hp == (void*)ptr) {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        walk = walk.next;
    }
    return false;
$else
    return false;
$endif
}

// ============================================================================
// GC sweep
// ============================================================================

/**
 * Walk heap_allocated, unlink and free everything the mark phase did not reach,
 * and clear the reachable flag on the survivors ready for the next cycle.
 *
 * The work runs in three phases so that a dying object's teardown can never
 * read or re-free a sibling this same sweep is also collecting.
 */
fn void Heap.sweep(&self) {
    // In sweep mode, decref() skips references into unmarked nodes, so freeing
    // one garbage object cannot follow a link into a sibling that is already
    // gone. Survivors hold their reachable bit for the whole free pass to keep
    // the "unmarked means dying" test reliable, and a later pass clears it.
    self.sweeping = true;

    // Phase A: unlink every dying node, meaning unmarked and not a temproot,
    // and thread it onto a local list through its now-unused .next pointer.
    // Nothing is freed yet, so every dying header and mark bit stays readable
    // through phases B and C.
    HeapHeader* cur = self.heap_allocated;
    HeapHeader* prev = null;
    HeapHeader* dying = null;
    uint kept = 0;

    while (cur != null) {
        HeapHeader* next = cur.next;
        if (!cur.is_reachable() && !cur.is_temproot()) {
            if (prev != null) {
                prev.next = next;
            } else {
                self.heap_allocated = next;
            }
            if (next != null) {
                next.prev = prev;
            }
            $if $feature(HEAP_VERIFY):
                if (self.is_in_generator_saved_regs(cur)) {
                    io::eprintf("[HEAP_VERIFY]   SWEEP WARNING: freeing %p (htype=%d) which is in a generator's saved_regs!\n",
                                cur, (int)cur.get_type());
                }
            $endif
            // The node is off the live list, so .next can thread the dying list.
            cur.next = dying;
            dying = cur;
        } else {
            // A survivor: either reachable, or an unmarked temproot being kept.
            // Its reachable bit stays set until the free pass ends so decref's
            // dying test holds for nodes freed later.
            prev = cur;
            kept++;
        }
        cur = next;
    }

    // Phase B: run each dying node's teardown while all of that memory is still
    // valid. hobject_free can decref neighbours it references, and the sweep
    // guard in decref skips any neighbour that is itself dying, so nothing is
    // read or freed twice.
    for (HeapHeader* d = dying; d != null; d = d.next) {
        if (d.is_object()) {
            hobject::hobject_free((HObject*)d, (void*)self, false);
        }
    }

    // Phase C: release each dying node's header memory. Doing this last means no
    // phase B teardown could have touched already-freed memory.
    HeapHeader* d = dying;
    while (d != null) {
        HeapHeader* dnext = d.next;
        if (d.is_object()) {
            hobject::hobject_free_header((HObject*)d, (void*)self);
        } else {
            // A BigInt box or other non-object leaf.
            self.free_func(self.heap_udata, d);
        }
        d = dnext;
    }

    // With the free pass over, reset the survivors for the next cycle. Reachable
    // ones clear both bits. Nodes kept only by their temproot flag hold onto it
    // and stay protected until something anchors them.
    for (HeapHeader* s = self.heap_allocated; s != null; s = s.next) {
        if (s.is_reachable()) {
            s.clear_reachable();
            s.clear_temproot();
        }
    }

    self.sweeping = false;
    self.live_obj_count = kept;
}

/**
 * Free interned strings that only the string table still holds, replacing their
 * slots with tombstones, then shrink the table if it has emptied out.
 *
 * Runs under the same condition as sweep_large_strings: only at a safe point
 * where no raw HString* is live in a C3 local. See mark_and_sweep phase 3b.
 */
fn void Heap.sweep_strings(&self) {
    if (self.str_table_size == 0) { return; }
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) { continue; }
        // A refcount of 1 does not prove the string is dead, because property
        // tables and IC entries hold keys without taking a reference and rely on
        // the table to keep them alive. Reachability decides it: drain_gray
        // marks the keys of live objects.
        if (entry.refcount == 1 && !((HeapHeader*)entry).is_reachable()) {
            self.str_table[i] = STR_TABLE_TOMBSTONE;
            if (self.str_table_used > 0) { self.str_table_used--; }
            self.free_string(entry);
        }
    }

    if (self.str_table_used < self.str_table_size / 4 && self.str_table_size > INITIAL_STR_TABLE_SIZE) {
        self.str_table_shrink();
    }
}

/**
 * Free every registered large string the mark phase did not reach.
 *
 * The registry is a weak list holding no reference of its own, so no refcount
 * value means "only the registry is left" the way it does for the string table.
 * Reachability is the whole test: mark_tval marks any large string a live
 * register, property, or stack slot references, so an unmarked one is
 * unreferenced whatever its refcount says. That makes this pass a backstop for a
 * refcount that was never decremented.
 *
 * Runs under the same condition as sweep_strings: only at a safe point where no
 * raw HString* is live in a C3 local. See mark_and_sweep phase 3b.
 */
fn void Heap.sweep_large_strings(&self) {
    uint kept = 0;
    for (uint i = 0; i < self.large_string_count; i++) {
        HString* s = self.large_strings[i];
        if (((HeapHeader*)s).is_reachable()) {
            // Survivors compact downward, carrying their recorded slot along.
            self.large_strings[kept] = s;
            s.registry_slot = kept;
            kept++;
        } else {
            self.free_string(s);
        }
    }
    self.large_string_count = kept;
}

/**
 * Run a full mark-and-sweep garbage collection.
 *
 * 1. Clear all reachable flags.
 * 2. Mark all reachable objects starting from roots (built-in prototypes,
 *    registered GC roots, and the string table).
 * 3. Sweep unmarked (unreachable) objects, freeing their memory.
 * 4. Reset the GC trigger counter based on the new live-object count.
 *
 * The gc_running guard makes this non-re-entrant.
 *
 * With `safepoint` true, phase 1 also clears temproot flags so newly allocated
 * objects become collectable. A collection outside a safepoint keeps temproots
 * so in-flight allocations survive.
 *
 * Clearing temproots is only safe when no native builtin frame sits on the C3
 * stack. A builtin that allocates a result and then re-enters the VM, for a user
 * callback, a getter, or a species constructor, holds that object in a raw local
 * the mark phase cannot see, even though the nested execution reaches VM
 * safepoints. native_frame_depth therefore vetoes the clear.
 */
fn void Heap.mark_and_sweep(&self, bool safepoint) {
    if (self.gc_running) { return; }
    self.gc_running = true;

    bool clear_temproots = safepoint && self.native_frame_depth == 0;

    // Phase 1: clear reachable flags, and temproots when allowed.
    {
        HeapHeader* cur = self.heap_allocated;
        while (cur != null) {
            cur.clear_reachable();
            if (clear_temproots) {
                cur.clear_temproot();
            }
            cur = cur.next;
        }
        // Interned strings are not on the heap_allocated list, so their marks
        // clear through the string table and sweep_strings sees fresh bits.
        for (uint i = 0; i < self.str_table_size; i++) {
            HString* s = self.str_table[i];
            if (s != null && s != STR_TABLE_TOMBSTONE) {
                ((HeapHeader*)s).clear_reachable();
            }
        }
        // Large strings are in neither list, so the registry clears theirs.
        for (uint i = 0; i < self.large_string_count; i++) {
            ((HeapHeader*)self.large_strings[i]).clear_reachable();
        }
    }

    // Phase 2: mark from the roots.
    self.mark_roots();

    // Phase 3: sweep objects.
    self.sweep();

    // Phase 3b: sweep unreachable strings, only where the caller guarantees no
    // raw interned-string pointer is live. Any allocation can trigger a GC,
    // including one made while builtin init or an opcode holds a freshly
    // interned HString* in a local that nothing roots, such as between
    // str_intern and put_prop. Sweeping then would free that in-flight string.
    if (self.string_sweep_safe) {
        self.sweep_strings();
        self.sweep_large_strings();
    }

    // Phase 4: scale the next trigger to the surviving heap. Under GC_STRESS the
    // trigger stops scaling, so the next allocation collects again and every
    // value that survives an allocating call has to be a real GC root rather
    // than merely lucky. See the gc-stress target and `just test-gc-stress`.
$if $feature(GC_STRESS):
    long new_trigger = 1;
$else
    long new_trigger = (long)self.live_obj_count * GC_TRIGGER_GROW_FACTOR;
    if (new_trigger < GC_INITIAL_TRIGGER) {
        new_trigger = GC_INITIAL_TRIGGER;
    }
$endif
    self.gc_trigger_counter = new_trigger;
    self.gc_running = false;
}

/**
 * Collect outside a safepoint, keeping temproots so in-flight allocations
 * survive.
 */
fn void Heap.trigger_gc(&self) {
    self.mark_and_sweep(false);
}

/**
 * Collect at a VM safe point. With no native builtin frame active, every live
 * value is anchored in a register, an environment, or an object graph, so the
 * temproot flags can clear and the string tables can be swept.
 *
 * A safepoint reached inside a builtin's nested VM execution is not that quiet,
 * since the builtin's own locals may hold an unrooted object or interned string.
 * Both reclamation passes are suppressed while native_frame_depth is non-zero.
 * The collection still runs and still reclaims whatever the mark phase proves
 * dead.
 */
fn void Heap.safepoint_gc(&self) {
    bool quiescent = self.native_frame_depth == 0;
    self.string_sweep_safe = quiescent;
    self.mark_and_sweep(true);
    self.string_sweep_safe = false;
    self.gc_pending = false;
}

// ============================================================================
// String hashing (FNV-1a, 32-bit)
// ============================================================================

const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
const uint FNV1A_PRIME        = 0x0100_0193;

/**
 * Compute a 32-bit FNV-1a hash of `data`, mixing in the heap's seed so hash
 * collisions cannot be predicted from outside.
 */
fn uint Heap.hash_string(&self, char[] data) {
    uint h = FNV1A_OFFSET_BASIS ^ self.hash_seed;
    foreach (b : data) {
        h ^= (uint)b;
        h *= FNV1A_PRIME;
    }
    return h;
}

// ============================================================================
// String table (open-addressing, linear probing)
// ============================================================================

/**
 * Double the string table once the load factor is exceeded, rehashing every live
 * entry into the new one.
 */
fn void*? Heap.str_table_grow(&self) {
    uint new_size = self.str_table_size * 2;
    if (new_size < INITIAL_STR_TABLE_SIZE) {
        new_size = INITIAL_STR_TABLE_SIZE;
    }

    usz new_bytes = HString*::size * new_size;
    void* raw = self.alloc_func(self.heap_udata, new_bytes);
    if (raw == null) {
        return HEAP_ALLOC_FAULT~;
    }
    mem::clear(raw, (sz)(new_bytes));

    HString** new_table = (HString**)raw;

    // Rehash existing entries
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) { continue; }

        uint idx = entry.hash & (new_size - 1);
        while (new_table[idx] != null) {
            idx = (idx + 1) & (new_size - 1);
        }
        new_table[idx] = entry;
    }

    // Free old table, swap in the new one
    self.free_func(self.heap_udata, self.str_table);
    self.str_table      = new_table;
    self.str_table_size = new_size;

    return raw;  // non-null signals success
}

/**
 * Shrink the string table by half, rehashing all live entries.
 */
fn void Heap.str_table_shrink(&self) {
    uint new_size = self.str_table_size / 2;
    if (new_size < INITIAL_STR_TABLE_SIZE) {
        new_size = INITIAL_STR_TABLE_SIZE;
    }

    usz new_bytes = HString*::size * new_size;
    void* raw = self.alloc_func(self.heap_udata, new_bytes);
    if (raw == null) { return; }
    mem::clear(raw, (sz)(new_bytes));

    HString** new_table = (HString**)raw;

    // Rehash existing entries
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) { continue; }

        uint idx = entry.hash & (new_size - 1);
        while (new_table[idx] != null) {
            idx = (idx + 1) & (new_size - 1);
        }
        new_table[idx] = entry;
    }

    // Replace old table
    self.free_func(self.heap_udata, self.str_table);
    self.str_table = new_table;
    self.str_table_size = new_size;
}

/**
 * Look up an interned string by byte content and precomputed hash, returning
 * null when the table does not hold it.
 */
fn HString* Heap.str_table_lookup(&self, char[] data, uint hash) {
    if (self.str_table_size == 0) { return null; }

    uint idx = hash & (self.str_table_size - 1);

    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null) {
            return null;  // an empty slot ends the probe chain
        }
        if (entry == STR_TABLE_TOMBSTONE) {
            idx = (idx + 1) & (self.str_table_size - 1);
            continue;  // a deleted slot does not
        }

        if (entry.hash == hash && entry.blen == (uint)data.len) {
            if (entry.equals(data)) {
                return entry;
            }
        }

        idx = (idx + 1) & (self.str_table_size - 1);
    }
    return null;
}

/**
 * Insert an HString with its .hash already set, growing the table first if the
 * load factor demands it.
 *
 * Taking a slot makes the table an owner: the string is marked interned and
 * increfed for the table's reference, which str_table_remove and the reset and
 * destroy sweeps release. A string that gets no slot remains un-interned under
 * plain refcounting, and the caller must register it as a large string to keep
 * it reachable for teardown.
 */
fn bool Heap.str_table_insert(&self, HString* hstr) {
    float load = (float)(self.str_table_used + 1) / (float)self.str_table_size;
    if (load > STR_TABLE_LOAD_FACTOR) {
        // A failed grow only costs longer probe chains, so the insert continues
        // into the existing table.
        void* ignored = self.str_table_grow() ?? null;
    }

    uint idx = hstr.hash & (self.str_table_size - 1);
    uint first_tombstone = self.str_table_size;  // out-of-range means none seen yet
    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) {
            if (entry == STR_TABLE_TOMBSTONE && first_tombstone == self.str_table_size) {
                first_tombstone = idx;
            }
            if (entry == null) {
                // Reusing an earlier tombstone keeps probe chains short.
                uint use = (first_tombstone < self.str_table_size) ? first_tombstone : idx;
                self.str_table[use] = hstr;
                self.str_table_used++;
                self.str_table_adopt(hstr);
                return true;
            }
        }
        idx = (idx + 1) & (self.str_table_size - 1);
    }
    // Table is full but we found a tombstone: reuse it.
    if (first_tombstone < self.str_table_size) {
        self.str_table[first_tombstone] = hstr;
        self.str_table_used++;
        self.str_table_adopt(hstr);
        return true;
    }
    return false;
}

/**
 * Take the string table's ownership reference on a freshly inserted string:
 * mark it interned so `decref` unhooks it from the table (not the large-string
 * registry) and incref for the slot the table now holds.
 */
fn void Heap.str_table_adopt(&self, HString* hstr) @local {
    hstr.flags.is_interned = true;
    ((HeapHeader*)hstr).incref();
}

/**
 * Remove an interned string from the table by pointer identity.
 * Sets the slot to a tombstone so probe chains remain intact.
 */
fn void Heap.str_table_remove(&self, hstring::HString* hstr) {
    if (self.str_table_size == 0) { return; }
    uint idx = hstr.hash & (self.str_table_size - 1);
    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null) { return; }
        if (entry == hstr) {
            self.str_table[idx] = STR_TABLE_TOMBSTONE;
            if (self.str_table_used > 0) { self.str_table_used--; }
            return;
        }
        idx = (idx + 1) & (self.str_table_size - 1);
    }
}

/**
 * Append a non-interned string to the large-string registry.
 *
 * The string records its own slot so `large_string_unregister` can drop it
 * in O(1).  A failed grow leaves the string unregistered: it stays a pure
 * refcounted leaf, so the caller need not fail.
 */
fn void Heap.large_string_register(&self, HString* s) {
    if (self.large_string_count == self.large_string_capacity) {
        uint new_cap = self.large_string_capacity == 0 ? 64 : self.large_string_capacity * 2;
        void* grown = self.realloc_func(self.heap_udata, self.large_strings,
                                        HString*::size * (usz)new_cap);
        if (grown == null) { return; }
        self.large_strings         = (HString**)grown;
        self.large_string_capacity = new_cap;
    }
    s.registry_slot = self.large_string_count;
    self.large_strings[self.large_string_count] = s;
    self.large_string_count++;
}

/**
 * Remove a non-interned string from the registry by its recorded slot,
 * moving the last entry into the vacated slot and fixing up its index.
 */
fn void Heap.large_string_unregister(&self, HString* s) {
    uint slot = s.registry_slot;
    if (slot >= self.large_string_count) { return; }
    uint last = self.large_string_count - 1;
    if (slot != last) {
        HString* moved = self.large_strings[last];
        self.large_strings[slot] = moved;
        moved.registry_slot = slot;
    }
    self.large_string_count = last;
    s.registry_slot = hstring::REGISTRY_SLOT_NONE;
}

/// Intern an HString on demand. An already-interned string comes back
/// unchanged; otherwise a lookup by content may find an existing copy, and
/// failing that this string is inserted. Property lookup calls this when a
/// non-interned concatenation result is used as a key.
fn HString* Heap.ensure_interned(&self, hstring::HString* s) {
    if (s.flags.is_interned) return s;
    HString* existing = self.str_table_lookup(s.get_data(), s.hash);
    if (existing != null) return existing;
    // The table owns the string from here on, so it must leave the registry or
    // the sweep would free it behind the table's back. If the table cannot take
    // it, the registry takes it back so it still has an owner.
    self.large_string_unregister(s);
    if (!self.str_table_insert(s)) { self.large_string_register(s); }
    return s;
}

/// Record that a lightfunc's virtual property was deleted. The bit index is
/// fn_idx * 3 + prop_bit, with prop_bit 0 for name, 1 for length, 2 for prototype.
fn void lf_mark_deleted(ulong* bits, uint fn_idx, uint prop_bit) @inline {
    if (fn_idx >= LF_MAX_TRACKED) return;
    uint idx = fn_idx * 3 + prop_bit;
    bits[idx / 64] |= ((ulong)1 << (idx % 64));
}

fn bool lf_is_deleted(ulong* bits, uint fn_idx, uint prop_bit) @inline {
    if (fn_idx >= LF_MAX_TRACKED) return false;
    uint idx = fn_idx * 3 + prop_bit;
    return (bits[idx / 64] & ((ulong)1 << (idx % 64))) != 0;
}

/// Map a lightfunc virtual property name to its prop_bit, or -1 for any other key.
fn int lf_key_to_prop_bit(HString* key) @inline {
    if (key.equals("name")) return 0;
    if (key.equals("length")) return 1;
    if (key.equals("prototype")) return 2;
    return -1;
}

fn HString* Heap.str_intern(&self, char[] data) {
    // Raw 4-byte UTF-8 astral sequences, such as an emoji typed straight into
    // source, become CESU-8 surrogate pairs before the hash and lookup. One
    // logical string can otherwise intern under two byte encodings depending on
    // how the astral character arrived, as a literal, a \u{...} escape, or
    // String.fromCodePoint, which breaks `===` and property-key dedup. Almost no
    // string contains a 4-byte sequence, so the check avoids the scratch buffer.
    if (hstring::has_raw_utf8_astral(data)) {
        usz cap = (usz)data.len + ((usz)data.len / 4) * 2 + 1;
        char* scratch = (char*)alloc::malloc_try(mem, (sz)cap) ?? null;
        if (scratch != null) {
            uint norm_len = hstring::normalize_to_cesu8(data, scratch[:cap]);
            HString* result = self.str_intern_normalized(scratch[:norm_len]);
            mem::free(scratch);
            return result;
        }
    }
    return self.str_intern_normalized(data);
}

/// Intern bytes that are already CESU-8 canonical. Callers whose input has no
/// raw 4-byte UTF-8 sequences, such as pure-ASCII builtin literals or data
/// already put through `normalize_to_cesu8`, can skip the astral scan by
/// calling this directly.
fn HString* Heap.str_intern_normalized(&self, char[] data) {
    uint hash = self.hash_string(data);
    // Strings this long are not used as property keys, symbols, or identifiers.
    // Interning them piles dead strings into the table until the next GC, giving
    // O(n^2) memory growth in string-building loops such as buildString in the
    // test262 regExpUtils harness. A non-interned string is refcounted and so
    // freed promptly.
    if (data.len > MAX_INTERN_BYTES) {
        HString*? new_s = hstring::hstring_alloc(self, data, hash);
        if (try s = new_s) {
            // The registry is what the mark-sweep backstop and heap reset use to
            // reach a string the table does not hold.
            self.large_string_register(s);
            return s;
        }
        return null;
    }
    HString* existing = self.str_table_lookup(data, hash);
    if (existing != null) {
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(self, data, hash);
    if (try s = new_s) {
        // str_table_insert takes the table's owning reference, increfing and
        // marking the string interned. If it cannot, the registry keeps the
        // string reachable for reset and destroy.
        if (!self.str_table_insert(s)) { self.large_string_register(s); }
        return s;
    }
    return null;
}

// ============================================================================
// PRNG (xorshift32)
// ============================================================================

/**
 * Advance the heap's xorshift32 PRNG and return the new state.
 */
fn uint Heap.xorshift32(&self) {
    uint x = self.rnd_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    self.rnd_state = x;
    return x;
}

// ============================================================================
// Microtask queue, the spec's PromiseJobs job queue
// ============================================================================

/// Enqueue a promise reaction job as a (handler, argument, downstream) triple.
/// The queue drains after each top-level script and after vm_call_fn_impl
/// returns from a compiled function.
fn void Heap.enqueue_microtask(&self, TVal handler, TVal arg, TVal downstream) {
    // Grow the queue if the new entry does not fit; each takes 3 TVal slots.
    uint needed = self.microtask_count + 1;
    if (needed > self.microtask_capacity) {
        uint new_cap = self.microtask_capacity == 0 ? 16 : self.microtask_capacity * 2;
        usz new_bytes = (usz)new_cap * TVal::size * 3;
        TVal* new_q = (TVal*)self.realloc_func(self.heap_udata, self.microtask_queue, new_bytes);
        if (new_q == null) { return; }
        mem::clear(new_q + self.microtask_capacity * 3, (sz)((long)(new_cap - self.microtask_capacity) * TVal::size * 3));
        self.microtask_queue = new_q;
        self.microtask_capacity = new_cap;
    }
    uint idx = self.microtask_count * 3;
    self.tval_copy_ref(&self.microtask_queue[idx], &handler);
    self.tval_copy_ref(&self.microtask_queue[idx + 1], &arg);
    self.tval_copy_ref(&self.microtask_queue[idx + 2], &downstream);
    self.microtask_count++;
}

/// Run every queued job, including jobs enqueued while draining, such as when a
/// handler resolves another promise. A re-entrancy guard keeps a nested call
/// from starting a second drain.
fn void Heap.drain_microtasks(&self, void* vm) {
    if (self.microtask_draining) { return; }
    if (self.microtask_count == 0) { return; }
    self.microtask_draining = true;
    defer self.microtask_draining = false;

    // A read cursor walks the queue in FIFO order. Jobs that a handler enqueues
    // append past the cursor and run in this same drain, which is the ordering
    // the spec requires. microtask_count must keep counting the whole queue:
    // resetting it here would let new jobs overwrite the in-flight batch from
    // slot 0 and hide the queued entries from the GC.
    {
        uint i = 0;
        while (i < self.microtask_count) {
            if (self.gc_pending) { self.safepoint_gc(); }
            uint base = i * 3;
            i++;
            TVal handler    = self.microtask_queue[base];
            TVal arg        = self.microtask_queue[base + 1];
            TVal downstream = self.microtask_queue[base + 2];

            TVal result;
            if (self.call_handler_fn != null && vm != null) {
                result = self.call_handler_fn(vm, handler, &arg);
            } else {
                result = arg;
            }

            if (downstream.is_object() && downstream.get_heapptr() != null &&
                self.microtask_after_fn != null && vm != null) {
                self.microtask_after_fn((void*)self, vm, result, downstream);
            }

            // The queue owns one reference to each value until the job has
            // completed. Release those references before advancing.
            self.decref_tval(&self.microtask_queue[base]);
            self.microtask_queue[base].set_undefined();
            self.decref_tval(&self.microtask_queue[base + 1]);
            self.microtask_queue[base + 1].set_undefined();
            self.decref_tval(&self.microtask_queue[base + 2]);
            self.microtask_queue[base + 2].set_undefined();
        }
        self.microtask_count = 0;
    }
}
