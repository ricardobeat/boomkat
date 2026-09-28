module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::re_bindings;
import std::io;
import std::math;

// The bytecode virtual machine: a register-based interpreter.
//
// Execution runs over a value stack of activation records. A CALL takes the
// argument count in A and a base register in BC, with the callee at `base`,
// `this` at `base+1`, and the arguments from `base+2`. The inner dispatch loop
// restarts on a JS-to-JS call rather than recursing.
module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::re_bindings;
import std::io;
import std::math;

// ============================================================================
// Fault codes
// ============================================================================

faultdef VM_ERROR;
faultdef STACK_OVERFLOW;

// ============================================================================
// Constants
// ============================================================================

// Total live JavaScript frames, including native reentry. The heap-owned
// storage keeps activation addresses stable across callbacks and stack growth.
const uint MAX_CALLS        = 4096;
const uint INITIAL_VALSTACK = 1024;

// Cap on nested Vm.run invocations, counted by Vm.run_depth.
//
// Native callbacks consume C stack independently of their JavaScript frame
// count. Keep a separate bound for hosts with small native stacks.
const uint MAX_RUN_DEPTH    = 128;

// ============================================================================
// Shadow roots publish the caller segment while a nested Vm.run executes.
// Activations stay in the VM storage; this descriptor lives on the C stack.
// ============================================================================

struct ShadowActFrame {
    // Previous frame in the linked list (null = end of list).
    void* prev;
    // The suspended caller segment in activation_storage.
    Activation* acts;
    // Number of activations saved in acts[0..count-1].
    uint count;
}

// One arrow awaiting its derived constructor's super() call; see
// Vm.pending_this_arrows. `act` identifies the constructor frame whose
// this_binding the arrow is waiting on, and `fn_obj` is the arrow closure
// whose captured_this must be overwritten once that binding exists.
struct PendingThisArrow {
    // Next entry in the linked list (null = end of list).
    void* next;
    // The derived-constructor activation this arrow was created in. Compared
    // by identity when super() flushes the list; never dereferenced after the
    // frame is popped.
    Activation* act;
    // The arrow closure whose captured_this is the TDZ sentinel. Marked by the
    // GC through this list so a registered arrow cannot be collected while the
    // entry names it.
    HObject* fn_obj;
}

// ============================================================================
// Activation record: one call frame
// ============================================================================

struct Activation {
    // The function being executed, borrowed.
    void* func;
    // The calling activation, null at the outermost frame.
    Activation* parent;
    // Current variable environment
    EnvRecord* var_env;
    // Current lexical environment
    EnvRecord* lex_env;
    // Current catcher chain (null if none)
    void* cat;
    // Live for-in enumeration states created by this frame (null if none).
    //
    // Every INITFOR pushes here and the frame owns them until it is popped,
    // so no abrupt exit out of a for-in body can strand a state. Head of a
    // heap::ForInState chain; typed as void* to match `cat`.
    //
    // Because vm.activations[] is a pool reused WITHOUT zeroing, every push
    // must clear this: a stale chain inherited from a returned frame at the
    // same depth would be double-freed on the next pop. Cleared by
    // activation_begin(); do not assign the field ad hoc.
    void* forin;

