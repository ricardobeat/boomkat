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
// Heap management — allocator, GC bookkeeping, string table
// ============================================================================

// --- Allocator callback signatures ----------------------------------------

alias AllocFunc   = fn void*(void* udata, usz size);
alias ReallocFunc = fn void*(void* udata, void* ptr, usz size);
alias FreeFunc    = fn void(void* udata, void* ptr);
alias FatalFunc   = fn void(void* udata, char* msg);

/// Function pointer type for calling a JS handler function from builtins.
/// Takes an opaque VM pointer, the handler TVal, an argument TVal pointer.
/// Returns the result TVal.
alias VmCallHandlerFn = fn TVal(void* vm, TVal handler, TVal* arg);
/// Callback to mark activation-record env bindings during GC mark phase.
alias MarkActivationsFn = fn void(void* vm, void* heap);

/// Callback invoked after a microtask handler completes.  Receives the heap,
/// VM, handler return value, and the downstream promise to resolve.
alias MicrotaskAfterFn = fn void(void* heap, void* vm, TVal result, TVal downstream);

/// Function pointer type for calling a JS function with multiple arguments.
/// Takes an opaque VM pointer, the function TVal, args array, arg count, and this TVal.
/// Returns the result TVal.
alias VmCallFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal this_val);

/// Function pointer type for `new` semantics: invoke a JS function as a
/// constructor and return the resulting this. `new_target` is the value seen
/// as `new.target` inside the constructor (the subclass for super() calls).
alias VmConstructFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal new_target);

/// Proxy MOP bridges (set by vm_create) — allow the hobject prototype-chain
/// walkers to route through Proxy traps without a module dependency on the
/// builtins layer.  On error the callee sets heap.has_error/error_value and
/// returns false.
alias ProxyGetFn = fn bool(void* vm, void* heap, void* proxy, void* key, TVal receiver, TVal* out);
alias ProxyHasFn = fn bool(void* vm, void* heap, void* proxy, void* key, bool* out);

// --- Faults ---------------------------------------------------------------

faultdef HEAP_ALLOC_FAULT;

// --- Constants ------------------------------------------------------------

const uint  INITIAL_STR_TABLE_SIZE  = 256;
const float STR_TABLE_LOAD_FACTOR   = 0.70;
const long  GC_INITIAL_TRIGGER      = 1;
const long  GC_TRIGGER_GROW_FACTOR  = 1;
const uint  MEGA_CACHE_SIZE         = 512;
/// Initial capacity for the gray object stack (grows as needed).
const uint  GRAY_STACK_INITIAL_CAP  = 64;
const usz   STRS_CACHE_SIZE         = 256;
const uint  GC_MAX_ROOTS            = 64;
const uint  BWD_GC_INTERVAL        = 1024;  /// Backward-jump GC check interval (prevents thrashing)
/// Strings longer than this are never interned — they can't be property keys
/// in practice, and interning them wastes memory (they accumulate in the table
/// until the next GC, causing O(n²) memory growth in loops like `s += chunk`).
const uint  MAX_INTERN_BYTES        = 256;

// Lightfunc deleted-property bitset sizing.
// Each builtin index occupies 3 bits (name/length/prototype deleted flags).
const uint LF_DELETED_WORDS   = 32;                           // ulong words in lf_deleted_props
const uint LF_MAX_TRACKED     = (LF_DELETED_WORDS * 64) / 3; // 682 — max trackable builtin index
/// Sentinel for deleted string table entries (tombstone for open addressing).
const HString* STR_TABLE_TOMBSTONE = (HString*)1;

// --- LongjmpState ---------------------------------------------------------

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

// --- GeneratorState (ES6 §25.3) -------------------------------------------

/// Generator execution state per ES6 §25.3.3.1 GeneratorState.
enum GeneratorStateType : char {
    GEN_SUSPENDED_START,
    GEN_SUSPENDED_YIELD,
    GEN_EXECUTING,
    GEN_COMPLETED,
    // Async-generator-only state (ES2018 §27.6): the generator is running the
    // §27.6.3.7 await-return dance after a `.return()` request while COMPLETED
    // or suspended, and must not drain further requests until it settles.
    GEN_AWAITING_RETURN,
}

/// One entry in an async generator's request queue (ES2018 §27.6.3.1
/// AsyncGeneratorRequest). Concurrent next/return/throw calls each push a
/// request and receive their own promise; the queue drains FIFO.
struct AsyncGenRequest {
    ResumeKind        completion_kind; // NEXT / RETURN / THROW
    TVal              value;           // completion value / thrown value
    void*             capability;      // HObject* — the promise to settle (opaque to avoid a cycle)
    AsyncGenRequest*  next;            // FIFO link (null == tail)
}

/// How a generator was resumed — determines what the YIELD opcode does
/// when execution reaches a yield point.
enum ResumeKind : char {
    NEXT,     /// .next() — yield returns IteratorResult as usual
    THROW,    /// .throw() — inject exception at yield point
    RETURN,   /// .return() — inject return at yield point
}

/// How an async-generator body last suspended, recorded by the AWAIT/YIELD
/// opcodes so the drain (async_gen_drain) knows whether the returned-from-body
/// value settles the current request (YIELD/RETURN) or whether the body merely
/// suspended internally on an `await` and must be re-driven by a microtask
/// (AWAIT) without touching the current request's promise.
enum GenSuspendKind : char {
    AG_SUSPEND_NONE,   /// idle / not an async-gen resume
    AG_SUSPEND_AWAIT,  /// body suspended at an internal `await` (invisible to caller)
    AG_SUSPEND_YIELD,  /// body reached a `yield` — settle current request {v,false}
}

/// Saved execution context for a generator.
///
/// When a generator function is called, instead of executing the body
/// immediately, the VM saves the initial execution state in this struct
/// and returns a generator object.  Subsequent calls to .next(), .throw(),
/// or .return() resume execution from the saved state.
struct GeneratorState {
    GeneratorStateType state;
    void* func;               // CompiledFunction* (opaque to avoid circular deps)
    void* func_obj;           // HObject* of the generator function itself (opaque)
                              // — read at GEN_START (after param-init) to resolve
                              // the generator instance's [[Prototype]] per ES2015
                              // §25.3.3, since a default-parameter side effect can
                              // still mutate functionObject.prototype up to that point.
    void* gen_obj;            // HObject* of the generator INSTANCE this state backs
                              // (opaque). The instance owns the state, so the state
                              // cannot mark it as a child — this is a back-pointer,
                              // used to root the instance while it has in-flight
                              // async work (see Heap.mark_roots).
    TVal* saved_regs;         // malloc'd array of register values
    uint num_regs;
    void* saved_pc;           // Instruction* (opaque)
    void* var_env;            // EnvRecord* (opaque)
    void* lex_env;            // EnvRecord* (opaque)
    void* cat;                // Catcher* chain head (opaque) — saved across yields
    TVal this_binding;
    TVal resume_value;        // value passed by .next()
    ResumeKind resume_kind;   // how the generator was resumed
    TVal throw_value;         // exception to inject (when resume_kind == THROW)
    TVal return_value;        // value to return (when resume_kind == RETURN)
    // yield* delegation state
    void* delegated_iter;     // HObject* — iterator being delegated to
    // async yield* delegation sub-state (ES2018 §14.4.14 / §27.6.3.8). The
    // YIELD_STAR_ASYNC opcode is a resumable state machine: each spec Await is a
    // real suspension that re-enters the same opcode, so the "program counter"
    // of the delegation lives here. See AsyncYieldStarStep in vm_generators.c3.
    // AYS_INACTIVE (0) means no async yield* is in progress on this gs.
    uint ays_step;
    TVal ays_received;        // value to forward into the next inner call
    TVal ays_next_method;     // cached delegate [[NextMethod]] (§14.4.14 GetIterator
                              // reads iterator.next ONCE; reused every iteration)
    // async state
    void* async_promise;      // HObject* — the async function's outer Promise (null for generators)
    // async-generator state (ES2018 §27.6): true for `async function*` bodies.
    // The request queue holds pending next/return/throw calls, drained FIFO.
    bool  is_async_gen;
    AsyncGenRequest* agr_head; // FIFO queue head (current in-flight request)
    AsyncGenRequest* agr_tail; // FIFO queue tail
    // The request currently being serviced (dequeued from agr_head at the start
    // of a resume, held here across internal `await` suspensions so the eventual
    // yield/return/throw settles the right promise). Null when idle.
    void* ag_current_request;  // HObject* — the promise the in-flight request settles
    // The in-flight request's completion value. Held here (not just in the
    // caller's local copy of the dequeued struct) so the mark phase can see it
    // for as long as the request is being serviced.
    TVal ag_current_value;
    // How the async-gen body last suspended (ES2018 §27.6): AWAIT means the body
    // suspended internally on an await and the drain must NOT settle the current
    // request — a microtask resume will re-drive it. YIELD/RETURN/THROW settle.
    GenSuspendKind ag_suspend_kind;
    // yield-through state: when yield fires inside a non-generator inner
    // function (e.g. a default expression thunk), the resume value must be
    // placed into a specific register in the generator's frame on resume.
    // 0xFFFF means unused.
    uint pending_resume_reg;
    /// Number of HObjects currently holding this GeneratorState: the GENERATOR
    /// instance plus every `is_async_state` reaction closure that parks the
    /// pointer in func.var_env. Maintained by gs_acquire / gs_release.
    uint ref_count;
}

/// Register one more HObject holder of `gs`. Every store of a GeneratorState*
/// into an HObject (gen.generator_data or an is_async_state func.var_env) must
/// be paired with this, and with a gs_release when that HObject is torn down.
fn void gs_acquire(GeneratorState* gs) {
    if (gs != null) { gs.ref_count++; }
}

/// Drop one HObject's hold on `gs`, freeing the state (and its saved registers)
/// once the last holder is gone.
///
/// The count is the ONLY ownership signal: sweep tears every dying node down in
/// a single pass, so a holder that decided ownership by reading a gs field
/// would race its siblings in that same pass — the first free recycles the
/// struct and the next holder reads back whatever landed there. Counting keeps
/// the last teardown, in whatever order sweep visits them, the one that frees.
///
/// `heap_ptr` owns the allocator the state was allocated from and must always
/// be supplied — including during full-heap teardown, which clears the
/// `_active_heap` global but still frees through the heap's own allocator. An
/// embedder allocator makes the difference load-bearing: releasing to libc
/// instead is a cross-allocator free.
///
/// `run_decref` is false in teardown mode, where the refcount pass is skipped
/// because the heap is already being dismantled.
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
    h.free_func(h.heap_udata, gs);
}

/// One parked Atomics.waitAsync waiter (single-agent). `buffer` is the backing
/// SharedArrayBuffer HObject, `byte_index` the absolute byte offset in it, and
/// `promise` the pending Promise resolved by Atomics.notify with "ok".
struct AtomicsWaiter {
    hobject::HObject* buffer;
    hobject::HObject* promise;
    uint              byte_index;
    bool              active;
}

