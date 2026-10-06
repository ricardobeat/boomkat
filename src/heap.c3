module boomkat::heap;

import boomkat::types;
import boomkat::gcprofile;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::bytecode;
import boomkat::re_bindings;
import boomkat::esm;
import boomkat::vm;
import std::io;
import std::collections::list;
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

// Calls a JS handler function from a builtin, passing one argument.
// The VM pointer is opaque here to keep heap independent of the vm module.
alias VmCallHandlerFn = fn TVal(void* vm, TVal handler, TVal* arg);
// Marks activation-record env bindings during the GC mark phase.
alias MarkActivationsFn = fn void(void* vm, void* heap);
alias MarkActivationsSliceFn = fn bool(void* vm, void* heap, uint* cursor, uint budget);

// Walks a Catcher chain head, which the heap holds only as an opaque `void*`
// (Catcher lives in the vm module, which depends on this one). A suspended
// generator's chain needs marking during GC and freeing at teardown, and the
// heap can do neither without knowing the layout. Set by vm_create.
alias CatcherChainFn = fn void(void* heap, void* cat_head, int mode);

// Mark the chain's values for the GC and leave the chain intact.
const int CATCHER_CHAIN_MARK             = 0;
// Release the owned values and free every node.
const int CATCHER_CHAIN_FREE             = 1;
// Free every node without releasing what it points at, for heap teardown,
// where the referents are already gone.
const int CATCHER_CHAIN_FREE_NODES_ONLY  = 2;

// Runs after a microtask handler completes, with the handler's return value
// and the downstream promise to resolve.
alias MicrotaskAfterFn = fn void(void* heap, void* vm, TVal result, TVal downstream);

// Host notification for a promise that was rejected with nothing watching it.
// Called once per such promise at the end of drain_microtasks, with the
// rejection reason. `udata` is whatever the host passed to
// Heap.set_rejection_tracker.
alias RejectionTrackerFn = fn void(void* heap, void* vm, TVal promise, TVal reason, void* udata);

// Calls a JS function with an argument array and an explicit `this`.
// The VM owns the returned value until its next callback result. A caller
// retaining it across another call acquires its own reference.
alias VmCallFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal this_val);

// Invokes a JS function as a constructor and returns the resulting `this`.
// `new_target` is the value seen as `new.target` inside the constructor,
// which is the subclass for super() calls.
alias VmConstructFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal new_target);

// Proxy MOP bridges, set by vm_create. They let the hobject prototype-chain
// walkers route through Proxy traps without depending on the builtins layer.
// On error the callee sets heap.has_error/error_value and returns false.
alias ProxyGetFn = fn bool(void* vm, void* heap, void* proxy, void* key, TVal receiver, TVal* out);

// Force a Deferred Module Namespace Exotic Object's module to evaluate
// (ES2025 import-defer). Installed by the VM so hobject's prototype-chain
// walk can trigger deferral without depending on the module subsystem, the
// same arrangement as ProxyGetFn above. Returns false when evaluation threw.
alias ForceDeferredNsFn = fn bool(void* heap, void* vm, void* ns);
alias ProxyHasFn = fn bool(void* vm, void* heap, void* proxy, void* key, bool* out);

// --- Faults ---

faultdef HEAP_ALLOC_FAULT;

// --- Constants ---

const uint  INITIAL_STR_TABLE_SIZE  = 256;
// The string table grows once more than this many tenths of its slots are used.
const uint  STR_TABLE_MAX_LOAD_TENTHS = 7;
const long  GC_INITIAL_TRIGGER      = 1;
const long  GC_TRIGGER_GROW_FACTOR  = 1;
// Divisor applied to the last cycle's mark work when it sets the next cycle's
// allocation budget.
//
// The budget wants to track marking cost (see the trigger reset), but using
// that cost raw collects far too rarely and holds a lot of floating garbage.
// Dividing it trades a little of each back. Measured on `for (const x of arr)`
// over a 200k array (best of 5) with peak RSS from the 400k case:
//
//     divisor   1      82ms   137MB
//     divisor   4      81ms    90MB
//     divisor   8      79ms    82MB
//     divisor  16      75ms    78MB   <- both fastest and near-leanest
//     divisor  32      86ms    76MB
//     divisor  64      98ms    77MB
//
// 16 is not a compromise between the two: collecting a little more often
// keeps the working set in cache, so below it the extra floating garbage
// costs time as well as memory, and above it the collection frequency starts
// to dominate again.
const long  GC_MARK_WORK_DIVISOR    = 16;
const uint  GC_CALL_INTERVAL        = 16;
const uint  MEGA_CACHE_SIZE         = 512;
// Initial capacity for Array.prototype.join's in-progress set, allocated on
// first use (most programs never nest a join) and grown as needed.
const uint  JOIN_VISITED_INITIAL_CAP = 16;
const usz   STRS_CACHE_SIZE         = 256;
const usz   ASCII_CHAR_CACHE_SIZE   = 128;

// Marks an embedder-owned root set that is not an HObject. Called during
// mark_roots with the pointer stored in Heap.capi_roots.
alias CapiMarkFn = fn void(void*);
alias CapiMarkSliceFn = fn bool(void* roots, void* heap, uint* cursor, uint budget);

enum GcPhase : char { IDLE, MARK, SWEEP }
enum GcKind : char { MAJOR, MINOR }

struct EnvSweepCursor {
    void* block;
    uint index;
    bool started;
}
// The C ABI's interrupt callback, invoked by the VM at safepoints. Returns
// non-zero to abort the running script. Lives here rather than in the capi
// module so vm_execute can call it without importing capi (which imports vm).
alias BkInterruptFn = fn int(void* runtime, void* opaque);
// How many backward jumps between GC checks. Spacing them out stops loops
// from thrashing the collector.
const uint  BWD_GC_INTERVAL        = 1024;
// How many back-edge safepoints between interrupt handler calls. Under
// threaded dispatch most back-edges run inside the burst and never reach the
// switch, which is where the poll site lives, so the effective cadence there
// is this many times BWD_GC_INTERVAL. A power of two; reset after every
// handler call and at each top-level eval, so a near-zero budget from a prior
// run cannot trigger an immediate unprompted callback.
const uint  INTERRUPT_BUDGET_INIT  = 16;
// Strings longer than this are never interned. They are very rarely property
// keys, and interned copies pile up in the table until the next GC, which
// gives O(n^2) memory growth in loops like `s += chunk`.
const uint  MAX_INTERN_BYTES        = 256;

// Lightfunc deleted-property bitset sizing.
// Each builtin index occupies 3 bits: name, length, and prototype deleted flags.
const uint LF_DELETED_WORDS   = 32;                          // ulong words in lf_deleted_props
const uint LF_MAX_TRACKED     = (LF_DELETED_WORDS * 64) / 3; // 682, the highest trackable builtin index
// Sentinel marking a deleted string table entry, so open addressing can probe past it.
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

// Generator execution state, per ES6 §25.3.3.1 GeneratorState.
enum GeneratorStateType : char {
    GEN_SUSPENDED_START,
    GEN_SUSPENDED_YIELD,
    GEN_EXECUTING,
    GEN_COMPLETED,
    // Async generators only (ES2018 §27.6). The generator is working through
    // the §27.6.3.7 await-return steps for a `.return()` request, and holds
    // off draining further requests until that settles.
    GEN_AWAITING_RETURN,
}

// One entry in an async generator's request queue (ES2018 §27.6.3.1
// AsyncGeneratorRequest). Concurrent next/return/throw calls each push a
// request and get their own promise. The queue drains FIFO.
struct AsyncGenRequest {
    ResumeKind        completion_kind; // NEXT, RETURN, or THROW
    TVal              value;           // completion value, or the thrown value
    void*             capability;      // HObject* of the promise to settle, opaque to avoid a module cycle
    AsyncGenRequest*  next;            // FIFO link; null at the tail
}

// How a generator was resumed, which tells the YIELD opcode what to do when
// execution reaches a yield point.
enum ResumeKind : char {
    NEXT,     /// .next(): yield returns an IteratorResult as usual
    THROW,    /// .throw(): inject an exception at the yield point
    RETURN,   /// .return(): inject a return at the yield point
}

// How an async-generator body last suspended. The AWAIT and YIELD opcodes
// record this so async_gen_drain knows what to do with the value coming back
// from the body. YIELD and RETURN settle the current request. AWAIT means the
// body suspended on an internal `await`, so a microtask re-drives it and the
// current request's promise stays untouched.
enum GenSuspendKind : char {
    AG_SUSPEND_NONE,   /// idle, or this is not an async-gen resume
    AG_SUSPEND_AWAIT,  /// body suspended at an internal `await`, invisible to the caller
    AG_SUSPEND_YIELD,  /// body reached a `yield`, so settle the current request with {v, false}
}

// ============================================================================
// For-in enumeration state
// ============================================================================

// Runtime state for a for-in loop iteration. Created by INITFOR.
//
// OWNERSHIP: the state is owned by the *activation that created it*, via the
// intrusive `parent` chain rooted at `Activation.forin`, exactly like the
// Catcher chain hanging off `Activation.cat`. The `iter_state` register that
// INITFOR writes holds a BORROWED pointer, read by NEXTFOR to advance the
// enumeration; it is never the owner.
//
// The register cannot be the owner because a for-in has many abrupt exits
// (break, labeled break, return, throw, labeled continue to an outer loop)
// and the compiler frees the register after the loop, so a state left behind
// by an early exit becomes unreachable. Making the *frame* the owner means
// no exit edge has to remember anything: every one of them either re-runs
// INITFOR (which releases the state its own output register still names) or
// pops the activation (which drains the whole chain). See free_forin_chain.
//
// `keys` holds a flat array of interned HString* pointers collected from
// the object and its prototype chain (omitting duplicates). The array and
// the struct itself are plain-malloc'd; forin_state_free releases both.
//
// `target` is the original for-in target (a borrowed pointer to the
// heap-allocated HObject). The activation or suspended generator traces it,
// even when the loop body does not reference it. NEXTFOR re-checks property
// existence at yield time per EnumerateObjectProperties, so a property deleted
// before its turn is skipped (plan 062 group N).
//
// The snapshot owns each key until enumeration finishes, including virtual
// Proxy keys and keys deleted while the loop is suspended.
struct CheckpointEntry {
    hstring::StringRef key;
    TVal value;
}

struct ForInState {
    hstring::StringRef* keys; /// Owned enumeration snapshot
    HObject* target;     /// Borrowed pointer to the for-in target (NOT owned)
    ForInState* parent;  /// Next state on the owning activation's chain
    uint count;          /// Number of keys in the array
    uint index;          /// Current position (next key to return)
}

// Saved execution context for a generator.
//
// Calling a generator function saves the initial execution state here and
// returns a generator object. Later calls to .next(), .throw(), or .return()
// resume the body from this state.
struct GeneratorState {
    // All live states form a heap-owned intrusive list. Marking uses a separate
    // queue link so the registry remains stable through a collection.
    GeneratorState* gc_next;
    GeneratorState* gc_prev;
    GeneratorState* gc_gray_next;
    bool gc_gray_queued;
    bool gc_mark_epoch;
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
    // ForInState* chain head, opaque and saved across yields exactly like
    // `cat`. A generator can suspend in the middle of a for-in, and the
    // suspend pops the activation, so ownership of the frame's live for-in
    // states moves here. Otherwise the pop would free states that saved_regs
    // still points at, and resuming would read freed memory. Resume moves them
    // back, and gs_release frees them if the generator never resumes.
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
    // How many HObjects currently hold this GeneratorState: the generator
    // instance, plus every `is_async_state` reaction closure that parks the
    // pointer in func.var_env. Maintained by gs_acquire and gs_release.
    uint ref_count;
}

// Register one more HObject holder of `gs`. Every store of a GeneratorState*
// into an HObject (gen.generator_data or an is_async_state func.var_env) must
// be paired with this, and with a gs_release when that HObject is torn down.
fn void gs_acquire(GeneratorState* gs) {
    if (gs != null) { gs.ref_count++; }
}