    // Next instruction to execute, a stable pointer into the bytecode.
    // Null for native calls.
    Instruction* curr_pc;
    // This activation's bottom in the valstack, used to reset valstack_bottom
    // on return.
    TVal* bottom;
    // Where in the valstack the return value goes. Only set on non-topmost
    // activations.
    TVal* retval;
    // Flags: strict, tailcalled, construct, etc.
    uint flags;
    // One past the highest register index that ever held a heap reference, so
    // 0 means "none" and register 0 is expressible as 1. A plain highest-index
    // would make the empty case and register 0 the same value, and
    // decref_callee_regs' early-out would then skip a frame whose only heap
    // value sits in register 0.
    uint heap_reg_count;
    // This activation's `this` binding.
    TVal this_binding;
    // The `new.target` value: the constructor a `new` expression named, or the
    // arrow's captured one. Null outside a construct call.
    HObject* new_target;
    // The Promise an async function or module settles on return.
    //
    // This is a borrow rather than a hold, even though it holds the promise's
    // birth reference in practice: no push site increfs into this slot and no
    // pop site decrefs out of it. What keeps the promise alive across an AWAIT
    // suspension is the caller's result register, which vm_calls.c3 fills with
    // an owning set_object, together with the reaction closures on the
    // microtask queue. Do not add a release on pop: the RET paths in
    // vm_execute.c3 already account for exactly three references, meaning
    // birth, the result register, and the returned value.
    //
    // vm.activations[] is a pool reused without zeroing, so every push must
    // write this field. Every functional read is gated on ACT_FLAG_ASYNC, but
    // mark_activation_fields() is not: it marks the raw pointer on every GC for
    // every activation below activation_count. A stale value inherited from a
    // settled async frame at the same depth is a freed HObject*, and marking it
    // writes set_reachable() into freed memory and then walks its recycled
    // prototype and property words, ending in a "pointer being freed was not
    // allocated" abort inside sweep(). Push through activation_begin() rather
    // than assigning the field directly.
    HObject* async_promise;
    // The GeneratorState this activation is running, for a generator or async
    // body resume, and null on ordinary frames. It lets exception unwinding move
    // the generator to GEN_COMPLETED when an uncaught throw pops past its body
    // (ES6 §25.3.3.2).
    //
    // This is a borrow and takes no gs_acquire, which is safe only because the
    // frame is popped before the generator's own holders release the state.
    //
    // vm.activations[] is a pool reused without zeroing, so every push must
    // write this field. A stale non-null value makes YIELD's
    // `walk.async_gen_state == gs` parent search match the wrong activation,
    // and vm_complete_gen_on_unwind writes GEN_COMPLETED through it on a
    // non-null check alone. Push through activation_begin() rather than
    // setting the field directly.
    void* async_gen_state;
    // The callee as a TVal: undefined for a script or module body. It is a
    // plain copy of the caller's callee register unless ACT_FLAG_CALLEE_OWNED
    // says the frame holds its own reference. Every push writes it, because a
    // borrowed call compares it with its own callee to detect a self-call.
    TVal tv_func;
    // The caller's valstack_top at CALL time, restored on RET without recomputing.
    TVal* caller_valstack_top;
}