// --- Heap struct ----------------------------------------------------------

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

    // Registry of large (non-interned) strings.  Strings over
    // MAX_INTERN_BYTES are not in str_table, so the table sweep and the
    // reset teardown cannot see them.  Every such string is appended here at
    // allocation and removed at free, giving mark-and-sweep a backstop for
    // unreachable ones and reset() a complete list to release.  Each entry
    // stores its own slot in HString.hash (dead for non-interned strings),
    // so removal is an O(1) swap with the last element.
    HString**    large_strings;
    uint         large_string_count;
    uint         large_string_capacity;

    // Built-in strings cache (indexed by string constant IDs)
    void*[STRS_CACHE_SIZE]  strs;

    // GC state
    long  gc_trigger_counter;
    bool  gc_pending;              /// Deferred GC requested by alloc/realloc
    uint  bwd_gc_budget;            /// Countdown for backward-jump GC safepoint
    /// Nesting depth of native builtin frames currently on the C3 stack.
    /// Non-zero means a builtin may be holding a freshly allocated object in a
    /// raw C3 local that no GC root can see, so temproot flags must survive
    /// even a safepoint collection (see Heap.mark_and_sweep).
    uint  native_frame_depth;
    uint  live_obj_count;
    uint  peak_live_obj_count;   /// High-water mark for live objects

    // String-table sweeping is only safe when no raw HString* pointers are
    // held in C3 locals (see mark_and_sweep phase 3b).  Off by default;
    // callers at a true safe point may set it around a GC.
    bool  string_sweep_safe;

    // Gray set for iterative mark — dynamic array of HObject* pointers.
    // Avoids C-stack overflow on deep object graphs.
    void** gray_objects;
    uint   gray_count;
    uint   gray_capacity;

    // Current execution thread (HThread*)
    void* curr_thread;

    // Longjmp state for error handling
    LongjmpState lj;

    // Error flag: set by the VM when an unhandled throw occurs.
    // Cleared before each top-level call. Checked by builtins (e.g. JSON)
    // that call back into JS and need to detect errors from call_fn.
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

    // Object.prototype.__proto__ getter/setter — set by register_object_constructor
    // (which runs BEFORE Function.prototype exists) and back-patched by
    // register_function_constructor once `function_proto` is allocated. The
    // back-patch re-stamps the accessor's [[Prototype]] so the `get __proto__`
    // function can resolve Function.prototype.{apply,call,bind,toString} —
    // without it, test262's built-in-function-object test crashes when
    // `Reflect.ownKeys` walks Object.getOwnPropertyDescriptors(Object).get
    // and calls Function.prototype.toString on a null-prototype function.
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
    /// Promise constructor function (lazily cached, rooted via this field)
    HObject* promise_ctor;
    /// Function constructor object — %Function% (ES2015 §19.2.2). Stashed so
    /// later registration passes (GeneratorFunction, AsyncFunction,
    /// AsyncGeneratorFunction) can wire their [[Prototype]] to it, per the
    /// spec requirement that those constructors are subclasses of Function.
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
    /// Set by the AWAIT opcode when it suspends an *async-generator* body on an
    /// internal await (ES2018 §27.6.3.8 / §27.6.3.9): the drain must leave the
    /// current request's promise untouched — a microtask ASYNC_GEN resume will
    /// re-drive the body. Cleared by the drain before each body resume.
    bool ag_did_await;

    // Initial generator call state — set by the initial-call path in vm_calls
    // before eagerly running the frame, cleared by the GEN_START handler.
    // Non-null while a generator function body is executing its parameter
    // initialization phase (before the first GEN_START instruction is hit).
    GeneratorState* gen_initial_gs;   /// Pre-allocated GeneratorState for the initial call
    void*           gen_initial_obj;  /// HObject* — the generator object being initialized
    TVal*           gen_initial_retval; /// Where to write the generator object in the caller's frame

    // Nested generator initial-call stack — supports generator functions whose
    // parameter initialization itself calls other generator functions (e.g.
    // `*outer([[,] = innerGen()])`).  Each entry saves the outer gen_initial_*
    // state before the inner call overwrites it; GEN_START pops one entry per
    // generator that completes its initial-call phase.
    GeneratorState*[8] gen_init_stack_gs;
    void*[8]           gen_init_stack_obj;
    TVal*[8]           gen_init_stack_retval;
    uint               gen_init_stack_depth;  /// Number of saved entries (0 = empty)

    // Global symbol registry for Symbol.for / Symbol.keyFor
    HString** symbol_registry_keys;   /// Array of key HString* pointers
    HString** symbol_registry_syms;   /// Array of symbol HString* pointers
    uint      symbol_registry_count;  /// Number of entries
    uint      symbol_registry_cap;    /// Allocated capacity

    // Global checkpoint for __resetGlobals() — saves initial global state
    void**    checkpoint_keys;   /// Array of HString* pointers
    TVal*     checkpoint_vals;   /// Parallel array of TVal values
    uint      checkpoint_count;  /// Number of saved entries
    uint      checkpoint_cap;    /// Allocated capacity

    // Environment record pool — freelist of EnvRecord nodes
    void*     env_freelist;     /// EnvRecord* freelist (chains via .parent)
    void*     env_pool_blocks;  /// EnvPoolBlock* linked list for cleanup

    // CompiledFunction tracking — growable array of all CompiledFunction*
    // allocated through the compiler.  Freed in Heap.destroy.
    void**    compiled_funcs;    /// Array of CompiledFunction* pointers
    uint      compiled_func_cap; /// Allocated capacity
    uint      compiled_func_count; /// Number of tracked entries

    // GC root registration (pointers to always-reachable HeapHeader*)
    void*[GC_MAX_ROOTS] gc_roots;
    uint                gc_root_count;

    // VM valstack pointers for GC root scanning.
    // valstack_base is updated on VM create / resize.
    // valstack_top_ptr is a pointer to vm.valstack_top so GC always
    // reads the current value (no sync needed on push/pop).
    TVal*      valstack_base;    /// VM's valstack base pointer
    TVal**     valstack_top_ptr; /// Points to vm.valstack_top

    // GC re-entrancy guard
    bool                gc_running;

    // Set for the duration of Heap.sweep(). While sweeping, decref must not
    // follow a reference into another unmarked (dying) heap node: the sweep
    // loop frees every unmarked object/bigint itself, so touching such a
    // node's header from a sibling's hobject_free is a use-after-free / double
    // free. When sweeping, decref skips unmarked non-string targets — their
    // memory is reclaimed by the sweep, not by refcounting.
    bool                sweeping;

    // VM callback for calling JS functions from builtins (set by vm_create)
    VmCallHandlerFn     call_handler_fn;
    VmCallFn            call_fn;
    VmConstructFn       construct_fn;
    /// Proxy trap bridges + owning VM pointer (see ProxyGetFn/ProxyHasFn).
    ProxyGetFn          proxy_get_fn;
    ProxyHasFn          proxy_has_fn;
    void*               vm_ptr;
    /// Callback to mark activation-record env bindings during GC (set by vm_create).
    MarkActivationsFn   mark_activations_fn;

    // Cached iterator symbol (lazily created, rooted via this field).
    HString*            iterator_symbol;

    // Cached Symbol.toStringTag (lazily created, rooted via this field).
    HString*            tostringtag_symbol;

    // Cached Symbol.toPrimitive (lazily created, rooted via this field).
    HString*            toprimitive_symbol;

    // Cached Symbol.isConcatSpreadable (lazily created, rooted via this field).
    HString*            concatspreadable_symbol;

    // Cached Symbol.hasInstance (lazily created, rooted via this field).
    HString*            hasinstance_symbol;

    // Cached well-known symbols for @@match, @@search, @@replace, @@split protocols.
    HString*            match_symbol;
    HString*            search_symbol;
    HString*            replace_symbol;
    HString*            split_symbol;

    // Cached Symbol.species (lazily created, rooted via this field).
    HString*            species_symbol;
    // Cached Symbol.unscopables (lazily created, rooted via this field).
    HString*            unscopables_symbol;
    // Cached Symbol.matchAll (lazily created, rooted via this field).
    HString*            matchall_symbol;
    // Cached Symbol.asyncIterator (lazily created, rooted via this field).
    HString*            asynciterator_symbol;

    // Microtask completion callback (set by builtins init, resolves downstream promises)
    MicrotaskAfterFn    microtask_after_fn;

    // Microtask queue — enqueued by promise_trigger_reactions, drained after
    // each top-level script execution and after vm_call_fn_impl returns.
    // Each entry is 3 TVal slots: [handler, arg, downstream].
    // downstream is the promise to resolve with the handler's return value (or undefined).
    TVal*     microtask_queue;
    uint      microtask_count;
    uint      microtask_capacity;
    bool      microtask_draining;  // re-entrancy guard

    // Atomics.waitAsync async-waiter list (single-agent). Each active waiter
    // parks a pending Promise on a (SharedArrayBuffer, byte-index) location;
    // Atomics.notify resolves matching waiters with "ok" (FIFO). All fields are
    // GC roots while the waiter is active.
    AtomicsWaiter[64] async_waiters;
    uint      async_waiter_count;

    // Shape (hidden class) system for inline cache support.
    hobject::Shape**    shapes;       // pointer array — each element points to a shape allocation
    uint                shape_count;
    uint                shape_capacity;
    uint                shape_gen;

    // Shape transition deduplication table.
    // Maps (parent_shape_id, key_pointer) → child_shape_id so that two
    // objects following the same property-addition path share one Shape.
    TransitionEntry*    trans_table;
    uint                trans_mask;   // table has mask+1 entries
    uint                trans_count;

    // Global megamorphic property cache: (shape_id, key) → (proto, prop_idx, value)
    // Shared across all call sites to avoid repeated prototype chain walks.
    // Lossy single-slot hash table with implicit eviction on collision.
    // Heap-allocated separately to avoid bloating the hot Heap struct.
    hobject::MegamorphicEntry* mega_cache;

    // Small-integer string cache: pinned HString* for integer keys 0–255.
    // Populated lazily on first use; entries are pinned (HeapHeader.set_pinned)
    // so they are never freed by RC or GC sweep, and incref/decref against
    // them are no-ops.
    HString*[256] small_int_strs;

    // Lightfunc virtual property deletion tracking.
    // 3 bits per builtin index: 0=name deleted, 1=length deleted, 2=prototype deleted.
    // Indexed as: bit = fn_idx * 3 + prop_bit
    ulong[LF_DELETED_WORDS] lf_deleted_props;

    // Pool allocators for HObject headers — eliminates per-object malloc overhead.
    // Three size classes matching alloc_size_for_class():
    //   plain (72B): OBJECT, ERROR, ARGUMENTS, PROXY
    //   array (80B): ARRAY
    //   func  (104B): FUNCTION, REGEXP, BOOLEAN, NUMBER, STRING, DATE, etc.
    mempool::FixedBlockPool obj_pool_plain;
    mempool::FixedBlockPool obj_pool_array;
    mempool::FixedBlockPool obj_pool_func;

    // Module system — module cache and host hooks.
    void*       module_cache;       // ModuleDef** — growable array of ModuleDef pointers
    uint        module_cache_count;
    uint        module_cache_cap;
    void*       module_hooks;       // ModuleHostHooks* — pluggable host callbacks
    // Name of the module whose body is currently executing (empty when not
    // inside a module evaluation). Base for resolving relative dynamic-import
    // specifiers issued from functions that carry no filename of their own.
    char[]      current_module_name;
}