// Drop one HObject's hold on `gs`, freeing the state and its saved registers
// once the last holder is gone.
//
// The count is the only ownership signal. Sweep tears down every dying node in
// one pass, so deciding ownership by reading a gs field would race siblings in
// that same pass: the first free recycles the struct, and the next holder reads
// whatever landed there.
//
// `heap_ptr` is always required, including during full-heap teardown, which
// still frees through the heap's own allocator. With an embedder allocator,
// freeing to libc instead would be a cross-allocator free.
//
// `run_decref` is false during teardown, where the heap is already coming apart.
fn void gs_release(GeneratorState* gs, void* heap_ptr, bool run_decref) {
    if (gs == null) { return; }
    if (gs.ref_count > 0) { gs.ref_count--; }
    if (gs.ref_count != 0) { return; }
    if (heap_ptr == null) {
        // No heap at all (defensive): nothing sensible to free through.
        return;
    }
    Heap* h = (Heap*)heap_ptr;
    if (run_decref && !h.tearing_down) {
        h.retire_generator_state(gs);
        return;
    }
    // Normal retirement releases saved registers, this_binding, the current
    // async-generator completion, and queued request completions in slices.
    // Teardown frees their storage directly after string allocations are
    // handled as a group.
    if (run_decref) {
        if (gs.saved_regs != null) {
            for (uint i = 0; i < gs.num_regs; i++) {
                h.decref_tval(&gs.saved_regs[i]);
            }
        }
        h.decref_tval(&gs.this_binding);
    }
    if (gs.saved_regs != null) { h.free_scanned((void*)gs.saved_regs, (usz)gs.num_regs * TVal::size); }
    // A generator abandoned mid-for-in (never resumed to exhaustion, then
    // collected) still owns the states its body was enumerating, which were
    // MOVED here when the body suspended. Nothing else can reach them now, so
    // this is their last chance to be freed. The target's temporary pin belongs
    // to the safepoint lifetime and may also protect native locals.
    ForInState* fi = (ForInState*)gs.forin;
    while (fi != null) {
        ForInState* fi_parent = fi.parent;
        hstring::free_string_refs(h, fi.keys[:fi.count]);
        h.free_scanned((void*)fi, (usz)ForInState::size);
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
    AsyncGenRequest* req = gs.agr_head;
    while (req != null) {
        AsyncGenRequest* next = req.next;
        h.free_scanned(req, AsyncGenRequest::size);
        req = next;
    }
    gs.agr_head = null;
    gs.agr_tail = null;
    h.free_generator_state(gs);
}

// One parked Atomics.waitAsync waiter. `byte_index` is an absolute offset into
// `buffer`, and Atomics.notify resolves `promise` with "ok".
struct AtomicsWaiter {
    hobject::HObject* buffer;
    hobject::HObject* promise;
    uint              byte_index;
    bool              active;
}

// One registered host function.
//
// `handler` is the host trampoline; it is called with the BuiltinContext the
// VM already staged, so no argument copying happens at the boundary itself.
// `udata` is opaque and passed through untouched. `name` is an interned
// HString backing Function.prototype.name, and `arity` backs .length.
// Called during the mark phase for each live instance of the class. Must mark
// every JS value the payload holds, via Heap.mark_tval / Heap.mark_hobject.
alias HostClassMarkFn = fn void(void* payload, Heap* heap, void* udata);

// Called when an instance is collected. Frees whatever the payload owns; must
// not allocate on the JS heap or resurrect objects.
alias HostClassFinalizeFn = fn void(void* payload, void* udata);

// A class registered at runtime by an embedder or add-on. Instances are
// ObjClass.HOST objects whose extra.host.class_id indexes Heap.host_classes.
//
// `gc_mark` is the load-bearing field: without it, JS values held inside a
// payload are invisible to the collector and get freed underneath the module.
// Both callbacks may be null for a payload that holds no JS values and needs
// no teardown.
//
// `proto` is the prototype instances get, and is a GC root: the heap marks it
// for every registered class, so a module does not need engine-side storage
// for its prototypes.
struct HostClassEntry {
    void* finalizer;     // HostClassFinalizeFn
    void* gc_mark;       // HostClassMarkFn
    void* udata;
    hstring::StringRef name;
    HObject* proto;      // prototype for instances; marked as a root
}

struct HostFnEntry {
    void* handler;
    void* udata;
    hstring::StringRef name;
    int   arity;
    bool  constructable;
}

// One host-call scope: the values a single host callback can address.
//
// `values` is a real JS Array allocated through alloc_object, so it carries a
// temproot flag and its elements are marked transitively. That is what keeps
// arguments alive without spending a GC-root entry, and
// without referencing ctx.regs — a nested bk_call can realloc the valstack
// and leave a register pointer dangling (see vm_calls.c3:1331).
//
// `generation` is bumped every time a scope is popped, so a handle used after
// its callback returned fails the check and reads no freed memory.
struct HostScope {
    hobject::HObject* values;
    uint              generation;
}

// --- Heap struct ---

// Size classes for the small-block pools on the Heap. Property blocks and
// string bodies both draw from them, so the classes cover the property-table
// sizes (8-byte slots growing at 1.5x: 64, 96, 144, 216, ...) and the string
// sizes that dominate real programs (a 40-byte header plus a short payload).
// Requests above the largest class go through the heap allocator, where the
// per-block overhead is a rounding error.
const usz POOL_CLASS_COUNT = 16;
const usz[POOL_CLASS_COUNT] POOL_CLASS_SIZES = {
    48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192
};

// The pool that holds a request of `size` bytes, or -1 when it exceeds the
// largest class and must go to the heap allocator.
fn int pool_class_index(usz size) @inline {
$if $feat(POOL_BYPASS):
    // Debug builds send every block to the heap allocator rather than a size
    // class. A pooled block is recycled through its pool's freelist and never
    // reaches free(), so AddressSanitizer cannot poison it and a
    // use-after-free reads memory that is still mapped -- returning whatever
    // the pool has since handed out at that address. Reporting -1 for every
    // size takes the allocator path that alloc, pool_alloc and pool_free
    // already share for oversized blocks, so each block becomes a real
    // alloc/free pair and ASan reports the offending read where it happens.
    //
    // Doing it here rather than at the three call sites keeps alloc and free
    // agreeing on the classification, which is what makes the switch safe: a
    // block allocated with bypass on must never be freed with it off.
    return -1;
$else
    for (usz i = 0; i < POOL_CLASS_COUNT; i++) {
        if (size <= POOL_CLASS_SIZES[i]) return (int)i;
    }
    return -1;
$endif
}

// Block count for one object pool page.
//
// A page is a single allocator request, and the allocator rounds it up to its
// next size class, so a page that spills just past 64 KB costs about a quarter
// more than the same bytes packed under it. Measured: 8M plain objects cost
// 1168 MB with 512-block pages (53 KB) and 1011 MB with 630-block pages
// (65.5 KB); 4M Date objects cost 708 MB with 512-block pages (74 KB) and
// 647 MB with 455-block pages (65.5 KB). Sizing each page to fill the class it
// lands in is worth roughly a tenth of the heap.
fn sz pool_page_blocks(sz block_size) @inline {
    return (sz)(65536 / block_size);
}

// One link of an allocation-free stack of native scoped environment roots. A
// C3 local that holds the only reference to an EnvRecord across a GC-capable
// call pushes one of these; the GC traces the stack on every collection so a
// detached scope's bindings stay alive until the local goes out of scope.
struct EnvRoot {
    EnvRoot* previous;
    void*    env;  // EnvRecord* (opaque)
}

// A native local can keep an object alive across arbitrary VM re-entry,
// including quiescent collections that expire allocation pins.
struct ObjectRoot {
    ObjectRoot* previous;
    HObject* object;
}

// A native local can own a temporary JS value across a reentrant callback.
struct ValueRoot {
    ValueRoot* previous;
    TVal value;
}

// Slot indices of the properties RegExp.prototype must still hold, in the order
// `regexp_proto_pristine` checks them, valid while the prototype keeps this
// shape. `epoch` is the heap's shape-recycle epoch when `shape_id` was read.
struct RegExpGuard {
    uint shape_id;
    uint epoch;
    ushort[12] slots;
}

struct Heap {
    // Allocator callbacks
    AllocFunc    alloc_func;
    ReallocFunc  realloc_func;
    FreeFunc     free_func;
    void*        heap_udata;
    FatalFunc    fatal_func;

    // Flags
    uint flags;

    // Young survivors join the old allocation list during bounded sweeping.
    HeapHeader*  heap_allocated;
    HeapHeader*  young_allocated;
    HeapHeader*  finalize_list;

    // String interning table (open-addressing)
    HString**    str_table;
    uint         str_table_size;
    uint         str_table_used;

    // Weak registry for non-interned strings. The one-based header slot lets
    // removal swap in the final entry without scanning the live strings.
    HString**    large_strings;
    uint         large_string_count;
    uint         large_string_capacity;

    // Built-in strings cache (indexed by string constant IDs)
    void*[STRS_CACHE_SIZE]  strs;

    // GC state
    long  gc_trigger_counter;
    bool  gc_pending;            /// The next safepoint has collector work: a collection or a sweep step
    bool  gc_requested;          /// A collection is due; see request_gc
    GcPhase gc_phase;
    GcKind gc_kind;
    uint gc_minors;
    uint gc_old_count;
    uint gc_major_old_count;
    ulong gc_major_mark_work;
    uint gc_young_kept;          /// Young objects the current major cycle promoted
    uint gc_young_dead;          /// Young objects the current major cycle freed
    bool gc_major_churn;         /// The last major cycle freed most of the young objects it swept
    ulong gc_aux_alloc_bytes;
    HObject* gc_remembered;
    HObject* gc_remembered_cursor;
    GeneratorState* gc_root_generator_cursor;
    EnvSweepCursor gc_aux_env_cursor;
    HeapHeader* gc_old_sweep_start;
    bool gc_sweep_old;
    bool gc_blocking;
    bool gc_keep_temproots;
    GcGeneratorCursor gc_generator_cursor;
    // Released catcher blocks awaiting reuse, linked through their first word.
    // See catcher_release.
    void*             catcher_pool;
    uint              catcher_pool_len;
    GeneratorState* gc_gen_retired;
    GcGeneratorReleaseCursor gc_generator_release_cursor;
    bool gc_mark_epoch;
    bool gc_oracle_running;
    bool gc_in_step;
    uint gc_root_stage;
    uint gc_root_index;
    uint gc_root_subindex;
    uint gc_new_compiled_index;
    uint gc_new_compiled_subindex;
    bool gc_new_compiled_pending;
    uint gc_weak_func_index;
    uint gc_weak_entry_index;
    uint gc_sweep_stage;
    uint gc_string_index;
    uint gc_large_string_index;
    bool gc_roots_done;
    bool gc_weak_done;
    uint gc_mark_schedule_stage;
    ulong gc_alloc_since_begin;
    ulong gc_alloc_paced;        /// gc_alloc_since_begin as of the last slice that was sized by it
    EnvSweepCursor gc_env_sweep_cursor;
    HObject* gc_free_object;
    usz gc_free_index;
    ObjectRoot* gc_root_object_cursor;
    EnvRoot* gc_root_env_cursor;
    ValueRoot* gc_root_value_cursor;
    uint gc_vm_root_cursor;
    uint gc_capi_root_cursor;
    HObject* gc_gray_head;
    HObject* gc_gray_tail;
    HObject* gc_scan_object;
    uint gc_scan_stage;
    usz gc_scan_index;
    void* gc_env_gray_head;
    void* gc_env_gray_tail;
    GeneratorState* gc_gen_gray_head;
    GeneratorState* gc_gen_gray_tail;
    GeneratorState* gc_scan_generator;
    uint gc_gen_scan_stage;
    uint gc_gen_scan_index;
    // Lazy sweep state. After marking, the pause leaves the unswept part of the
    // object list, from sweep_cursor to the tail, for safepoints to sweep in
    // steps. Nodes allocated since then sit ahead of the cursor, so the sweep
    // never visits them.
    HeapHeader* sweep_cursor;
    bool  sweep_active;
    uint  marked_obj_count;      /// Objects marked this cycle, counted in gray_push
    bool  gc_quiescent_pending;  /// A collection retained native temporary roots
    uint  bwd_gc_budget;         /// Countdown to the next backward-jump GC safepoint
    uint  gc_call_budget;        /// Countdown to the next call/return GC safepoint
    uint  iter_result_shape;     /// Shape of `{value, done}` iterator results, 0 until the first is built
    // Nesting depth of native builtin frames on the C3 stack. Non-zero means a
    // builtin may hold a fresh object in a raw local that no GC root can see,
    // so temproot flags must survive a safepoint collection. See mark_and_sweep.
    uint  native_frame_depth;
    uint  live_obj_count;
    uint  peak_live_obj_count;   /// High-water mark for live objects
    // TVals visited by the last mark phase.
    //
    // live_obj_count counts allocation nodes. Marking cost is not
    // that number: an array's elements live inside its prop_alloc rather than
    // as separate nodes, so a 200k-element array marks 226k values while
    // contributing ~1 to live_obj_count. Budgeting against the node count
    // therefore let mark cost grow with the array while the allocations
    // permitted between cycles stayed flat -- the product being quadratic. See
    // mark_work_last use in the trigger reset.
    ulong mark_work_last;

    // Host function registry. A host function is an ordinary FUNCTION object
    // whose builtin_fn_index is HOST_FN_BASE + slot, so every existing call
    // site treats it as a builtin and dispatch_builtin's out-of-range branch
    // routes it here. See builtins::HOST_FN_BASE.
    //
    // Not a GC root and does not need to be: the only heap pointer stored is
    // an interned HString for the name, which the intern table already keeps
    // alive for the heap's lifetime. No TVal lives here, so the 64-root
    // budget is untouched.
    HostFnEntry* host_fns;
    uint         host_fn_count;
    uint         host_fn_capacity;
    HostClassEntry* host_classes;
    uint            host_class_count;
    uint            host_class_capacity;
    // Values handed to add-ons for the duration of one call. A GC root, so a
    // handle keeps its value alive without the add-on doing anything; reset
    // per call rather than released individually.
    TVal*           addon_handles;
    uint            addon_handle_count;
    uint            addon_handle_capacity;

    // Promoted-builtin cache: the one HObject that represents each LIGHTFUNC
    // builtin, indexed by its Builtin ordinal, materialised on first use.
    //
    // Most builtins are stored as a bare LIGHTFUNC TVal carrying only a builtin
    // index, which keeps startup from allocating an object per builtin. That
    // representation is invisible to a plain call but wrong for every operation
    // that treats a function as an object: ToObject, instanceof, `in`,
    // Reflect.*, property assignment, and use as a Map/WeakSet key all need a
    // real HObject with an identity. Promotion mints that object on demand.
    //
    // The cache is what makes promotion safe rather than merely convenient.
    // `JSON.parse === JSON.parse` holds today only because the builtin index
    // *is* the value, so two promotions of the same index must hand back the
    // same pointer or identity breaks. One slot per ordinal makes promotion
    // idempotent by construction.
    //
    // Unlike host_fns this IS a GC root (see mark_roots): a promoted object may
    // be reachable from nothing else, and a swept-but-still-cached pointer would
    // be a use-after-free on the next promotion of that ordinal. The array is
    // allocated lazily on the first promotion, so a program that never uses a
    // builtin as an object pays nothing.
    HObject** promoted_builtins;
    uint      promoted_builtin_capacity;

    // Stack of live host-call scopes; index host_scope_depth-1 is the
    // innermost. Scopes nest exactly as the C3 call stack does, so a
    // host -> JS -> host chain pushes one per level.
    HostScope* host_scopes;
    uint       host_scope_depth;
    uint       host_scope_capacity;
    // Monotonic counter stamped into each handle. Never reset, so a handle
    // from a popped scope can never collide with a live one.
    uint       host_scope_generation;
    // Monotonic compile-time id for class private-slot binding names
    // ("#priv:<id>:foo"), one per class body. Per-runtime: every compiler
    // context in one runtime shares it, so sibling classes across the
    // parent/arrow context split stay distinct, and separate runtimes never
    // race on it.
    uint       priv_class_id;

    // Explicit full collection sweeps strings only when its caller guarantees
    // that no native frame borrows a raw HString pointer.
    bool  string_sweep_safe;

    // Intrusive gray queue count, used by the full verification traversal.
    uint   gray_count;

    // Arrays currently being rendered by Array.prototype.join, innermost last.
    // The set spans nested join calls rather than living in one invocation's
    // frame, because a cycle re-enters join through a separate call (directly,
    // or via a user toString that joins the outer array again). An array found
    // already on the stack contributes the empty string instead of recursing,
    // which is what V8 does and is the only thing standing between a cyclic
    // array and unbounded recursion. Grown on demand.
    void** join_visited;
    uint   join_visited_count;
    uint   join_visited_capacity;

    // Current execution thread (HThread*)
    void* curr_thread;

    // HEAP_VERIFY: register range a frame pop is currently releasing. The
    // decref-to-zero check skips these slots, because the release it is
    // watching is exactly what clears them: a frame's registers are shared
    // with the caller's window, so a scan attributes the slot being released
    // to an enclosing frame and reports the release itself.
    TVal* decref_exempt_lo;
    TVal* decref_exempt_hi;

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

    // %ThrowTypeError%, the per-realm intrinsic both AddRestrictedFunctionProperties
    // (Function.prototype caller/arguments) and the strict arguments object's
    // callee accessor share. Built once in register_function_constructor and
    // frozen there, per ES2017 §9.2.7 / §9.4.4.7.
    HObject* throw_type_error;
    // %Array.prototype.values%, the function every arguments object carries as
    // its @@iterator (ES2024 §10.4.4.6 step 7, §10.4.4.7 step 8) whatever the
    // program later does to Array.prototype. A root, since the program can
    // delete the property that otherwise keeps it alive.
    HObject* array_values_fn;

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
    // Promise constructor, cached lazily and rooted through this field.
    HObject* promise_ctor;
    // %Function% (ES2015 §19.2.2). Kept so the later GeneratorFunction,
    // AsyncFunction, and AsyncGeneratorFunction passes can point their
    // [[Prototype]] at it, since the spec makes those subclasses of Function.
    HObject* function_ctor;
    HObject* generator_proto;
    HObject* generator_func_proto; // GeneratorFunction.prototype (ES6 §25.2.3)
    HObject* async_func_proto;     // AsyncFunction.prototype (ES2017 §25.7.3)
    // %AbstractModuleSource% and its prototype (ES2025 source-phase-imports).
    // Created only by the test262 host setup, which is the only thing that
    // exposes them ($262.AbstractModuleSource); null in an ordinary engine.
    HObject* abstract_module_source_ctor;
    HObject* abstract_module_source_proto;
    // The concrete module-source prototype sitting between a Module Source
    // object and %AbstractModuleSource%.prototype, standing in for what a real
    // source representation (WebAssembly.Module.prototype) would provide.
    HObject* module_source_proto;
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
    // Shared ISO Calendar, Calendar prototype, and PlainDate prototype,
    // cached to avoid global environment lookups in constructor calls.
    HObject* temporal_iso_calendar;
    HObject* temporal_duration_proto;
    HObject* temporal_plain_date_proto;
    HObject* temporal_plain_time_proto;
    HObject* temporal_plain_datetime_proto;
    HObject* temporal_plain_yearmonth_proto;
    HObject* temporal_plain_monthday_proto;
    HObject* temporal_instant_proto;
    HObject* temporal_zoneddatetime_proto;

    // Generator resume state (set by .next()/.throw()/.return() builtins,
    // read by the VM CALL handler and YIELD/RET opcodes).
    GeneratorState* resume_gen;
    TVal yield_value;          /// Value yielded by YIELD opcode
    bool did_yield;            /// True when YIELD was just executed
    // Set by AWAIT when it suspends an async-generator body on an internal
    // await (ES2018 §27.6.3.8, §27.6.3.9). The drain then leaves the current
    // request's promise alone and a microtask ASYNC_GEN resume re-drives the
    // body. The drain clears this before each body resume.
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
    CheckpointEntry* checkpoint_entries;
    uint      checkpoint_count;
    uint      checkpoint_cap;

    void*     env_freelist;     /// EnvRecord* freelist, chained through .parent
    void*     env_pool_blocks;  /// EnvPoolBlock* list, walked at cleanup

    // Environment pool accounting. Environments are never reclaimed in normal
    // execution, so live_cells tracks every record created since reset rather
    // than the reachable set; block_count and bytes_reserved measure what the
    // pool holds back from the allocator. These are the reclamation oracle for
    // plans/085: after reclamation lands, a bounded live scope graph must have
    // bounded live_cells and bytes_reserved after a quiescent collection.
    uint      env_alloc_count;      /// Total records handed out since reset
    uint      env_live_cells;       /// Records allocated and not yet returned
    uint      env_block_count;      /// Pool blocks currently reserved
    usz       env_bytes_reserved;   /// Bytes held by env_pool_blocks
    usz       env_peak_bytes_reserved; /// High-water mark for env_bytes_reserved
    // Current environment-marking epoch, flipped at the start of each accepted
    // collection. A cell whose EnvRecord.flags.mark_epoch equals this value was
    // traced by the current cycle.
    bool      env_mark_epoch;
    // Stack of native scoped environment roots. Each link protects one
    // EnvRecord held only in a C3 local; the GC traces it as a root.
    EnvRoot*  env_roots;
    ObjectRoot* object_roots;
    ValueRoot* value_roots;
    // Countdown of environment allocations until the next collection request.
    // Decremented per allocation (a freelist hit still creates potential
    // garbage); expiry sets gc_pending. Reset after each completed cycle.
    long      env_alloc_budget;

    // Every CompiledFunction the compiler allocates. Freed in Heap.destroy.
    void**    compiled_funcs;
    uint      compiled_func_cap;
    uint      compiled_func_count;

    // Registered GC roots: HeapHeader* that are always reachable. Every
    // module env's bindings object registers here, so whole-library import
    // graphs (60+ modules) run past any fixed size; a capped array silently
    // dropped registrations and the sweep collected live module envs.
    List{void*} gc_roots;

    GeneratorState* generator_states;

    // The C ABI's value registry is a plain array rather than an HObject, so
    // the mark phase cannot reach it transitively. capi_mark, when set, is
    // called with capi_roots during mark_roots to mark every host-held value.
    void*               capi_roots;

    // The C ABI Runtime that owns this heap, or null when the heap was not
    // created through bk_open. A host function receives a call context, which
    // carries a heap, so this is how it reaches its runtime without a global
    // naming "the one runtime". Distinct from capi_roots, which happens to hold
    // the same pointer but means "what the GC should walk for host-held values".
    void*               capi_runtime;
    CapiMarkFn          capi_mark;
    CapiMarkSliceFn     capi_mark_slice;

    // The C ABI interrupt handler, polled at VM safepoints (vm_execute's
    // vm_poll_interrupt). Set by bk_set_interrupt_handler, which reaches the
    // heap through the runtime; null means no handler and the poll is a single
    // compare. The handler runs on the engine thread and must not re-enter the
    // engine; opaque is never dereferenced here.
    void*               capi_interrupt_fn;
    void*               capi_interrupt_opaque;
    uint                interrupt_budget;
    // Set when interrupt_budget runs down to zero; the switch site clears it
    // and calls the handler. The threaded burst charges the budget too and
    // bails on this flag, so back-edges consumed inside a burst still reach
    // the poll without underflowing (charge resets the budget at zero).
    bool                interrupt_due;
    // Set while an "interrupted" error is unwinding. vm_throw_value skips
    // catch catchers while it is set, so script cannot swallow the abort;
    // finally blocks still run. Cleared only at the host boundary when the
    // BK_ERR_INTERRUPT status is handed out.
    bool                uncatchable_throw;

    // Valstack window the GC scans for roots. valstack_base is refreshed on VM
    // create and resize. valstack_top_ptr points at vm.valstack_top so the GC
    // reads the live value and push/pop need no synchronization.
    TVal*      valstack_base;
    TVal**     valstack_top_ptr;

    // GC re-entrancy guard
    bool                gc_running;

    // VM callbacks, all set by vm_create.
    VmCallHandlerFn     call_handler_fn;
    VmCallFn            call_fn;
    VmConstructFn       construct_fn;
    // Proxy trap bridges and the owning VM. See ProxyGetFn and ProxyHasFn.
    ProxyGetFn          proxy_get_fn;
    ForceDeferredNsFn   force_deferred_ns_fn;
    ProxyHasFn          proxy_has_fn;
    void*               vm_ptr;
    // Marks activation-record env bindings during GC.
    MarkActivationsFn   mark_activations_fn;
    MarkActivationsSliceFn mark_activations_slice_fn;
    // Marks or frees a suspended generator's Catcher chain. See CatcherChainFn.
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

    // Resolves downstream promises once a microtask handler finishes. Set by builtins init.
    MicrotaskAfterFn    microtask_after_fn;

    // Microtask queue, filled by promise_trigger_reactions and drained after
    // each top-level script execution and after vm_call_fn_impl returns. Every
    // entry occupies 3 TVal slots: handler, arg, and the downstream promise to
    // resolve with the handler's return value, or undefined.
    // Jobs [microtask_head, microtask_count) are pending; the drain releases the
    // slots before the head, and a full queue slides the pending jobs down.
    TVal*     microtask_queue;
    uint      microtask_head;
    uint      microtask_count;
    uint      microtask_capacity;
    bool      microtask_draining;  // re-entrancy guard

    // Promises rejected with [[PromiseIsHandled]] still false. Recording one
    // here is provisional: a handler attached later in the same tick clears its
    // is_handled flag and the entry is skipped, which is why the decision can
    // only be made once the drain has run to completion.
    //
    // Entries are TVals so the GC marks them and so the list holds a reference,
    // keeping a rejected promise nobody else references alive long enough to be
    // reported.
    TVal*                unhandled_rejections;
    uint                 unhandled_count;
    uint                 unhandled_capacity;
    bool                 reporting_rejections;
    // Host callback for unhandled rejections, invoked at the end of the drain.
    RejectionTrackerFn   rejection_tracker_fn;
    void*                rejection_tracker_udata;

    // Parked Atomics.waitAsync waiters. Each holds a pending Promise against a
    // SharedArrayBuffer and byte index, and Atomics.notify resolves matching
    // waiters with "ok" in FIFO order. Active waiters act as GC roots.
    AtomicsWaiter[64] async_waiters;
    uint      async_waiter_count;

    // Shapes (hidden classes) backing the inline caches.
    hobject::Shape**    shapes;    // each element points to one shape allocation
    uint                shape_count;
    uint                shape_capacity;
    // Transition shapes of an ordinary function (length, name, prototype), of
    // a function without a `.prototype` (length, name), and of a `.prototype`
    // object (constructor), built on first use. 0 = unbuilt.
    uint                fn_shape;
    uint                fn_bare_shape;
    uint                fn_proto_shape;
    // Transition shapes of a mapped arguments object, indexed by argument
    // count and recorded by new_arguments_object. 0 = not seen yet.
    uint[5]             args_shapes;
    // Counts how many times a shape id has been handed back out for reuse.
    // A variable inline cache stores the value it saw and compares it instead
    // of loading the per-shape generation, which lets it skip a dependent load
    // into the shapes table on every access. Property storage growing is the
    // other reason a shape generation moves, and that one a variable cache does
    // not care about, because it addresses values by index and re-reads the
    // base pointer every time.
    uint                shape_recycle_epoch;
    // Where the intrinsic exec, flags and flag getters sit on RegExp.prototype,
    // cached against the prototype's shape so the pristine-RegExp check does
    // not repeat the key lookups.
    RegExpGuard         regexp_guard;
    // Head of the reclaimed-slot list, or SHAPE_FREE_END when empty. Only
    // private shapes are ever freed, so a slot on this list has no live
    // referent. The link is threaded through the shapes array itself: a free
    // slot holds SHAPE_FREE_TAG | next_free cast to a pointer.
    uint                shape_free_head;
    // Source of shape generations. A generation is a value taken from this
    // clock, so a recycled id never re-presents an (id, generation) pair that a
    // live inline cache still matches, nor does a storage move.
    uint                shape_gen_clock;
    // Generation the next shape stored in the just-allocated slot starts at:
    // zero for a slot never used before, a fresh clock value for a recycled one.
    // Set by alloc_shape_slot.
    uint                shape_reuse_gen;

    // Counter making generated symbol descriptions unique within this heap.
    // Symbols are per-heap, so this is too: a process-wide counter would let
    // one runtime's allocations shift another's symbol names.
    uint                symbol_counter;

    // Set for the duration of destroy() and reset(), which free every object
    // directly. Object teardown reads it to skip its string decref loop:
    // releasing strings while the teardown runs would corrupt the string table
    // it is walking, and every string is about to be freed regardless.
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

    // Pinned one-byte ASCII strings, interned lazily for character-producing
    // operations that repeatedly request the same code unit.
    HString*[ASCII_CHAR_CACHE_SIZE] ascii_char_strs;

    // Which lightfunc virtual properties have been deleted. Three bits per
    // builtin index at fn_idx * 3 + prop_bit: 0 name, 1 length, 2 prototype.
    ulong[LF_DELETED_WORDS] lf_deleted_props;

    // Pooled HObject headers, avoiding a malloc per object. The size classes
    // match alloc_size_for_class():
    //   plain: classes with no payload of their own, so no HObjectExtra
    //   array: ARGUMENTS and collection payloads
    //   dense array: ARRAY header and length, without inline named slots
    //   inline literal array: one six-slot ARRAY header and dense part
    //   gs:    GETTER_SETTER accessor cells, which have no inline props
    //   small: every class whose payload fits the promise payload, from the
    //          boxed primitives up through ARRAYBUFFER and PROMISE
    //   func:  FUNCTION and PROXY, sized for the function payload
    //   big:   the two payloads that exceed the small block: ITERATOR_HELPER
    //          and the Temporal classes
    mempool::FixedBlockPool obj_pool_plain;
    mempool::FixedBlockPool obj_pool_array;
    mempool::FixedBlockPool obj_pool_dense_array;
    mempool::FixedBlockPool obj_pool_inline_literal_array;
    mempool::FixedBlockPool obj_pool_gs;
    mempool::FixedBlockPool obj_pool_small;
    mempool::FixedBlockPool obj_pool_func;
    mempool::FixedBlockPool obj_pool_big;

    // One FixedBlockPool per POOL_CLASS_SIZES entry, shared by property blocks
    // and string bodies. Both are small, high-churn allocations; keeping them
    // inside page-granular pool pages removes the per-block malloc header and
    // the arena fragmentation that repeated grow/free of prop blocks leaves
    // behind. pool_alloc/pool_free select the class, so no block stores one.
    mempool::FixedBlockPool[POOL_CLASS_COUNT] small_pools;

    // Module cache and host hooks.
    void*       module_cache;       // growable ModuleDef** array
    uint        module_cache_count;
    uint        module_cache_cap;
    void*       module_hooks;       // ModuleHostHooks*, the pluggable host callbacks
    // Host-defined module sources (esm::DefinedModule array), consulted before
    // the filesystem when a specifier is resolved and read.
    void*       defined_modules;
    uint        defined_module_count;
    uint        defined_module_cap;
    // Module whose body is currently executing, empty outside a module
    // evaluation. Relative dynamic-import specifiers resolve against it when the
    // importing function has no filename of its own.
    char[]      current_module_name;
}

// ============================================================================
// Built-in string cache, pre-interned at heap creation
// ============================================================================

// Indices into Heap.strs[] for frequently-used interned strings.
// Eliminates repeated hash+lookup for these strings on every property
// access, typeof, and error path.
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
    // Keys the RegExp builtins rebuild on every exec, match, replace and split.
    LAST_INDEX,    // "lastIndex"
    EXEC,          // "exec"
    INDEX,         // "index"
    INPUT,         // "input"
    GROUPS,        // "groups"
    SOURCE,        // "source"
    FLAGS,         // "flags"
    GLOBAL,        // "global"
    IGNORE_CASE,   // "ignoreCase"
    MULTILINE,     // "multiline"
    DOT_ALL,       // "dotAll"
    UNICODE,       // "unicode"
    UNICODE_SETS,  // "unicodeSets"
    STICKY,        // "sticky"
    HAS_INDICES,   // "hasIndices"
    INDICES,       // "indices"
    // The iterator protocol's method names, read on every step.
    NEXT,          // "next"
    RETURN,        // "return"
    THROW,         // "throw"
    // Promise reaction records and the Promise Resolution Procedure.
    ON_FULFILLED,  // "onFulfilled"
    ON_REJECTED,   // "onRejected"
    DOWNSTREAM,    // "downstream"
    CAP_RESOLVE,   // "\xFFcap_resolve_tv"
    CAP_REJECT,    // "\xFFcap_reject_tv"
    CAP_PROMISE,   // "\xFFcap_promise_tv"
    THEN,          // "then"
    RESOLVE,       // "resolve"
    REJECT,        // "reject"
    // Hidden slots; the leading \xFF cannot be spelled in a source literal.
    REACTION_NEXT,    // "\xFFpromise_reaction_next"
    HIDDEN_PROMISE,   // "\xFFpromise"
    CAP_CELL,         // "\xFFcap_cell"
    ALREADY_RESOLVED, // "\xFFalreadyResolved"
}