const uint ACT_FLAG_CONSTRUCT      = 1u << 1;
const uint ACT_FLAG_PREVENT_YIELD  = 1u << 2;
const uint ACT_FLAG_DIRECT_EVAL    = 1u << 3;
const uint ACT_FLAG_ASYNC          = 1u << 4;
// Set when this_binding was incref'd via tval_copy_ref and must be
// decref'd when the activation is popped in handle_return.
const uint ACT_FLAG_THIS_OWNED     = 1u << 5;
// A derived class constructor, which `extends` creates and `super()` must
// initialize. handle_return enforces §9.2.2 step 13.c on it: returning anything
// but an object or undefined throws a TypeError.
const uint ACT_FLAG_DERIVED        = 1u << 6;
// The activation came from SUPER_CALL, so on return its constructed object
// initializes the pending derived-constructor this_binding up the chain.
const uint ACT_FLAG_SUPER_CTOR     = 1u << 7;
// The callee was borrowed from a permanent binding: copied into the caller's
// callee register, which for CALL_VAR is also the retval slot, with no incref
// and no track_heap_store. The return value overwrites that same slot, so the
// write-back must not decref what it finds there. See resolve_call_var.
// The binding can be reassigned while the call runs, so such a frame also
// carries ACT_FLAG_CALLEE_OWNED, which roots tv_func for the marker and keeps
// the borrowed slot's function alive. A function calling itself skips the
// flag: its caller's frame runs the same closure and keeps it alive.
const uint ACT_FLAG_BORROWED_CALLEE = 1u << 8;
// The activation's this_binding holds a live value that the frame BORROWED
// rather than incref'd: the caller keeps the owning reference for the whole
// duration of the call, so nothing here may be decref'd on pop. It exists
// purely to tell the GC that the slot is a real value and not the stale bits
// a reused activation slot would otherwise carry, since activation_begin does
// not clear this_binding and call_fn deliberately reuses activations[0]
// without zeroing it. Refcount liveness is not reachability: a mark-and-sweep
// safepoint that never marks a borrowed receiver will free it even at a
// nonzero refcount, so the two must be flagged independently of
// ACT_FLAG_THIS_OWNED, whose only job is to schedule the matching decref.
const uint ACT_FLAG_THIS_VALID     = 1u << 9;
// SUPER_CALL dispatched this super-constructor from an ARROW whose captured
// `this` was already a real object, i.e. a repeat super() reached through an
// arrow that outlived its derived constructor. The derived frame is long gone,
// so the RET-side live-frame walk cannot see that `this` was already bound;
// the verdict has to be taken before dispatch (the arrow's own frame is
// overwritten by the first call's flush) and carried here. §8.1.1.3.1
// BindThisValue step 3 then throws once the superclass constructor has run.
const uint ACT_FLAG_SUPER_REBIND   = 1u << 10;
// tv_func holds a reference the frame took, released when the frame pops. A
// frame needs one whenever nothing older keeps its function alive: the callee
// register was borrowed (ACT_FLAG_BORROWED_CALLEE) from a binding the call can
// reassign, or a tail call slid the frame down over the register that held it.
const uint ACT_FLAG_CALLEE_OWNED   = 1u << 11;

// The flags a frame may carry and still return through RET's and RETUNDEF's
// fast paths. Each of the others asks the pop for work only the general path
// does.
const uint RET_FAST_FLAGS = ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED
    | ACT_FLAG_THIS_OWNED | ACT_FLAG_THIS_VALID;

// Write this_binding as a BORROWED value: the caller holds the owning
// reference for the whole call, so nothing is incref'd here and nothing is
// decref'd on pop.
//
// Both setters exist so that publishing the slot to the GC is part of writing
// it rather than a second step a call site has to remember. A raw
// `act.this_binding = v` keeps the refcount right and still leaves the slot
// invisible to the mark phase, which is not a mistake the reader of one call
// site can see -- it looks correct, and only a collection at the wrong moment
// reveals otherwise. Assigning the field directly is therefore reserved for
// the two places that genuinely must (restoring a generator's saved receiver,
// and clearing the slot); everywhere else goes through these.
macro void Activation.set_this_borrowed(&self, void* heap, TVal val) {
    ((heap::Heap*)heap).shade_root_tval(val);
    self.this_binding = val;
    self.flags |= ACT_FLAG_THIS_VALID;
}

// Write this_binding as an OWNED value: the reference is taken here and
// released when the activation is popped. `heap` is the heap whose
// tval_copy_ref performs the incref.
macro void Activation.set_this_owned(&self, void* heap, TVal val) {
    TVal tmp = val;
    ((heap::Heap*)heap).tval_copy_ref(&self.this_binding, &tmp);
    self.flags |= ACT_FLAG_THIS_OWNED | ACT_FLAG_THIS_VALID;
}

// Release an owned this_binding as the frame pops, and clear the slot.
// Activation slots are pooled by depth index and reused without zeroing, and
// the next owned write (tval_copy_ref) decrefs whatever it finds there, so
// stale bits would release the same reference a second time, or read freed
// memory if the object has since been swept. Callers run this after the
// result is written, since a construct return may still read this_binding.
macro void Activation.release_this(&self, void* heap) {
    if ((self.flags & ACT_FLAG_THIS_OWNED) != 0) {
        ((heap::Heap*)heap).decref_tval(&self.this_binding);
        self.this_binding.set_undefined();
    }
}