// ============================================================================
// Built-in string cache — pre-interned at heap creation
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
// These are the C-ABI allocator hooks selected when heap::create is passed
// null callbacks.  They keep the (void* udata, ...) function-pointer shape so
// embedders can still supply their own malloc/realloc/free, but the default
// bodies now route through the C3 thread allocator (`mem`), which is the
// libc-backed LIBC_ALLOCATOR by default.  The `_try ?? null` form preserves the
// OOM-returns-null contract the heap's GC-retry paths depend on (bare
// mem::malloc panics on OOM).

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

// The FixedBlockPools are backed directly by the stdlib libc allocator
// singleton `allocators::LIBC_ALLOCATOR` (a strict superset of the old
// hand-rolled LibcPoolAllocator).

// ============================================================================
// Heap creation / destruction
// ============================================================================

/**
 * Allocate and initialise a brand-new Heap.
 *
 * If any allocator callback is `null` the corresponding default (libc)
 * version is used.  Returns a fault on allocation failure.
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

    // Allocate gray object stack
    void* gray_raw = afn(udata, void*::size * GRAY_STACK_INITIAL_CAP);
    if (gray_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    h.gray_objects   = (void**)gray_raw;
    h.gray_count     = 0;
    h.gray_capacity  = GRAY_STACK_INITIAL_CAP;

    // PRNG seed (non-zero required for xorshift32)
    h.rnd_state = 0xDEAD_BEEF;

    // Fixed hash seed (never changes after creation)
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

    // Allocate megamorphic property cache (separate allocation to keep Heap struct compact)
    h.mega_cache = (hobject::MegamorphicEntry*)alloc::malloc_try(mem, (sz)(MEGA_CACHE_SIZE * hobject::MegamorphicEntry::size)) ?? null;
    if (h.mega_cache != null) {
        mem::clear(h.mega_cache, (sz)(MEGA_CACHE_SIZE * hobject::MegamorphicEntry::size));
    }

    // Allocate microtask queue: 16 entries, each a (handler, arg, downstream)
    // TRIPLE — 48 TVal slots. (Was sized for pairs, so entry 11+ wrote past
    // the allocation.)
    h.microtask_capacity = 16;
    h.microtask_queue = (TVal*)afn(udata, TVal::size * 48);
    if (h.microtask_queue != null) {
        mem::clear(h.microtask_queue, (sz)(TVal::size * 48));
    }
    h.microtask_count = 0;
    h.microtask_draining = false;
    h.async_waiter_count = 0;

    // Initialize object pool allocators (3 size classes).
    {
        h.obj_pool_plain.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_PLAIN, 512);
        h.obj_pool_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARRAY, 512);
        h.obj_pool_func.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_FUNC, 512);
    }

    // Activate this heap for RC operations and shape transitions.
    hobject::hobject_set_active_heap((void*)h);

    return h;
}

/// Pre-intern frequently-used strings into Heap.strs[].
/// Called once during heap creation.  Each string is hashed, looked up in
/// the string table, and allocated only if not already present — so this
/// is safe to call multiple times.
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
    // Pin: builtin strings must never be freed by refcounting, and every
    // incref/decref against them (from transient register/TVal borrows) is
    // a no-op — see HeapHeader.set_pinned.
    for (uint i = 0; i < 29; i++) {
        if (self.strs[i] != null) {
            ((HeapHeader*)self.strs[i]).set_pinned();
        }
    }
    // Cache the "length" pointer for HObject.put_prop array_length sync.
    hobject::builtin_length_key = self.strs[BuiltinStr.LENGTH];
}

/// Convert an integer to an interned HString*, using the small-integer cache
/// for values 0–255 and formatting + interning for all other values.
///
/// Ownership: like Heap.str_intern, the returned HString* is a BORROWED
/// reference — callers use it directly as a property key or incref it
/// themselves if they need to anchor it in a TVal/register. Values 0–255
/// are cached on first use and pinned (HeapHeader.set_pinned), so every
/// incref/decref a caller performs on the cached entry is a no-op: no
/// release is ever required, matching the treatment of builtin strings in
/// init_builtin_strs().
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
        // Pin so RC/sweep never frees this cached entry, and so incref/decref
        // against it are no-ops (see HeapHeader.set_pinned).
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
const uint SHAPE_NONE          = 0xFFFF_FFFF;
const uint SHAPE_TRANS_INITIAL = 16;   // must be power of 2
const uint SHAPE_TRANS_LOAD    = 70;   // max load percentage before grow
/// Sentinel for ushort shape IDs (max ushort = 65535, cap valid IDs at 65534).
const ushort SHAPE_ID_NONE     = 0xFFFF;

struct TransitionEntry {
    uint parent_id;
    void* key;
    ushort shape_id;
    /// Property flags this transition installs (raw PropFlags byte). Part of
    /// the dedup key: two objects reaching the same parent shape and adding
    /// the same key with the same flags can share the resulting shape, but a
    /// transition that installs different flags for that key must be a
    /// distinct shape (or every reader would see the wrong attributes).
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

fn ushort Heap.lookup_transition(&self, uint parent_id, void* key, char flags) {
    uint h = hash_transition(parent_id, key, flags);
    uint mask = self.trans_mask;
    uint slot = h & mask;
    TransitionEntry* table = self.trans_table;
    for (uint i = 0; i <= mask; i++) {
        TransitionEntry* e = &table[slot];
        if (e.parent_id == SHAPE_NONE) return SHAPE_ID_NONE;
        if (e.parent_id == parent_id && e.key == key && e.flags == flags) return e.shape_id;
        slot = (slot + 1) & mask;
    }
    return SHAPE_ID_NONE;
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

fn void Heap.insert_transition(&self, uint parent_id, void* key, char flags, ushort shape_id) {
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
    self.shape_count    = 1;  // slot 0 = root shape
    self.shape_gen      = 0;
    // Allocate pointer array
    usz bytes = (usz)SHAPE_INITIAL_CAP * (void*::size);
    self.shapes = (hobject::Shape**)self.alloc_func(self.heap_udata, bytes);
    mem::clear(self.shapes, (sz)(bytes));
    // Allocate root shape: 0 properties, minimum hash (mask=0 → 2 slots)
    self.shapes[0] = hobject::shape_create(0, 0, SHAPE_NONE, null);
    // Init transition dedup table
    self.init_transition_table();
}

/// Allocate a new shape slot in the shapes array. Returns the new shape ID.
/// Does NOT initialize the shape pointer (caller must set shapes[id]).
fn uint Heap.alloc_shape_slot(&self) {
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
    if (id >= 0xFFFE) return SHAPE_NONE;
    return id;
}


/// Transition to a new shape that includes the given property key, using the
/// default WEC data-property flags.  Thin wrapper over
/// transition_shape_new_flags() for the overwhelmingly common case.
fn ushort Heap.transition_shape_new(&self, ushort cur_shape_id, void* key) {
    return self.transition_shape_new_flags(cur_shape_id, key, hobject::PROP_FLAGS_WEC);
}

/// Transition to a new shape that includes the given property key with the
/// given flags.
///
/// If the current shape already has this key, returns the current shape
/// (the caller should update the existing slot).
/// Transition to a new shape for a property that is KNOWN to be new.
/// Skips the O(N) chain walk — the caller has already confirmed via
/// find_prop_idx() that the key does not exist in the object.
///
/// The transition table is keyed on (parent shape, key, flags): two objects
/// that reach the same parent shape and add the same key with the same flags
/// converge on one shared shape, even when those flags are non-default (e.g.
/// every instance of a class installing the same private field). Only a
/// transition that installs *different* flags for that key gets a distinct
/// shape — sharing is never based on key alone.
fn ushort Heap.transition_shape_new_flags(&self, ushort cur_shape_id, void* key, hobject::PropFlags flags) {
    if (cur_shape_id >= self.shape_count || self.shapes[cur_shape_id] == null) {
        return cur_shape_id;
    }

    hobject::Shape* cur = self.shapes[cur_shape_id];
    char raw_flags = (char)flags;

    // Check transition table for existing child shape (another object may have
    // already taken the same transition with the same flags).
    ushort existing = self.lookup_transition(cur_shape_id, key, raw_flags);
    if (existing != SHAPE_ID_NONE) {
        return existing;
    }

    // Allocate a new shape that extends the current one.
    hobject::Shape* ns = hobject::shape_extend(cur, cur_shape_id, key, flags);
    if (ns == null) return cur_shape_id;

    uint new_id = self.alloc_shape_slot();
    if (new_id == SHAPE_NONE) {
        hobject::shape_free(ns, (void*)self);
        return cur_shape_id;
    }

    self.shapes[new_id] = ns;
    self.insert_transition(cur_shape_id, key, raw_flags, (ushort)new_id);
    return (ushort)new_id;
}

fn void Heap.bump_shape_gen(&self, ushort shape_id) {
    if (shape_id < self.shape_count && self.shapes[shape_id] != null) {
        self.shapes[shape_id].generation++;
        self.shape_gen++;
    }
}

/// Get a shape pointer by ID. Returns null if invalid.
fn hobject::Shape* Heap.get_shape(&self, ushort shape_id) {
    if (shape_id >= self.shape_count) return null;
    return self.shapes[shape_id];
}

/**
 * Free every tracked CompiledFunction and its sub-arrays, leaving the
 * `compiled_funcs` array itself alone. Teardown-only: no decref is needed
 * because the caller is tearing the heap down and the interned strings are
 * released by the str_table sweep. Shared by destroy() and reset().
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
        // Direct-eval private-name snapshot (compiler/context.c3 finish() —
        // heap-tracked when a function had direct eval AND inherited names
        // from a parent class body).
        if (cf.eval_private_names != null) { self.free_func(self.heap_udata, cf.eval_private_names); }
        // The function's own name and retained source text, copied out of the
        // compiler's scratch buffers so they outlive the compile. Both come
        // from `mem`, not the heap allocator. `filename_ptr` is deliberately
        // NOT freed: stamp_module_filename hands the module's normalized
        // specifier to every nested function, so it is borrowed, not owned.
        if (cf.name_ptr != null) { mem::free(cf.name_ptr); cf.name_ptr = null; }
        if (cf.src_ptr != null) { mem::free(cf.src_ptr); cf.src_ptr = null; }
        self.free_func(self.heap_udata, cf);
    }
}

/**
 * Destroy the heap: walk every managed object and release it, then free
 * the heap struct itself.
 */