// The literal for each `BuiltinStr`, in enum order. `init_builtin_strs`
// interns entry `i` into `Heap.strs[i]`, so the two must stay aligned.
const String[] BUILTIN_STR_LITERALS = {
    "undefined", "object", "boolean", "number", "string", "function",
    "true", "false", "null", "message", "prototype", "constructor",
    "length", "value", "done", "arguments", "symbol", "name", "",
    "NaN", "Infinity", "-Infinity",
    "toString", "valueOf", "[object Object]", "[function]",
    "stack", "callee", "bigint",
    "lastIndex", "exec", "index", "input", "groups",
    "source", "flags", "global", "ignoreCase", "multiline", "dotAll",
    "unicode", "unicodeSets", "sticky", "hasIndices", "indices",
    "next", "return", "throw",
    "onFulfilled", "onRejected", "downstream",
    "\xFFcap_resolve_tv", "\xFFcap_reject_tv", "\xFFcap_promise_tv",
    "then", "resolve", "reject",
    "\xFFpromise_reaction_next", "\xFFpromise", "\xFFcap_cell", "\xFFalreadyResolved",
};

$assert BUILTIN_STR_LITERALS.len == BuiltinStr::len :
    "BUILTIN_STR_LITERALS must have one literal per BuiltinStr, in enum order";
$assert BUILTIN_STR_LITERALS.len <= STRS_CACHE_SIZE : "Heap.strs is too small for BUILTIN_STR_LITERALS";

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
    io::eprintfn("BOOMKAT FATAL: %s", msg);
    abort("boomkat fatal error");
}

// The FixedBlockPools draw from `allocators::LIBC_ALLOCATOR`.

// ============================================================================
// Scanned-state allocation
// ============================================================================

// Allocate a zeroed node for state the collector walks: a try handler's saved
// values, a for-in enumeration, a suspended generator's registers.
//
// C3 zero-initialises a declared struct value, but this heap hands back raw
// allocator memory, so a recycled block arrives holding the previous owner's
// bytes. A TVal field no writer has reached yet would then be scanned as a live
// pointer, and the marker stamps the reachable bit into whatever now lives at
// that address. A zeroed field is a double, which the mark phase ignores, so an
// uninitialised field costs a missing root rather than a corrupt heap.
macro void* alloc_scanned($Type, Heap* h) {
    void* raw = h.alloc_func(h.heap_udata, (usz)$Type::size);
    if (raw == null) { return null; }
    mem::clear(raw, (sz)((usz)$Type::size));
    return raw;
}

// Same, for a struct whose every field is written before the marker can reach
// it. A SCAN_POISON build fills the block with the poison TVal instead of
// zeroing, so a field a later edit forgets to write is reported at the marking
// site rather than silently read as `undefined`. Structs that rely on zero to
// mean "unset" (a suspended generator's delegation state, its this_binding)
// must keep using alloc_scanned: poison there is a false positive, not a
// finding.
macro void* alloc_scanned_checked($Type, Heap* h) {
    void* raw = alloc_scanned($Type, h);
    if (raw == null) { return null; }
    $if $feat(SCAN_POISON):
        h.poison_block(raw, (usz)$Type::size);
    $endif
    return raw;
}

// Free scanned state, poisoning its bytes first so a recycled block cannot hand
// the next owner a plausible-looking TVal. The fill is SCAN_POISON-only; every
// other build relies on alloc_scanned zeroing the block instead.
fn void Heap.free_scanned(&self, void* ptr, usz bytes) {
    self.gc_before_scanned_free(ptr);
    if (ptr == null) { return; }
    $if $feat(SCAN_POISON):
        self.poison_block(ptr, bytes);
    $endif
    self.free_func(self.heap_udata, ptr);
}

fn GeneratorState* Heap.alloc_generator_state(&self) {
    GeneratorState* gs = (GeneratorState*)alloc_scanned(GeneratorState, self);
    if (gs == null) return null;
    self.account_auxiliary_allocation(GeneratorState::size);
    gs.gc_mark_epoch = self.gc_phase == GcPhase.MARK
                     ? !self.gc_mark_epoch : self.gc_mark_epoch;
    gs.gc_next = self.generator_states;
    if (self.generator_states != null) self.generator_states.gc_prev = gs;
    self.generator_states = gs;
    return gs;
}

fn void Heap.free_generator_state(&self, GeneratorState* gs) {
    assert(!gs.gc_gray_queued || self.tearing_down);
    if (self.gc_root_generator_cursor == gs) self.gc_root_generator_cursor = gs.gc_next;
    if (gs.gc_prev != null) {
        gs.gc_prev.gc_next = gs.gc_next;
    } else {
        self.generator_states = gs.gc_next;
    }
    if (gs.gc_next != null) gs.gc_next.gc_prev = gs.gc_prev;
    self.free_scanned((void*)gs, (usz)GeneratorState::size);
}

// Overwrite `bytes` at `ptr` with the poison TVal, zeroing any tail too short to
// hold one. Only SCAN_POISON builds call this.
fn void Heap.poison_block(&self, void* ptr, usz bytes) @feat(SCAN_POISON) {
    TVal* slot = (TVal*)ptr;
    usz whole = bytes / TVal::size;
    for (usz i = 0; i < whole; i++) { slot[i].set_poison(); }
    usz tail = bytes % TVal::size;
    if (tail != 0) { mem::clear((char*)ptr + whole * TVal::size, (sz)tail); }
}

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
    h.gc_quiescent_pending  = false;
    h.bwd_gc_budget         = BWD_GC_INTERVAL;
    h.gc_call_budget        = GC_CALL_INTERVAL;
    h.env_alloc_budget      = 1024;
    h.capi_interrupt_fn     = null;
    h.capi_interrupt_opaque = null;
    h.interrupt_budget      = INTERRUPT_BUDGET_INIT;
    h.interrupt_due         = false;
    h.uncatchable_throw     = false;
    h.native_frame_depth    = 0;
    h.host_fns              = null;
    h.host_fn_count         = 0;
    h.host_fn_capacity      = 0;
    h.host_classes          = null;
    h.host_class_count      = 0;
    h.host_class_capacity   = 0;
    h.addon_handles         = null;
    h.addon_handle_count    = 0;
    h.addon_handle_capacity = 0;
    h.promoted_builtins     = null;
    h.promoted_builtin_capacity = 0;
    h.host_scopes           = null;
    h.host_scope_depth      = 0;
    h.host_scope_capacity   = 0;
    h.host_scope_generation = 0;

    h.gray_count     = 0;

    // xorshift32 requires a non-zero seed.
    h.rnd_state = 0xDEAD_BEEF;

    // Fixed for the heap's lifetime.
    h.hash_seed = h.rnd_state;

    // Allocate the initial string table
    usz tbl_bytes = str_table_bytes(INITIAL_STR_TABLE_SIZE);
    void* tbl_raw = afn(udata, tbl_bytes);
    if (tbl_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    mem::clear(tbl_raw, (sz)(tbl_bytes));

    h.str_table      = (HString**)tbl_raw;
    h.str_table_size = INITIAL_STR_TABLE_SIZE;
    h.str_table_used = 0;

    // The pools must exist before the first string does: pre-interning the
    // well-known strings below allocates through the size-class pools.
    {
        h.obj_pool_plain.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_PLAIN, pool_page_blocks(hobject::OBJ_SIZE_PLAIN));
        h.obj_pool_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARGS, pool_page_blocks(hobject::OBJ_SIZE_ARGS));
        h.obj_pool_dense_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARRAY, pool_page_blocks(hobject::OBJ_SIZE_ARRAY));
        h.obj_pool_inline_literal_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_INLINE_LITERAL_ARRAY, pool_page_blocks(hobject::OBJ_SIZE_INLINE_LITERAL_ARRAY));
        h.obj_pool_gs.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_GS, pool_page_blocks(hobject::OBJ_SIZE_GS));
        h.obj_pool_small.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_SMALL, pool_page_blocks(hobject::OBJ_SIZE_SMALL));
        h.obj_pool_func.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_FUNCTION, pool_page_blocks(hobject::OBJ_SIZE_FUNCTION));
        h.obj_pool_big.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_BIG, pool_page_blocks(hobject::OBJ_SIZE_BIG));
        for (usz i = 0; i < POOL_CLASS_COUNT; i++) {
            h.small_pools[i].init(&allocators::LIBC_ALLOCATOR, (sz)POOL_CLASS_SIZES[i]);
        }
    }

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
    // Allocated on the first unhandled rejection: most programs never have one.
    h.unhandled_rejections    = null;
    h.unhandled_count         = 0;
    h.unhandled_capacity      = 0;
    h.rejection_tracker_fn    = null;
    h.rejection_tracker_udata = null;
    h.async_waiter_count = 0;

    return h;
}

// The pre-interned, pinned HString for a builtin literal. Using this instead of
// re-interning the literal skips a hash and a string-table probe, and yields the
// same pointer the table holds, so pointer-identity equality is unaffected.
fn HString* Heap.str(&self, BuiltinStr which) @inline {
    return (HString*)self.strs[which.ordinal];
}

// Pre-intern frequently-used strings into Heap.strs[], once at heap creation.
// Each string is allocated only if the table does not already hold it, so
// repeat calls are harmless.
fn void Heap.init_builtin_strs(&self) {
    foreach (i, lit : BUILTIN_STR_LITERALS) {
        HString* s = self.str_intern((char[])lit);
        self.strs[i] = s;
        // Pinning keeps these alive through refcounting and sweep, and makes
        // every incref and decref against them a no-op. See HeapHeader.set_pinned.
        if (s != null) { ((HeapHeader*)s).set_pinned(); }
    }
}

// Convert an integer to an interned HString*. Values from 0 to 255 come from
// the small-integer cache; anything else is formatted and interned.
//
// As with Heap.str_intern, the result is a borrowed reference: use it directly
// as a property key, or incref it to anchor it in a TVal or register. Cached
// entries are pinned like the builtin strings above, so incref and decref
// against them do nothing and they never need releasing.
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
// The one value that is never a valid shape ID. It means "not a shape" in
// every context: no parent shape, no transition found, and no slot available.
// alloc_shape_slot() refuses to hand it out, so no live shape can equal it.
const uint SHAPE_NONE          = 0xFFFF_FFFF;
const uint SHAPE_TRANS_INITIAL = 16;   // must be a power of 2
const uint SHAPE_TRANS_LOAD    = 70;   // percent load that triggers a grow
// Property count from which an object on a shape no second object has reached
// moves to a dictionary shape. See transition_shape_new_flags.
const uint SHAPE_SOLITARY_MIN_PROPS = 64;

// Set on a shapes[] entry that is a free-list link rather than a shape
// pointer. The top address bit is never set on a real allocation.
const uptr SHAPE_FREE_TAG      = (uptr)1 << (uptr)(uptr::size * 8 - 1);
// Marks the end of the free-slot list. Slot 0 holds the root shape, which is
// never freed, so it can stand for "no next".
const uint SHAPE_FREE_END       = 0;

struct TransitionEntry {
    uint parent_id;
    hstring::StringRef key;
    uint shape_id;
    // Raw PropFlags byte this transition installs. It is part of the dedup key:
    // objects that reach the same parent and add the same key with the same
    // flags share a shape, while differing flags need their own shape so
    // readers see the right attributes.
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
        if (e.parent_id == parent_id && e.key.borrow() == key && e.flags == flags) return e.shape_id;
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
        uint h = hash_transition(e.parent_id, e.key.borrow(), e.flags);
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
    table[slot].key = hstring::string_ref((HString*)key);
    table[slot].flags = flags;
    table[slot].shape_id = shape_id;
    self.trans_count++;
}

fn void Heap.init_shapes(&self) {
    self.shape_capacity = SHAPE_INITIAL_CAP;
    self.shape_count    = 1;  // slot 0 holds the root shape
    self.fn_shape = 0;
    self.fn_bare_shape = 0;
    self.fn_proto_shape = 0;
    self.args_shapes = {};
    self.shape_recycle_epoch = 0;
    self.regexp_guard = {};
    self.shape_free_head = SHAPE_FREE_END;
    self.shape_gen_clock = 0;
    usz bytes = (usz)SHAPE_INITIAL_CAP * (void*::size);
    self.shapes = (hobject::Shape**)self.alloc_func(self.heap_udata, bytes);
    mem::clear(self.shapes, (sz)(bytes));
    // Root shape: no properties, smallest hash (mask 0, so 2 slots).
    self.shapes[0] = hobject::shape_create(0, 0, SHAPE_NONE, null, self);
    self.init_transition_table();
}