// Drop an owned callee as the frame pops, so the marker stops tracing tv_func.
// Functions are not reference-counted, so there is no count to release.
macro void Activation.release_callee(&self, void* heap) {
    if ((self.flags & ACT_FLAG_CALLEE_OWNED) != 0) {
        self.flags &= ~ACT_FLAG_CALLEE_OWNED;
    }
}

// Release every reference the frame owns as it pops, after its result is
// written. The outermost frame of a Vm.run is the exception: its re-entrant
// caller reads this_binding after the run returns, so it releases only the
// callee.
macro void Activation.release_refs(&self, void* heap) {
    self.release_this(heap);
    self.release_callee(heap);
}

// ============================================================================
// Catcher, one entry in the exception handler chain
// ============================================================================

// Flags for catcher struct.
const uint CATCHER_FLAG_CATCH_ENABLED    = 1u << 0;
const uint CATCHER_FLAG_FINALLY_ENABLED  = 1u << 1;
const uint CATCHER_FLAG_PENDING_RETURN   = 1u << 2;
const uint CATCHER_FLAG_PENDING_BREAK    = 1u << 3;
const uint CATCHER_FLAG_PENDING_CONTINUE = 1u << 4;
const uint CATCHER_FLAG_IN_FINALLY       = 1u << 5;
// Set alongside PENDING_RETURN when the return originates from a generator
// return (RET_GEN/RETUNDEF_GEN, or a .return()/.throw() completion injected
// via LOAD_RESUME), which tells ENDFINALLY to complete through the generator-aware
// path (wrap in IteratorResult, mark GEN_COMPLETED) instead of a plain RET.
const uint CATCHER_FLAG_PENDING_RETURN_GEN = 1u << 6;

// One handler pushed by TRY, on the singly-linked chain rooted at
// Activation.cat.
struct Catcher {
    // Previous (parent) catcher in the chain, or null if none.
    Catcher* parent;
    // Flags: CATCHER_FLAG_*
    uint flags;
    // The thrown exception value (set by THROW, read by CATCH).
    TVal thrown_val;
    // Absolute PC of the catch handler (CATCH instruction).
    Instruction* catch_pc;
    // Absolute PC of the finally handler (FINALLY instruction), or null if none.
    Instruction* finally_pc;
    // PC of the ENDFINALLY closing this finally block, which the FINALLY opcode
    // computes on first use. A `return` inside the finally body jumps here to
    // skip the rest of the body and run the completion, the same override that
    // break, continue, and throw already get.
    Instruction* endfinally_pc;
    // Saved return value for return-through-finally (set by RET).
    TVal return_val;
    // Saved PC target for break/continue-through-finally.
    Instruction* pending_pc;
    // The lexical environment at TRY entry. An exceptional exit skips the try
    // block's POP_LEX instructions, so CATCH and FINALLY restore this to keep
    // the chain balanced and give the catch scope a clean base.
    void* saved_lex_env;
}

// ============================================================================
// Vm, the interpreter's own state
// ============================================================================

struct Vm {
    Heap* heap;

    // Incremental root cursor state. Structural frame and chain changes restart
    // the scan before a pointer kept here can refer to a released node.
    uint gc_root_act_index;
    uint gc_root_substage;
    uint gc_root_reg_index;
    void* gc_root_chain;
    void* gc_root_shadow;
    void* gc_root_pending;

    // Value stack
    TVal* valstack;        /// Base pointer of value stack
    uint valstack_size;    /// Allocated size in slots
    TVal* valstack_top;   /// Current top (one-past-last used slot)
    TVal* valstack_end;   /// End of allocated space
    TVal* valstack_bottom; /// Pointer to current activation's bottom