fn void Heap.destroy(&self) {
    // Deactivate the active heap so hobject_free skips its RC decref loop —
    // teardown frees everything directly, mixing decref with str_table
    // backshift-delete corrupts the table for the subsequent str_table sweep.
    hobject::hobject_clear_active_heap();

    HeapHeader* cur = self.heap_allocated;
    while (cur != null) {
        HeapHeader* next = cur.next;
        if (cur.is_object()) {
            hobject::hobject_free((HObject*)cur, (void*)self);
        } else if (cur.is_bigint()) {
            // HBigInt boxes are the only non-object node on heap_allocated; they
            // hold no children, so a plain free suffices.
            self.free_func(self.heap_udata, cur);
        }
        cur = next;
    }
    self.heap_allocated = null;

    // Free EnvRecord pool blocks
    {
        void* b = self.env_pool_blocks;
        while (b != null) {
            void* next = *(void**)b;  // next pointer is first field
            self.free_func(self.heap_udata, b);
            b = next;
        }
        self.env_pool_blocks = null;
        self.env_freelist = null;
    }

    // Free all tracked CompiledFunction objects and their sub-arrays.
    // No decref needed — everything is being torn down and strings will be
    // freed from the str_table sweep below.
    if (self.compiled_funcs != null) {
        self.free_compiled_funcs();
        self.free_func(self.heap_udata, self.compiled_funcs);
        self.compiled_funcs = null;
    }

    // Free all interned HStrings via the string table (RC-managed; teardown frees directly).
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

    // Free all large (non-interned) HStrings and the registry backing array.
    for (uint i = 0; i < self.large_string_count; i++) {
        self.free_string(self.large_strings[i]);
    }
    self.large_string_count = 0;
    if (self.large_strings != null) {
        self.free_func(self.heap_udata, self.large_strings);
        self.large_strings = null;
        self.large_string_capacity = 0;
    }

    // Free microtask queue
    if (self.microtask_queue != null) {
        self.free_func(self.heap_udata, self.microtask_queue);
        self.microtask_queue = null;
    }

    // Free gray stack
    if (self.gray_objects != null) {
        self.free_func(self.heap_udata, self.gray_objects);
        self.gray_objects = null;
    }

    // Free shape system
    if (self.trans_table != null) {
        self.free_func(self.heap_udata, self.trans_table);
        self.trans_table = null;
    }
    if (self.shapes != null) {
        for (uint i = 0; i < self.shape_count; i++) {
            if (self.shapes[i] != null) {
                hobject::shape_free(self.shapes[i], null);
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

    // Destroy object pool allocators — releases all pool pages to libc.
    self.obj_pool_plain.free();
    self.obj_pool_array.free();
    self.obj_pool_func.free();

    // Finally free the Heap struct itself
    FreeFunc    ffn   = self.free_func;
    void*       udata = self.heap_udata;
    ffn(udata, self);
}

/**
 * Reset the heap to a clean state without freeing the heap struct itself.
 * Frees all GC objects, compiled functions, interned strings, symbol registry,
 * and checkpoint data. Reinitialises the string table and builtin string cache
 * in-place, reusing existing backing arrays where possible.
 *
 * After this call the heap is ready to host a fresh VM, with no memory from
 * the previous test run retained — avoiding the create/destroy churn that
 * causes allocator fragmentation and RSS bloat.
 */
fn void Heap.reset(&self) {
    // Decref all string and bigint TVals held by live objects BEFORE entering
    // teardown mode.  BigInt boxes have no list of their own to drain later,
    // so this pass is what releases them; strings it drives to zero also
    // unregister themselves, leaving the registry drain below only the ones
    // still holding references.
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
    // Also decref strings still on the valstack (from an aborted/thrown test).
    if (self.valstack_base != null && self.valstack_top_ptr != null) {
        types::TVal* top = *self.valstack_top_ptr;
        types::TVal* base = self.valstack_base;
        while (base < top) {
            if (base.is_string() || base.is_bigint()) { self.decref_tval(base); }
            base++;
        }
    }

    // Deactivate the active heap so hobject_free skips the RC decref loop —
    // same teardown-mode guard as in destroy().
    hobject::hobject_clear_active_heap();

    HeapHeader* cur = self.heap_allocated;
    while (cur != null) {
        HeapHeader* next = cur.next;
        if (cur.is_object()) {
            hobject::hobject_free((HObject*)cur, (void*)self);
        } else if (cur.is_bigint()) {
            // HBigInt boxes are the only non-object node on heap_allocated; they
            // hold no children, so a plain free suffices.
            self.free_func(self.heap_udata, cur);
        }
        cur = next;
    }
    self.heap_allocated = null;

    // Free all tracked CompiledFunctions — no decref needed, teardown mode.
    self.free_compiled_funcs();
    self.compiled_func_count = 0;
    // Keep compiled_funcs array allocated — just reset the count

    // Free every large (non-interned) string via the registry.  These are in
    // neither str_table nor heap_allocated, so the registry is the only list
    // that can find them; without this pass they would survive the reset with
    // no owner and accumulate across batch runs.
    for (uint i = 0; i < self.large_string_count; i++) {
        self.free_string(self.large_strings[i]);
    }
    self.large_string_count = 0;

    // Free all interned HStrings via str_table and reset (strings are RC-managed).
    if (self.str_table != null) {
        for (uint i = 0; i < self.str_table_size; i++) {
            hstring::HString* s = self.str_table[i];
            if (s != null && s != STR_TABLE_TOMBSTONE) {
                self.free_string(s);
                self.str_table[i] = null;
            }
        }
        // Shrink if it grew very large
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

    // Free symbol registry
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

    // Free env pool blocks and clear freelist — env nodes hold TVal bindings
    // that point into the (now-freed) heap, so reusing a stale freelist node
    // in the next run would cause use-after-free on tval_copy_ref decref.
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

    // Free checkpoint state
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

    // Reset microtask queue. Heap objects from the previous run were freed
    // wholesale above, so clear stale TVal bits without decrefing them.
    if (self.microtask_queue != null) {
        mem::clear(self.microtask_queue,
            (sz)((usz)self.microtask_capacity * TVal::size * 3));
    }
    self.microtask_count    = 0;
    self.microtask_draining = false;
    self.async_waiter_count = 0;
    self.sweeping           = false;
    mem::clear(&self.async_waiters, (sz)(AtomicsWaiter::size * 64));

    // Clear all other heap state (prototypes, GC roots, execution state)
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
    self.gc_running       = false;
    self.gc_trigger_counter = GC_INITIAL_TRIGGER;
    self.gc_pending       = false;
    self.bwd_gc_budget    = BWD_GC_INTERVAL;
    self.native_frame_depth = 0;
    self.gray_count       = 0;

    // Clear the megamorphic property cache — it holds stale HObject*/HString*
    // pointers from the previous run.  Since pool allocators are reset to the
    // same initial addresses, new objects can get false cache hits with the
    // old (now freed) entries and return wrong property values.
    if (self.mega_cache != null) {
        mem::clear(self.mega_cache, (sz)(MEGA_CACHE_SIZE * hobject::MegamorphicEntry::size));
    }

    // Clear builtin prototype pointers
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

    // Clear builtin string cache
    for (usz i = 0; i < STRS_CACHE_SIZE; i++) {
        self.strs[i] = null;
    }

    // Clear small-integer string cache — entries will be re-populated lazily
    // after the string table is rebuilt in init_builtin_strs().
    for (usz i = 0; i < 256; i++) {
        self.small_int_strs[i] = null;
    }


    // Clear lightfunc virtual property deletion tracking
    mem::clear(&self.lf_deleted_props[0], (sz)(LF_DELETED_WORDS * 8));

    // Clear longjmp state
    self.lj.lj_type = LjType.UNKNOWN;
    self.lj.iserror = false;
    self.lj.value1.set_undefined();
    self.lj.value2.set_undefined();

    // Clear cached TVal fields that may hold heap pointers
    self.error_value.set_undefined();
    self.yield_value.set_undefined();
    self.has_error = false;

    // Clear generator initial-call state — gen_initial_obj points into the
    // freed heap and the GC mark phase dereferences it when non-null; a test
    // aborted mid-generator-init would poison every later test in the worker.
    self.gen_initial_gs = null;
    self.gen_initial_obj = null;
    self.gen_initial_retval = null;
    self.gen_init_stack_depth = 0;

    // Clear cached symbol pointers — these point into the (now-freed)
    // string table and must not be reused after reset.  They are
    // re-populated lazily by ensure_iterator_symbol / ensure_toprimitive_symbol.
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

    // Reset shape system — free all shapes and transition table, then reinit
    if (self.trans_table != null) {
        self.free_func(self.heap_udata, self.trans_table);
        self.trans_table = null;
    }
    if (self.shapes != null) {
        for (uint i = 0; i < self.shape_count; i++) {
            if (self.shapes[i] != null) {
                hobject::shape_free(self.shapes[i], null);
            }
        }
        // Reuse the pointer array, just zero it
        mem::clear(self.shapes, (sz)((usz)self.shape_capacity * (void*::size)));
    }
    self.shape_count = 1;
    self.shape_gen   = 0;
    self.shapes[0]   = hobject::shape_create(0, 0, SHAPE_NONE, null);
    self.init_transition_table();

    // Free module cache
    self.free_module_cache();
    self.module_hooks = null;
    self.current_module_name = {};

    // Destroy and reinitialize object pool allocators — all pool pages are
    // freed to libc, fresh pools start with clean bump + empty freelist.
    self.obj_pool_plain.free();
    self.obj_pool_array.free();
    self.obj_pool_func.free();
    {
        self.obj_pool_plain.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_PLAIN, 512);
        self.obj_pool_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARRAY, 512);
        self.obj_pool_func.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_FUNC, 512);
    }

    // Reintern builtin strings into the now-empty string table
    self.init_builtin_strs();

    // Re-activate the heap for the next run.
    hobject::hobject_set_active_heap((void*)self);
}

// ============================================================================
// CompiledFunction tracking
// ============================================================================

/**
 * Register a CompiledFunction* for cleanup when the heap is destroyed.
 * The compiler allocates CompiledFunctions via the heap's alloc_func and
 * they are not tracked by the GC object array, so we need a separate list.
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
// Module system — hooks and cache management
// ============================================================================

/// Register module host hooks. Call before any module loading.
/// Pass NULL to use defaults. The hooks pointer must remain valid
/// for the lifetime of the Heap.
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
 * Allocate `size` bytes through the heap's allocator.  Decrements the GC
 * trigger counter and flags a deferred collection when it reaches zero.
 */
fn void*? Heap.alloc(&self, usz size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.gc_pending = true;
    }

    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        // Emergency GC then retry once
        self.trigger_gc();
        ptr = self.alloc_func(self.heap_udata, size);
        if (ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return ptr;
}

/// Allocate without triggering GC.  Use for RC-managed objects (strings)
/// that are not in the mark-and-sweep heap_allocated list.
fn void*? Heap.alloc_no_gc(&self, usz size) {
    // Large (non-interned-class) strings still contribute to GC pressure: a
    // program building many multi-KB concat results referenced by short-lived
    // objects would otherwise never burn down the trigger counter, so the
    // arrays and objects holding those strings pile up unswept and memory
    // grows without bound. Only the DEFERRED flag is set here — the collection
    // itself runs at the next safepoint (see the note below about why a
    // synchronous GC from inside this allocator is unsafe). Small strings are
    // deliberately NOT counted: they are interned (string-table backstop) and
    // counting them measurably shifts GC cadence for every property-key
    // allocation without reclaiming anything extra.
    if (size > 1024) {
        self.gc_trigger_counter -= (long)(size >> 10);
        if (self.gc_trigger_counter <= 0) {
            self.gc_pending = true;
        }
    }
    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        // OOM — try a GC pass to reclaim M&S objects, then retry once
        self.trigger_gc();
        ptr = self.alloc_func(self.heap_udata, size);
        if (ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    // Note: no periodic GC trigger here.  A mark-and-sweep from inside an
    // allocation can free in-flight objects/strings that a C3 local still
    // points to but no GC root can see (e.g. between alloc_object and the
    // put_prop that anchors it), corrupting the pool via double-free.
    return ptr;
}

/**
 * Allocate a new HObject and register it with the heap's GC tracking list.
 *
 * This is the preferred way to create objects — it replaces raw calls to
 * hobject::hobject_alloc() by also inserting the object into the
 * heap_allocated list so that the mark-and-sweep collector can find it.
 *
 * Returns the new HObject or a fault on allocation failure.
 */
fn HObject*? Heap.alloc_object(&self, hobject::ObjClass cls) {
    HObject*? result = hobject::hobject_alloc((void*)self, cls);
    if (try obj = result) {
        // Insert into the heap_allocated linked list (preserving flags
        // already set by hobject_alloc).
        self.insert_into_heap_allocated_preserve_flags((HeapHeader*)obj);
        // Mark as temporary root so emergency (non-safepoint) GC never frees
        // an in-flight object whose only reference is a C3 local.
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
 * Reallocate a block through the heap's allocator, with GC trigger.
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

/**
 * Free a block through the heap's allocator.
 */
fn void Heap.free(&self, void* ptr) {
    self.free_func(self.heap_udata, ptr);
}

/**
 * Write a string into a VM register with correct refcounting.
 * Decrements the old register value (if string), then stores and increfs.
 */
fn void Heap.set_reg_string(&self, TVal* reg, hstring::HString* s) @inline {
    self.decref_tval(reg);
    reg.set_string(s);
}

/**
 * Free an HString through the heap's allocator (matches Heap.alloc).
 */
fn void Heap.free_string(&self, hstring::HString* s) {
    if (s == null) { return; }
    self.free_func(self.heap_udata, s);
}



// ============================================================================
// Reference counting — decref + free when count reaches zero
// ============================================================================

/**
 * Decrement the reference count of a heap object, buffer, or interned string.
 * When the count reaches zero the object is unlinked from the
 * heap_allocated list and freed (objects/buffers) or freed directly (strings).
 *
 * Objects freed here are NOT visited by the subsequent mark-and-sweep
 * sweep phase — they are already gone from the linked list.  M&S only
 * needs to collect cycle garbage (objects with refcount > 0 but not
 * reachable from roots).
 */
fn void Heap.decref(&self, HeapHeader* hdr) {
    // Sweep guard: while Heap.sweep() is freeing unmarked garbage, a dying
    // object's hobject_free may decref a neighbour it references (getter/setter,
    // captured_this, promise result, a bigint leaf, ...). If that neighbour is
    // itself unmarked it is being — or has already been — freed by the same
    // sweep; reading or re-freeing its header is a use-after-free / double free.
    // Strings are never on the swept heap_allocated list (they are pure RC), so
    // they are always safe to decref. Everything else that is unmarked belongs
    // to the sweep and must not be touched here.
    if (self.sweeping && !hdr.is_string() && !hdr.is_reachable() && !hdr.is_temproot()) {
        return;
    }
    // Pinned strings (builtin strings, well-known symbols, small-int cache)
    // never mutate their refcount — see HeapHeader.set_pinned.
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
                // Buffer or BigInt box — leaf, free directly.
                self.free_func(self.heap_udata, hdr);
            }
        }
    }
}

/**
 * Decrement the reference count of the heap object, buffer, or string held
 * by a TVal.  Safe to call on any TVal — non-heap values are silently
 * ignored.  Typically called BEFORE overwriting a VM register or TVal
 * slot that holds a heap pointer.
 */
fn void Heap.decref_tval(&self, TVal* tv) @inline {
    if (tv.is_heap_allocated()) {
        void* ptr = tv.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
}

/// Copy a TVal from src to dst with proper refcounting.
/// - Increments the new src reference first (guards against src == dst same-object case)
/// - Decrements the old dst reference (safe now that src's object is anchored)
/// - Copies the bits verbatim
/// - Safe when dst == src (no-op in that case)
fn void Heap.tval_copy_ref(&self, TVal* dst, TVal* src) @inline {
    if (dst != src) {
        // Incref the incoming value FIRST so that if src and dst both
        // point to the same heap object (e.g. assigning global → global
        // when its refcount is 1), the decref below cannot prematurely
        // free it before the incref anchors the new reference.
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

/// Move a builtin's result (held in a transient local TVal, e.g. the slot
/// `ctx.result` points at) into a VM register, releasing the transient's own
/// claim when the result is a freshly built, non-interned string it solely owns.
///
/// Builtins populate their result via increffing setters (`set_string`, ...)
/// regardless of whether the value is brand new (refcount 0 before the setter
/// ran) or an already-owned value being passed through (refcount >= 1 before).
/// `tval_copy_ref` establishes the register's own reference correctly in both
/// cases, but the transient local's claim from the builtin's setter is
/// otherwise never released. For most heap values this is harmless — objects
/// are reclaimed by GC mark-sweep and interned strings are kept alive by the
/// string table regardless of refcount — so releasing them here is at best
/// pointless and at worst a use-after-free (a Symbol's backing string, for
/// instance, is a live value other code still references at refcount 1).
///
/// The one class with no such backstop is a large, NON-interned, non-symbol
/// string (e.g. from `String.fromCodePoint` or string concatenation): a pure
/// refcounted leaf that leaks permanently if the setter's transient reference
/// is never balanced. That — and only that — is what this releases. The
/// refcount == 1 check confirms the setter's reference is the sole one: nothing
/// else has had a chance to reference a value the builtin just created.
fn void Heap.store_builtin_result(&self, TVal* dst, TVal* transient) @inline {
    bool release_transient = false;
    if (transient.is_string()) {
        void* ptr = transient.get_heapptr();
        // Exclude an aliased dst/transient (same string already sitting in the
        // destination register): tval_copy_ref is refcount-neutral there, so
        // releasing the transient would drop a live reference.
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

/// Move a TVal from a register (src) into a heap slot (dst), transferring src's
/// reference to dst: the old dst value is decref'd, src's bits are moved in, and
/// src is cleared to undefined by the caller (no incref — ownership transfers).
/// The combined branch skips the decref when the old dst value is primitive
/// (nothing to free). Used on the hot global-slot write path (PUTGLOBAL).
/// Correctness: whether src is heap or primitive is irrelevant to the OLD-dst
/// decref decision — the move preserves src's refcount either way; only the
/// value being overwritten (dst) determines whether a decref is owed.
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
// Managed-object linked-list operations (doubly-linked via HeapHeader)
// ============================================================================

/**
 * Insert `hdr` at the head of the heap_allocated doubly-linked list.
 */
fn void Heap.insert_into_heap_allocated(&self, HeapHeader* hdr) {
    hdr.init(hdr.get_type(), &self.heap_allocated);
}

/**
 * Remove `hdr` from the heap_allocated doubly-linked list.
 * Uses HeapHeader.unlink() for O(1) removal.
 */
fn void Heap.remove_from_heap_allocated(&self, HeapHeader* hdr) {
    hdr.unlink(&self.heap_allocated);
}

/**
 * Insert `hdr` at the head of the heap_allocated list without calling
 * HeapHeader.init(), preserving any flags already set by the caller.
 *
 * This is the safe path for tracked objects where the subtype (HObject,
 * HString) has already set its flags and we only need the linked-list
 * wiring.  Use insert_into_heap_allocated() when a full header init is
 * desired (e.g. raw HeapHeader allocations).
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
 * Insert `hdr` at the head of the finalize_list doubly-linked list.
 */
fn void Heap.insert_into_finalize_list(&self, HeapHeader* hdr) {
    // Re-link into finalize_list — set the finalizable flag.
    hdr.set_finalizable();
    hdr.next = self.finalize_list;
    hdr.prev = null;
    if (self.finalize_list != null) {
        self.finalize_list.prev = hdr;
    }
    self.finalize_list = hdr;
}

/**
 * Remove `hdr` from the finalize_list doubly-linked list.
 */
fn void Heap.remove_from_finalize_list(&self, HeapHeader* hdr) {
    hdr.unlink(&self.finalize_list);
}

// ============================================================================
// GC root registration
// ============================================================================

/**
 * Register a heap object as a GC root.  Root objects are always treated as
 * reachable during mark-and-sweep, preventing them from being freed.
 */
fn void Heap.register_gc_root(&self, HeapHeader* hdr) {
    if (self.gc_root_count < GC_MAX_ROOTS) {
        self.gc_roots[self.gc_root_count] = (void*)hdr;
        self.gc_root_count++;
    }
}

// ============================================================================
// GC marking helpers — tri-color marking with explicit gray stack
// ============================================================================

/**
 * Push an object onto the gray stack for later child processing.
 * Grows the stack dynamically when full.
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
 * Mark a TVal value as reachable.
 *
 * If the value holds a heap-allocated object (OBJECT tag), marks the
 * object reachable and pushes it onto the gray stack for later child
 * processing.  Strings are marked directly (they have no outgoing edges).
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
        // BigInt box is a GC leaf on the heap_allocated list — mark only.
        HeapHeader* b = (HeapHeader*)v.get_heapptr();
        if (b != null) {
            b.set_reachable();
        }
    }
}

/// Mark all references held by a suspended GeneratorState (used by both
/// generator objects and async/await resume/reject builtin functions).
fn void Heap.mark_generator_state(&self, GeneratorState* gs) {
    if (gs == null) return;
    // Mark saved registers (contains TVal references to live objects)
    if (gs.saved_regs != null) {
        for (uint i = 0; i < gs.num_regs; i++) {
            self.mark_tval(&gs.saved_regs[i]);
        }
    }
    // Mark the suspended body's lexical/variable environments. gs.var_env/
    // lex_env are opaque void* (heap.c3 cannot import env.c3 — circular),
    // so the typed EnvRecord* dereference happens in hobject.c3 instead.
    HObject* gs_var_bindings = hobject::env_record_bindings(gs.var_env);
    if (gs_var_bindings != null) { self.mark_hobject(gs_var_bindings); }
    HObject* gs_lex_bindings = hobject::env_record_bindings(gs.lex_env);
    if (gs_lex_bindings != null) { self.mark_hobject(gs_lex_bindings); }
    // Mark TVal fields
    self.mark_tval(&gs.this_binding);
    self.mark_tval(&gs.resume_value);
    self.mark_tval(&gs.throw_value);
    self.mark_tval(&gs.return_value);
    // async yield* delegation state (held across suspensions)
    self.mark_tval(&gs.ays_received);
    self.mark_tval(&gs.ays_next_method);
    // Mark heap object pointers
    if (gs.delegated_iter != null) {
        self.mark_hobject((HObject*)gs.delegated_iter);
    }
    if (gs.async_promise != null) {
        self.mark_hobject((HObject*)gs.async_promise);
    }
    // Keep the generator INSTANCE alive for as long as this state is reachable.
    // Normally the instance marks the state (it owns it), never the reverse —
    // but an async generator driven only by its own internal machinery has no
    // JS-visible reference left: `g().next()` drops the instance immediately,
    // and from then on the only path to the state is a reaction closure hanging
    // off the awaited promise. Without this back-edge the instance is swept
    // while its request queue is still being serviced, and the recycled memory
    // is read back as a live promise (settling the chain with whatever object
    // now occupies the freed slot).
    if (gs.gen_obj != null) {
        self.mark_hobject((HObject*)gs.gen_obj);
    }
    // The request being serviced right now has already been dequeued, so the
    // loop below no longer covers it: from the dequeue until the settle it is
    // reachable only from here (and, in between, from a C3 local). Missing it
    // frees the promise the drain is about to settle, and the recycled slot is
    // then read back as an unrelated live promise.
    if (gs.ag_current_request != null) {
        self.mark_hobject((HObject*)gs.ag_current_request);
    }
    self.mark_tval(&gs.ag_current_value);
    // Async-generator request queue: each pending request holds a completion
    // value and a promise capability (the promise to settle) that must stay
    // reachable while queued.
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
 * Mark an HObject pointer as reachable and schedule it for child
 * processing via the gray stack.  No-op when already reachable.
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
 * Drain the gray stack by popping objects and processing their
 * outgoing references (prototype, properties, array elements,
 * primitive wrapper value, environment bindings).
 *
 * Each newly discovered object is pushed onto the gray stack via
 * mark_tval / mark_hobject, so the loop eventually reaches
 * the transitive closure of all reachable objects.
 *
 * Iterative — no recursion, no depth cap, no C-stack overflow.
 */
fn void Heap.drain_gray(&self) {
    while (self.gray_count > 0) {
        HObject* obj = self.gray_pop();

        // --- Prototype chain ---
        if (obj.prototype != null) {
            self.mark_hobject(obj.prototype);
        }

        // --- Named properties ---
        TVal* pv = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key != null) {
                ((HeapHeader*)key).set_reachable();
            }
            self.mark_tval(&pv[i]);
        }

        // --- Array part ---
        TVal* ap = obj.array_part();
        if (ap != null && obj.array_used > 0) {
            for (uint i = 0; i < obj.array_size; i++) {
                self.mark_tval(&ap[i]);
            }
        }

        // --- Subtype-specific fields ---
        switch (obj.flags.obj_class) {
            case ObjClass.FUNCTION:
            case ObjClass.THREAD:
                // Bound functions never set var_env/lex_env/captured_this/
                // captured_new_target — mark only the bound_* fields.
                if (obj.flags.is_bound) {
                    self.mark_tval(&(*obj.extra_ptr()).func.bound_target);
                    self.mark_tval(&(*obj.extra_ptr()).func.bound_this);
                    if ((*obj.extra_ptr()).func.bound_args != null) {
                        self.mark_hobject((*obj.extra_ptr()).func.bound_args);
                    }
                    break;
                }
                // Async/await resume/reject builtins repurpose var_env to
                // stash a GeneratorState* instead of an EnvRecord* — treating
                // it as an EnvRecord below would read gs.func (a
                // CompiledFunction*) through the EnvRecord.bindings offset
                // and mark_hobject a non-HObject pointer. Mark the
                // GeneratorState (which itself keeps the real var_env/lex_env
                // alive) and skip the EnvRecord walk entirely for these.
                if (obj.flags.is_async_state) {
                    GeneratorState* gs = (GeneratorState*)(*obj.extra_ptr()).func.var_env;
                    self.mark_generator_state(gs);
                    break;
                }
                if ((*obj.extra_ptr()).func.var_env != null && (*obj.extra_ptr()).func.var_env.bindings != null) {
                    self.mark_hobject((*obj.extra_ptr()).func.var_env.bindings);
                }
                if ((*obj.extra_ptr()).func.lex_env != null && (*obj.extra_ptr()).func.lex_env.bindings != null) {
                    self.mark_hobject((*obj.extra_ptr()).func.lex_env.bindings);
                }
                self.mark_tval(&(*obj.extra_ptr()).func.captured_this);
                if ((*obj.extra_ptr()).func.captured_new_target != null) {
                    self.mark_hobject((*obj.extra_ptr()).func.captured_new_target);
                }
                break;
            case ObjClass.GENERATOR:
                if ((*obj.extra_ptr()).gen.var_env != null && (*obj.extra_ptr()).gen.var_env.bindings != null) {
                    self.mark_hobject((*obj.extra_ptr()).gen.var_env.bindings);
                }
                if ((*obj.extra_ptr()).gen.lex_env != null && (*obj.extra_ptr()).gen.lex_env.bindings != null) {
                    self.mark_hobject((*obj.extra_ptr()).gen.lex_env.bindings);
                }
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
                // Mark the resolved value/rejection reason and the linked list
                // of pending reaction records. The chain's "next" pointer is
                // stored as a hidden TVal property (see
                // hobject::promise_reaction_next_key /
                // builtins::reaction_set_next), NOT HeapHeader.next (that's
                // the unrelated heap_allocated GC-list thread pointer) —
                // reading .next here would walk garbage.
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
                // Mark all views chained off this buffer so they survive as
                // long as the buffer does (mirrors PROMISE's reaction chain).
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
                // Mark the iterated object (extra.iter.target, active only for
                // these three iterator classes — not STRING_ITERATOR).
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
 * Mark all GC roots: registered roots, built-in prototypes, the VM
 * value stack, and individual string references found during tracing.
 * Uses the gray stack for iterative transitive marking — no recursion,
 * no depth cap.
 */
fn void Heap.mark_roots(&self) {
    // Mark all registered roots
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

    // Mark built-in error prototypes
    if (self.err_proto != null) { self.mark_hobject(self.err_proto); }
    if (self.type_err_proto != null) { self.mark_hobject(self.type_err_proto); }
    if (self.range_err_proto != null) { self.mark_hobject(self.range_err_proto); }
    if (self.ref_err_proto != null) { self.mark_hobject(self.ref_err_proto); }
    if (self.syntax_err_proto != null) { self.mark_hobject(self.syntax_err_proto); }
    if (self.eval_err_proto != null) { self.mark_hobject(self.eval_err_proto); }
    if (self.uri_err_proto != null) { self.mark_hobject(self.uri_err_proto); }
    if (self.aggregate_err_proto != null) { self.mark_hobject(self.aggregate_err_proto); }

    // Mark built-in constructor prototypes
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

    // Scan the VM value stack as a GC root — all live TVal slots
    // (from base to top) may reference heap objects or strings.
    if (self.valstack_base != null && self.valstack_top_ptr != null) {
        TVal* top = *self.valstack_top_ptr;
        TVal* scan = self.valstack_base;
        while (scan < top) {
            self.mark_tval(scan);
            scan++;
        }
    }

    // Promise jobs retain their handler, argument, and downstream promise until
    // the queue is drained. These values live outside the VM stack, so mark
    // every live triplet explicitly.
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

    // Mark symbol registry entries
    for (uint i = 0; i < self.symbol_registry_count; i++) {
        HString* key = self.symbol_registry_keys[i];
        HString* sym = self.symbol_registry_syms[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
        if (sym != null) { ((HeapHeader*)sym).set_reachable(); }
    }

    // Mark built-in cached strings
    for (uint i = 0; i < STRS_CACHE_SIZE; i++) {
        HString* s = (HString*)self.strs[i];
        if (s != null) {
            ((HeapHeader*)s).set_reachable();
        }
    }

    // Mark strings in CompiledFunction constant pools.
    // CompiledFunctions are not GC-tracked objects — they live in a
    // separate tracking array.  Their constants may reference interned
    // HStrings that would otherwise be swept.
    for (uint fi = 0; fi < self.compiled_func_count; fi++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[fi];
        if (cf == null || cf.constants == null) { continue; }
        for (uint ci = 0; ci < cf.const_count; ci++) {
            self.mark_tval(&cf.constants[ci]);
        }
        // Mark IC entries: trace cached proto HObject* and key HString*
        if (cf.ic_entries != null && cf.ic_count > 0) {
            hobject::ICEntry* ics = (hobject::ICEntry*)cf.ic_entries;
            for (uint ii = 0; ii < cf.ic_count; ii++) {
                hobject::ICEntry* ie = &ics[ii];
                if (ie.key != null) { ((HeapHeader*)ie.key).set_reachable(); }
                if (ie.proto != null) { self.mark_hobject((HObject*)ie.proto); }
            }
        }
        // Mark VarIC entries: trace cached bindings HObject* and key HString*
        if (cf.var_ic_entries != null && cf.var_ic_count > 0) {
            hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
            for (uint vi = 0; vi < cf.var_ic_count; vi++) {
                hobject::VarICEntry* vie = &vics[vi];
                if (vie.key != null) { ((HeapHeader*)vie.key).set_reachable(); }
                if (vie.bindings != null) { self.mark_hobject((HObject*)vie.bindings); }
            }
        }
    }

    // Mark the cached iterator symbol (may not be in strs[] or symbol registry)
    if (self.iterator_symbol != null) {
        ((HeapHeader*)self.iterator_symbol).set_reachable();
    }

    // Mark the cached Symbol.toStringTag (may not be in strs[] or symbol registry)
    if (self.tostringtag_symbol != null) {
        ((HeapHeader*)self.tostringtag_symbol).set_reachable();
    }

    // Mark the cached Symbol.toPrimitive (may not be in strs[] or symbol registry)
    if (self.toprimitive_symbol != null) {
        ((HeapHeader*)self.toprimitive_symbol).set_reachable();
    }

    // Mark the cached Symbol.isConcatSpreadable (may not be in strs[] or symbol registry)
    if (self.concatspreadable_symbol != null) {
        ((HeapHeader*)self.concatspreadable_symbol).set_reachable();
    }

    // Mark the cached Symbol.hasInstance (may not be in strs[] or symbol registry)
    if (self.hasinstance_symbol != null) {
        ((HeapHeader*)self.hasinstance_symbol).set_reachable();
    }

    // Mark cached @@match, @@search, @@replace, @@split symbols
    if (self.match_symbol != null)   { ((HeapHeader*)self.match_symbol).set_reachable(); }
    if (self.search_symbol != null)  { ((HeapHeader*)self.search_symbol).set_reachable(); }
    if (self.replace_symbol != null) { ((HeapHeader*)self.replace_symbol).set_reachable(); }
    if (self.split_symbol != null)   { ((HeapHeader*)self.split_symbol).set_reachable(); }

    // Mark cached Symbol.species, Symbol.unscopables, Symbol.matchAll, Symbol.asyncIterator
    if (self.species_symbol != null)       { ((HeapHeader*)self.species_symbol).set_reachable(); }
    if (self.unscopables_symbol != null)   { ((HeapHeader*)self.unscopables_symbol).set_reachable(); }
    if (self.matchall_symbol != null)      { ((HeapHeader*)self.matchall_symbol).set_reachable(); }
    if (self.asynciterator_symbol != null) { ((HeapHeader*)self.asynciterator_symbol).set_reachable(); }

    // Mark global checkpoint keys
    for (uint i = 0; i < self.checkpoint_count; i++) {
        HString* key = (HString*)self.checkpoint_keys[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
    }

    // Mark activation-record env bindings (fresh per-call envs not otherwise rooted)
    if (self.mark_activations_fn != null && self.curr_thread != null) {
        self.mark_activations_fn(self.curr_thread, self);
    }

    // Conservative roots pending single-error-channel consolidation
    self.mark_tval(&self.error_value);
    self.mark_tval(&self.yield_value);
    self.mark_generator_state(self.resume_gen);
    self.mark_generator_state(self.gen_initial_gs);

    // Mark the generator object being initialized during an initial generator call.
    // gen_initial_obj is not yet reachable from any register or stack slot during
    // param-init execution, so it must be marked explicitly to prevent GC collection.
    if (self.gen_initial_obj != null) {
        self.mark_hobject((HObject*)self.gen_initial_obj);
    }
    // Mark any generator objects saved on the nested init stack (outer generators
    // whose param-init is paused while an inner generator call completes).
    for (uint gsi = 0; gsi < self.gen_init_stack_depth; gsi++) {
        if (self.gen_init_stack_obj[gsi] != null) {
            self.mark_hobject((HObject*)self.gen_init_stack_obj[gsi]);
        }
    }

    // Mark cached module state. ModuleDefs live in a separate malloc'd cache
    // (not the GC heap) that the sweep never scans, so any TVal they hold must
    // be marked here or it would be collected. `eval_error` is the cached
    // [[EvaluationError]] of an ERRORED module (re-rejected on every later
    // import); `json_value` is a JSON module's default value.
    if (self.module_cache != null) {
        esm::ModuleDef** cache = (esm::ModuleDef**)self.module_cache;
        for (uint i = 0; i < self.module_cache_count; i++) {
            esm::ModuleDef* mod = cache[i];
            if (mod == null) continue;
            if (mod.has_eval_error) { self.mark_tval(&mod.eval_error); }
            if (mod.is_json)        { self.mark_tval(&mod.json_value); }
            // The import.meta object (§16.2.1.10 [[ImportMeta]]) is cached on
            // the ModuleDef and holds user-visible state (added properties,
            // changed prototype/extensibility). It must survive GC for the
            // module's lifetime — mark it explicitly since the cache is not
            // GC-scanned.
            if (mod.import_meta_obj != null) { self.mark_hobject(mod.import_meta_obj); }
        }
    }

    // Drain the gray stack — transitively marks all reachable objects
    self.drain_gray();
}

// ============================================================================
// Heap verification (debug) — enabled with `-D HEAP_VERIFY`
// ============================================================================

/// Validate that a HeapHeader pointer is live and has a valid htype.
/// For OBJECT/BUFFER: walks `heap_allocated` (O(n)).
/// For STRING: checks htype only (symbols are not in str_table, only htype
/// validation is reliable for all string types).
/// Returns true if valid, false + stderr diagnostic if not.
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

    // Strings (including symbols) use alloc_no_gc and are not always tracked
    // in str_table — htype validity is the only reliable check.
    if (ht == HType.STRING) {
        return true;
    }

    // OBJECT/BUFFER: walk the live heap list
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

/// Validate every heap pointer inside a TVal array (e.g. saved_regs).
/// Returns the number of errors found.
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

/// Verify all GC root sets point to live heap objects.
/// Enabled only with `-D HEAP_VERIFY`. Returns true if all checks pass.
fn bool Heap.verify_roots(&self, ZString context) {
$if $feature(HEAP_VERIFY):
    io::eprintf("[HEAP_VERIFY] %s: checking roots...\n", context);

    // Count live objects
    uint live_count = 0;
    HeapHeader* h = self.heap_allocated;
    while (h != null) {
        live_count++;
        h = h.next;
    }
    io::eprintf("[HEAP_VERIFY]   live objects: %d\n", (int)live_count);

    uint checked = 0;
    uint errors = 0;

    // Check GC roots
    for (uint i = 0; i < self.gc_root_count; i++) {
        void* root = self.gc_roots[i];
        if (root != null) {
            if (!self.validate_hobject((HeapHeader*)root, "gc_root")) errors++;
            checked++;
        }
    }

    // Check built-in error prototypes
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

    // Check built-in constructor prototypes
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

    // Scan the VM value stack
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

    // Check symbol registry entries
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

    // Check built-in cached strings
    for (uint i = 0; i < STRS_CACHE_SIZE; i++) {
        HString* s = (HString*)self.strs[i];
        if (s != null) {
            if (!self.validate_hobject((HeapHeader*)s, "strs_cache")) errors++;
            checked++;
        }
    }

    // Check cached well-known symbols
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

    // Check checkpoint keys
    for (uint i = 0; i < self.checkpoint_count; i++) {
        HString* key = (HString*)self.checkpoint_keys[i];
        if (key != null) {
            if (!self.validate_hobject((HeapHeader*)key, "checkpoint_key")) errors++;
            checked++;
        }
    }

    // Check generator saved_regs — walk heap for GENERATOR objects
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

/// Check if a pointer is referenced by any suspended generator's saved_regs.
/// Called during sweep before freeing an object. Returns true if the pointer
/// is in a generator's saved_regs (meaning freeing it would create a dangling pointer).
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
 * Sweep phase: walk the heap_allocated list and free every object that
 * was NOT marked reachable during the mark phase.  Clears the reachable
 * flag on surviving objects for the next cycle.  Unlinks dead nodes
 * from the list.
 */
fn void Heap.sweep(&self) {
    // Enter sweep mode: decref() will now skip references into unmarked
    // (dying) heap nodes so that freeing one garbage object cannot follow a
    // link into a sibling that this same sweep already freed (or is about to).
    // Survivors keep their reachable bit set for the whole free pass so the
    // "unmarked == dying" test stays reliable; a second pass below clears them.
    self.sweeping = true;

    // Phase A: unlink every dying (unmarked, non-temproot) node from the
    // heap_allocated list and thread it onto a local "dying" list via its
    // now-unused .next pointer. Nothing is freed yet, so every dying node's
    // header — and its mark bit — stays readable through phases B and C.
    HeapHeader* cur = self.heap_allocated;
    HeapHeader* prev = null;
    HeapHeader* dying = null;
    uint kept = 0;

    while (cur != null) {
        HeapHeader* next = cur.next;
        if (!cur.is_reachable() && !cur.is_temproot()) {
            // Unlink from the live list.
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
            // Thread onto the dying list (reuse .next; node is off the heap now).
            cur.next = dying;
            dying = cur;
        } else {
            // Survivor (reachable, or an unmarked-but-kept temproot). Keep its
            // reachable bit set until the whole free pass finishes so decref's
            // "unmarked == dying" test stays valid for nodes freed later.
            prev = cur;
            kept++;
        }
        cur = next;
    }

    // Phase B: run every dying node's teardown (hobject_free) with all dying
    // memory still valid. hobject_free may decref neighbours it references; the
    // decref sweep guard skips any neighbour that is itself dying (unmarked,
    // non-temproot), so no dying header is re-freed or read after free here.
    for (HeapHeader* d = dying; d != null; d = d.next) {
        if (d.is_object()) {
            hobject::hobject_free((HObject*)d, (void*)self, false);
        }
    }

    // Phase C: release the header memory of every dying node. Done last so no
    // teardown in phase B could have touched an already-freed neighbour.
    HeapHeader* d = dying;
    while (d != null) {
        HeapHeader* dnext = d.next;
        if (d.is_object()) {
            hobject::hobject_free_header((HObject*)d, (void*)self);
        } else {
            // BigInt box (or any non-object leaf) — free directly.
            self.free_func(self.heap_udata, d);
        }
        d = dnext;
    }

    // Free pass complete — no more dying nodes will be touched. Now clear the
    // mark/temproot bits on the survivors for the next cycle. Reachable
    // survivors clear both bits; temproot-kept nodes (unmarked but retained)
    // keep their temproot flag so they stay protected until anchored.
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
 * Sweep the string table: no-op for RC-managed strings.
 * Strings are freed by refcounting, not M&S. Kept as a hook for
 * future hybrid RC+M&S string collection if needed.
 */
fn void Heap.sweep_strings(&self) {
    // Sweep interned strings that have only the string table reference
    // (refcount == 1).  These strings are no longer referenced by any
    // register, property, or stack slot — only the table keeps them alive.
    // Removing them frees memory while keeping the table consistent.
    if (self.str_table_size == 0) { return; }
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) { continue; }
        // refcount == 1 alone does not prove the string is dead: property
        // tables and IC entries hold keys without a reference, relying on
        // the string table to keep them alive.  Only free strings the mark
        // phase did not reach (keys of live objects are marked by drain_gray).
        if (entry.refcount == 1 && !((HeapHeader*)entry).is_reachable()) {
            self.str_table[i] = STR_TABLE_TOMBSTONE;
            if (self.str_table_used > 0) { self.str_table_used--; }
            self.free_string(entry);
        }
    }

    // Shrink table if usage fell below 25%
    if (self.str_table_used < self.str_table_size / 4 && self.str_table_size > INITIAL_STR_TABLE_SIZE) {
        self.str_table_shrink();
    }
}

/**
 * Sweep the large-string registry: free every registered string the mark
 * phase did not reach.
 *
 * The registry is a weak list — it holds no reference of its own — so unlike
 * the string table there is no refcount level that means "only the registry
 * is left".  Reachability is the whole test: a large string referenced by any
 * marked register, property, or stack slot was marked by mark_tval, and
 * anything unmarked is unreferenced no matter what its refcount claims.  That
 * makes this pass a true backstop for a refcount that was never decremented.
 *
 * Runs under the same safety condition as sweep_strings (see mark_and_sweep
 * phase 3b): only at a safe point where no raw HString* is live in a C3 local.
 */
fn void Heap.sweep_large_strings(&self) {
    uint kept = 0;
    for (uint i = 0; i < self.large_string_count; i++) {
        HString* s = self.large_strings[i];
        if (((HeapHeader*)s).is_reachable()) {
            // Compact survivors down; their recorded slot moves with them.
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
 * Re-entrancy is prevented by the gc_running guard.
 *
 * When `safepoint` is true, Phase 1 also clears all temproot flags so that
 * newly allocated objects become eligible for collection.  Emergency
 * (non-safepoint) GC preserves temproots so in-flight allocations survive it.
 *
 * Temproots are only genuinely safe to clear when no native builtin frame is
 * on the C3 stack.  A builtin that allocates a result object and then re-enters
 * the VM (calling a user callback, a getter, a species constructor, ...) holds
 * that object solely in a raw C3 local: the nested execution reaches VM
 * safepoints, but the mark phase cannot see the local.  Clearing its temproot
 * there would sweep an object the builtin is still about to write to, so
 * native_frame_depth vetoes the clear.
 */
fn void Heap.mark_and_sweep(&self, bool safepoint) {
    if (self.gc_running) { return; }
    self.gc_running = true;

    bool clear_temproots = safepoint && self.native_frame_depth == 0;

    // --- Phase 1: Clear all reachable (and optionally temproot) flags ---
    {
        HeapHeader* cur = self.heap_allocated;
        while (cur != null) {
            cur.clear_reachable();
            if (clear_temproots) {
                cur.clear_temproot();
            }
            cur = cur.next;
        }
        // Interned strings are not on the heap_allocated list; clear their
        // marks via the string table so sweep_strings sees fresh bits.
        for (uint i = 0; i < self.str_table_size; i++) {
            HString* s = self.str_table[i];
            if (s != null && s != STR_TABLE_TOMBSTONE) {
                ((HeapHeader*)s).clear_reachable();
            }
        }
        // Large strings are in neither list; clear their marks via the
        // registry so sweep_large_strings sees fresh bits.
        for (uint i = 0; i < self.large_string_count; i++) {
            ((HeapHeader*)self.large_strings[i]).clear_reachable();
        }
    }

    // --- Phase 2: Mark from roots ---
    self.mark_roots();

    // --- Phase 3: Sweep objects ---
    self.sweep();

    // --- Phase 3b: Sweep unreachable strings (safe points only) ---
    // GC can trigger from any allocation, including while builtin init or
    // VM opcode code holds a freshly interned HString* in a C3 local that
    // is anchored nowhere the mark phase can see (e.g. between str_intern
    // and put_prop).  Sweeping the string table at such a moment frees the
    // in-flight string.  Only sweep when the caller guarantees no raw
    // interned-string pointers are live (heap reset between scripts).
    if (self.string_sweep_safe) {
        self.sweep_strings();
        self.sweep_large_strings();
    }

    // --- Phase 4: Reset trigger counter (scales with live heap) ---
    long new_trigger = (long)self.live_obj_count * GC_TRIGGER_GROW_FACTOR;
    if (new_trigger < GC_INITIAL_TRIGGER) {
        new_trigger = GC_INITIAL_TRIGGER;
    }
    self.gc_trigger_counter = new_trigger;
    self.gc_running = false;
}

/**
 * Trigger a mark-and-sweep GC pass (emergency / non-safepoint).
 * Temproot objects are preserved — in-flight allocations survive.
 */
fn void Heap.trigger_gc(&self) {
    self.mark_and_sweep(false);
}

/**
 * Run a GC at a VM safe point.  With no native builtin frame active, every
 * live value is anchored in registers, environments, or object graphs, so
 * temproot flags can be cleared and the string table swept.
 *
 * A safepoint reached from inside a builtin's nested VM execution is not that
 * quiet: the builtin's own C3 locals may hold a freshly allocated object or an
 * interned string that nothing roots.  Both reclamation passes are therefore
 * suppressed while native_frame_depth is non-zero; the collection still runs
 * and still reclaims everything the mark phase can prove dead.
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
 * Compute a 32-bit FNV-1a hash of `data`.  Mixes in the heap's random
 * state for HashDoS mitigation.
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
 * Grow the string table when the load factor exceeds the threshold.
 * Rehashes every live entry into the new table.
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
 * Look up an interned string by raw byte content and precomputed hash.
 * Returns the existing HString or `null` if not found.
 */
fn HString* Heap.str_table_lookup(&self, char[] data, uint hash) {
    if (self.str_table_size == 0) { return null; }

    uint idx = hash & (self.str_table_size - 1);

    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null) {
            return null;  // empty slot — not present
        }
        if (entry == STR_TABLE_TOMBSTONE) {
            idx = (idx + 1) & (self.str_table_size - 1);
            continue;  // deleted slot — keep probing
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
 * Insert a fully initialised HString (with .hash set) into the string
 * table.  Grows the table first if the load factor is too high.
 *
 * Taking a slot makes the table an owner: the string is marked interned and
 * increfed for the table's reference, which is what `str_table_remove` and
 * the reset/destroy sweeps release.  A string that fails to get a slot stays
 * un-interned and is left to plain refcounting, so it must be registered as
 * a large string by the caller to remain reachable for teardown.
 */
fn bool Heap.str_table_insert(&self, HString* hstr) {
    // Grow if necessary
    float load = (float)(self.str_table_used + 1) / (float)self.str_table_size;
    if (load > STR_TABLE_LOAD_FACTOR) {
        // Best-effort grow; if it fails we still insert into the
        // existing table (it will just be slower).
        void* ignored = self.str_table_grow() ?? null;
    }

    uint idx = hstr.hash & (self.str_table_size - 1);
    uint first_tombstone = self.str_table_size;  // sentinel: no tombstone found
    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) {
            if (entry == STR_TABLE_TOMBSTONE && first_tombstone == self.str_table_size) {
                first_tombstone = idx;
            }
            if (entry == null) {
                // Use the first tombstone if we found one, otherwise this null slot
                uint use = (first_tombstone < self.str_table_size) ? first_tombstone : idx;
                self.str_table[use] = hstr;
                self.str_table_used++;
                self.str_table_adopt(hstr);
                return true;
            }
        }
        idx = (idx + 1) & (self.str_table_size - 1);
    }
    // Table is full but we found a tombstone — reuse it
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

/// Lazy-intern: ensure an HString is in the string table.  If already
/// interned, returns it unchanged.  Otherwise looks up by content (may
/// find an existing copy), or inserts this string.  Used by property
/// lookup when a non-interned concatenation result is used as a key.
fn HString* Heap.ensure_interned(&self, hstring::HString* s) {
    if (s.flags.is_interned) return s;
    HString* existing = self.str_table_lookup(s.get_data(), s.hash);
    if (existing != null) return existing;
    // Promotion into the table: the string table tracks it from here on, so
    // it must leave the registry or the sweep would free it behind the
    // table's back.  If the table cannot take it, put it back on the registry
    // so it still has an owner.
    self.large_string_unregister(s);
    if (!self.str_table_insert(s)) { self.large_string_register(s); }
    return s;
}

/**
 * Intern a string: return the existing copy if one exists, otherwise
 * allocate, insert, and return the new copy.  Returns null on alloc failure.
 */
/// Lightfunc virtual property deletion tracking.
/// Bit index = fn_idx * 3 + prop_bit, where prop_bit: 0=name, 1=length, 2=prototype.
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

/// Resolve a lightfunc virtual property name to a prop_bit.
/// Returns -1 if the key is not a virtual property.
fn int lf_key_to_prop_bit(HString* key) @inline {
    if (key.equals("name")) return 0;
    if (key.equals("length")) return 1;
    if (key.equals("prototype")) return 2;
    return -1;
}

fn HString* Heap.str_intern(&self, char[] data) {
    // Normalize any raw 4-byte UTF-8 astral sequences (e.g. a literal
    // emoji typed directly in source) to CESU-8 surrogate pairs *before*
    // hashing/lookup — otherwise the same logical string could intern
    // under two different byte encodings depending on how the astral
    // character reached this call (literal vs. \u{...} escape vs.
    // String.fromCodePoint), breaking `===` and property-key dedup.
    // Fast path: the overwhelming majority of strings have no 4-byte
    // sequences at all, so skip the scratch allocation entirely.
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

/// Intern already-CESU-8-canonical bytes. Callers that can guarantee their
/// input has no raw 4-byte UTF-8 sequences (e.g. pure-ASCII builtin
/// literals, or data already round-tripped through `normalize_to_cesu8`)
/// may call this directly to skip the astral-scan fast-path check.
fn HString* Heap.str_intern_normalized(&self, char[] data) {
    uint hash = self.hash_string(data);
    // Large strings are never used as property keys, symbols, or identifiers.
    // Interning them accumulates dead strings in the table until the next GC,
    // causing O(n²) memory growth in string-building loops (e.g. buildString
    // in the test262 regExpUtils harness).  Return a heap-allocated but
    // non-interned string instead; it will be freed promptly by refcounting.
    if (data.len > MAX_INTERN_BYTES) {
        HString*? new_s = hstring::hstring_alloc(self, data, hash);
        if (try s = new_s) {
            // Not in the string table, so register it for the mark-sweep
            // backstop and for release at heap reset.
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
        // str_table_insert takes the table's owning reference (incref +
        // is_interned).  If the table could not take the string, fall back to
        // the large-string registry so reset/destroy can still free it.
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
// Internal helpers
// ============================================================================

// ============================================================================
// Microtask queue — PromiseJobs job queue
// ============================================================================

/// Enqueue a microtask (Promise reaction job).  Each entry stores a
/// (handler, argument, downstream) triple.  The queue is drained after each
/// top-level script execution and after vm_call_fn_impl returns for compiled
/// functions.
fn void Heap.enqueue_microtask(&self, TVal handler, TVal arg, TVal downstream) {
    // Grow if needed (each entry = 3 TVal slots)
    uint needed = self.microtask_count + 1;
    if (needed > self.microtask_capacity) {
        uint new_cap = self.microtask_capacity == 0 ? 16 : self.microtask_capacity * 2;
        usz new_bytes = (usz)new_cap * TVal::size * 3;
        TVal* new_q = (TVal*)self.realloc_func(self.heap_udata, self.microtask_queue, new_bytes);
        if (new_q == null) { return; }
        // Zero the new slots
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

/// Drain the microtask queue.  Processes all currently-enqueued entries,
/// and continues draining if new entries are added during execution
/// (e.g. a handler resolves another promise).  Uses a re-entrancy guard
/// to prevent infinite loops.
fn void Heap.drain_microtasks(&self, void* vm) {
    if (self.microtask_draining) { return; }
    if (self.microtask_count == 0) { return; }
    self.microtask_draining = true;
    defer self.microtask_draining = false;

    // Process the queue in strict FIFO order with a read cursor. Handlers may
    // enqueue new jobs during processing — those append past the cursor and
    // are processed in the same drain (ES2015+ job-queue ordering). Do NOT
    // reset microtask_count before processing: new enqueues would overwrite
    // the in-flight batch from slot 0 (and the still-queued entries stop
    // being GC-visible).
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