// Reserve a slot in the shapes array and return its ID. The caller is
// responsible for storing the shape at shapes[id]. Returns SHAPE_NONE when no
// slot could be reserved, in which case no slot is consumed. The array grows on
// demand, so the only bound is what the allocator will hand out.
fn uint Heap.alloc_shape_slot(&self) {
    // Reuse a reclaimed slot before growing. Without this the pool is a pure
    // bump allocator and a delete/insert loop exhausts the id space.
    //
    // Inline caches key on (shape_id, shape.generation), so a recycled id must
    // never come back with a generation an existing cache entry still matches:
    // that entry would then read properties at the previous shape's offsets.
    // Every generation after the first comes from one clock, so the pair is
    // never reused.
    if (self.shape_free_head != SHAPE_FREE_END) {
        uint id = self.shape_free_head;
        self.shape_free_head = (uint)((uptr)self.shapes[id] & ~SHAPE_FREE_TAG);
        self.shape_reuse_gen = ++self.shape_gen_clock;
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

// Store a freshly created shape in a slot just returned by alloc_shape_slot,
// stamping the generation that keeps recycled ids from colliding with live
// inline-cache entries.
fn void Heap.store_new_shape(&self, uint id, hobject::Shape* sh) {
    sh.generation = self.shape_reuse_gen;
    self.shapes[id] = sh;
}

// True when shapes[id] holds a real shape rather than a free-list link.
// Free slots store SHAPE_FREE_TAG | next_free; the tag is bit 63 (bit 31 on a
// 32-bit host), which no live allocation carries, so teardown can skip those
// entries instead of freeing an integer as a pointer.
fn bool Heap.shape_slot_live(&self, uint id) {
    hobject::Shape* sh = self.shapes[id];
    if (sh == null) return false;
    return ((uptr)sh & SHAPE_FREE_TAG) == 0;
}

// Release a slot holding a *private* shape, freeing the shape and putting the
// id back on the free list.
//
// Only private shapes may be passed here. A private shape has
// parent == PRIVATE_SHAPE_PARENT, is absent from the transition table, and is
// referenced by exactly one object -- the one replacing it right now. Freeing
// a transition-table shape instead would be a use-after-free, since other
// objects and cached transitions still point at it, so that case is rejected
// rather than trusted to the caller.
//
fn void Heap.free_shape_slot(&self, uint id) {
    if (id == 0 || id >= self.shape_count) return;
    if (!self.shape_slot_live(id)) return;
    hobject::Shape* sh = self.shapes[id];
    if (sh.parent != hobject::PRIVATE_SHAPE_PARENT) return;   // shared: not ours to free
    hobject::shape_free(sh, self);
    self.shapes[id] = (hobject::Shape*)(SHAPE_FREE_TAG | (uptr)self.shape_free_head);
    self.shape_free_head = id;
}


// Transition to a new shape that includes the given property key, using the
// default WEC data-property flags.  Thin wrapper over
// transition_shape_new_flags() for the overwhelmingly common case.
fn uint Heap.transition_shape_new(&self, uint cur_shape_id, void* key) {
    return self.transition_shape_new_flags(cur_shape_id, key, hobject::PROP_FLAGS_WEC);
}

// Transition to a shape that adds `key` with `flags`.
//
// The key must be absent from the object; callers confirm that with
// find_prop_idx() first, which lets this skip the O(N) chain walk.
//
// The transition table is keyed on (parent shape, key, flags), so two objects
// that reach the same parent and add the same key with the same flags converge
// on one shape. That holds for non-default flags too, such as every instance of
// a class installing the same private field. Differing flags for the same key
// produce separate shapes.
//
// An object with SHAPE_SOLITARY_MIN_PROPS properties on a shape no other
// object has reached is being used as a dictionary: nothing will follow its
// path, so a shape per property would only cost memory and cache. It moves to
// a dictionary shape of its own that takes further keys in place. A second
// object built the same way gets a dictionary of its own too, which costs
// nothing but sharing.
//
// Returns SHAPE_NONE when no shape could be produced. The caller must treat
// that as a hard failure: continuing with the unchanged shape would store a
// value the shape does not describe, which reads back as a missing property.
fn uint Heap.transition_shape_new_flags(&self, uint cur_shape_id, void* key, hobject::PropFlags flags) {
    if (cur_shape_id >= self.shape_count || !self.shape_slot_live(cur_shape_id)) {
        return cur_shape_id;
    }

    hobject::Shape* cur = self.shapes[cur_shape_id];
    char raw_flags = (char)flags;

    if (cur.dict) {
        hobject::Shape* grown = hobject::shape_dict_push(cur, key, flags, self);
        if (grown == null) return SHAPE_NONE;
        self.shapes[cur_shape_id] = grown;
        return cur_shape_id;
    }

    // Another object may already have taken this transition. Reaching one that
    // exists is exactly the second user arriving, so the shape is now shared
    // and a hash table built for it will serve every later arrival too.
    // The root shape's parent id is SHAPE_NONE, which reads as private.
    uint count = cur.offset + cur.own_count;
    bool is_private = cur_shape_id != 0 && cur.parent == hobject::PRIVATE_SHAPE_PARENT;
    if (is_private || (!cur.shared && count >= SHAPE_SOLITARY_MIN_PROPS)) {
        return self.extend_unshared(cur_shape_id, key, flags);
    }

    uint existing = self.lookup_transition(cur_shape_id, key, raw_flags);
    if (existing != SHAPE_NONE) {
        if (self.shape_slot_live(existing)) self.shapes[existing].shared = true;
        return existing;
    }

    hobject::Shape* ns = hobject::shape_extend(cur, cur_shape_id, key, flags, self);
    if (ns == null) return SHAPE_NONE;

    uint new_id = self.alloc_shape_slot();
    if (new_id == SHAPE_NONE) {
        hobject::shape_free(ns, (void*)self);
        return SHAPE_NONE;
    }

    self.store_new_shape(new_id, ns);
    self.insert_transition(cur_shape_id, key, raw_flags, new_id);
    return new_id;
}

// Give an object that no other object can follow a flat shape of its own with
// `key` added: one it already has (a delete or a flag edit made it private), or
// one that has outgrown the transition table. The shape of a dictionary, one
// holding SHAPE_SOLITARY_MIN_PROPS or more properties, has spare room and takes
// later keys in place. A smaller shape is exactly sized and replaced per key.
// Either way it stays out of the transition table, so nothing outlives the
// object that a freed shape id could confuse. Returns the new shape id, or
// SHAPE_NONE when it cannot be built.
fn uint Heap.extend_unshared(&self, uint cur_shape_id, void* key, hobject::PropFlags flags) {
    hobject::Shape* cur = self.shapes[cur_shape_id];
    uint count = cur.offset + cur.own_count;
    bool dict = count >= SHAPE_SOLITARY_MIN_PROPS;
    hobject::Shape* flat = hobject::shape_flatten(cur, dict ? count * 2 : count + 1, self);
    if (flat == null) return SHAPE_NONE;
    flat.dict = dict;
    hobject::shape_dict_push(flat, key, flags, self);

    uint new_id = self.alloc_shape_slot();
    if (new_id == SHAPE_NONE) {
        hobject::shape_free(flat, (void*)self);
        return SHAPE_NONE;
    }
    self.store_new_shape(new_id, flat);
    // Nothing else names a private shape, and the call does nothing for a
    // transition-table shape.
    self.free_shape_slot(cur_shape_id);
    return new_id;
}

fn void Heap.bump_shape_gen(&self, uint shape_id) {
    if (shape_id < self.shape_count && self.shape_slot_live(shape_id)) {
        self.shapes[shape_id].generation = ++self.shape_gen_clock;
    }
}

// Get a shape pointer by ID. Returns null if invalid or reclaimed.
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
        if (cf.await_live != null) { self.free_func(self.heap_udata, cf.await_live); }
        if (cf.capture_names != null) { self.free_func(self.heap_udata, cf.capture_names); }
        if (cf.capture_cells != null) { self.free_func(self.heap_udata, cf.capture_cells); }
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
        // Direct-eval call-site offsets from compiler/context.c3 finish().
        if (cf.direct_eval_offsets != null) { self.free_func(self.heap_udata, cf.direct_eval_offsets); }
        if (cf.eval_var_idxs != null) { self.free_func(self.heap_udata, cf.eval_var_idxs); }
        // The function's name, source filename, and retained source text,
        // copied out of the compiler's scratch buffers so they outlive the
        // compile. All three come from `mem` rather than the heap allocator.
        if (cf.name_ptr != null) { mem::free(cf.name_ptr); cf.name_ptr = null; }
        if (cf.filename_ptr != null) { mem::free(cf.filename_ptr); cf.filename_ptr = null; }
        if (cf.src_buf != null) {
            bytecode::source_buf_release(cf.src_buf);
            cf.src_buf = null;
            cf.src_ptr = null;
        } else if (cf.src_ptr != null) {
            mem::free(cf.src_ptr);
            cf.src_ptr = null;
        }
        self.free_func(self.heap_udata, cf);
    }
}

/**
 * Release every managed object, then free the heap struct itself.
 */
fn void Heap.destroy(&self) {
    $if $feat(GC_PROFILE):
        ulong[5] refcounts;
        ulong retained_bytes;
        for (uint i = 0; i < self.large_string_count; i++) {
            HString* string = self.large_strings[i];
            uint bucket = string.refcount < 4 ? string.refcount : 4;
            refcounts[bucket]++;
            retained_bytes += hstring::HSTRING_HDR_SIZE + (ulong)string.capacity + 1;
        }
        io::eprintfn("# GC_STRING_REFS zero=%d one=%d two=%d three=%d four_plus=%d bytes=%d",
                     refcounts[0], refcounts[1], refcounts[2], refcounts[3], refcounts[4], retained_bytes);
    $endif
    // Teardown frees everything directly, so object teardown must skip its
    // string decref loop: mixing decref with the str_table backshift-delete
    // would corrupt the table for the sweep below.
    self.tearing_down = true;
    if (self.gc_free_object != null) {
        hobject::hobject_free(self.gc_free_object, self, true);
        self.gc_free_object = null;
    }

    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* cur = generation == 0 ? self.young_allocated : self.heap_allocated;
        while (cur != null) {
            HeapHeader* next = cur.next;
            if (cur.is_object()) {
                hobject::hobject_free((HObject*)cur, (void*)self, true);
            } else {
                self.free_func(self.heap_udata, cur);
            }
            cur = next;
        }
    }
    self.young_allocated = null;
    self.heap_allocated = null;
    while (self.generator_states != null) {
        GeneratorState* gs = self.generator_states;
        gs.ref_count = 1;
        gs_release(gs, self, false);
    }

    hobject::env_pool_teardown(self);

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

    // Only the index array is ours; the promoted objects themselves are
    // ordinary heap objects already released by the sweep above.
    if (self.promoted_builtins != null) {
        self.free_func(self.heap_udata, (void*)self.promoted_builtins);
        self.promoted_builtins = null;
        self.promoted_builtin_capacity = 0;
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

    if (self.unhandled_rejections != null) {
        self.free_func(self.heap_udata, self.unhandled_rejections);
        self.unhandled_rejections = null;
        self.unhandled_capacity = 0;
    }
    self.unhandled_count = 0;


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
                hobject::shape_free(self.shapes[i], (void*)self);
            }
        }
        self.free_func(self.heap_udata, self.shapes);
        self.shapes = null;
    }

    if (self.checkpoint_entries != null) {
        self.free_func(self.heap_udata, self.checkpoint_entries);
        self.checkpoint_entries = null;
    }

    // Free megamorphic property cache
    if (self.mega_cache != null) {
        mem::free(self.mega_cache);
        self.mega_cache = null;
    }

    // Free module cache
    self.drain_catcher_pool();
    self.free_module_cache();
    esm::free_defined_modules(self);

    // Releases every pool page back to libc.
    self.obj_pool_plain.free();
    self.obj_pool_array.free();
    self.obj_pool_dense_array.free();
    self.obj_pool_inline_literal_array.free();
    self.obj_pool_gs.free();
    self.obj_pool_small.free();
    self.obj_pool_func.free();
    self.obj_pool_big.free();
    for (usz i = 0; i < POOL_CLASS_COUNT; i++) {
        self.small_pools[i].free();
    }

    self.gc_roots.free();

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
fn void Heap.drain_catcher_pool(&self) {
    void* block = self.catcher_pool;
    while (block != null) {
        void* next = *(void**)block;
        self.free_func(self.heap_udata, block);
        block = next;
    }
    self.catcher_pool = null;
    self.catcher_pool_len = 0;
}

fn void Heap.reset(&self) {
    assert(self.env_roots == null && self.object_roots == null && self.value_roots == null);
    // Decref the strings held by live objects before teardown mode starts.
    // Strings driven to zero here unregister themselves, leaving the registry
    // drain below only those still referenced.
    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* cur = generation == 0 ? self.young_allocated : self.heap_allocated;
        while (cur != null) {
            if (cur.is_object()) {
                hobject::HObject* obj = (hobject::HObject*)cur;
                hobject::PropValue* pvs = obj.prop_values();
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (pvs[i].get().is_string()) { self.decref_slot(&pvs[i]); }
                }
                hobject::PropValue* arr = obj.array_part();
                if (arr != null) {
                    uint used = obj.array_used;
                    for (uint i = 0; i < used; i++) {
                        if (arr[i].get().is_string()) { self.decref_slot(&arr[i]); }
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
            if (base.is_string()) { self.decref_tval(base); }
            base++;
        }
    }

    // Same teardown mode as destroy(): object teardown skips its string decref loop.
    self.tearing_down = true;
    if (self.gc_free_object != null) {
        hobject::hobject_free(self.gc_free_object, self, true);
        self.gc_free_object = null;
    }

    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* cur = generation == 0 ? self.young_allocated : self.heap_allocated;
        while (cur != null) {
            HeapHeader* next = cur.next;
            if (cur.is_object()) {
                hobject::hobject_free((HObject*)cur, (void*)self, true);
            } else {
                self.free_func(self.heap_udata, cur);
            }
            cur = next;
        }
    }
    self.young_allocated = null;
    self.heap_allocated = null;
    while (self.generator_states != null) {
        GeneratorState* gs = self.generator_states;
        gs.ref_count = 1;
        gs_release(gs, self, false);
    }

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
            usz tbl_bytes = str_table_bytes(INITIAL_STR_TABLE_SIZE);
            void* new_tbl = self.alloc_func(self.heap_udata, tbl_bytes);
            if (new_tbl != null) {
                mem::clear(new_tbl, (sz)(tbl_bytes));
                self.str_table      = (HString**)new_tbl;
                self.str_table_size = INITIAL_STR_TABLE_SIZE;
            }
        }
        mem::clear(self.str_tags(), (sz)(self.str_table_size * uint::size));
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
    hobject::env_pool_teardown(self);

    if (self.checkpoint_entries != null) {
        self.free_func(self.heap_udata, self.checkpoint_entries);
        self.checkpoint_entries = null;
    }
    self.checkpoint_count = 0;
    self.checkpoint_cap   = 0;

    // The objects these TVals referenced were freed wholesale above, so clear
    // the stale bits without decrefing.
    if (self.microtask_queue != null) {
        mem::clear(self.microtask_queue,
            (sz)((usz)self.microtask_capacity * TVal::size * 3));
    }
    if (self.unhandled_rejections != null) {
        mem::clear(self.unhandled_rejections,
            (sz)((usz)self.unhandled_capacity * TVal::size));
    }
    self.unhandled_count    = 0;
    self.reporting_rejections = false;
    self.microtask_head     = 0;
    self.microtask_count    = 0;
    self.microtask_draining = false;
    self.async_waiter_count = 0;
    mem::clear(&self.async_waiters, (sz)(AtomicsWaiter::size * 64));

    // Remaining heap state: GC roots, execution state, prototypes.
    self.heap_allocated   = null;
    self.finalize_list    = null;
    self.flags            = 0;
    self.curr_thread      = null;
    self.decref_exempt_lo = null;
    self.decref_exempt_hi = null;
    self.valstack_base    = null;
    self.valstack_top_ptr = null;
    self.resume_gen       = null;
    self.did_yield        = false;
    self.ag_did_await     = false;
    self.gc_roots.clear();
    self.capi_roots       = null;
    self.capi_runtime     = null;
    self.capi_mark        = null;
    self.capi_mark_slice  = null;
    self.capi_interrupt_fn = null;
    self.capi_interrupt_opaque = null;
    self.interrupt_budget = INTERRUPT_BUDGET_INIT;
    self.interrupt_due = false;
    self.uncatchable_throw = false;
    self.gc_running       = false;
    self.gc_trigger_counter = GC_INITIAL_TRIGGER;
    self.gc_alloc_since_begin = 0;
    self.gc_alloc_paced       = 0;
    self.live_obj_count = 0;
    self.peak_live_obj_count = 0;
    self.marked_obj_count = 0;
    self.mark_work_last = 0;
    self.gc_pending       = false;
    self.gc_requested     = false;
    self.gc_phase         = GcPhase.IDLE;
    self.gc_in_step       = false;
    self.gc_kind = GcKind.MAJOR;
    self.gc_minors = 0;
    self.gc_old_count = 0;
    self.gc_major_old_count = 0;
    self.gc_major_mark_work = 0;
    self.gc_young_kept = 0;
    self.gc_young_dead = 0;
    self.gc_major_churn = false;
    self.gc_aux_alloc_bytes = 0;
    self.gc_remembered = null;
    self.gc_remembered_cursor = null;
    self.gc_root_generator_cursor = null;
    self.gc_aux_env_cursor = {};
    self.gc_old_sweep_start = null;
    self.gc_sweep_old = false;
    self.gc_blocking      = false;
    self.gc_keep_temproots = false;
    self.gc_roots_done    = false;
    self.gc_weak_done     = false;
    self.gc_gray_head     = null;
    self.gc_gray_tail     = null;
    self.gc_scan_object   = null;
    self.gc_env_gray_head = null;
    self.gc_env_gray_tail = null;
    self.gc_gen_gray_head = null;
    self.gc_gen_gray_tail = null;
    self.gc_scan_generator = null;
    self.gc_gen_retired = null;
    self.gc_free_object = null;
    self.env_roots = null;
    self.object_roots = null;
    self.value_roots = null;
    self.gc_root_value_cursor = null;
    self.gc_env_sweep_cursor = {};
    self.gc_generator_cursor = {};
    self.gc_generator_release_cursor = {};
    self.gc_quiescent_pending = false;
    self.sweep_cursor     = null;
    self.sweep_active     = false;
    self.bwd_gc_budget    = BWD_GC_INTERVAL;
    self.gc_call_budget   = GC_CALL_INTERVAL;
    self.iter_result_shape = 0;
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
    self.throw_type_error = null;
    self.array_values_fn  = null;
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
    self.abstract_module_source_ctor  = null;
    self.abstract_module_source_proto = null;
    self.module_source_proto          = null;
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
    for (usz i = 0; i < ASCII_CHAR_CACHE_SIZE; i++) {
        self.ascii_char_strs[i] = null;
    }

    mem::clear(&self.lf_deleted_props[0], (sz)(LF_DELETED_WORDS * 8));

    // Every promoted builtin was allocated in the heap this reset has just
    // torn down, so the cache now holds only dangling pointers. It is also a
    // GC root, which makes leaving them in place strictly worse than a leak:
    // the next mark phase would follow each one into freed memory. The array
    // itself is retained because the next run will promote into it again.
    if (self.promoted_builtins != null) {
        mem::clear((void*)self.promoted_builtins,
                   (sz)((usz)self.promoted_builtin_capacity * HObject*::size));
    }

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
                hobject::shape_free(self.shapes[i], (void*)self);
            }
        }
        // The pointer array is reused, so zeroing it is enough.
        mem::clear(self.shapes, (sz)((usz)self.shape_capacity * (void*::size)));
    }
    self.shape_count = 1;
    self.fn_shape = 0;
    self.fn_bare_shape = 0;
    self.fn_proto_shape = 0;
    self.args_shapes = {};
    self.shape_recycle_epoch = 0;
    self.regexp_guard = {};
    self.shape_free_head = SHAPE_FREE_END;
    self.shape_gen_clock = 0;
    self.shapes[0]   = hobject::shape_create(0, 0, SHAPE_NONE, null, self);
    self.init_transition_table();

    self.drain_catcher_pool();
    self.free_module_cache();
    esm::free_defined_modules(self);
    self.module_hooks = null;
    self.current_module_name = {};

    // Every pool page goes back to libc, and the fresh pools start with a clean
    // bump pointer and an empty freelist.
    self.obj_pool_plain.free();
    self.obj_pool_array.free();
    self.obj_pool_dense_array.free();
    self.obj_pool_inline_literal_array.free();
    self.obj_pool_gs.free();
    self.obj_pool_small.free();
    self.obj_pool_func.free();
    self.obj_pool_big.free();
    for (usz i = 0; i < POOL_CLASS_COUNT; i++) {
        self.small_pools[i].free();
    }
    {
        self.obj_pool_plain.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_PLAIN, pool_page_blocks(hobject::OBJ_SIZE_PLAIN));
        self.obj_pool_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARGS, pool_page_blocks(hobject::OBJ_SIZE_ARGS));
        self.obj_pool_dense_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_ARRAY, pool_page_blocks(hobject::OBJ_SIZE_ARRAY));
        self.obj_pool_inline_literal_array.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_INLINE_LITERAL_ARRAY, pool_page_blocks(hobject::OBJ_SIZE_INLINE_LITERAL_ARRAY));
        self.obj_pool_gs.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_GS, pool_page_blocks(hobject::OBJ_SIZE_GS));
        self.obj_pool_small.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_SMALL, pool_page_blocks(hobject::OBJ_SIZE_SMALL));
        self.obj_pool_func.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_FUNCTION, pool_page_blocks(hobject::OBJ_SIZE_FUNCTION));
        self.obj_pool_big.init(&allocators::LIBC_ALLOCATOR, hobject::OBJ_SIZE_BIG, pool_page_blocks(hobject::OBJ_SIZE_BIG));
        for (usz i = 0; i < POOL_CLASS_COUNT; i++) {
            self.small_pools[i].init(&allocators::LIBC_ALLOCATOR, (sz)POOL_CLASS_SIZES[i]);
        }
    }

    self.init_builtin_strs();

    // The sweep is over and the heap is usable again, so object teardown must
    // resume decrefing rather than assuming everything is about to be freed.
    // Registration names and prototypes belong to the heap being reset.
    self.host_fn_count = 0;
    self.host_class_count = 0;
    self.tearing_down = false;
}

// ============================================================================
// Host function registry
// ============================================================================

// Record a host function and return its slot, or -1 if the table cannot grow.
//
// The slot is an index into host_fns; callers turn it into a callable object
// through builtins::make_host_function, which adds HOST_FN_BASE. Slots are
// never reused: a registration is permanent for the heap's lifetime, so an
// index captured in a function object can never come to mean a different
// function.
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
    self.host_fns[slot].name          = hstring::string_ref((HString*)name);
    self.host_fns[slot].arity         = arity;
    self.host_fns[slot].constructable = constructable;
    self.host_fn_count++;
    return (long)slot;
}

// Entry for `slot`, or null when the slot was never registered. Every caller
// treats null as "not a host function" rather than faulting, so a stale or
// forged index degrades to a TypeError instead of a wild jump.
fn HostFnEntry* Heap.host_fn_at(&self, uint slot) {
    if (slot >= self.host_fn_count) return null;
    return &self.host_fns[slot];
}

// Register a host class, returning its id or -1 on allocation failure. Ids are
// dense and start at 0; they are stable for the life of the Heap, so a module
// can cache the id it gets back and compare against extra.host.class_id to
// check that an object is one of its own.
fn long Heap.register_host_class(&self, void* finalizer, void* gc_mark, void* udata, void* name, HObject* proto) {
    if (self.host_class_count >= self.host_class_capacity) {
        uint new_cap = self.host_class_capacity == 0 ? 4 : self.host_class_capacity * 2;
        usz new_bytes = (usz)new_cap * HostClassEntry::size;
        void* grown = self.realloc_func(self.heap_udata, (void*)self.host_classes, new_bytes);
        if (grown == null) return -1;
        self.host_classes = (HostClassEntry*)grown;
        self.host_class_capacity = new_cap;
    }
    uint id = self.host_class_count;
    self.host_classes[id].finalizer = finalizer;
    self.host_classes[id].gc_mark   = gc_mark;
    self.host_classes[id].udata     = udata;
    self.host_classes[id].name      = hstring::string_ref((HString*)name);
    self.host_classes[id].proto     = proto;
    self.shade_root_object(proto);
    self.host_class_count++;
    return (long)id;
}