    // Native reentry advances activations past the suspended caller segment.
    // activation_capacity bounds every push against the shared storage end.
    Activation[MAX_CALLS] activation_storage;
    Activation* activations;
    uint activation_capacity;
    uint activation_count;

    // Current execution state (stable pointers reloaded on restart)
    CompiledFunction* current_func;
    Instruction* curr_pc; /// Current PC, kept in sync with the dispatch loop's local

    // Global environment
    EnvRecord* global_env;

    // Global lexical environment, the Global Environment Record's
    // DeclarativeRecord (ES2015 §8.1.1.4). Holds top-level `let`/`const`/
    // `class` bindings, which are NOT properties of the global object.
    // Declarative, parented to `global_env` (the ObjectRecord), and persists
    // across `$262.evalScript` calls so cross-script redeclarations collide.
    EnvRecord* global_lex_env;

    // Return value (for outer executor return)
    TVal return_val;

    // Debug tracing, costing one predicted-not-taken branch when false
    bool trace;

    // Shadow activation frames, linked and unlinked by vm_call_fn_impl around a
    // nested Vm.run() so the GC can mark the saved outer activations.
    void* shadow_act_list;  // ShadowActFrame*

    // Arrows created in a derived constructor BEFORE super() ran, which
    // therefore captured the TDZ sentinel as their `this`.
    //
    // An arrow captures `this` by value at closure-creation time, which is
    // right for an initialized binding but not for one super() has yet to
    // fill: the arrow must observe that later initialization. While the
    // constructor frame is live, super_walk_live_this() re-resolves through
    // it, but an arrow that ESCAPES the constructor outlives that frame and
    // has nothing left to walk. So each such arrow registers here at creation,
    // and super_init_this_chain() writes the constructed object into every
    // entry belonging to the frame it initializes, then unlinks them.
    //
    // Entries are owned by the VM and freed when flushed or when the
    // constructor frame is popped without a super() call (an abrupt exit), so
    // the list cannot outlive the frames it names.
    void* pending_this_arrows;  // PendingThisArrow*

    // Error state
    bool has_error;

    // Pending throw from ToPrimitive/ToNumber (set by to_primitive_value,
    // checked by opcode handlers that call vm_to_number)
    TVal throw_value;
    bool throw_pending;

    // Number of Vm.run invocations currently on the C stack. Nonzero means
    // the VM is mid-dispatch, so any module evaluation must go through the
    // re-entrant path (execute_module_nested) instead of taking over
    // activations[0]/valstack[0].
    uint run_depth;
}

// ============================================================================
// Per-frame dispatch state, bundled so sub-dispatch functions can be
// extracted into separate files without threading 12 parameters.
// ============================================================================

// The cold half of the frame state, kept as the leading sub-struct of
// Dispatch so the threaded handlers can take `&ds.cold` once per frame
// instead of rebuilding an argument bundle per instruction. `inline` keeps
// the three fields addressable as ds.vm / ds.act / ds.code_base, so the
// existing frame-change assignments throughout the switch keep it current.
struct ColdCtx {
    Vm* vm;
    Activation* act;
    Instruction* code_base;
    // The current function's VarIC array, null when it has none. Frame-
    // invariant for the whole burst, so the global-slot handlers read it
    // here instead of re-chasing vm -> current_func -> var_ic_entries.
    hobject::VarICEntry* var_ic_base;
}

struct Dispatch {
    inline ColdCtx cold;
    uint code_count;
    Instruction* code_end;
    TVal* constants;
    hobject::ICEntry* ic_base;
    uint nregs;
    TVal* regs_base;
    Instruction* curr_pc;
    bool needs_restart;
    // Set by a sub-dispatch handler (e.g. top-level RET) to make Vm.run exit
    // its loop and return `halt_value`.  Distinguishes "VM is done" from the
    // ordinary "continue to next instruction" of an empty optional return.
    bool halt;
    TVal halt_value;
}
