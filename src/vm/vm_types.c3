module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::io;
import std::math;

/// The bytecode virtual machine: a register-based interpreter.
///
/// Execution runs over a value stack of activation records. A CALL takes the
/// argument count in A and a base register in BC, with the callee at `base`,
/// `this` at `base+1`, and the arguments from `base+2`. The inner dispatch loop
/// restarts on a JS-to-JS call rather than recursing.
module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
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

const uint MAX_CALLS        = 512;
const uint INITIAL_VALSTACK = 1024;

// ============================================================================
// Shadow activation frames keep outer activations visible to the GC while a
// nested Vm.run() executes. vm_call_fn_impl allocates them on the C stack and
// links them through the Vm struct.
// ============================================================================

struct ShadowActFrame {
    /// Previous frame in the linked list (null = end of list).
    void* prev;
    /// Pointer to the C-stack saved_acts array in vm_call_fn_impl.
    Activation* acts;
    /// Number of activations saved in acts[0..count-1].
    uint count;
}

// ============================================================================
// Activation record: one call frame
// ============================================================================

struct Activation {
    /// The function being executed, borrowed.
    void* func;
    /// The calling activation, null at the outermost frame.
    Activation* parent;
    /// Current variable environment
    EnvRecord* var_env;
    /// Current lexical environment
    EnvRecord* lex_env;
    /// Current catcher chain (null if none)
    void* cat;

    /// Next instruction to execute, a stable pointer into the bytecode.
    /// Null for native calls.
    Instruction* curr_pc;
    /// This activation's bottom in the valstack, used to reset valstack_bottom
    /// on return.
    TVal* bottom;
    /// Where in the valstack the return value goes. Only set on non-topmost
    /// activations.
    TVal* retval;
    /// Flags: strict, tailcalled, construct, etc.
    uint flags;
    /// This activation's `this` binding.
    TVal this_binding;
    /// The `new.target` value: the constructor a `new` expression named, or the
    /// arrow's captured one. Null outside a construct call.
    HObject* new_target;
    /// An async function's Promise, owned while the activation lives.
    HObject* async_promise;
    /// The GeneratorState this activation is running, for a generator or async
    /// body resume, and null on ordinary frames. It lets exception unwinding move
    /// the generator to GEN_COMPLETED when an uncaught throw pops past its body
    /// (ES6 §25.3.3.2).
    ///
    /// This is a borrow and takes no gs_acquire, which is safe only because the
    /// frame is popped before the generator's own holders release the state.
    ///
    /// vm.activations[] is a pool reused without zeroing, so every push must
    /// write this field. A stale non-null value makes YIELD's
    /// `walk.async_gen_state == gs` parent search match the wrong activation.
    /// Push through activation_begin() rather than setting the field directly.
    void* async_gen_state;
    /// The callee as a TVal, borrowed, which lightfuncs need.
    TVal tv_func;
    /// Highest register index that has ever held a heap reference.
    /// 0 means no register holds a heap reference, so decref_callee_regs can skip.
    uint max_heap_reg;
    /// The caller's valstack_top at CALL time, restored on RET without recomputing.
    TVal* caller_valstack_top;
}

const uint ACT_FLAG_CONSTRUCT      = 1u << 1;
const uint ACT_FLAG_PREVENT_YIELD  = 1u << 2;
const uint ACT_FLAG_DIRECT_EVAL    = 1u << 3;
const uint ACT_FLAG_ASYNC          = 1u << 4;
/// Set when this_binding was incref'd via tval_copy_ref and must be
/// decref'd when the activation is popped in handle_return.
const uint ACT_FLAG_THIS_OWNED     = 1u << 5;
/// A derived class constructor, which `extends` creates and `super()` must
/// initialize. handle_return enforces §9.2.2 step 13.c on it: returning anything
/// but an object or undefined throws a TypeError.
const uint ACT_FLAG_DERIVED        = 1u << 6;
/// The activation came from SUPER_CALL, so on return its constructed object
/// initializes the pending derived-constructor this_binding up the chain.
const uint ACT_FLAG_SUPER_CTOR     = 1u << 7;
/// The callee was borrowed from a permanent global binding: copied into the
/// caller's callee register, which for CALL_VAR is also the retval slot, with no
/// incref and no track_heap_store. The return value overwrites that same slot,
/// so the write-back must not decref what it finds there. See resolve_call_var.
const uint ACT_FLAG_BORROWED_CALLEE = 1u << 8;