// Entry for `id`, or null when never registered. As with host_fn_at, callers
// treat null as "not a host class" rather than faulting, so a forged class_id
// degrades instead of jumping through a wild pointer.
// Push `v` into the per-call handle table, returning its slot or -1.
fn long Heap.addon_handle_push(&self, TVal v) {
    if (self.addon_handle_count >= self.addon_handle_capacity) {
        uint new_cap = self.addon_handle_capacity == 0 ? 16 : self.addon_handle_capacity * 2;
        usz new_bytes = (usz)new_cap * TVal::size;
        void* grown = self.realloc_func(self.heap_udata, (void*)self.addon_handles, new_bytes);
        if (grown == null) return -1;
        self.addon_handles = (TVal*)grown;
        self.addon_handle_capacity = new_cap;
    }
    uint slot = self.addon_handle_count;
    self.addon_handles[slot] = types::make_undefined();
    self.tval_copy_ref(&self.addon_handles[slot], &v);
    self.addon_handle_count++;
    return (long)slot;
}

// The value at `slot`, or empty when out of range: a forged handle reads as
// undefined rather than off the end of the table.
fn TVal? Heap.addon_handle_at(&self, usz slot) {
    if (slot >= (usz)self.addon_handle_count) return HEAP_ALLOC_FAULT~;
    return self.addon_handles[slot];
}

// Nested calls release only the handles allocated in their own scope.
fn void Heap.addon_handles_rewind(&self, uint mark) {
    assert(mark <= self.addon_handle_count);
    while (self.addon_handle_count > mark) {
        self.addon_handle_count--;
        TVal* value = &self.addon_handles[self.addon_handle_count];
        if (!self.tearing_down) self.decref_tval(value);
        value.set_undefined();
    }
}

fn void Heap.addon_handles_reset(&self) {
    self.addon_handles_rewind(0);
}

fn HostClassEntry* Heap.host_class_at(&self, uint id) {
    if (id >= self.host_class_count) return null;
    return &self.host_classes[id];
}

// ============================================================================
// Host call scopes
// ============================================================================

// Slot 0 of every scope holds `this`; slot 1 holds new.target; arguments
// start at HOST_SCOPE_ARG0. Fixed offsets keep bk_this/bk_arg branch-free.
const uint HOST_SCOPE_THIS = 0;
const uint HOST_SCOPE_NEW_TARGET = 1;
const uint HOST_SCOPE_ARG0 = 2;

// Push a scope for one host callback and return its depth index, or -1.
//
// Each backing ARRAY stays in host_scopes until the callback returns; the
// collector traces that registry throughout the callback.
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
    // A native callback can push a scope after its registry cursor passed.
    self.shade_root_object(arr);
    self.host_scopes[depth].values = arr;
    self.host_scopes[depth].generation = self.host_scope_generation;
    self.host_scope_depth++;
    return (long)depth;
}

// Pop the innermost scope. Its values become unreachable and its generation
// is retired, so any handle still held by the host now fails validation.
fn void Heap.host_scope_pop(&self) {
    if (self.host_scope_depth == 0) return;
    self.host_scope_depth--;
    self.host_scopes[self.host_scope_depth].values = null;
    self.host_scopes[self.host_scope_depth].generation = 0;
}

// Store `v` in the innermost scope at `index`, returning success.
fn bool Heap.host_scope_set(&self, uint depth, uint index, TVal v) {
    if (depth >= self.host_scope_depth) return false;
    HObject* arr = self.host_scopes[depth].values;
    if (arr == null) return false;
    HString* key = self.int_to_hstring((long)index);
    if (key == null) return false;
    return arr.put_prop(key, v, hobject::PROP_FLAGS_WEC, self);
}

// Read the value at `index` in scope `depth`. Returns false when the scope is
// gone or the index was never populated.
fn bool Heap.host_scope_get(&self, uint depth, uint index, TVal* out) {
    if (depth >= self.host_scope_depth) return false;
    HObject* arr = self.host_scopes[depth].values;
    if (arr == null) return false;
    HString* key = self.int_to_hstring((long)index);
    if (key == null) return false;
    TVal? v = arr.get_prop(key, self);
    if (catch v) return false;
    *out = v;
    return true;
}

// Generation stamp of scope `depth`, or 0 when that depth is not live.
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
    uint index = self.compiled_func_count;
    self.compiled_funcs[index] = cf;
    if (self.gc_phase == GcPhase.MARK && !self.gc_new_compiled_pending) {
        self.gc_new_compiled_index = index;
        self.gc_new_compiled_subindex = 0;
        self.gc_new_compiled_pending = true;
    }
    self.compiled_func_count++;
}

// ============================================================================
// Module system: hooks and cache management
// ============================================================================

// Register module host hooks, before any module loading happens. Null selects
// the defaults. The pointer must stay valid for the lifetime of the Heap.
fn void Heap.set_module_hooks(&self, void* hooks) {
    self.module_hooks = hooks;
}

// Free the module cache and all ModuleDef entries.
fn void Heap.free_module_cache(&self) {
    if (self.module_cache != null) {
        void** cache = (void**)self.module_cache;
        for (uint i = 0; i < self.module_cache_count; i++) {
            if (cache[i] != null) {
                // Release the module's own side allocations before the record.
                esm::module_release_buffers(self, cache[i]);
                self.free_func(self.heap_udata, cache[i]);
            }
        }
        esm::module_release_batch_buffer(self);
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
    if (self.gc_phase != GcPhase.IDLE) self.gc_alloc_since_begin++;
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.request_gc();
    }

    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        return HEAP_ALLOC_FAULT~;
    }
    return ptr;
}

// Allocate without running a collection. Used for refcounted allocations such
// as strings, which the mark-and-sweep heap_allocated list does not hold.
//
// A synchronous GC from inside this allocator would be unsafe: it can free an
// in-flight object or string that a C3 local still points to but no GC root can
// see, such as the gap between alloc_object and the put_prop that anchors it,
// which corrupts the pool through a double free. Allocations here only ever set
// gc_pending, and the collection runs at the next safepoint.
//
// Small requests come from the size-class pools; only oversized ones reach the
// allocator below, so strings pay no per-block malloc header.
fn void*? Heap.alloc_no_gc(&self, usz size) {
    // Large strings still count toward GC pressure. A program building many
    // multi-KB concat results held by short-lived objects would never burn the
    // trigger down, and the objects holding those strings would pile up unswept.
    // Small strings stay uncounted: they are interned, so the string table backs
    // them, and counting them shifts GC cadence for every property-key
    // allocation without reclaiming more.
    if (size > 1024) {
        if (self.gc_phase != GcPhase.IDLE) self.gc_alloc_since_begin += (ulong)(size >> 10);
        self.gc_trigger_counter -= (long)(size >> 10);
        if (self.gc_trigger_counter <= 0) {
            self.request_gc();
        }
    }
    int cls = pool_class_index(size);
    if (cls >= 0) {
        return self.small_pools[cls].alloc();
    }
    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        return HEAP_ALLOC_FAULT~;
    }
    return ptr;
}

/**
 * Allocate a block of at least `size` bytes from the size-class pools, or
 * through the heap allocator when the request exceeds the largest class.
 * GC counting matches Heap.alloc, which is the path the fallback shares.
 */
fn void*? Heap.pool_alloc(&self, usz size) {
    int cls = pool_class_index(size);
    void*? result;
    if (cls >= 0) {
        result = self.small_pools[cls].alloc();
    } else {
        result = self.alloc(size);
    }
$if $feat(GC_PROFILE):
    if (try ptr = result) gcprofile::gcprof_pool_alloc(size);
$endif
    return result;
}

/**
 * Return a pooled block to its class pool. `size` must be the size the block
 * was requested with: it selects the class, or the heap allocator for an
 * oversized block.
 */
fn void Heap.pool_free(&self, void* ptr, usz size) {
    int cls = pool_class_index(size);
    if (cls >= 0) {
        self.small_pools[cls].dealloc(ptr);
    } else {
        self.free(ptr);
    }
}

/**
 * Allocate an HObject and add it to the heap's GC tracking list. Use this
 * rather than hobject::hobject_alloc() directly, which leaves the object off
 * heap_allocated and therefore invisible to mark-and-sweep.
 *
 * Returns the new HObject, or a fault if allocation fails.
 */
fn HObject*? Heap.alloc_object(&self, hobject::ObjClass cls, uint inline_array_capacity = 0) {
    HObject*? result = hobject::hobject_alloc((void*)self, cls, inline_array_capacity);
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
        if (self.gc_phase != GcPhase.IDLE) self.gc_alloc_since_begin++;
        gcprofile::gcprof_alloc();
        if (self.gc_trigger_counter <= 0) {
            self.request_gc();
        }
    }
    return result;
}

// Transition layouts remain valid until heap reset.
fn HObject*? Heap.alloc_shaped_object(&self, uint shape_id, hobject::ObjClass cls = hobject::ObjClass.OBJECT) {
    HObject* obj = self.alloc_object(cls)!;
    self.init_object_shape(obj, shape_id)!;
    return obj;
}

// Install a shared layout into a fresh object's empty property storage.
fn void? Heap.init_object_shape(&self, HObject* obj, uint shape_id) @inline {
    hobject::Shape* shape = self.get_shape(shape_id);
    uint count = shape.offset + shape.own_count;
    if (count > obj.prop_capacity) {
        void* storage = self.pool_alloc((usz)count * hobject::PropValue::size)!;
        obj.prop_alloc = storage;
        obj.prop_capacity = count;
    }
    for (uint i = 0; i < count; i++) obj.prop_values()[i].set_undefined();
    obj.prop_count = count;
    obj.shape_id = shape_id;
}

// CreateIterResultObject (ES2024 §7.4.14): `{value, done}` with the standard
// attributes and Object.prototype. The first result builds the shape through
// ordinary property definition; later ones allocate it directly. The value gains
// a reference of its own, so a caller that owns one still releases it.
fn HObject*? Heap.alloc_iter_result(&self, TVal value, bool done) {
    TVal done_tv;
    done_tv.set_boolean(done);
    HObject* result;
    if (self.iter_result_shape != 0) {
        result = self.alloc_shaped_object(self.iter_result_shape)!;
        hobject::PropValue* slots = result.prop_values();
        self.store_slot_ref(result, &slots[0], &value);
        slots[1] = (hobject::PropValue)done_tv;
    } else {
        result = self.alloc_object(hobject::ObjClass.OBJECT)!;
        result.put_prop(self.strs[BuiltinStr.VALUE], value, hobject::PROP_FLAGS_WEC, self);
        result.put_prop(self.strs[BuiltinStr.DONE], done_tv, hobject::PROP_FLAGS_WEC, self);
        hobject::Shape* shape = self.get_shape(result.shape_id);
        if (shape.parent != hobject::PRIVATE_SHAPE_PARENT) self.iter_result_shape = result.shape_id;
    }
    self.set_prototype(result, self.object_proto);
    return result;
}

/**
 * Reallocate a block through the heap's allocator, counting down the GC trigger.
 */
fn void*? Heap.realloc(&self, void* ptr, usz new_size) {
    if (self.gc_phase != GcPhase.IDLE) self.gc_alloc_since_begin++;
    gcprofile::gcprof_realloc();
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.request_gc();
    }

    void* new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
    if (new_ptr == null && new_size > 0) {
        return HEAP_ALLOC_FAULT~;
    }
    return new_ptr;
}

fn void Heap.free(&self, void* ptr) {
    self.free_func(self.heap_udata, ptr);
}

// Register stores release the overwritten string after evaluating the input.
fn void Heap.set_reg_fastint(&self, TVal* reg, long value) @inline {
    self.decref_tval(reg);
    reg.set_fastint(value);
}

fn void Heap.set_reg_undefined(&self, TVal* reg) @inline {
    self.decref_tval(reg);
    reg.set_undefined();
}

fn void Heap.set_reg_null(&self, TVal* reg) @inline {
    self.decref_tval(reg);
    reg.set_null();
}

fn void Heap.set_reg_boolean(&self, TVal* reg, bool value) @inline {
    self.decref_tval(reg);
    reg.set_boolean(value);
}

fn void Heap.set_reg_number(&self, TVal* reg, double value) @inline {
    self.decref_tval(reg);
    reg.set_number(value);
}

fn void Heap.set_reg_object(&self, TVal* reg, void* value) @inline {
    self.shade_root_object((HObject*)value);
    self.decref_tval(reg);
    reg.set_object(value);
}

fn void Heap.set_reg_fastint_or_number(&self, TVal* reg, long value) @inline {
    self.decref_tval(reg);
    reg.set_fastint_or_number(value);
}

fn void Heap.set_reg_bigint(&self, TVal* reg, void* value) @inline {
    if (self.gc_phase == GcPhase.MARK) self.mark_header((HeapHeader*)value);
    self.decref_tval(reg);
    reg.set_bigint(value);
}

fn void Heap.set_reg_pointer(&self, TVal* reg, void* value) @inline {
    self.decref_tval(reg);
    reg.set_pointer(value);
}

fn void Heap.set_reg_envref(&self, TVal* reg, void* value) @inline {
    self.shade_root_env(value);
    self.decref_tval(reg);
    reg.set_envref(value);
}

fn void Heap.set_reg_string(&self, TVal* reg, hstring::HString* s) @inline {
    TVal acquired;
    acquired.set_string(s);
    self.decref_tval(reg);
    *reg = acquired;
}

/**
 * Free an HString through the heap, matching how it was allocated: back to its
 * size-class pool, or to the allocator for a string above the largest class.
 */
fn void Heap.free_string(&self, hstring::HString* s) {
    if (s == null) { return; }
    usz total = hstring::HSTRING_HDR_SIZE + (usz)s.capacity + 1;  // +1 for NUL
    gcprofile::gcprof_string_free(total);
    if (s.blen == 1 && s.flags.is_ascii) {
        gcprofile::gcprof_ascii_char_free();
    }
    int cls = pool_class_index(total);
    if (cls >= 0) {
        self.small_pools[cls].dealloc((void*)s);
    } else {
        self.free_func(self.heap_udata, (void*)s);
    }
}



// ============================================================================
// Reference counting: decref, and free at zero
// ============================================================================

/**
 * Drop a reference to a string, freeing it at zero. Strings are the only
 * reference-counted values: objects, buffers and BigInts are reclaimed by the
 * collector alone, so a release of one of those does nothing.
 */
fn void Heap.decref(&self, HeapHeader* hdr) {
    // Pinned headers, meaning builtin strings, well-known symbols, and the
    // small-int cache, keep a fixed refcount. See HeapHeader.set_pinned.
    if (!hdr.is_string() || hdr.is_pinned()) {
        return;
    }
    if (--hdr.refcount == 0) {
        hstring::HString* s = (hstring::HString*)hdr;
        if (s.flags.is_interned) {
            self.str_table_remove(s);
        } else {
            self.large_string_unregister(s);
        }
        self.free_string(s);
    }
}

/**
 * Drop a reference to whatever heap object, buffer, or string a TVal holds.
 * Any TVal is acceptable, since primitives are ignored. Call this before
 * overwriting a register or slot that may hold a heap pointer.
 */
fn void Heap.decref_tval(&self, TVal* tv) @inline {
    $if $feat(SCAN_POISON):
        self.reject_poison(tv, "decref_tval");
    $endif
    if (tv.is_refcounted()) {
        void* ptr = tv.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
}

fn void Heap.decref_slot(&self, hobject::PropValue* slot) @inline {
    TVal value = slot.get();
    self.decref_tval(&value);
}

fn void Heap.copy_slot_to_tval(&self, TVal* dst, hobject::PropValue* src) @inline {
    TVal value = src.get();
    self.tval_copy_ref(dst, &value);
}

fn void Heap.copy_tval_to_slot(&self, HObject* owner, hobject::PropValue* dst, TVal* src) @inline {
    self.store_slot_ref(owner, dst, src);
}

fn void Heap.move_slot_to_tval(&self, TVal* dst, hobject::PropValue* src) @inline {
    TVal value = src.get();
    self.shade_root_tval(value);
    self.decref_tval(dst);
    *dst = value;
    src.set_undefined();
}

// Copy a TVal from src to dst, keeping refcounts balanced. Increfs src, then
// decrefs the old dst value, then copies the bits. Does nothing when dst == src.
fn void Heap.tval_copy_ref(&self, TVal* dst, TVal* src) @inline {
    if (dst != src) {
        self.shade_root_tval(*src);
        // The incref comes first so that when src and dst hold the same object
        // at refcount 1, such as assigning one global to another, the decref
        // below cannot free it before the new reference is anchored.
        if (src.is_refcounted()) {
            void* ptr = src.get_heapptr();
            if (ptr != null) {
                ((HeapHeader*)ptr).incref();
            }
        }
        self.decref_tval(dst);
        *dst = *src;
    }
}

// Both slots own their values. Shade the incoming value before releasing
// the destination, then transfer its reference and clear the source slot.
fn void Heap.move_tval_ref(&self, TVal* dst, TVal* src) @inline {
    if (dst == src) return;
    self.shade_root_tval(*src);
    self.decref_tval(dst);
    *dst = *src;
    src.set_undefined();
}

fn void Heap.store_builtin_result(&self, TVal* dst, TVal* result) @inline {
    self.move_tval_ref(dst, result);
}

// Move a TVal from a register into a slot of `owner`, handing src's reference
// to dst. The destination releases its old value and src becomes undefined.
// A primitive already in dst needs no decref, so the branch skips it. This is
// the hot global-slot write path used by PUTGLOBAL.
//
// Only the overwritten dst value decides whether a decref is owed. The move
// preserves src's refcount whether src is a heap value or a primitive.
fn void Heap.tval_move_slot_fast(&self, HObject* owner, hobject::PropValue* dst, TVal* src) @inline {
    self.write_barrier(owner, *src);
    TVal old = dst.get();
    if (old.is_heap_allocated()) {
        void* ptr = old.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
    *dst = (hobject::PropValue)*src;
    src.set_undefined();
}

// ============================================================================
// Managed-object lists, doubly linked through HeapHeader
// ============================================================================

/**
 * Insert a newly allocated header on the sweep list.
 */
fn void Heap.insert_into_heap_allocated(&self, HeapHeader* hdr) {
    hdr.init(hdr.get_type(), &self.young_allocated);
    self.shade_new_header(hdr);
}

/**
 * Remove `hdr` from its generation's allocation list.
 */
fn void Heap.remove_from_heap_allocated(&self, HeapHeader* hdr) {
    hdr.unlink(hdr.gc.old ? &self.heap_allocated : &self.young_allocated);
}

/**
 * Insert `hdr` at the head of the young list without calling HeapHeader.init(),
 * so flags the caller already set survive.
 *
 * Use this when the subtype, HObject or HString, has set its own flags and only
 * the list wiring is missing. Raw HeapHeader allocations that need a full header
 * init should use insert_into_heap_allocated() instead.
 */
fn void Heap.insert_into_heap_allocated_preserve_flags(&self, HeapHeader* hdr) {
    hdr.prev = null;
    hdr.next = self.young_allocated;
    if (self.young_allocated != null) {
        self.young_allocated.prev = hdr;
    }
    self.young_allocated = hdr;
    self.shade_new_header(hdr);
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
    // A zero-initialized Heap carries a zeroed List (null entries); arm its
    // allocator on first use so every creation path is covered without an
    // explicit init order.
    if (self.gc_roots.entries == null && self.gc_roots.size == 0) {
        self.gc_roots.allocator = mem;
    }
    self.gc_roots.push((void*)hdr);
    if (self.gc_phase == GcPhase.MARK && hdr != null) {
        self.mark_header(hdr);
    }
}

// ============================================================================
// Array.prototype.join cycle detection
// ============================================================================

// True when `obj` is already being joined further up the call stack, i.e.
// recursing into it would not terminate.
fn bool Heap.join_visited_has(&self, HObject* obj) {
    for (uint i = 0; i < self.join_visited_count; i++) {
        if (self.join_visited[i] == (void*)obj) return true;
    }
    return false;
}

// Mark `obj` as being joined. Returns false when the stack cannot grow, which
// callers must treat as a failure to enter rather than as "no cycle": pushing
// nothing would let the next level re-enter the same array unnoticed.
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

// Unmark the innermost array being joined.
fn void Heap.join_visited_pop(&self) {
    if (self.join_visited_count > 0) self.join_visited_count--;
}

// ============================================================================
// GC marking: tri-color marking over an intrusive gray queue
// ============================================================================

/**
 * Store `v` into a property or element slot of `owner`, passing the write
 * barrier. Every object slot store goes through here;
 * PropValue's distinct type keeps a plain assignment from compiling.
 */
fn void Heap.store_slot(&self, HObject* owner, hobject::PropValue* slot, TVal v) @inline {
    *slot = (hobject::PropValue)v;
    self.write_barrier(owner, v);
}

/**
 * tval_copy_ref into a slot of `owner`, passing the write barrier.
 */
fn void Heap.store_slot_ref(&self, HObject* owner, hobject::PropValue* slot, TVal* src) @inline {
    TVal old = slot.get();
    if (src.is_refcounted()) {
        void* ptr = src.get_heapptr();
        if (ptr != null) ((HeapHeader*)ptr).incref();
    }
    self.write_barrier(owner, *src);
    self.decref_tval(&old);
    *slot = (hobject::PropValue)*src;
}

/**
 * Shade a newly stored traced value while incremental marking is active.
 * Every pointer store, including construction stores, uses this barrier.
 */
fn void Heap.write_barrier(&self, HObject* owner, TVal v) @inline {
    if (self.gc_phase == GcPhase.MARK) {
        if (v.is_traced()) self.shade_value(v);
    } else if (owner != null && owner.gc.old && self.is_young_value(v)) {
        self.remember(owner);
    }
}

/**
 * mark_tval for a by-value TVal. Marking needs the value's address, and taking
 * it in an inlined barrier would pin a stack slot in every store site, which
 * costs a threaded handler its tail-call dispatch.
 */
fn void Heap.shade_value(&self, TVal v) @noinline {
    self.mark_tval(&v);
}

/**
 * The write barrier for a store of a node pointer rather than a TVal.
 */
fn void Heap.write_barrier_ptr(&self, HObject* owner, void* target) @inline {
    HeapHeader* header = (HeapHeader*)target;
    if (self.gc_phase == GcPhase.MARK) {
        self.mark_header(header);
    } else if (owner != null && owner.gc.old && header != null && !header.gc.old) {
        self.remember(owner);
    }
}

fn void Heap.shade_root_tval(&self, TVal value) @inline {
    if (self.gc_phase == GcPhase.MARK && value.is_traced()) self.mark_tval(&value);
}

fn void Heap.shade_root_object(&self, HObject* value) @inline {
    if (self.gc_phase == GcPhase.MARK && value != null) self.mark_hobject(value);
}

fn void Heap.shade_root_env(&self, void* value) @inline {
    if (self.gc_phase == GcPhase.MARK && value != null) self.mark_env_chain(value);
}

fn void Heap.shade_root_generator_state(&self, GeneratorState* value) @inline {
    if (self.gc_phase != GcPhase.MARK || value == null || value.gc_mark_epoch == self.gc_mark_epoch) return;
    value.gc_mark_epoch = self.gc_mark_epoch;
    value.gc_gray_queued = true;
    gs_acquire(value);
    value.gc_gray_next = null;
    if (self.gc_gen_gray_tail != null) {
        self.gc_gen_gray_tail.gc_gray_next = value;
    } else {
        self.gc_gen_gray_head = value;
    }
    self.gc_gen_gray_tail = value;
}

fn void Heap.restart_vm_root_scan(&self) @inline {
    if (self.gc_phase != GcPhase.MARK) return;
    self.gc_vm_root_cursor = 0;
    if (self.gc_root_stage > 0) self.gc_root_stage = 0;
}

fn void Heap.shade_new_header(&self, HeapHeader* value) @inline {
    if (self.gc_phase != GcPhase.MARK || value == null) return;
    value.set_reachable();
    if (value.is_object()) self.gray_push((HObject*)value);
}

/**
 * Assign `value` to an internal field of `owner`, such as a promise's result or
 * an iterator's target, and run the barrier that matches the field: the TVal
 * form for a TVal, the pointer form for a node pointer. TVal fields own their
 * string references; replacement acquires the new value before release.
 */
macro void Heap.@set_edge(&self, HObject* owner, #field, value) {
    $switch $Typeof(value):
        $case TVal:
            TVal edge = value;
            self.tval_copy_ref(&(#field), &edge);
            self.write_barrier(owner, edge);
        $default:
            #field = value;
            self.write_barrier_ptr(owner, (void*)value);
    $endswitch
}

/**
 * [[SetPrototypeOf]] and construction stores pass the incremental insertion
 * barrier so a marker that already scanned the object sees the new prototype.
 */
fn void Heap.set_prototype(&self, HObject* obj, HObject* proto) @inline {
    obj.prototype = proto;
    self.write_barrier_ptr(obj, proto);
}

/**
 * Queue an object for tracing without an allocator call.
 */
fn void Heap.gray_push(&self, HObject* obj) {
    self.marked_obj_count++;
    obj.gc_gray_next = null;
    if (self.gc_gray_tail != null) {
        self.gc_gray_tail.gc_gray_next = obj;
    } else {
        self.gc_gray_head = obj;
    }
    self.gc_gray_tail = obj;
    self.gray_count++;
}

/**
 * Remove the oldest gray object. Returns null when the queue is empty.
 */
fn HObject* Heap.gray_pop(&self) {
    HObject* obj = self.gc_gray_head;
    if (obj == null) return null;
    self.gc_gray_head = obj.gc_gray_next;
    if (self.gc_gray_head == null) self.gc_gray_tail = null;
    obj.gc_gray_next = null;
    self.gray_count--;
    return obj;
}

/**
 * Mark the value a TVal holds as reachable. An object is marked and pushed onto
 * the gray queue so its children are visited. Strings and bigints have no
 * outgoing edges, so they are only marked.
 */
// A poisoned slot is one no writer ever reached, or one whose owner was freed
// while the marker still had a path to it. The payload is not a heap address, so
// following it stamps the reachable bit into whatever now occupies that address.
fn void Heap.reject_poison(&self, TVal* v, ZString where) @feat(SCAN_POISON) {
    if (v.is_poison()) {
        io::eprintf("[scan-poison] %s: slot %p holds the poison fill\n", where, v);
        self.fatal_func(self.heap_udata, "scan-poison: poisoned slot reached the collector");
    }
}

// Same check for a pointer field that holds the fill because no writer reached
// it: casting such a pointer to a HeapHeader and reading its flags is the write
// this rejects.
fn void Heap.reject_poison_ptr(&self, void* ptr, ZString where) @feat(SCAN_POISON) {
    if ((usz)ptr == (usz)types::POISON_PAYLOAD) {
        io::eprintf("[scan-poison] %s: pointer %p holds the poison fill\n", where, ptr);
        self.fatal_func(self.heap_udata, "scan-poison: poisoned pointer reached the collector");
    }
}

// A quiescent root cannot depend on a temporary native borrow.
fn void Heap.verify_string_owner(&self, HString* value) @feat(GC_VERIFY) {
    if (value == null || self.native_frame_depth != 0) return;
    uint table_reference = value.flags.is_interned ? 1u : 0u;
    if (value.refcount <= table_reference) {
        io::eprintfn("[GC_VERIFY] live string lacks an owner: refs=%d interned=%d bytes=%d",
            value.refcount, (int)value.flags.is_interned, value.blen);
        self.fatal_func(self.heap_udata, "GC_VERIFY: unowned live string");
    }
}

fn void Heap.mark_tval(&self, TVal* v) {
    gcprofile::gcprof_mark();
    self.mark_work_last++;
    $if $feat(SCAN_POISON):
        self.reject_poison(v, "mark_tval");
    $endif
    if (v.is_object()) {
        self.mark_hobject((HObject*)v.get_heapptr());
    } else if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null) {
            $if $feat(GC_VERIFY):
                self.verify_string_owner(s);
            $endif
        }
    } else if (v.is_bigint() || v.is_buffer()) {
        self.mark_header((HeapHeader*)v.get_heapptr());
    } else if (v.is_envref()) {
        // A saved internal environment reference. Trace its whole chain; the
        // epoch check inside mark_env_chain dedups shared ancestors.
        self.mark_env_chain(v.get_heapptr());
    }
}

/**
 * Mark the `bindings` HObject of every EnvRecord in a scope chain.
 *
 * An EnvRecord is a pool-allocated cell and its `bindings` object is an
 * ordinary heap node. Marking only the innermost link roots one scope and
 * leaves every enclosing one collectible: a closure suspended over
 * `outer -> middle -> inner` survives a sweep with `inner.bindings` intact and
 * `outer.bindings` freed, and the first GETVAR walking past `inner` reads a
 * recycled pool block, which surfaces as HObject.get_shape under find_prop_idx.
 *
 * Whoever roots a scope chain roots the whole chain, so callers must never mark
 * `env.bindings` directly. mark_activation_envs in vm_core.c3 does this walk for
 * live frames; this is the counterpart for closures, generator objects, and
 * suspended GeneratorStates.
 *
 * The walk is first-visit: a cell whose mark_epoch already equals the heap's
 * current epoch was traced earlier this cycle, so the chain above it was too,
 * and the loop stops. Shared chains are therefore visited once per collection
 * rather than once per closure, and the traversal is iterative so chain depth
 * cannot grow the C stack.
 *
 * `env_ptr` is an opaque EnvRecord*, since heap.c3 cannot import env.c3, which
 * imports heap.c3. The typed field reads happen in hobject.c3.
 */
fn void Heap.mark_env_chain(&self, void* env_ptr) {
    if (self.gc_phase == GcPhase.MARK && !self.gc_oracle_running) {
        self.queue_env(env_ptr);
        return;
    }
    void* cur = env_ptr;
    while (cur != null) {
        $if $feat(SCAN_POISON):
            self.reject_poison_ptr(cur, "mark_env_chain");
        $endif
        // Only an allocated cell has meaningful bindings/heap. A free cell or a
        // stale pointer into a recycled cell must stop the walk before either
        // is read; verification builds report it rather than walking on.
        if (!hobject::env_record_is_allocated(cur)) {
            $if $feat(HEAP_VERIFY):
                io::eprintf("[HEAP_VERIFY]   ERROR mark_env_chain: %p is not an allocated EnvRecord\n", cur);
            $endif
            break;
        }
        $if $feat(HEAP_VERIFY):
            if (!hobject::env_pool_contains(self, cur)) {
                io::eprintf("[HEAP_VERIFY]   ERROR mark_env_chain: %p is not in this heap's pool\n", cur);
                break;
            }
        $endif
        if (hobject::env_record_get_epoch(cur) == self.env_mark_epoch) {
            break;
        }
        hobject::env_record_set_epoch(cur, self.env_mark_epoch);
        self.mark_work_last++;
        HObject* bindings = hobject::env_record_bindings(cur);
        if (bindings != null) { self.mark_hobject(bindings); }
        cur = hobject::env_record_parent(cur);
    }
}

fn void Heap.queue_env(&self, void* env_ptr) {
    if (env_ptr == null || !hobject::env_record_is_allocated(env_ptr)) return;
    if (hobject::env_record_get_epoch(env_ptr) == self.env_mark_epoch) return;
    hobject::env_record_set_epoch(env_ptr, self.env_mark_epoch);
    hobject::env_record_set_gray_next(env_ptr, null);
    if (self.gc_env_gray_tail != null) {
        hobject::env_record_set_gray_next(self.gc_env_gray_tail, env_ptr);
    } else {
        self.gc_env_gray_head = env_ptr;
    }
    self.gc_env_gray_tail = env_ptr;
}

fn bool Heap.scan_env_step(&self) {
    void* env_ptr = self.gc_env_gray_head;
    if (env_ptr == null) {
        if (self.gc_aux_env_cursor.block == null) return false;
        hobject::env_pool_mark_slice(self, 1);
        return true;
    }
    self.gc_env_gray_head = hobject::env_record_gray_next(env_ptr);
    if (self.gc_env_gray_head == null) self.gc_env_gray_tail = null;
    hobject::env_record_set_gray_next(env_ptr, null);
    HObject* bindings = hobject::env_record_bindings(env_ptr);
    if (bindings != null) self.mark_hobject(bindings);
    self.queue_env(hobject::env_record_parent(env_ptr));
    return true;
}

// Push a native scoped environment root: `root` is a C3 local that now
// protects `env` (an EnvRecord the GC could not otherwise reach) until the
// matching pop. The GC traces env_roots on every collection.
fn void Heap.push_env_root(&self, EnvRoot* root, void* env) {
    root.env = env;
    root.previous = self.env_roots;
    self.env_roots = root;
    self.shade_root_env(env);
}

// Remove `root` from the native environment-root stack. Removal is LIFO.
fn void Heap.pop_env_root(&self, EnvRoot* root) {
    $if $feat(HEAP_VERIFY):
        if (self.env_roots != root) {
            io::eprintf("[HEAP_VERIFY] env root popped out of order\n");
        }
    $endif
    if (self.gc_root_env_cursor == root) self.gc_root_env_cursor = root.previous;
    self.env_roots = root.previous;
}

fn void Heap.push_object_root(&self, ObjectRoot* root, HObject* object) {
    root.object = object;
    root.previous = self.object_roots;
    self.object_roots = root;
    self.shade_root_object(object);
}

fn void Heap.pop_object_root(&self, ObjectRoot* root) {
    assert(self.object_roots == root);
    if (self.gc_root_object_cursor == root) self.gc_root_object_cursor = root.previous;
    self.object_roots = root.previous;
}

fn void Heap.push_value_root(&self, ValueRoot* root, TVal value) {
    root.value.set_undefined();
    self.tval_copy_ref(&root.value, &value);
    root.previous = self.value_roots;
    self.value_roots = root;
}

fn void Heap.pop_value_root(&self, ValueRoot* root) {
    assert(self.value_roots == root);
    if (self.gc_root_value_cursor == root) self.gc_root_value_cursor = root.previous;
    self.value_roots = root.previous;
    self.decref_tval(&root.value);
    root.value.set_undefined();
}

// Mark everything a suspended GeneratorState references. Both generator objects
// and the async/await resume and reject builtins go through here.
fn void Heap.mark_generator_state_full(&self, GeneratorState* gs) {
    if (gs == null) return;
    // These edges belong to the state, which can outlive one owner object.
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
    // The function the body was created from. GEN_START and every resume read it
    // to fill the activation's borrowed callee slot, and a suspended generator
    // can outlive every other reference to the function: `.next()` keeps only
    // the instance, and the instance holds no back-pointer to it.
    if (gs.func_obj != null) {
        self.mark_hobject((HObject*)gs.func_obj);
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

fn void Heap.mark_generator_state(&self, GeneratorState* gs) {
    if (self.gc_phase == GcPhase.MARK && !self.gc_oracle_running) {
        self.shade_root_generator_state(gs);
    } else {
        self.mark_generator_state_full(gs);
    }
}

/**
 * Mark an HObject reachable and queue it for tracing. Does nothing if it
 * is already marked.
 */
fn void Heap.mark_hobject(&self, HObject* obj) {
    if (obj == null) { return; }
    $if $feat(SCAN_POISON):
        self.reject_poison_ptr((void*)obj, "mark_hobject");
    $endif
    self.mark_header((HeapHeader*)obj);
}

// The object class selects the active member of the calendar/identifier union.
fn void Heap.mark_temporal(&self, HObjectTemporal* t, ObjClass kind) {
    if (t.big_ns != null) {
        self.mark_header((HeapHeader*)t.big_ns);
    }
    if (kind == ObjClass.TEMPORAL_TIMEZONE || kind == ObjClass.TEMPORAL_ZONEDDATETIME) {
        $if $feat(GC_VERIFY):
            self.verify_string_owner(t.identifier.borrow());
        $endif
    } else if (t.calendar != null) {
        self.mark_hobject(t.calendar);
    }
    if (t.timezone != null) { self.mark_hobject(t.timezone); }
}

/**
 * Pop objects off the gray queue and follow their outgoing references: the
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

        hobject::PropValue* pv = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            TVal value = pv[i].get();
            self.mark_tval(&value);
        }

        hobject::PropValue* ap = obj.array_part();
        if (ap != null && obj.array_used > 0) {
            for (uint i = 0; i < obj.array_size; i++) {
                TVal value = ap[i].get();
                self.mark_tval(&value);
            }
        }

        // Fields that only some subtypes have.
        switch (obj.flags.obj_class) {
            case ObjClass.FUNCTION:
            case ObjClass.THREAD:
                // Bound functions leave var_env, lex_env, captured_this, and
                // captured_new_target unset, so only the bound_* fields matter.
                if (obj.flags.is_bound) {
                    self.mark_tval(&(*obj.extra_ptr()).func.bound.target);
                    self.mark_tval(&(*obj.extra_ptr()).func.bound.this_arg);
                    if ((*obj.extra_ptr()).func.bound.args != null) {
                        self.mark_hobject((*obj.extra_ptr()).func.bound.args);
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
                if ((*obj.extra_ptr()).func.capture_refs != null
                    && (*obj.extra_ptr()).func.comp_func != null) {
                    uint capture_count = (*obj.extra_ptr()).func.comp_func.capture_count;
                    hobject::CaptureRef* refs = (*obj.extra_ptr()).func.capture_refs;
                    for (uint i = 0; i < capture_count; i++) {
                        if (refs[i].is_value) { self.mark_tval(&refs[i].value); }
                        else if (refs[i].owner != null) { self.mark_hobject(refs[i].owner); }
                    }
                }
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
                // (BuiltinStr.REACTION_NEXT, written by
                // builtins::reaction_set_next). HeapHeader.next threads the
                // heap_allocated GC list instead, so walking it here would
                // follow unrelated objects.
                self.mark_tval(&(*obj.extra_ptr()).promise.result);
                HObject* reaction = (*obj.extra_ptr()).promise.reactions_head;
                while (reaction != null) {
                    self.mark_hobject(reaction);
                    HObject* next_reaction = null;
                    if (try nv = reaction.get_prop(self.str(BuiltinStr.REACTION_NEXT), self)) {
                        if (nv.is_object() && nv.get_heapptr() != null) {
                            next_reaction = (HObject*)nv.get_heapptr();
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
            case ObjClass.HOST:
                // Hand the payload to the class's own mark callback so values
                // it holds stay reachable. A class with no JS values in its
                // payload registers a null gc_mark and costs one branch.
                HostClassEntry* hc = self.host_class_at((*obj.extra_ptr()).host.class_id);
                if (hc != null && hc.gc_mark != null) {
                    HostClassMarkFn mark_fn = (HostClassMarkFn)hc.gc_mark;
                    mark_fn((*obj.extra_ptr()).host.payload, self, hc.udata);
                }
                break;
            case ObjClass.ARRAY_ITERATOR:
            case ObjClass.MAP_ITERATOR:
            case ObjClass.SET_ITERATOR:
                // extra.iter.target holds the iterated object for these three
                // classes.
                if ((*obj.extra_ptr()).iter.target != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter.target);
                }
                break;
            case ObjClass.STRING_ITERATOR:
                $if $feat(GC_VERIFY):
                    self.verify_string_owner((*obj.extra_ptr()).str_iter.string.borrow());
                $endif
                break;
            case ObjClass.REGEXP_STRING_ITERATOR:
                $if $feat(GC_VERIFY):
                    self.verify_string_owner((*obj.extra_ptr()).regexp_iter.string.borrow());
                $endif
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
                if ((*obj.extra_ptr()).iter_helper.buffer != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter_helper.buffer);
                }
                break;
            case ObjClass.GETTER_SETTER:
                self.mark_tval(&(*obj.extra_ptr()).gs.getter);
                self.mark_tval(&(*obj.extra_ptr()).gs.setter);
                break;
            case ObjClass.ERROR:
                self.mark_tval(&(*obj.extra_ptr()).err.captured_stack);
                break;
            case ObjClass.TEMPORAL_CALENDAR:
            case ObjClass.TEMPORAL_DURATION:
            case ObjClass.TEMPORAL_PLAIN_DATE:
            case ObjClass.TEMPORAL_PLAIN_TIME:
            case ObjClass.TEMPORAL_PLAIN_DATETIME:
            case ObjClass.TEMPORAL_PLAIN_YEARMONTH:
            case ObjClass.TEMPORAL_PLAIN_MONTHDAY:
            case ObjClass.TEMPORAL_INSTANT:
            case ObjClass.TEMPORAL_TIMEZONE:
            case ObjClass.TEMPORAL_ZONEDDATETIME:
                self.mark_temporal(&(*obj.extra_ptr()).temporal, obj.flags.obj_class);
                break;
            default:
                break;
        }

    }
}

/**
 * Mark every GC root: the registered roots, built-in prototypes, the VM value
 * stack, and the string references found along the way. Transitive marking runs
 * through the gray queue, so there is no recursion or depth limit.
 */
fn void Heap.mark_roots(&self) {
    for (ObjectRoot* r = self.object_roots; r != null; r = r.previous) {
        self.mark_hobject(r.object);
    }
    for (ValueRoot* r = self.value_roots; r != null; r = r.previous) {
        self.mark_tval(&r.value);
    }
    // Native scoped environment roots: an EnvRecord held only in a C3 local
    // across a GC-capable call. Traced first so their whole chains are marked
    // before the gray queue drains.
    for (EnvRoot* r = self.env_roots; r != null; r = r.previous) {
        self.mark_env_chain(r.env);
    }

    for (uint i = 0; i < (uint)self.gc_roots.len(); i++) {
        HeapHeader* hdr = (HeapHeader*)self.gc_roots[i];
        self.mark_header(hdr);
    }

    // Values the C ABI's host holds handles to.
    if (self.capi_mark != null) self.capi_mark(self.capi_roots);

    // Promoted builtin function objects. A promoted builtin is frequently
    // reachable from nothing else -- the LIGHTFUNC value the program holds
    // carries only an index, not the pointer -- so the cache is its sole root.
    // Sweeping one while the cache still names it would leave a dangling
    // pointer that the next promotion of that ordinal would hand straight back
    // to script.
    if (self.promoted_builtins != null) {
        for (uint i = 0; i < self.promoted_builtin_capacity; i++) {
            HObject* pf = self.promoted_builtins[i];
            if (pf != null) { self.mark_hobject(pf); }
        }
    }

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
    // Values on loan to an add-on stay alive for the duration of its call.
    for (uint i = 0; i < self.addon_handle_count; i++) {
        self.mark_tval(&self.addon_handles[i]);
    }
    // Every registered host class's prototype is a root, so add-ons need no
    // engine-side field of their own.
    for (uint i = 0; i < self.host_class_count; i++) {
        if (self.host_classes[i].proto != null) { self.mark_hobject(self.host_classes[i].proto); }
    }
    if (self.array_proto != null) { self.mark_hobject(self.array_proto); }
    if (self.array_values_fn != null) { self.mark_hobject(self.array_values_fn); }
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
    if (self.abstract_module_source_ctor != null) { self.mark_hobject(self.abstract_module_source_ctor); }
    if (self.abstract_module_source_proto != null) { self.mark_hobject(self.abstract_module_source_proto); }
    if (self.module_source_proto != null) { self.mark_hobject(self.module_source_proto); }
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
    if (self.temporal_iso_calendar != null) { self.mark_hobject(self.temporal_iso_calendar); }
    if (self.temporal_duration_proto != null) { self.mark_hobject(self.temporal_duration_proto); }
    if (self.temporal_plain_date_proto != null) { self.mark_hobject(self.temporal_plain_date_proto); }
    if (self.temporal_plain_time_proto != null) { self.mark_hobject(self.temporal_plain_time_proto); }
    if (self.temporal_plain_datetime_proto != null) { self.mark_hobject(self.temporal_plain_datetime_proto); }
    if (self.temporal_plain_yearmonth_proto != null) { self.mark_hobject(self.temporal_plain_yearmonth_proto); }
    if (self.temporal_plain_monthday_proto != null) { self.mark_hobject(self.temporal_plain_monthday_proto); }
    if (self.temporal_instant_proto != null) { self.mark_hobject(self.temporal_instant_proto); }
    if (self.temporal_zoneddatetime_proto != null) { self.mark_hobject(self.temporal_zoneddatetime_proto); }

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
        for (uint i = self.microtask_head * 3; i < self.microtask_count * 3; i++) {
            self.mark_tval(&self.microtask_queue[i]);
        }
    }

    // A promise queued for unhandled-rejection reporting is frequently
    // referenced by nothing else, so this list is its only root until the
    // drain ends and the report is made.
    if (self.unhandled_rejections != null) {
        for (uint i = 0; i < self.unhandled_count; i++) {
            self.mark_tval(&self.unhandled_rejections[i]);
        }
    }

    // Atomics.waitAsync waiters keep their parked buffer + pending promise alive.
    for (uint i = 0; i < self.async_waiter_count; i++) {
        if (self.async_waiters[i].active) {
            if (self.async_waiters[i].buffer != null) self.mark_hobject(self.async_waiters[i].buffer);
            if (self.async_waiters[i].promise != null) self.mark_hobject(self.async_waiters[i].promise);
        }
    }

    // CompiledFunctions live in their own tracking array rather than the GC
    // heap, so the strings and objects their constant pools and inline caches
    // reference are rooted here.
    for (uint fi = 0; fi < self.compiled_func_count; fi++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[fi];
        if (cf == null) { continue; }
        if (cf.constants != null) {
            for (uint ci = 0; ci < cf.const_count; ci++) {
                self.mark_tval(&cf.constants[ci]);
            }
        }
        // Property IC entries cache a proto object and a key string.
        if (cf.ic_entries != null && cf.ic_count > 0) {
            hobject::ICEntry* ics = (hobject::ICEntry*)cf.ic_entries;
            for (uint ii = 0; ii < cf.ic_count; ii++) {
                hobject::ICEntry* ie = &ics[ii];
                if (ie.proto != null) { self.mark_hobject((HObject*)ie.proto); }
            }
        }
    }

    for (uint i = 0; i < self.checkpoint_count; i++) {
        self.mark_tval(&self.checkpoint_entries[i].value);
    }

    // Per-call activation envs, which nothing else roots.
    if (self.mark_activations_fn != null && self.curr_thread != null) {
        self.mark_activations_fn(self.curr_thread, self);
    }

    // In-flight error and generator state held directly on the heap.
    self.mark_tval(&self.error_value);
    self.mark_tval(&self.yield_value);
    for (uint i = 0; i < self.host_scope_depth; i++) {
        self.mark_hobject(self.host_scopes[i].values);
    }
    self.mark_generator_state(self.resume_gen);
    self.mark_generator_state(self.gen_initial_gs);

    // While param-init runs, the generator object under construction is not yet
    // in any register or stack slot, so this field is its only root.
    if (self.gen_initial_obj != null) {
        self.mark_hobject((HObject*)self.gen_initial_obj);
    }
    // Outer generators whose param-init is paused on an inner generator call.
    for (uint gsi = 0; gsi < self.gen_init_stack_depth; gsi++) {
        self.mark_generator_state(self.gen_init_stack_gs[gsi]);
        if (self.gen_init_stack_obj[gsi] != null) {
            self.mark_hobject((HObject*)self.gen_init_stack_obj[gsi]);
        }
    }

    // ModuleDefs are in a malloc'd cache the sweep never scans, so the values
    // they hold are rooted here. `eval_error` is an ERRORED module's cached
    // [[EvaluationError]], re-rejected on every later import, and `synth_value`
    // is a synthetic module's default export -- for a bytes module, the only
    // reference to its Uint8Array and the immutable buffer behind it.
    if (self.module_cache != null) {
        esm::ModuleDef** cache = (esm::ModuleDef**)self.module_cache;
        for (uint i = 0; i < self.module_cache_count; i++) {
            esm::ModuleDef* mod = cache[i];
            if (mod == null) continue;
            // The module environment holds its bindings and chains to the
            // global scope. The namespace/eval-error/import.meta marks below do
            // not substitute for this edge: a module with no executing
            // activation still needs its record alive.
            self.mark_env_chain((void*)mod.env);
            if (mod.has_eval_error) { self.mark_tval(&mod.eval_error); }
            if (mod.is_synthetic)   { self.mark_tval(&mod.synth_value); }
            // The cached import.meta object (§16.2.1.10 [[ImportMeta]]) carries
            // user-visible state such as added properties and a changed
            // prototype, and lives as long as the module.
            if (mod.import_meta_obj != null) { self.mark_hobject(mod.import_meta_obj); }
            // The cached namespace objects live as long as the module, so every
            // later import() returns the same identity (§16.2.1.10
            // GetModuleNamespace).
            if (mod.namespace_obj != null) { self.mark_hobject(mod.namespace_obj); }
            if (mod.deferred_namespace_obj != null) { self.mark_hobject(mod.deferred_namespace_obj); }
            // Likewise the module source object (ES2025 source-phase-imports),
            // which exists only for a module some `import source` names.
            if (mod.module_source_obj != null) { self.mark_hobject(mod.module_source_obj); }
            // The import.defer() promise awaiting this module's async subgraph.
            if (mod.defer_pending_promise != null) { self.mark_hobject(mod.defer_pending_promise); }
            if (mod.eval_promise != null) { self.mark_hobject(mod.eval_promise); }
        }
    }

    self.drain_gray();
}

// Prune weak variable-inline-cache entries once marking reaches a fixed point,
// while object and environment marks are still readable and before any object
// or environment memory is freed. A surviving entry needs live, marked records
// at both env and search_head, a marked bindings object, and that object to be
// the env's current bindings. Anything else is stale and is cleared so the
// cache cannot hold a scope chain, and so a later address reuse is never served
// from a dead entry.
fn void Heap.prune_var_ic_entries(&self) {
    for (uint fi = 0; fi < self.compiled_func_count; fi++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[fi];
        if (cf == null || cf.var_ic_entries == null || cf.var_ic_count == 0) { continue; }
        hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
        for (uint vi = 0; vi < cf.var_ic_count; vi++) {
            hobject::VarICEntry* vie = &vics[vi];
            if (vie.env == null && vie.bindings == null && vie.search_head == null) {
                continue;  // already empty
            }
            bool survive = false;
            // Verify the env records are live before reading vie.bindings or
            // the env's bindings pointer: a dead owner's cached object may
            // already be freed.
            if (hobject::env_record_is_allocated(vie.env)
                && hobject::env_record_get_epoch(vie.env) == self.env_mark_epoch
                && hobject::env_record_is_allocated(vie.search_head)
                && hobject::env_record_get_epoch(vie.search_head) == self.env_mark_epoch) {
                HObject* b = (HObject*)vie.bindings;
                if (b != null && ((HeapHeader*)b).is_reachable()
                    && hobject::env_record_bindings(vie.env) == b) {
                    survive = true;
                }
            }
            if (!survive) {
                hobject::var_ic_clear(vie);
            }
        }
    }
}

// Clear variable inline caches before eval introduces a new binding. A new
// property can shadow the cached owner while leaving the search-head pointer
// unchanged, so shape checks alone cannot reject the old resolution.
fn void Heap.invalidate_var_ic_entries(&self) {
    for (uint fi = 0; fi < self.compiled_func_count; fi++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[fi];
        if (cf == null || cf.var_ic_entries == null || cf.var_ic_count == 0) { continue; }
        hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
        for (uint vi = 0; vi < cf.var_ic_count; vi++) {
            hobject::VarICEntry* vie = &vics[vi];
            if (vie.env != null || vie.bindings != null || vie.search_head != null) {
                hobject::var_ic_clear(vie);
            }
        }
    }
}

// ============================================================================
// Heap verification, built only with `-D HEAP_VERIFY`
// ============================================================================

// Check that a HeapHeader is live and carries a valid htype. Objects and
// buffers are looked up by walking the sweep list, which is O(n). Strings,
// symbols included, are checked by htype alone, since not all of them are in
// str_table. Returns false and writes a diagnostic to stderr on failure.
fn bool Heap.validate_hobject(&self, HeapHeader* hdr, ZString where) {
$if $feat(HEAP_VERIFY):
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

    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* head = generation == 0 ? self.young_allocated : self.heap_allocated;
        for (HeapHeader* walk = head; walk != null; walk = walk.next) {
            if (walk == hdr) return true;
        }
    }

    io::eprintf("[HEAP_VERIFY]   ERROR at %s: pointer %p (htype=%d) not in the heap list\n",
                where, hdr, (int)ht);
    return false;
$else
    return true;
$endif
}

// Validate every heap pointer in a TVal array such as saved_regs, returning
// the number of errors found.
fn uint Heap.verify_tval_array(&self, TVal* arr, uint count, ZString context) {
$if $feat(HEAP_VERIFY):
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

// Check that every GC root set points at a live heap object, returning true
// when all of them do. Built only with `-D HEAP_VERIFY`.
fn bool Heap.verify_roots(&self, ZString context) {
$if $feat(HEAP_VERIFY):
    io::eprintf("[HEAP_VERIFY] %s: checking roots...\n", context);

    uint live_count = 0;
    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* head = generation == 0 ? self.young_allocated : self.heap_allocated;
        for (HeapHeader* h = head; h != null; h = h.next) {
            live_count++;
        }
    }
    io::eprintf("[HEAP_VERIFY]   live objects: %d\n", (int)live_count);

    uint checked = 0;
    uint errors = 0;

    for (uint i = 0; i < (uint)self.gc_roots.len(); i++) {
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
        HString* key = self.checkpoint_entries[i].key.borrow();
        if (key != null) {
            if (!self.validate_hobject((HeapHeader*)key, "checkpoint_key")) errors++;
            checked++;
        }
    }

    // Generator saved registers belong to live generator objects.
    uint gen_count = 0;
    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* gen_walk = generation == 0 ? self.young_allocated : self.heap_allocated;
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

// Report whether any live activation register still references `ptr`, naming
// the first frame and slot that does.
//
// Freeing a node a register still holds is a fault whichever path gets there:
// the sweep frees whatever the mark phase did not reach at any refcount, and
// decref frees whatever reaches zero. Either way the frame reads freed memory
// the moment it touches that slot again, and by then the opcode at fault is
// long gone -- so both callers report here, at the release, rather than
// leaving a use-after-poison for whatever opcode reads the slot next.
const uint NATIVE_FRAME_SCAN_SLOTS = 64;

fn bool Heap.is_in_activation_regs(&self, HeapHeader* ptr, uint* out_frame, uint* out_slot) {
$if $feat(HEAP_VERIFY):
    if (self.curr_thread == null) return false;
    vm::Vm* vm = (vm::Vm*)self.curr_thread;
    for (uint f = 0; f < vm.activation_count; f++) {
        vm::Activation* a = &vm.activations[f];
        if (a.bottom == null) continue;
        // A native/builtin frame has func == null and so no declared num_regs,
        // but it still owns valstack slots -- exactly the ones the mark phase
        // skips. Scan a conservative window for those, clamped to the allocated
        // valstack so the scan itself never reads past the end.
        uint nregs = NATIVE_FRAME_SCAN_SLOTS;
        if (a.func != null) { nregs = ((CompiledFunction*)a.func).num_regs; }
        if (vm.valstack_end > a.bottom) {
            usz avail = (usz)(vm.valstack_end - a.bottom);
            if ((usz)nregs > avail) { nregs = (uint)avail; }
        } else {
            continue;
        }
        for (uint i = 0; i < nregs; i++) {
            TVal* tv = &a.bottom[i];
            if (self.decref_exempt_lo != null
                && tv >= self.decref_exempt_lo && tv < self.decref_exempt_hi) continue;
            if (!tv.is_heap_allocated()) continue;
            if (tv.get_heapptr() == (void*)ptr) {
                if (out_frame != null) *out_frame = f;
                if (out_slot != null) *out_slot = i;
                return true;
            }
        }
    }
    return false;
$else
    return false;
$endif
}

// Report whether any suspended generator's saved_regs still references `ptr`,
// which would make freeing it leave a dangling pointer. The sweep calls this
// before freeing an object.
fn bool Heap.is_in_generator_saved_regs(&self, HeapHeader* ptr) {
$if $feat(HEAP_VERIFY):
    for (uint generation = 0; generation < 2; generation++) {
        HeapHeader* walk = generation == 0 ? self.young_allocated : self.heap_allocated;
        while (walk != null) {
            if (walk.is_object()) {
                HObject* obj = (HObject*)walk;
                // Dying generators may hold children collected in the same sweep.
                if (obj.flags.obj_class == ObjClass.GENERATOR
                    && (walk.is_reachable() || walk.is_temproot())) {
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
    }
    return false;
$else
    return false;
$endif
}

// ============================================================================
// GC sweep
// ============================================================================

// Explicit callers can finish a scheduled sweep at a quiescent boundary.
fn void Heap.finish_sweep(&self, bool strings_safe) {
    if (self.native_frame_depth != 0) return;
    while (self.gc_phase == GcPhase.SWEEP) self.gc_step(uint::max, true);
}

/**
 * Ask the next safepoint to collect.
 */
fn void Heap.request_gc(&self) @inline {
    if (self.gc_phase == GcPhase.IDLE) self.gc_requested = true;
    self.gc_pending = true;
}

/**
 * Free interned strings that only the string table still holds, replacing their
 * slots with tombstones, then shrink the table when sparse.
 *
 * The caller must guarantee that no native frame borrows a raw HString pointer.
 */
fn void Heap.sweep_strings(&self) {
    if (self.str_table_size == 0) { return; }
    // Scanning table slots is collection work and belongs in the next trigger.
    self.mark_work_last += (ulong)self.str_table_size;
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null || entry == STR_TABLE_TOMBSTONE) { continue; }
        if (entry.refcount == 1) {
            self.str_table_tombstone(i);
            if (self.str_table_used > 0) { self.str_table_used--; }
            self.free_string(entry);
        }
    }

    if (self.str_table_used < self.str_table_size / 4 && self.str_table_size > INITIAL_STR_TABLE_SIZE) {
        self.str_table_shrink();
    }
}

// The registry tracks allocations for teardown and temporary native borrows.
// Counted owners keep a string alive independently of object tracing.
fn void Heap.sweep_large_strings(&self) {
    self.mark_work_last += (ulong)self.large_string_count;
    uint kept = 0;
    for (uint i = 0; i < self.large_string_count; i++) {
        HString* s = self.large_strings[i];
        if (s.refcount != 0) {
            // Survivors compact downward.
            self.large_strings[kept] = s;
            kept++;
            s.registry_slot = kept;
        } else {
            self.free_string(s);
        }
    }
    self.large_string_count = kept;
}

// Blocking collection uses the scheduled collector with native pins when
// raw initialization locals can still be live. A nested request waits for
// the current scheduled cycle to reach a quiescent boundary.
fn void Heap.mark_and_sweep(&self, bool safepoint, bool force_major) {
    if (self.gc_in_step) { self.gc_pending = true; return; }
    long blocking_start = gcprofile::gcprof_now();
    if (self.gc_phase != GcPhase.IDLE) {
        if (self.native_frame_depth != 0) {
            self.gc_pending = true;
            return;
        }
        while (self.gc_phase != GcPhase.IDLE) self.gc_step(uint::max, true);
    }
    if (self.gc_running) return;
    bool keep_temproots = !safepoint || self.native_frame_depth != 0;
    self.gc_blocking = true;
    defer self.gc_blocking = false;
    self.gc_start_cycle(keep_temproots);
    if (keep_temproots) {
        for (uint generation = 0; generation < 2; generation++) {
            HeapHeader* head = generation == 0 ? self.young_allocated : self.heap_allocated;
            for (HeapHeader* cur = head; cur != null; cur = cur.next) {
                if (!cur.is_temproot()) continue;
                cur.set_reachable();
                if (cur.is_object()) self.gray_push((HObject*)cur);
            }
        }
        hobject::env_pool_seed_or_clear_pins(self, false);
    }
    while (self.gc_phase != GcPhase.IDLE) self.gc_step(uint::max, !keep_temproots);
    self.gc_quiescent_pending = keep_temproots;
    gcprofile::gcprof_phase(32, &blocking_start);
}

// Schedule rather than collect here: the native return value must first be
// anchored by the VM. Only the outermost return ends the temporary-root window.
fn void Heap.leave_native_frame(&self) @inline {
    self.native_frame_depth--;
    if (self.native_frame_depth == 0 && self.gc_quiescent_pending) {
        self.request_gc();
    }
}

/**
 * Collect outside a safepoint, keeping temproots so in-flight allocations
 * survive.
 */
fn void Heap.trigger_gc(&self) {
    self.mark_and_sweep(false, true);
}

/**
 * Collect at a VM safe point. With no native builtin frame active, every live
 * value is anchored in a register, an environment, or an object graph, so the
 * temproot flags can clear and the string tables can be swept.
 *
 * A safepoint reached inside a builtin's nested VM execution is not that quiet,
 * since the builtin's own locals may hold an unrooted object or interned string.
 * Marking can advance there; reclamation waits for a quiescent boundary.
 */
fn void Heap.safepoint_gc(&self, uint work_budget = GC_SLICE_WORK) {
    bool quiescent = self.native_frame_depth == 0;
    // A running cycle owes work in proportion to what the mutator allocated
    // since the last slice. Sweeping waits for a quiescent safepoint, and a
    // program that spends its time inside builtins and their callbacks reaches
    // few of them, so the debt carries over and the slice that can sweep pays
    // it in one go. The slice clock still bounds the pause.
    if (self.gc_phase != GcPhase.IDLE && (quiescent || self.gc_phase == GcPhase.MARK)) {
        ulong owed = (self.gc_alloc_since_begin - self.gc_alloc_paced) * GC_WORK_PER_ALLOC;
        self.gc_alloc_paced = self.gc_alloc_since_begin;
        if (owed > work_budget) work_budget = owed > GC_LOOP_WORK ? GC_LOOP_WORK : (uint)owed;
    }
    long slice_start = gcprofile::gcprof_now();
    self.gc_step(work_budget, quiescent);
    gcprofile::gcprof_phase(31, &slice_start);
}

// Call and return instructions preserve root publication. The pending check
// stays cheap while a collection is active; loop safepoints provide independent
// progress for code that makes few calls.
fn void Heap.safepoint_gc_on_call(&self) @inline {
    if (!self.gc_pending) return;
    $if $feat(GC_STRESS):
        self.safepoint_gc();
    $else
        if (--self.gc_call_budget == 0) {
            self.gc_call_budget = GC_CALL_INTERVAL;
            self.safepoint_gc();
        }
    $endif
}

// Whether a call or return must take the switch, which runs the safepoint. A
// pending collection only does work every GC_CALL_INTERVAL calls; the calls in
// between are counted down here, so the threaded handlers keep them. The last
// one is left for the switch to count to zero. `publishes` says the handler
// makes a heap value or a frame's roots visible to the collector, which a
// marking collection must see shaded, so it always takes the switch then.
fn bool Heap.gc_safepoint_due(&self, bool publishes) @inline {
    if (!self.gc_pending) return false;
    $if $feat(GC_STRESS):
        return true;
    $else
        if ((publishes && self.gc_phase == GcPhase.MARK) || self.gc_call_budget <= 1) return true;
        self.gc_call_budget--;
        return false;
    $endif
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
    // Keep HASH_DEFERRED reserved as the "not computed yet" sentinel.
    return h == hstring::HASH_DEFERRED ? h + 1 : h;
}

// The string's content hash, computing and caching it if it was deferred.
// Interned strings always have it already, so this is a plain field read on
// the hot path; only a large non-interned string ever pays the O(blen) scan,
// and only if something actually needs its hash.
fn uint Heap.content_hash(&self, hstring::HString* s) {
    if (s.hash == hstring::HASH_DEFERRED) {
        s.hash = self.hash_string(s.get_data());
    }
    return s.hash;
}

// ============================================================================
// String table (open-addressing, linear probing)
// ============================================================================

// Bytes for a string table of `size` slots: the pointer array, then the tag
// array that follows it in the same allocation.
fn usz str_table_bytes(uint size) @inline => (HString*::size + uint::size) * (usz)size;

// A slot's tag in the tag array: 0 for a slot never used, STR_TAG_TOMBSTONE for
// a deleted one, and otherwise the string's hash shifted up with the low bit set.
// Probing and rehashing read tags alone, so neither dereferences a string, and
// the hash's low bits, which choose the slot, are recoverable from the tag.
const uint STR_TAG_TOMBSTONE = 2;

fn uint str_tag(uint hash) @inline => (hash << 1) | 1;

fn uint* Heap.str_tags(&self) @inline => (uint*)(self.str_table + self.str_table_size);

fn void Heap.str_table_store(&self, uint idx, HString* hstr) @inline {
    self.str_table[idx] = hstr;
    self.str_tags()[idx] = str_tag(hstr.hash);
}

fn void Heap.str_table_tombstone(&self, uint idx) @inline {
    self.str_table[idx] = STR_TABLE_TOMBSTONE;
    self.str_tags()[idx] = STR_TAG_TOMBSTONE;
}

/**
 * Rebuild the string table with `new_size` slots (a power of two), moving every
 * live entry and dropping tombstones. Entries are placed from their tags, so no
 * string is touched. The old table is kept when the allocation fails.
 */
fn bool Heap.str_table_resize(&self, uint new_size) {
    long maintenance_start = gcprofile::gcprof_now();
    defer gcprofile::gcprof_phase(34, &maintenance_start);
    usz new_bytes = str_table_bytes(new_size);
    void* raw = self.alloc_func(self.heap_udata, new_bytes);
    if (raw == null) return false;
    mem::clear(raw, (sz)new_bytes);

    HString** old_table = self.str_table;
    uint* old_tags = self.str_tags();
    uint old_size = self.str_table_size;
    HString** new_table = (HString**)raw;
    uint* new_tags = (uint*)(new_table + new_size);
    for (uint i = 0; i < old_size; i++) {
        uint tag = old_tags[i];
        if ((tag & 1) == 0) continue;
        uint idx = (tag >> 1) & (new_size - 1);
        while (new_tags[idx] != 0) idx = (idx + 1) & (new_size - 1);
        new_table[idx] = old_table[i];
        new_tags[idx] = tag;
    }
    self.free_func(self.heap_udata, old_table);
    self.str_table = new_table;
    self.str_table_size = new_size;
    return true;
}

/**
 * Double the string table once the load factor is exceeded.
 */
fn bool Heap.str_table_grow(&self) {
    return self.str_table_resize(max(self.str_table_size * 2, INITIAL_STR_TABLE_SIZE));
}

/**
 * Shrink the string table by half.
 */
fn void Heap.str_table_shrink(&self) {
    self.str_table_resize(max(self.str_table_size / 2, INITIAL_STR_TABLE_SIZE));
}

/**
 * Look up an interned string by byte content and precomputed hash, returning
 * null when the table does not hold it.
 */
fn HString* Heap.str_table_lookup(&self, char[] data, uint hash) {
    long lookup_start = gcprofile::gcprof_now();
    defer gcprofile::gcprof_phase(35, &lookup_start);
    if (self.str_table_size == 0) return null;
    uint mask = self.str_table_size - 1;
    uint* tags = self.str_tags();
    uint tag = str_tag(hash);
    uint idx = hash & mask;
    for (uint probes = 0; probes <= mask; probes++) {
        uint slot = tags[idx];
        if (slot == 0) return null;  // an empty slot ends the probe chain; a tombstone does not
        if (slot == tag) {
            HString* entry = self.str_table[idx];
            if (entry.blen == (uint)data.len && entry.equals(data)) return entry;
        }
        idx = (idx + 1) & mask;
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
    // A failed grow only costs longer probe chains, so the insert continues
    // into the existing table.
    if ((ulong)(self.str_table_used + 1) * 10 > (ulong)self.str_table_size * STR_TABLE_MAX_LOAD_TENTHS) {
        self.str_table_grow();
    }

    uint mask = self.str_table_size - 1;
    uint* tags = self.str_tags();
    uint idx = hstr.hash & mask;
    uint first_tombstone = self.str_table_size;  // out-of-range means none seen yet
    for (uint probes = 0; probes <= mask; probes++) {
        uint slot = tags[idx];
        if (slot == 0) {
            // Reusing an earlier tombstone keeps probe chains short.
            self.str_table_store(first_tombstone <= mask ? first_tombstone : idx, hstr);
            self.str_table_used++;
            self.str_table_adopt(hstr);
            return true;
        }
        if (slot == STR_TAG_TOMBSTONE && first_tombstone > mask) first_tombstone = idx;
        idx = (idx + 1) & mask;
    }
    // Table is full but we found a tombstone: reuse it.
    if (first_tombstone <= mask) {
        self.str_table_store(first_tombstone, hstr);
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
fn void Heap.str_table_adopt(&self, HString* hstr) {
    hstr.flags.is_interned = true;
    ((HeapHeader*)hstr).incref();
}

/**
 * Remove an interned string from the table by pointer identity.
 * Sets the slot to a tombstone so probe chains remain intact.
 */
fn void Heap.str_table_remove(&self, hstring::HString* hstr) {
    if (self.str_table_size == 0) { return; }
    uint mask = self.str_table_size - 1;
    uint* tags = self.str_tags();
    uint idx = hstr.hash & mask;
    for (uint probes = 0; probes <= mask; probes++) {
        if (tags[idx] == 0) return;
        if (self.str_table[idx] == hstr) {
            self.str_table_tombstone(idx);
            if (self.str_table_used > 0) { self.str_table_used--; }
            return;
        }
        idx = (idx + 1) & mask;
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
    self.large_strings[self.large_string_count] = s;
    self.large_string_count++;
    s.registry_slot = self.large_string_count;
}

/**
 * Remove a non-interned string by swapping the final registry entry into its slot.
 */
fn void Heap.large_string_unregister(&self, HString* s) {
    if (s.registry_slot == 0) return;
    uint slot = s.registry_slot - 1;
    self.large_string_count--;
    HString* moved = self.large_strings[self.large_string_count];
    self.large_strings[slot] = moved;
    moved.registry_slot = slot + 1;
    s.registry_slot = 0;
}

// Concatenation results defer hashing and interning until a consumer needs
// them. Accumulators reserve spare capacity for subsequent in-place appends.
// Returns null if allocation fails.
fn HString* Heap.alloc_concat_string(&self, char[] data, uint cap) {
    HString*? new_s = hstring::hstring_alloc_cap(self, data, hstring::HASH_DEFERRED, cap);
    if (try s = new_s) {
        // Same registry contract as any other large non-interned string: the
        // registry is how mark-sweep and heap reset reach a string the table
        // does not hold.
        self.large_string_register(s);
        return s;
    }
    return null;
}

// Allocate a non-interned concatenation directly from its two source spans.
// The registry keeps the result reachable by mark-sweep until a VM register
// or the string table owns it.
fn HString* Heap.alloc_concat_string_parts(&self, char[] left, char[] right,
                                          uint cap) {
    HString*? new_s = hstring::hstring_alloc_concat_cap(
        self, left, right, hstring::HASH_DEFERRED, cap);
    if (try s = new_s) {
        self.large_string_register(s);
        return s;
    }
    return null;
}

fn HString* Heap.alloc_concat_join(&self, TVal[] parts, uint length) {
    if (try s = hstring::hstring_alloc_join(self, parts, length)) {
        self.large_string_register(s);
        return s;
    }
    return null;
}

// Intern an HString on demand. An already-interned string comes back
// unchanged; otherwise a lookup by content may find an existing copy, and
// failing that this string is inserted. Property lookup calls this when a
// non-interned concatenation result is used as a key.
fn HString* Heap.ensure_interned(&self, hstring::HString* s) {
    if (s.flags.is_interned) return s;
    // A large concat result reaches here with its hash still deferred, and the
    // table both probes and stores by hash, so materialize it first.
    HString* existing = self.str_table_lookup(s.get_data(), self.content_hash(s));
    if (existing != null) return existing;
    // The table owns the string from here on, so it must leave the registry or
    // the sweep would free it behind the table's back. If the table cannot take
    // it, the registry takes it back so it still has an owner.
    self.large_string_unregister(s);
    if (!self.str_table_insert(s)) { self.large_string_register(s); }
    return s;
}

// Record that a lightfunc's virtual property was deleted. The bit index is
// fn_idx * 3 + prop_bit, with prop_bit 0 for name, 1 for length, 2 for prototype.
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

// Map a lightfunc virtual property name to its prop_bit, or -1 for any other key.
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

// Intern bytes that are already CESU-8 canonical. Callers whose input has no
// raw 4-byte UTF-8 sequences, such as pure-ASCII builtin literals or data
// already put through `normalize_to_cesu8`, can skip the astral scan by
// calling this directly.
fn HString* Heap.str_intern_normalized(&self, char[] data) {
    // Strings this long are not used as property keys, symbols, or identifiers.
    // Interning them piles dead strings into the table until the next GC, giving
    // O(n^2) memory growth in string-building loops such as buildString in the
    // test262 regExpUtils harness. A non-interned string is refcounted and so
    // freed promptly.
    //
    // The length test comes before the hash on purpose: hashing is O(len), so
    // hashing first would make every `s += chunk` rehash the whole accumulated
    // string and turn the loop O(n^2) in time even though it is already O(n) in
    // memory. These strings get `HASH_DEFERRED` and hash lazily via
    // `content_hash` if anything ever needs it.
    if (data.len > MAX_INTERN_BYTES) {
        HString*? new_s = hstring::hstring_alloc(self, data, hstring::HASH_DEFERRED);
        if (try s = new_s) {
            // The registry is what the mark-sweep backstop and heap reset use to
            // reach a string the table does not hold.
            self.large_string_register(s);
            return s;
        }
        return null;
    }
    bool cache_ascii_char = false;
    uint ascii_char_index = 0;
    if (data.len == 1) {
        ascii_char_index = (uint)data[0];
        cache_ascii_char = ascii_char_index < ASCII_CHAR_CACHE_SIZE;
        if (cache_ascii_char) {
            HString* cached = self.ascii_char_strs[ascii_char_index];
            if (cached != null) return cached;
        }
    }
    uint hash = self.hash_string(data);
    HString* existing = self.str_table_lookup(data, hash);
    if (existing != null) {
        if (cache_ascii_char) {
            ((HeapHeader*)existing).set_pinned();
            self.ascii_char_strs[ascii_char_index] = existing;
        }
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(self, data, hash);
    if (try s = new_s) {
        // str_table_insert takes the table's owning reference, increfing and
        // marking the string interned. If it cannot, the registry keeps the
        // string reachable for reset and destroy.
        if (!self.str_table_insert(s)) { self.large_string_register(s); }
        if (cache_ascii_char) {
            ((HeapHeader*)s).set_pinned();
            self.ascii_char_strs[ascii_char_index] = s;
        }
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

// Enqueue a promise reaction job as a (handler, argument, downstream) triple.
// The queue drains after each top-level script and after vm_call_fn_impl
// returns from a compiled function.
fn void Heap.enqueue_microtask(&self, TVal handler, TVal arg, TVal downstream) {
    // Make room for the new entry; each takes 3 TVal slots. A queue whose first
    // half is already drained slides down instead of growing, so a drain that
    // keeps enqueuing its own successor runs in constant space.
    if (self.microtask_count + 1 > self.microtask_capacity && self.microtask_head >= self.microtask_capacity / 2) {
        uint pending = self.microtask_count - self.microtask_head;
        mem::move(self.microtask_queue, self.microtask_queue + self.microtask_head * 3, (sz)((usz)pending * TVal::size * 3));
        mem::clear(self.microtask_queue + pending * 3, (sz)((usz)self.microtask_head * TVal::size * 3));
        self.microtask_head = 0;
        self.microtask_count = pending;
        // The root scan walks the queue by index, so a slide can carry a job
        // below the cursor before it was marked.
        for (uint i = 0; i < pending * 3; i++) self.shade_root_tval(self.microtask_queue[i]);
    }
    if (self.microtask_count + 1 > self.microtask_capacity) {
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

// Release the three references that queue slot `job` owns.
fn void Heap.release_microtask_slot(&self, uint job) {
    for (uint i = job * 3; i < job * 3 + 3; i++) {
        self.decref_tval(&self.microtask_queue[i]);
        self.microtask_queue[i].set_undefined();
    }
}

// Run every queued job, including jobs enqueued while draining, such as when a
// handler resolves another promise. A re-entrancy guard keeps a nested call
// from starting a second drain.
// `report` is false for the drains that Promise combinators run in the middle
// of their own builtin, before they have returned the promise to the caller.
// Running the jobs there is fine; REPORTING there is not -- a rejection is only
// unhandled once the turn ends, and at that point user code has not had the
// chance to attach a handler yet, so `Promise.all.call(P, [])` where P's
// resolve throws would report a rejection the very next statement handles.
fn void Heap.drain_microtasks(&self, void* vm, bool report = true) {
    if (self.microtask_draining) { return; }
    // An empty queue still has to fall through to the report: a top-level
    // `Promise.reject(x)` with no `.then` anywhere queues no job at all, and
    // is precisely the rejection most in need of reporting.
    if (self.microtask_count == 0) {
        if (report) self.report_unhandled_rejections(vm);
        return;
    }
    self.microtask_draining = true;
    defer self.microtask_draining = false;

    // Jobs that a handler enqueues append past the tail and run in this same
    // drain, which is the ordering the spec requires. The job in flight stays
    // at microtask_head, counted and visible to the GC, until it completes; an
    // enqueue may slide the queue down meanwhile, so the head is re-read
    // rather than held across the handler call.
    {
        bool interrupted = false;
        while (self.microtask_head < self.microtask_count) {
            if (self.gc_pending) { self.safepoint_gc(); }
            TVal handler    = self.microtask_queue[self.microtask_head * 3];
            TVal arg        = self.microtask_queue[self.microtask_head * 3 + 1];
            TVal downstream = self.microtask_queue[self.microtask_head * 3 + 2];

            TVal result;
            if (self.call_handler_fn != null && vm != null) {
                result = self.call_handler_fn(vm, handler, &arg);
            } else {
                result = arg;
            }

            ValueRoot result_root;
            self.push_value_root(&result_root, result);

            // An interrupt raised inside this job aborts the drain. The job's
            // unwind already recorded the error on has_error and left
            // uncatchable_throw set for the host boundary; settle no promise
            // with it, and drop the jobs still queued so a later drain cannot
            // resume half-dead promise state.
            if (self.uncatchable_throw) {
                interrupted = true;
            } else if (downstream.is_object() && downstream.get_heapptr() != null &&
                       self.microtask_after_fn != null && vm != null) {
                self.microtask_after_fn((void*)self, vm, result, downstream);
            }
            self.pop_value_root(&result_root);

            // The queue owns one reference to each value until the job has
            // completed. Release those references before advancing.
            self.release_microtask_slot(self.microtask_head++);

            if (interrupted) {
                // Drop the remainder of the queue.
                while (self.microtask_head < self.microtask_count) {
                    self.release_microtask_slot(self.microtask_head++);
                }
            }
        }
        self.microtask_head = 0;
        self.microtask_count = 0;
    }

    if (report) self.report_unhandled_rejections(vm);
}

// ============================================================================
// Unhandled rejection tracking
// ============================================================================

// Install the host's unhandled-rejection callback. Passing null disables
// reporting, which is the default: the engine keeps recording rejections
// either way, so a tracker installed mid-run still sees later ones.
fn void Heap.set_rejection_tracker(&self, RejectionTrackerFn fnp, void* udata) {
    self.rejection_tracker_fn = fnp;
    self.rejection_tracker_udata = udata;
}

// Record a promise that was rejected with nothing watching it.
//
// Called from promise_settle on every rejection. The verdict is provisional:
// `p.catch(...)` later in the same tick sets is_handled, and
// report_unhandled_rejections skips the entry. That is the whole reason the
// list exists rather than reporting at rejection time.
fn void Heap.track_rejection(&self, hobject::HObject* promise) {
    if (promise == null) return;
    if ((*promise.extra_ptr()).promise.in_reject_list) return;

    uint needed = self.unhandled_count + 1;
    if (needed > self.unhandled_capacity) {
        uint new_cap = self.unhandled_capacity == 0 ? 8 : self.unhandled_capacity * 2;
        usz new_bytes = (usz)new_cap * TVal::size;
        TVal* grown = (TVal*)self.realloc_func(self.heap_udata, self.unhandled_rejections, new_bytes);
        if (grown == null) return;
        mem::clear(grown + self.unhandled_capacity,
            (sz)((long)(new_cap - self.unhandled_capacity) * TVal::size));
        self.unhandled_rejections = grown;
        self.unhandled_capacity = new_cap;
    }

    TVal pv;
    pv.set_object(promise);
    self.tval_copy_ref(&self.unhandled_rejections[self.unhandled_count], &pv);
    self.unhandled_count++;
    (*promise.extra_ptr()).promise.in_reject_list = true;
}

// Deliver the rejections that are still unhandled now that the queue is
// empty, then clear the list.
//
// The list is drained into locals before any callback runs, because a tracker
// is host code that may evaluate script and reject further promises; those
// belong to the next drain, not this one.
fn void Heap.report_unhandled_rejections(&self, void* vm) {
    if (self.unhandled_count == 0 || self.reporting_rejections) return;
    self.reporting_rejections = true;
    defer self.reporting_rejections = false;

    uint n = self.unhandled_count;

    for (uint i = 0; i < n; i++) {
        TVal pv = self.unhandled_rejections[i];
        if (pv.is_object() && pv.get_heapptr() != null) {
            hobject::HObject* p = (hobject::HObject*)pv.get_heapptr();
            (*p.extra_ptr()).promise.in_reject_list = false;
            bool still_unhandled =
                !(*p.extra_ptr()).promise.is_handled &&
                (*p.extra_ptr()).promise.state == hobject::PROMISE_REJECTED;
            if (still_unhandled && self.rejection_tracker_fn != null) {
                // Marked handled before the callback so that a tracker which
                // itself attaches a handler, or which re-enters the engine and
                // re-rejects, cannot make the same promise report twice.
                (*p.extra_ptr()).promise.is_handled = true;
                TVal reason = (*p.extra_ptr()).promise.result;
                self.rejection_tracker_fn((void*)self, vm, pv, reason, self.rejection_tracker_udata);
            }
        }
        self.decref_tval(&self.unhandled_rejections[i]);
        self.unhandled_rejections[i].set_undefined();
    }
    // Reentrant callbacks append after the batch. Transfer those owned slots
    // down only after all callbacks finish, while the full array remains a root.
    uint remaining = self.unhandled_count - n;
    for (uint i = 0; i < remaining; i++) {
        self.unhandled_rejections[i] = self.unhandled_rejections[n + i];
        self.unhandled_rejections[n + i].set_undefined();
    }
    self.unhandled_count = remaining;
}