// ============================================================================
// Catcher, one entry in the exception handler chain
// ============================================================================

/// Flags for catcher struct.
const uint CATCHER_FLAG_CATCH_ENABLED    = 1u << 0;
const uint CATCHER_FLAG_FINALLY_ENABLED  = 1u << 1;
const uint CATCHER_FLAG_PENDING_RETURN   = 1u << 2;
const uint CATCHER_FLAG_PENDING_BREAK    = 1u << 3;
const uint CATCHER_FLAG_PENDING_CONTINUE = 1u << 4;
const uint CATCHER_FLAG_IN_FINALLY       = 1u << 5;
/// Set alongside PENDING_RETURN when the return originates from a generator
/// return (RET_GEN/RETUNDEF_GEN, or a .return()/.throw() completion injected
/// via LOAD_RESUME), which tells ENDFINALLY to complete through the generator-aware
/// path (wrap in IteratorResult, mark GEN_COMPLETED) instead of a plain RET.
const uint CATCHER_FLAG_PENDING_RETURN_GEN = 1u << 6;

/// One handler pushed by TRY, on the singly-linked chain rooted at
/// Activation.cat.
struct Catcher {
    /// Previous (parent) catcher in the chain, or null if none.
    Catcher* parent;
    /// Flags: CATCHER_FLAG_*
    uint flags;
    /// The thrown exception value (set by THROW, read by CATCH).
    TVal thrown_val;
    /// Absolute PC of the catch handler (CATCH instruction).
    Instruction* catch_pc;
    /// Absolute PC of the finally handler (FINALLY instruction), or null if none.
    Instruction* finally_pc;
    /// PC of the ENDFINALLY closing this finally block, which the FINALLY opcode
    /// computes on first use. A `return` inside the finally body jumps here to
    /// skip the rest of the body and run the completion, the same override that
    /// break, continue, and throw already get.
    Instruction* endfinally_pc;
    /// Saved return value for return-through-finally (set by RET).
    TVal return_val;
    /// Saved PC target for break/continue-through-finally.
    Instruction* pending_pc;
    /// The lexical environment at TRY entry. An exceptional exit skips the try
    /// block's POP_LEX instructions, so CATCH and FINALLY restore this to keep
    /// the chain balanced and give the catch scope a clean base.
    void* saved_lex_env;
}

// ============================================================================
// For-in enumeration state
// ============================================================================

/// One for-in loop's iteration state, created by INITFOR and freed by NEXTFOR.
///
/// `keys` is a flat array of interned property names gathered from the object
/// and its prototype chain, with duplicates omitted. It and the struct are
/// malloc'd, and both are freed when the loop ends or a catcher unwinds past it.
///
/// `target` is borrowed, but temproot-pinned for the whole enumeration. That
/// keeps it reachable even when the loop body never mentions it, and lets
/// NEXTFOR re-check each property's existence at yield time, as
/// EnumerateObjectProperties requires, so a property deleted before its turn is
/// skipped. Freeing the state clears the temproot.
struct ForInState {
    HString** keys;    /// Array of interned property-name HString* pointers
    HObject* target;   /// Borrowed pointer to the for-in target (NOT owned)
    uint count;        /// Number of keys in the array
    uint index;        /// Current position (next key to return)
}

// ============================================================================
// Vm, the interpreter's own state
// ============================================================================

struct Vm {
    Heap* heap;

    // Value stack
    TVal* valstack;        /// Base pointer of value stack
    uint valstack_size;    /// Allocated size in slots
    TVal* valstack_top;   /// Current top (one-past-last used slot)
    TVal* valstack_end;   /// End of allocated space
    TVal* valstack_bottom; /// Pointer to current activation's bottom

    // Activation/call stack
    Activation[MAX_CALLS] activations;
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

struct Dispatch {
    Vm* vm;
    Activation* act;
    Instruction* code_base;
    uint code_count;
    Instruction* code_end;
    TVal* constants;
    hobject::ICEntry* ic_base;
    hobject::VarICEntry* var_ic_base;
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
