/// Duktape bytecode virtual machine — register-based interpreter.
///
/// Architecture matches Duktape's duk_js_executor.c and duk_js_call.c:
/// - Value stack with activation records indexed by byte offsets
/// - CALL opcode: A=nargs, BC=base (callee at base, this at base+1, args at base+2..base+1+nargs)
/// - Bytecode executed via inner loop that restarts on ECMAScript-to-ECMAScript calls
module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import duktape::jit;
import std::io;
import std::math;
import libc;

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
// Activation record (matches duk_activation in duktape)
// ============================================================================

struct Activation {
    /// Function being executed (for compfunc/natfunc; borrowed reference)
    void* func;
    /// Previous (parent) activation, or null for outermost
    Activation* parent;
    /// Current variable environment
    EnvRecord* var_env;
    /// Current lexical environment
    EnvRecord* lex_env;
    /// Current catcher chain (null if none)
    void* cat;

    /// Next instruction to execute (points into bytecode; stable pointer)
    /// null for native calls
    Instruction* curr_pc;
    /// Pointer into valstack for this activation's bottom (absolute).
    /// Used to reset valstack_bottom on return.
    TVal* bottom;
    /// Pointer into valstack where return value goes (absolute).
    /// Only set for non-topmost activations.
    TVal* retval;
    /// Flags: strict, tailcalled, construct, etc.
    uint flags;
    /// The 'this' binding for this activation (full TVal)
    TVal this_binding;
    /// For construct calls: the originally created object (before constructor ran)
    HObject* new_target;
    /// Value stack pointer to function (borrowed; for lightfuncs)
    TVal tv_func;
    /// Highest register index that ever held a heap ref (object/buffer).
    /// 0 means no heap refs in any register — decref_callee_regs can skip.
    uint max_heap_reg;
    /// Caller's valstack_top saved at CALL time — restored on RET without recomputation.
    TVal* caller_valstack_top;
}

const uint ACT_FLAG_STRICT         = 1u << 0;
const uint ACT_FLAG_TAILCALLED     = 1u << 1;
const uint ACT_FLAG_CONSTRUCT      = 1u << 2;
const uint ACT_FLAG_PREVENT_YIELD  = 1u << 3;
const uint ACT_FLAG_DIRECT_EVAL    = 1u << 4;

// ============================================================================
// Catcher — exception handler chain entry
// ============================================================================

/// Flags for catcher struct.
const uint CATCHER_FLAG_CATCH_ENABLED    = 1u << 0;
const uint CATCHER_FLAG_FINALLY_ENABLED  = 1u << 1;
const uint CATCHER_FLAG_PENDING_RETURN   = 1u << 2;
const uint CATCHER_FLAG_PENDING_BREAK    = 1u << 3;
const uint CATCHER_FLAG_PENDING_CONTINUE = 1u << 4;
const uint CATCHER_FLAG_IN_FINALLY       = 1u << 5;

/// A catcher entry pushed by TRY for exception handling.
/// Singly-linked list rooted in Activation.cat.
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
    /// Saved return value for return-through-finally (set by RET).
    TVal return_val;
    /// Saved PC target for break/continue-through-finally.
    Instruction* pending_pc;
}

// ============================================================================
// For-in enumeration state
// ============================================================================

/// Runtime state for a for-in loop iteration.  Created by INITFOR and
/// consumed/freed by NEXTFOR.
///
/// `keys` holds a flat array of interned HString* pointers collected from
/// the object and its prototype chain (omitting duplicates).  The array
/// and the struct itself are plain-malloc'd and freed when the loop
/// finishes (NEXTFOR returning false) or on catcher unwind.
struct ForInState {
    HString** keys;    /// Array of interned property-name HString* pointers
    uint count;        /// Number of keys in the array
    uint index;        /// Current position (next key to return)
}

// ============================================================================
// VM state (matches duk_hthread)
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
    Instruction* curr_pc; /// Pointer to current PC variable (for sync)

    // Global environment
    EnvRecord* global_env;

    // Return value (for outer executor return)
    TVal return_val;

    // Error state
    bool has_error;

    // Pending throw from ToPrimitive/ToNumber (set by to_primitive_value,
    // checked by opcode handlers that call vm_to_number)
    TVal throw_value;
    bool throw_pending;
}

// ============================================================================
// Catcher chain — helper functions
// ============================================================================

/// Walk the catcher chain and throw a value.
/// Searches the full activation chain, unwinding intermediate activations
/// when a catcher is found in a parent activation.
///
/// Returns true if a catcher was found (execution continues after restart).
/// Returns false if no catcher was found anywhere in the call stack
/// (caller should return VM_ERROR~).
fn bool vm_throw_value(Vm* vm, TVal thrown_val, Activation* act,
                       Instruction** curr_pc, bool* needs_restart) {
    // Walk through current and parent activations
    Activation* search_act = act;
    while (search_act != null) {
        Catcher* cat = (Catcher*)search_act.cat;
        while (cat != null) {
            if (cat.flags & CATCHER_FLAG_CATCH_ENABLED) {
                // If this is not the innermost catcher (i.e., we skipped
                // catchers with IN_FINALLY), pop the skipped catchers so
                // that the CATCH handler reads from the correct catcher.
                if (cat != (Catcher*)search_act.cat) {
                    // Pop catchers from the chain up to (but not including) this one.
                    while ((Catcher*)search_act.cat != cat) {
                        Catcher* skip = (Catcher*)search_act.cat;
                        search_act.cat = (void*)skip.parent;
                        libc::free(skip);
                    }
                }
                vm.heap.tval_copy_ref(&cat.thrown_val, &thrown_val);
                cat.flags &= ~CATCHER_FLAG_CATCH_ENABLED;
                *curr_pc = cat.catch_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                // If we found the catcher in a parent activation, unwind
                // intermediate activations so the VM resumes at the right level.
                if (search_act != act) {
                    // Pop all activations down to the one with the catcher
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm.activation_count--;
                    }
                    // Restore the valstack_bottom for the target activation
                    vm.valstack_bottom = search_act.bottom;
                    // Restore valstack_top to match the target function's nregs
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        vm.valstack_top = search_act.bottom + target_nregs;
                    }
                }
                return true;
            }
            if ((cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0
                && (cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                // Skip catchers whose finally block is currently being executed
                // (CATCHER_FLAG_IN_FINALLY is set).  Without this, a throw
                // inside a finally block would re-enter the same finally block,
                // causing an infinite loop.
                vm.heap.tval_copy_ref(&cat.thrown_val, &thrown_val);
                *curr_pc = cat.finally_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                if (search_act != act) {
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm.activation_count--;
                    }
                    vm.valstack_bottom = search_act.bottom;
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        vm.valstack_top = search_act.bottom + target_nregs;
                    }
                }
                return true;
            }
            // If this catcher has IN_FINALLY, it means we're inside its finally
            // block and a throw occurred.  Pop it and continue to the next handler.
            if (cat.flags & CATCHER_FLAG_IN_FINALLY) {
                Catcher* next = (Catcher*)cat.parent;
                search_act.cat = (void*)next;
                libc::free(cat);
                cat = next;
                continue;
            }
            cat = cat.parent;
        }
        search_act = search_act.parent;
    }
    return false;
}

/// Helper to get index from valstack base to a pointer
fn uint byte_offset(TVal* base, TVal* ptr) @inline {
    return (uint)(ptr - base);
}

/// Helper to get TVal* from valstack base and index.
fn TVal* ptr_from_byteoff(TVal* base, uint idx) @inline {
    return base + idx;
}

// ============================================================================
// Helpers
// ============================================================================

/// Convert a value known to be numeric (FASTINT or NUMBER) to double.
fn double tval_numeric_to_double(TVal* val) @inline {
    return val.is_fastint() ? (double)val.get_fastint() : val.get_number();
}

/// ECMAScript ToNumber — convert any TVal to its numeric double value.
/// Handles BOOLEAN→0/1, OBJECT→ToPrimitive→number, STRING→parse, etc.
fn double vm_to_number(Vm* vm, TVal* val) {
    switch (val.get_tag()) {
        case FASTINT: return (double)val.get_fastint();
        case NUMBER:  return val.get_number();
        case BOOLEAN: return val.get_boolean() ? 1.0 : 0.0;
        case UNDEFINED: return double::nan;
        case NULL_VAL:  return 0.0;
        case STRING: {
            HString* hstr = (HString*)val.get_heapptr();
            // ES6 §7.1.3: ToNumber(Symbol) throws TypeError
            if (hstr != null && hstr.is_symbol()) {
                vm_set_type_error(vm, "Cannot convert a Symbol value to a number");
                return double::nan;
            }
            return builtins::builtin_string_to_number(hstr);
        }
        case OBJECT: {
            TVal prim = to_primitive_value(vm, val);
            if (prim.get_tag() == OBJECT) return double::nan;
            return vm_to_number(vm, &prim);
        }
        default: return double::nan;
    }
}

/// ECMAScript ToInt32 — ES5 §9.5
/// Converts a double to int32 using modular arithmetic (mod 2^32).
/// Handles NaN → 0, Infinity → 0, and large values via fmod.
fn int toint32(double d) @inline {
    // Fast path: value already fits in int32
    int i = (int)d;
    if ((double)i == d) return i;
    // Slow path: ES5 §9.5 ToInt32 via floor-mod
    double q = d * (1.0 / 4294967296.0);  // d / 2^32
    q = math::floor(q);                     // floor(d / 2^32)
    double r = d - q * 4294967296.0;        // d mod 2^32 (always [0, 2^32))
    // Values [0, 2^31) stay as-is, [2^31, 2^32) wrap to signed
    if (r >= 2147483648.0) r -= 4294967296.0;
    return (int)r;
}

/// ECMAScript truthiness.
macro bool is_truthy(TVal* val) {
$if types::USE_NANBOX:
    ulong tag = val.bits >> 48;
    // Falsy primitives: undefined, null, false
    if (tag == types::TAG_UNDEFINED ||
        tag == types::TAG_NULL_VAL ||
        val.bits == (types::TAG_BOOLEAN << 48)) {
        return false;
    }
    // Fastint: sign-extend 48-bit payload, check != 0
    if (tag == types::TAG_FASTINT) {
        long fi = ((long)(val.bits & types::NANBOX_PAYLOAD_MASK) << 16) >> 16;
        return fi != 0;
    }
    // Number (double): 0.0 and NaN are falsy
    if (types::nanbox_is_double(val.bits)) {
        double d = bitcast(val.bits, double);
        return d != 0.0 && !math::is_nan(d);
    }
    // String: empty string is falsy
    if (tag == types::TAG_STRING) {
        HString* s = (HString*)(val.bits & types::NANBOX_PAYLOAD_MASK);
        return s.blen > 0;
    }
    // Objects, lightfuncs, etc. are always truthy
    return true;
$else
    switch (val.get_tag()) {
        case UNDEFINED: return false;
        case NULL_VAL:  return false;
        case BOOLEAN:   return val.get_boolean();
        case NUMBER:    return val.get_number() != 0.0 && !math::is_nan(val.get_number());
        case FASTINT:   return val.get_fastint() != 0;
        case STRING:    return ((HString*)val.get_heapptr()).blen > 0;
        case OBJECT:    return true;
        case LIGHTFUNC: return true;
        default:        return true;
    }
$endif
}

/// Ensure the value stack has room for `needed` more slots.
/// Fast path uses pointer comparison (no division).
fn bool ensure_valstack(Vm* vm, uint needed) @inline {
    // Fast path: check if top + needed fits within allocated end
    if (vm.valstack_top + needed <= vm.valstack_end) {
        return true;
    }
    return ensure_valstack_grow(vm, needed);
}

/// Slow path: grow the value stack.
fn bool ensure_valstack_grow(Vm* vm, uint needed) {
    TVal* old_base = vm.valstack;
    uint used = (uint)((usz)vm.valstack_top - (usz)vm.valstack) / TVal::size;
    uint new_size = vm.valstack_size;
    while (new_size < used + needed) {
        new_size *= 2;
    }
    void* new_raw = libc::realloc(vm.valstack, (usz)new_size * TVal::size);
    if (new_raw == null) {
        return false;
    }
    TVal* new_base = (TVal*)new_raw;
    long diff = (char*)new_base - (char*)old_base;

    vm.valstack = new_base;
    vm.valstack_size = new_size;
    vm.valstack_top = (TVal*)((char*)vm.valstack_top + diff);
    vm.valstack_end = (TVal*)((char*)new_base + (usz)(new_size * TVal::size));
    vm.valstack_bottom = (TVal*)((char*)vm.valstack_bottom + diff);

    // Relocate all activation bottom/retval pointers (they point into the old buffer)
    for (uint i = 0; i < vm.activation_count; i++) {
        Activation* a = &vm.activations[i];
        a.bottom = (TVal*)((char*)a.bottom + diff);
        if (a.retval != null) {
            a.retval = (TVal*)((char*)a.retval + diff);
        }
    }

    // Update heap's valstack GC root pointers (base may have moved)
    vm.heap.valstack_base = vm.valstack;
    // valstack_top_ptr still points to vm.valstack_top (stable struct field)

    return true;
}

/// Get the current activation. Returns null if no activations.
fn Activation* curr_act(Vm* vm) @inline {
    if (vm.activation_count == 0) return null;
    assert(vm.activation_count <= MAX_CALLS);
    return &vm.activations[vm.activation_count - 1];
}

/// Get valstack_bottom as TVal*
fn TVal* valstack_bottom_ptr(Vm* vm) @inline {
    return curr_act(vm).bottom;
}

/// Convert a TVal to an interned string key for property access.
/// Uses a single tag extraction via switch to avoid redundant checks.
/// ES5 §11.8.7 / ES7 §12.2.1: ToPropertyKey — unwraps wrapper objects.
fn void* get_prop_key(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            if (!s.flags.is_interned) return h.ensure_interned(s);
            return s;
        }
        case FASTINT:
            if (try s = vm_fastint_to_string(vm, val.get_fastint())) return s;
            return null;
        case NUMBER:
            if (try s = vm_number_to_string(vm, val.get_number())) return s;
            return null;
        case BOOLEAN:
            if (val.get_boolean()) return h.strs[heap::BuiltinStr.TRUE];
            return h.strs[heap::BuiltinStr.FALSE];
        case UNDEFINED: return h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:  return h.strs[heap::BuiltinStr.NULL_STR];
        case OBJECT: {
            // Unwrap String/Number/Boolean wrapper objects per ToPrimitive hint string.
            TVal prim = builtins::to_primitive_value_local(val);
            if (prim.get_tag() != OBJECT) {
                TVal tmp = prim;
                return get_prop_key(vm, &tmp);
            }
            return h.strs[heap::BuiltinStr.UNDEFINED];
        }
        default:        return h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

/// Look up a property on an object, walking the prototype chain.
/// Returns the .prototype object for a constructor lightfunc, or null for non-constructor lightfuncs.
fn HObject* lightfunc_get_proto(Vm* vm, uint fn_idx) {
    switch (fn_idx) {
        case builtins::BUILTIN_ERROR:           return vm.heap.err_proto;
        case builtins::BUILTIN_TYPE_ERROR:      return vm.heap.type_err_proto;
        case builtins::BUILTIN_RANGE_ERROR:     return vm.heap.range_err_proto;
        case builtins::BUILTIN_REFERENCE_ERROR: return vm.heap.ref_err_proto;
        case builtins::BUILTIN_SYNTAX_ERROR:    return vm.heap.syntax_err_proto;
        case builtins::BUILTIN_EVAL_ERROR:      return vm.heap.eval_err_proto;
        case builtins::BUILTIN_BOOLEAN:         return vm.heap.bool_proto;
        case builtins::BUILTIN_STRING:          return vm.heap.string_proto;
        case builtins::BUILTIN_NUMBER:          return vm.heap.number_proto;
        case builtins::BUILTIN_OBJECT:          return vm.heap.object_proto;
        case builtins::BUILTIN_ARRAY:           return vm.heap.array_proto;
        case builtins::BUILTIN_FUNCTION:        return vm.heap.function_proto;
        case builtins::BUILTIN_DATE:            return vm.heap.date_proto;
        case builtins::BUILTIN_REGEXP:          return vm.heap.regexp_proto;
        case builtins::BUILTIN_MAP:             return vm.heap.map_proto;
        case builtins::BUILTIN_SET:             return vm.heap.set_proto;
        case builtins::BUILTIN_WEAKMAP:         return vm.heap.weakmap_proto;
        case builtins::BUILTIN_WEAKSET:         return vm.heap.weakset_proto;
        case builtins::BUILTIN_SYMBOL:          return vm.heap.symbol_proto;
        case builtins::BUILTIN_PROMISE:         return vm.heap.promise_proto;
        case builtins::BUILTIN_GENERATOR_FUNCTION: return vm.heap.generator_proto;
        case builtins::BUILTIN_URI_ERROR: return vm.heap.uri_err_proto;
        case builtins::BUILTIN_AGGREGATE_ERROR: return vm.heap.aggregate_err_proto;
        default: return null;
    }
}

fn TVal get_prop_with_proto(HObject* obj, void* key) {
    TVal? result = obj.get_prop_proto(key);
    if (try v = result) {
        return v;
    }
    TVal undef;
    undef.set_undefined();
    return undef;
}

// ============================================================================
// String helpers
// ============================================================================

/// Intern a raw byte slice into the VM's string table.
fn HString* intern_string(Vm* vm, char[] data) {
    return vm.heap.str_intern(data);
}

/// Return the interned typeof string for a TVal per ES spec.
fn HString* typeof_string(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case UNDEFINED: return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:  return (HString*)h.strs[heap::BuiltinStr.OBJECT];
        case BOOLEAN:   return (HString*)h.strs[heap::BuiltinStr.BOOLEAN];
        case NUMBER:    return (HString*)h.strs[heap::BuiltinStr.NUMBER];
        case FASTINT:   return (HString*)h.strs[heap::BuiltinStr.NUMBER];
        case STRING:
            HString* hstr = (HString*)val.get_heapptr();
            if (hstr != null && hstr.is_symbol()) {
                return (HString*)h.strs[heap::BuiltinStr.SYMBOL];
            }
            return (HString*)h.strs[heap::BuiltinStr.STRING];
        case OBJECT:
            HObject* hobj = (HObject*)val.get_heapptr();
            if (hobj != null && hobj.is_callable()) {
                return (HString*)h.strs[heap::BuiltinStr.FUNCTION];
            }
            return (HString*)h.strs[heap::BuiltinStr.OBJECT];
        case LIGHTFUNC: return (HString*)h.strs[heap::BuiltinStr.FUNCTION];
        default:        return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

// int_to_buf is defined in duktape::hstring and available via the module import.

/// Remove leading zero from exponent in %g/%e output: e-07 → e-7, e+07 → e+7.
/// Returns possibly shortened length.
fn int es5_fix_exponent(char[] buf, int len) {
    if (len <= 0) return len;
    int ei = len - 1;
    while (ei > 0 && buf[ei] != 'e' && buf[ei] != 'E') ei--;
    if (ei > 0 && ei + 3 < len && buf[ei + 2] == '0') {
        for (int j = ei + 3; j < len; j++) buf[j - 1] = buf[j];
        len--;
    }
    return len;
}

/// Convert a double to an interned HString* using shortest round-trip formatting.
fn HString*? vm_number_to_string(Vm* vm, double val) {
    // ES5 §9.8.1: ToString(Infinity) = "Infinity", ToString(NaN) = "NaN"
    if (math::is_nan(val)) {
        return (HString*)vm.heap.strs[heap::BuiltinStr.NAN_STR];
    }
    if (math::is_inf(val)) {
        return (HString*)((val > 0.0)
            ? vm.heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
            : vm.heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY]);
    }

    // ES5 §9.8.1: ToString(number) — -0 must produce "0", not "-0"
    if (val == 0.0) {
        return vm.heap.str_intern("0");
    }

    // ES5 §9.8.1 steps 5-7: integers with |val| < 10^21 use decimal notation
    if (val == math::trunc(val) && val > -1e21 && val < 1e21) {
        char[64] ibuf;
        int ilen = libc::snprintf(&ibuf, 64, "%.0f", val);
        if (ilen >= 0 && ilen < 64) {
            return vm.heap.str_intern(ibuf[:ilen]);
        }
    }

    char[64] buf;
    ulong val_bits = bitcast(val, ulong);

    // ES5 §9.8.1: compute base-10 exponent for decimal/exponential decision
    double abs_d = val < 0.0 ? -val : val;
    int exp10 = (int)math::floor(builtins::math_log10(abs_d));

    if (exp10 >= -6 && exp10 < 21) {
        // ES5 §9.8.1 step 5: decimal notation — format with %.*f
        int k = exp10 + 1;
        if (k < 1) k = 1;
        int nfrac = 17 - k;
        if (nfrac < 0) nfrac = 0;
        int len = libc::snprintf(&buf, 64, "%.*f", nfrac, val);
        // Trim trailing zeros after decimal point
        while (len > 1 && buf[len - 1] == '0' && buf[len - 2] != '.') len--;
        if (len > 1 && buf[len - 1] == '.') len--;
        // Progressively trim trailing digits while round-trip still holds,
        // producing the shortest decimal representation (e.g. 123.1234567
        // instead of 123.12345670000001).
        buf[len] = 0;
        while (len > 0) {
            char last = buf[len - 1];
            if (last == '.' || last == '-') break;
            buf[len - 1] = 0;
            double parsed = libc::strtod(&buf, null);
            if (bitcast(parsed, ulong) == val_bits) {
                len--;
            } else {
                buf[len - 1] = last;
                break;
            }
        }
        if (len >= 0 && len < 64) {
            return vm.heap.str_intern(buf[:len]);
        }
    }

    // Try %.15g first — shortest common case
    int len = libc::snprintf(&buf, 64, "%.15g", val);
    if (len >= 0 && len < 64) {
        double parsed = libc::strtod(&buf, null);
        if (bitcast(parsed, ulong) == val_bits) {
            // ES5 §9.8.1: remove leading zero in exponent (e-07 → e-7)
            len = es5_fix_exponent(&buf, len);
            return vm.heap.str_intern(buf[:len]);
        }
    }

    // Fall back to %.16g
    len = libc::snprintf(&buf, 64, "%.16g", val);
    if (len >= 0 && len < 64) {
        double parsed = libc::strtod(&buf, null);
        if (bitcast(parsed, ulong) == val_bits) {
            len = es5_fix_exponent(&buf, len);
            return vm.heap.str_intern(buf[:len]);
        }
    }

    // Final fallback to %.17g (always round-trips, no check needed)
    len = libc::snprintf(&buf, 64, "%.17g", val);
    if (len < 0 || len >= 64) {
        return null;
    }
    len = es5_fix_exponent(&buf, len);
    return vm.heap.str_intern(buf[:len]);
}

/// Convert a FASTINT to an interned HString* using the small-integer cache
/// for values 0–255, or fast int-to-string conversion for larger values.
fn HString*? vm_fastint_to_string(Vm* vm, long val) {
    HString* s = vm.heap.int_to_hstring(val);
    if (s == null) return null;
    return s;
}

/// Convert a TVal to an interned HString*.
fn HString*? vm_to_string(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case STRING: {
            HString* hstr = (HString*)val.get_heapptr();
            // ES6 §7.1.12: ToString(Symbol) throws TypeError
            if (hstr != null && hstr.is_symbol()) {
                vm_set_type_error(vm, "Cannot convert a Symbol value to a string");
                return null;
            }
            return hstr;
        }
        case NUMBER:
            return vm_number_to_string(vm, val.get_number());
        case FASTINT:
            return vm_fastint_to_string(vm, val.get_fastint());
        case BOOLEAN:
            if (val.get_boolean()) {
                return (HString*)h.strs[heap::BuiltinStr.TRUE];
            }
            return (HString*)h.strs[heap::BuiltinStr.FALSE];
        case UNDEFINED:
            return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:
            return (HString*)h.strs[heap::BuiltinStr.NULL_STR];
        case OBJECT: {
            // Call toString() on the object per ES5 §8.12 ToString
            if (vm != null && vm.heap.call_fn != null && val.get_heapptr() != null) {
                HObject* obj = (HObject*)val.get_heapptr();
                HString* to_str_key = (HString*)h.strs[heap::BuiltinStr.TO_STRING];
                if (to_str_key != null) {
                    if (try toString_fn = obj.get_prop_proto(to_str_key)) {
                        if (toString_fn.is_lightfunc() || (toString_fn.is_object() && toString_fn.get_heapptr() != null && ((HObject*)toString_fn.get_heapptr()).is_callable())) {
                            TVal result = h.call_fn(vm, toString_fn, null, 0, *val);
                            if (vm_check_call_fn_error(vm)) return null;
                            if (try result_str = vm_to_string(vm, &result)) {
                                return result_str;
                            }
                        }
                    }
                }
            }
            return (HString*)h.strs[heap::BuiltinStr.OBJECT_OBJECT];
        }
        case LIGHTFUNC:
            return (HString*)h.strs[heap::BuiltinStr.FUNCTION_STR];
        default:
            return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

/// Returns true for ECMAScript white-space and line-terminator characters
/// (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

/// ECMAScript ToNumber for strings (§7.1.3.1).
///
/// Converts an HString* to a double, trimming ECMAScript whitespace and
/// parsing numeric literals (decimal, hex, Infinity).  Returns NaN when
/// the string does not represent a valid numeric literal.
fn double hstring_to_number(HString* hstr) {
    char* cstr = hstr.get_cstr();
    uint blen = hstr.blen;

    // --- skip leading ECMAScript whitespace ---
    uint start = 0;
    while (start < blen && is_ecma_whitespace(cstr[start])) {
        start++;
    }

    // Empty or all-whitespace -> +0
    if (start == blen) {
        return 0.0;
    }

    char* p = cstr + start;

    // --- Infinity / -Infinity / +Infinity ---
    if (libc::strcmp((ZString)p, "Infinity") == 0)   return double::inf;
    if (libc::strcmp((ZString)p, "+Infinity") == 0)  return double::inf;
    if (libc::strcmp((ZString)p, "-Infinity") == 0)  return -double::inf;

    // --- Hex integer literal (0x...) ---
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        uint j = 2;
        ulong val = 0;
        while (p[j] != 0) {
            char c = p[j];
            uint digit;
            if      (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
            else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A' + 10); }
            else { break; }   // non-hex terminates the literal

            val = (val << 4) | digit;
            j++;
        }
        // Trailing must be whitespace
        while (p[j] != 0) {
            if (!is_ecma_whitespace(p[j])) return double::nan;
            j++;
        }
        return (double)val;
    }

    // --- Decimal via libc::strtod ---
    char* endptr;
    double result = libc::strtod(p, &endptr);

    // Nothing was consumed -> NaN
    if (endptr == p) {
        return double::nan;
    }

    // Trailing characters must be whitespace only
    while (*endptr != 0) {
        if (!is_ecma_whitespace(*endptr)) {
            return double::nan;
        }
        endptr++;
    }

    return result;
}

/// Extract [[PrimitiveValue]] from Boolean/Number/String wrapper objects.
/// After calling vm_to_number, check and throw if ToPrimitive failed.
/// Returns false if a throw was initiated (caller should break out of handler).
fn bool vm_check_to_number_throw(Vm* vm, Activation* act, Instruction** curr_pc, bool* needs_restart) {
    if (vm.throw_pending) {
        vm.throw_pending = false;
        return vm_throw_value(vm, vm.throw_value, act, curr_pc, needs_restart);
    }
    return true;
}

/// Helper: create a TypeError and set vm.throw_pending for deferred throw.
/// The opcode handler must check vm.throw_pending and call vm_throw_value.
fn void vm_set_toprimitive_error(Vm* vm) {
    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = vm.heap.type_err_proto;
        HString* msg_str = intern_string(vm, "Cannot convert object to primitive value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = intern_string(vm, "message");
            if (msg_key != null) {
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        TVal err_val;
        err_val.set_object(err);
        vm.heap.tval_copy_ref(&vm.throw_value, &err_val);
    }
    vm.throw_pending = true;
}

/// Helper: create a TypeError with a custom message and set vm.throw_pending.
fn void vm_set_type_error(Vm* vm, char[] msg) {
    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = vm.heap.type_err_proto;
        HString* msg_str = intern_string(vm, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = intern_string(vm, "message");
            if (msg_key != null) {
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        TVal err_val;
        err_val.set_object(err);
        vm.heap.tval_copy_ref(&vm.throw_value, &err_val);
    }
    vm.throw_pending = true;
}

/// Check if call_fn caused an unhandled throw inside the called function.
/// When call_fn invokes a compiled JS function that throws and no catcher
/// is found, vm.has_error is set and vm.return_val contains the thrown error.
/// This helper propagates that error into the deferred throw mechanism so
/// the outer opcode handler can properly propagate it.
/// Returns true if an error was detected (caller should return early).
fn bool vm_check_call_fn_error(Vm* vm) @inline {
    if (vm.has_error) {
        vm.heap.tval_copy_ref(&vm.throw_value, &vm.return_val);
        vm.throw_pending = true;
        vm.has_error = false;
        vm.heap.has_error = false;
        return true;
    }
    return false;
}

/// ES5 §9.1 ToPrimitive — hint "string" for +, "number" for arithmetic.
/// Calls Symbol.toPrimitive first (ES6 §7.1.1), then valueOf/toString.
/// Sets vm.throw_pending if both valueOf and toString return non-primitives.
fn TVal to_primitive_value(Vm* vm, TVal* val, bool hint_is_string = false) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        hobject::ObjClass cls = obj.get_class();
        // Fast path: wrapper objects unwrap directly
        if (cls == hobject::ObjClass.BOOLEAN &&
            (*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
            return result;
        }
        if (cls == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            TVal result;
            result.set_number((*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint());
            return result;
        }
        if (cls == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            TVal result;
            result.set_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return result;
        }
        // Fast path: Symbol wrapper → unwrap directly
        if (cls == hobject::ObjClass.SYMBOL &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            HString* s = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
            if (s != null && s.is_symbol()) {
                TVal result;
                result.set_string(s);
                return result;
            }
        }
        // Check Symbol.toPrimitive (ES6 §7.1.1)
        if (vm != null && vm.heap.call_fn != null && vm.heap.toprimitive_symbol != null) {
            Heap* h = vm.heap;
            HString* toprim_key = h.toprimitive_symbol;
            // Use find_accessor_proto to properly invoke getters (Object.defineProperty)
            hobject::AccessorResult acc = obj.find_accessor_proto(toprim_key, true);
            TVal toprim_fn;
            if (acc.found) {
                // Getter-defined Symbol.toPrimitive: invoke the getter
                TVal getter_this;
                getter_this.set_object(acc.this_obj);
                toprim_fn = h.call_fn(vm, acc.accessor_fn, null, 0, getter_this);
                if (vm_check_call_fn_error(vm)) return *val;
            } else {
                // Data property: try get_prop_proto as fallback
                TVal? toprim_val = obj.get_prop_proto(toprim_key);
                if (try tv = toprim_val) {
                    toprim_fn = tv;
                } else {
                    toprim_fn.set_undefined();
                }
            }
            if (toprim_fn.is_lightfunc() || (toprim_fn.is_object() && toprim_fn.get_heapptr() != null && ((HObject*)toprim_fn.get_heapptr()).is_callable())) {
                // Call Symbol.toPrimitive(obj, hint) — use "default" for general ToPrimitive,
                // but "string" for + operator (ES5 §11.6.1).
                HString* hint_str = hint_is_string
                    ? intern_string(vm, "string")
                    : intern_string(vm, "default");
                TVal hint_val;
                hint_val.set_string(hint_str);
                TVal[1] hint_args;
                hint_args[0] = hint_val;
                TVal prim = h.call_fn(vm, toprim_fn, &hint_args[0], 1, *val);
                if (vm_check_call_fn_error(vm)) return *val;
                if (!prim.is_object()) return prim;
                // ES6 §7.1.1 step 6.d: result is Object → TypeError
                // Signal caller via throw_pending (checked after return)
                vm_set_toprimitive_error(vm);
                return *val;
            }
        }
        // Generic objects: call valueOf(), then toString()
        // ES5 §9.1: hint "string" → toString first, then valueOf;
        //           hint "number" (default) → valueOf first, then toString.
        // Date objects override [[DefaultValue]] to always use "string" hint.
        if (vm != null && vm.heap.call_fn != null) {
            Heap* h = vm.heap;
            bool is_date = (cls == hobject::ObjClass.DATE);
            // Date always uses toString first; other objects depend on hint.
            bool use_string_first = is_date || hint_is_string;
            HString* first_key = use_string_first
                ? (HString*)h.strs[heap::BuiltinStr.TO_STRING]
                : (HString*)h.strs[heap::BuiltinStr.VALUE_OF];
            HString* second_key = use_string_first
                ? (HString*)h.strs[heap::BuiltinStr.VALUE_OF]
                : (HString*)h.strs[heap::BuiltinStr.TO_STRING];
            if (first_key != null) {
                TVal? first_val = obj.get_prop_proto(first_key);
                if (try first_fn = first_val) {
                    if (first_fn.is_lightfunc() || (first_fn.is_object() && first_fn.get_heapptr() != null && ((HObject*)first_fn.get_heapptr()).is_callable())) {
                        TVal prim = h.call_fn(vm, first_fn, null, 0, *val);
                        if (vm_check_call_fn_error(vm)) return *val;
                        if (!prim.is_object()) return prim;
                    }
                }
            }
            if (second_key != null) {
                TVal? second_val = obj.get_prop_proto(second_key);
                if (try second_fn = second_val) {
                    if (second_fn.is_lightfunc() || (second_fn.is_object() && second_fn.get_heapptr() != null && ((HObject*)second_fn.get_heapptr()).is_callable())) {
                        TVal prim = h.call_fn(vm, second_fn, null, 0, *val);
                        if (vm_check_call_fn_error(vm)) return *val;
                        if (!prim.is_object()) return prim;
                    }
                }
            }
            // ES5 §8.12.8 step 7: neither valueOf nor toString returned a primitive
            vm_set_toprimitive_error(vm);
        }
    }
    return *val;
}

const uint FORIN_INITIAL_CAP = 64;

/// Grow an HString** array if needed.
fn bool forin_ensure_cap(HString*** arr, uint* cap, uint need) {
    if (need >= *cap) {
        uint new_cap = *cap * 2;
        HString** new_arr = (HString**)libc::realloc(*arr, new_cap * HString*::size);
        if (new_arr == null) return false;
        *arr = new_arr;
        *cap = new_cap;
    }
    return true;
}

/// Add a key if not already in the seen set (pointer compare for interned strings).
fn bool forin_add_key(HString*** keys, uint* count,
                      HString*** seen, uint* seen_cnt, uint* cap,
                      HString* key) {
    for (uint j = 0; j < *seen_cnt; j++) {
        if ((*seen)[j] == key) return true;
    }
    if (!forin_ensure_cap(keys, cap, *count + 1)) return false;
    if (!forin_ensure_cap(seen, cap, *seen_cnt + 1)) return false;
    (*keys)[*count] = key;
    (*count)++;
    (*seen)[*seen_cnt] = key;
    (*seen_cnt)++;
    return true;
}

/// Collect all enumerable property keys from an object and its prototype
/// chain, de-duplicated (own keys shadow prototype keys).
///
/// Returns a malloc'd ForInState, or null if allocation fails.
/// The caller (NEXTFOR) is responsible for freeing via `libc::free`.
fn ForInState* collect_forin_keys(Vm* vm, HObject* obj) {

    uint cap = FORIN_INITIAL_CAP;
    HString** keys = (HString**)libc::malloc(cap * HString*::size);
    if (keys == null) return null;
    uint count = 0;

    HString** seen = (HString**)libc::malloc(cap * HString*::size);
    if (seen == null) { libc::free(keys); return null; }
    uint seen_cnt = 0;

    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        // STRING exotic: enumerate integer indices [0, clen) from the primitive value
        // before the named property list so index order matches the spec.
        if (cur.flags.exotic_stringobj && (*cur.extra_ptr()).prim.primitive_value.is_string()) {
            HString* prim = (HString*)(*cur.extra_ptr()).prim.primitive_value.get_heapptr();
            if (prim != null) {
                for (uint i = 0; i < prim.char_length(); i++) {
                    HString* k = vm.heap.int_to_hstring((long)i);
                    if (k == null) continue;
                    if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                        libc::free(keys);
                        libc::free(seen);
                        return null;
                    }
                }
            }
        }

        // Own dense array part indices — integer keys from dense storage (before named props).
        for (uint i = 0; i < cur.array_size; i++) {
            if (!cur.array_part()[i].is_undefined()) {
                HString* k = vm.heap.int_to_hstring((long)i);
                if (k == null) continue;
                if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                    libc::free(keys);
                    libc::free(seen);
                    return null;
                }
            }
        }

        // Own named properties — integer indices ascending, then strings in insertion order.
        // Phase 1: integer-indexed named properties (sorted by numeric index)
        {
            uint int_count = 0;
            for (uint i = 0; i < cur.prop_count; i++) {
                if (cur.prop_key_at(i) != null && ((HString*)cur.prop_key_at(i)).is_arridx()) {
                    int_count++;
                }
            }
            if (int_count > 0) {
                uint* sbuf = (uint*)libc::malloc((usz)(int_count * 2 * 4));
                if (sbuf != null) {
                    uint p = 0;
                    for (uint i = 0; i < cur.prop_count; i++) {
                        if (cur.prop_key_at(i) != null) {
                            HString* k = (HString*)cur.prop_key_at(i);
                            if (k.is_arridx()) {
                                sbuf[p * 2] = k.array_index();
                                sbuf[p * 2 + 1] = i;
                                p++;
                            }
                        }
                    }
                    // Insertion sort by arridx
                    for (uint i = 1; i < int_count; i++) {
                        uint t0 = sbuf[i * 2];
                        uint t1 = sbuf[i * 2 + 1];
                        uint j = i;
                        while (j > 0 && sbuf[(j - 1) * 2] > t0) {
                            sbuf[j * 2] = sbuf[(j - 1) * 2];
                            sbuf[j * 2 + 1] = sbuf[(j - 1) * 2 + 1];
                            j--;
                        }
                        sbuf[j * 2] = t0;
                        sbuf[j * 2 + 1] = t1;
                    }
                    for (uint i = 0; i < int_count; i++) {
                        uint si = sbuf[i * 2 + 1];
                        HString* k = (HString*)cur.prop_key_at(si);
                        if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                            libc::free(sbuf);
                            libc::free(keys);
                            libc::free(seen);
                            return null;
                        }
                    }
                    libc::free(sbuf);
                }
            }
        }
        // Phase 2: non-index string named properties (insertion order, enumerable only)
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.get_prop_flags(i).enumerable && cur.prop_key_at(i) != null) {
                HString* k = (HString*)cur.prop_key_at(i);
                if (k.is_arridx()) continue;
                if (k.is_symbol()) continue;
                if (cur.flags.exotic_stringobj && (void*)k == vm.heap.strs[heap::BuiltinStr.LENGTH]) continue;
                if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                    libc::free(keys);
                    libc::free(seen);
                    return null;
                }
            }
        }
        // Phase 3: symbol-keyed properties (insertion order, enumerable only)
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.get_prop_flags(i).enumerable && cur.prop_key_at(i) != null) {
                HString* k = (HString*)cur.prop_key_at(i);
                if (!k.is_symbol()) continue;
                if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                    libc::free(keys);
                    libc::free(seen);
                    return null;
                }
            }
        }

        cur = cur.prototype;
        depth++;
    }

    libc::free(seen);

    ForInState* state = (ForInState*)libc::malloc(ForInState::size);
    if (state == null) { libc::free(keys); return null; }
    state.keys = keys;
    state.count = count;
    state.index = 0;
    return state;
}

/// ECMAScript Abstract Equality Comparison (§7.2.14).
fn bool abstract_eq(Vm* vm, TVal* a, TVal* b) {
    // Same type -> strict equality
    if (a.get_tag() == b.get_tag()) {
        return strict_eq(a, b);
    }

    // null/undefined pair
    if ((a.is_null() && b.is_undefined()) ||
        (a.is_undefined() && b.is_null())) {
        return true;
    }

    // NUMBER/FASTINT: treat as same "numeric" type
    if (a.is_number() && b.is_fastint()) {
        return a.get_number() == (double)b.get_fastint();
    }
    if (a.is_fastint() && b.is_number()) {
        return (double)a.get_fastint() == b.get_number();
    }

    // Boolean -> ToNumber
    if (a.is_boolean()) {
        TVal a_num;
        a_num.set_number(a.get_boolean() ? 1.0 : 0.0);
        return abstract_eq(vm, &a_num, b);
    }
    if (b.is_boolean()) {
        TVal b_num;
        b_num.set_number(b.get_boolean() ? 1.0 : 0.0);
        return abstract_eq(vm, a, &b_num);
    }

    // String + Number -> ToNumber(string)
    if (a.is_string() && (b.is_number() || b.is_fastint())) {
        double num = hstring_to_number((HString*)a.get_heapptr());
        if (b.is_fastint()) return num == (double)b.get_fastint();
        return num == b.get_number();
    }
    if (b.is_string() && (a.is_number() || a.is_fastint())) {
        double num = hstring_to_number((HString*)b.get_heapptr());
        if (a.is_fastint()) return (double)a.get_fastint() == num;
        return a.get_number() == num;
    }

    // Object + Boolean/Number/String -> ToPrimitive
    if (a.is_object() && (b.is_boolean() || b.is_number() || b.is_fastint() || b.is_string())) {
        TVal prim = to_primitive_value(vm, a);
        if (!prim.is_object()) {
            return abstract_eq(vm, &prim, b);
        }
        return false;
    }
    if (b.is_object() && (a.is_boolean() || a.is_number() || a.is_fastint() || a.is_string())) {
        TVal prim = to_primitive_value(vm, b);
        if (!prim.is_object()) {
            return abstract_eq(vm, a, &prim);
        }
        return false;
    }

    return false;
}

/// Strict equality check (same as SEQ).
fn bool strict_eq(TVal* a, TVal* b) @inline {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return false;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING: {
                HString* sa = (HString*)a.get_heapptr();
                HString* sb = (HString*)b.get_heapptr();
                return sa != null && sb != null && sa.equals_hstring(sb);
            }
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default:        return false;
        }
    }
    // NUMBER and FASTINT are the same ES type
    if (a.is_number() && b.is_fastint()) {
        return a.get_number() == (double)b.get_fastint();
    }
    if (a.is_fastint() && b.is_number()) {
        return (double)a.get_fastint() == b.get_number();
    }
    return false;
}

// ============================================================================
// GC activation marking
// ============================================================================

/// Mark all env bindings held by live activation records.
/// Called from heap's mark_roots to keep per-call var_envs alive during GC.
fn void vm_mark_activations(void* vm_ptr, void* heap_ptr) {
    Vm* vm = (Vm*)vm_ptr;
    heap::Heap* h = (heap::Heap*)heap_ptr;
    for (uint i = 0; i < vm.activation_count; i++) {
        Activation* act = &vm.activations[i];
        if (act.var_env != null && act.var_env.bindings != null) {
            h.mark_hobject(act.var_env.bindings);
        }
        if (act.lex_env != null && act.lex_env.bindings != null && act.lex_env != act.var_env) {
            h.mark_hobject(act.lex_env.bindings);
        }
        // Walk parent env chains too
        env::EnvRecord* cur = act.var_env;
        while (cur != null) {
            if (cur.bindings != null) { h.mark_hobject(cur.bindings); }
            cur = cur.parent;
        }
    }
}

// ============================================================================
// Call handling (matches duk_js_call.c)
// ============================================================================

/// Set up a new activation for a function call.
/// Value stack must have: [func this arg0 arg1 ... argN]
/// idx_func = index of func on value stack
fn bool setup_call(Vm* vm, uint idx_func, uint nargs, bool is_construct) {
    // Save current activation state
    Activation* caller_act = curr_act(vm);
    TVal* caller_bottom = caller_act.bottom;

    // retval: where to write return value in caller's frame
    caller_act.retval = caller_bottom + idx_func;

    // Get target function
    TVal* func_slot = caller_bottom + idx_func;
    TVal func_val = *func_slot;

    CompiledFunction* target_func = null;
    EnvRecord* var_env = null;
    EnvRecord* lex_env = null;

    if (func_val.is_lightfunc()) {
        // Lightfunc: always strict, just call directly
        // Nothing special needed for var_env/lex_env
    } else if (func_val.is_object()) {
        HObject* hobj = (HObject*)func_val.get_heapptr();
        if (hobj != null && hobj.is_callable() && (*hobj.extra_ptr()).func.comp_func != null) {
            target_func = (*hobj.extra_ptr()).func.comp_func;
            var_env = (*hobj.extra_ptr()).func.var_env;
            lex_env = (*hobj.extra_ptr()).func.lex_env;
        } else {
            return false;
        }
    } else {
        return false;
    }

    // Allocate new activation
    if (vm.activation_count >= MAX_CALLS) {
        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = vm.heap.range_err_proto;
            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
            HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
            TVal msg_tv; msg_tv.set_string(msg_val);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            TVal err_val; err_val.set_object(err);
            vm.heap.tval_copy_ref(&vm.throw_value, &err_val);
        }
        vm.throw_pending = true;
        return false;
    }
    Activation* new_act = &vm.activations[vm.activation_count];
    vm.activation_count++;
    new_act.max_heap_reg = 0;
    new_act.caller_valstack_top = vm.valstack_top;

    // Compute new valstack bottom (after func + this + args)
    TVal* new_bottom = caller_bottom + ((uint)idx_func + 2);

    // Create a fresh var environment for this call so that `var` declarations
    // inside the function body don't clobber bindings in the outer/closure env.
    EnvRecord*? fresh_var = env::env_create_function_scope(vm.heap, var_env);
    EnvRecord* call_var_env = var_env;
    if (try fv = fresh_var) {
        call_var_env = fv;
    }

    // Set up activation
    new_act.parent = caller_act;
    new_act.func = target_func;
    new_act.var_env = call_var_env;
    new_act.lex_env = call_var_env;
    new_act.cat = null;
    new_act.curr_pc = null;
    new_act.bottom = new_bottom;
    new_act.retval = null;
    new_act.flags = (target_func != null && target_func.is_strict()) ? ACT_FLAG_STRICT : 0;
    if (is_construct) {
        new_act.flags |= ACT_FLAG_CONSTRUCT;
    }

    // Set up 'this' binding from slot idx_func+1
    TVal* this_slot = caller_bottom + idx_func + 1;
    vm.heap.tval_copy_ref(&new_act.this_binding, this_slot);

    // Move valstack_bottom to new activation
    vm.valstack_bottom = new_bottom;

    return true;
}

/// Handle return from current activation.
/// Invoke a getter function found on the prototype chain.
/// Sets up an ECMAScript call frame for the getter with `this` = this_obj,
/// and result register = result_reg (in the caller's frame).
/// Returns true if the call was set up (caller should `break` with needs_restart).
fn bool invoke_getter(Vm* vm, hobject::AccessorResult* acc,
                      TVal* this_val, uint result_reg,
                      Activation* act, Instruction** curr_pc, bool* needs_restart,
                      TVal* regs_base) {
    TVal getter_fn = acc.accessor_fn;

    // If getter is undefined/null, return undefined (no-op)
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        regs_base[result_reg].set_undefined();
        return false;
    }

    if (!getter_fn.is_object()) return false;
    HObject* func_obj = (HObject*)getter_fn.get_heapptr();
    if (func_obj == null || !func_obj.is_callable()) return false;

    // Fast path: builtin function getter — call directly, no JS frame needed
    if (func_obj.callable_kind() == hobject::CallableKind.BUILTIN_FN &&
        (*func_obj.extra_ptr()).func.builtin_fn_index >= 0) {
        uint fn_idx = (uint)(*func_obj.extra_ptr()).func.builtin_fn_index;
        TVal[1] temp_regs;
        temp_regs[0] = *this_val;  // this at regs[base_reg - 1] = regs[0]
        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = 0;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = *this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = func_obj;
        builtins::dispatch_builtin(fn_idx, &ctx);
        if (ctx.should_throw) {
            if (!vm_throw_value(vm, ctx.throw_value, act, curr_pc, needs_restart)) {
                regs_base[result_reg].set_undefined();
                return false;
            }
            regs_base = act.bottom;
        } else {
            vm.heap.tval_copy_ref(&regs_base[result_reg], ctx.result);
        }
        return false;
    }

    CompiledFunction* target = (*func_obj.extra_ptr()).func.comp_func;
    if (target == null) return false;

    // Set up call frame: callee_reg = result_reg (we reuse it)
    uint callee_reg = result_reg;
    uint frame_start = callee_reg + 2;
    TVal* new_bottom = act.bottom + frame_start;
    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

    if (!ensure_valstack(vm, needed)) {
        regs_base[result_reg].set_undefined();
        return false;
    }

    // Re-acquire regs_base after potential reallocation
    TVal* caller_regs = act.bottom;
    // Recompute new_bottom after realloc (act.bottom may have moved)
    new_bottom = act.bottom + frame_start;
    vm.heap.tval_copy_ref(&caller_regs[callee_reg], &getter_fn);
    vm.heap.tval_copy_ref(&caller_regs[callee_reg + 1], this_val);

    if (vm.activation_count >= MAX_CALLS) {
        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = vm.heap.range_err_proto;
            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
            HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
            TVal msg_tv; msg_tv.set_string(msg_val);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            TVal err_val; err_val.set_object(err);
            if (!vm_throw_value(vm, err_val, act, curr_pc, needs_restart)) {
                caller_regs[result_reg].set_undefined();
                return false;
            }
        } else {
            caller_regs[result_reg].set_undefined();
            return false;
        }
        return false;
    }

    Activation* new_act = &vm.activations[vm.activation_count];
    vm.activation_count++;
    new_act.max_heap_reg = 0;
    new_act.caller_valstack_top = vm.valstack_top;

    EnvRecord* invoke_getter_var_env = (*func_obj.extra_ptr()).func.var_env;
    if (try fv_ig = env::env_create_function_scope(vm.heap, (*func_obj.extra_ptr()).func.var_env)) { invoke_getter_var_env = fv_ig; }
    new_act.parent = act;
    new_act.func = target;
    new_act.var_env = invoke_getter_var_env;
    new_act.lex_env = invoke_getter_var_env;
    new_act.cat = null;
    new_act.curr_pc = target.code;
    new_act.bottom = new_bottom;
    new_act.retval = act.bottom + result_reg;
    new_act.flags = target.is_strict() ? ACT_FLAG_STRICT : 0;
    vm.heap.tval_copy_ref(&new_act.this_binding, this_val);

    // Clear registers and copy args (getters have 0 args)
    TVal* new_regs = new_act.bottom;
    uint new_nregs = target.num_regs;
    libc::memset(new_regs, 0, (usz)new_nregs * TVal::size);

    vm.valstack_top = new_regs + new_nregs;
    vm.valstack_bottom = new_act.bottom;

    // Save caller's PC so it resumes correctly after getter returns
    act.curr_pc = *curr_pc;

    *needs_restart = true;
    return true;
}

/// Track a heap-ref store in the current activation.  Call after any
/// instruction that writes an object or buffer TVal into a register.
/// Updates max_heap_reg so decref_callee_regs can skip non-heap registers.
fn void track_heap_store(Activation* act, TVal* val, uint reg_idx) @inline {
    if (val.is_heap_allocated()) {
        if (val.get_heapptr() != null && reg_idx > act.max_heap_reg) {
            act.max_heap_reg = reg_idx;
        }
    }
}

/// Decrement the reference count of every register in the given activation.
/// Must be called BEFORE the activation is popped, while the register range
/// is still valid.  Safe to call on activations with null func (no registers).
/// Fast-path: if max_heap_reg == 0, no register ever held a heap ref — skip.
fn void decref_callee_regs(Vm* vm, Activation* callee_act) {
    if (callee_act.func == null) return;
    if (callee_act.max_heap_reg == 0) return;  // fast path: no heap refs
    CompiledFunction* callee_func = (CompiledFunction*)callee_act.func;
    uint nregs = callee_func.num_regs;
    TVal* regs = callee_act.bottom;
    uint limit = callee_act.max_heap_reg;
    if (limit >= nregs) limit = nregs - 1;
    for (uint i = 0; i <= limit; i++) {
        // Clear the slot after releasing the ref: callee frames overlap the
        // caller's register window (sliding-window calls), and the caller's
        // own decref_callee_regs would otherwise decref the stale bits a
        // second time, underflowing the refcount.
        vm.heap.decref_tval(&regs[i]);
        regs[i].set_undefined();
    }
}

/// val: the return value (or undefined for RETUNDEF)
/// @inline: critical hot-path, called on every RET instruction.
/// Zero-initialize a range of registers to undefined.  For the small ranges
/// typical of function prologues, an inline loop beats libc::memset call
/// overhead and lets the C3 compiler unroll/optimize the stores.
fn void zero_regs_undefined(TVal* regs, uint start, uint end) @inline {
    for (uint i = start; i < end; i++) {
        regs[i].set_undefined();
    }}

fn TVal handle_return(Vm* vm, TVal val) @inline {
    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        return val;
    }

    Activation* callee_act = curr_act(vm);
    TVal* callee_result = callee_act.retval;

    // Decrement references for all callee registers before popping
    decref_callee_regs(vm, callee_act);

    // Pop activation
    vm.activation_count--;

    // If we just popped the last activation, there is no caller
    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        return val;
    }

    Activation* caller_act = curr_act(vm);
    assert(caller_act != null);

    // Restore valstack_bottom to caller's
    vm.valstack_bottom = caller_act.bottom;

    // Write result to caller's frame at the saved retval
    if (callee_result != null && callee_result >= vm.valstack && callee_result < vm.valstack_end) {
        // For construct calls: if return value is not an object, use this_binding
        TVal final_val = val;
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
            if (!final_val.is_object() || final_val.get_heapptr() == null) {
                // Return the instance (this) instead of the constructor's return value
                if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                    final_val = callee_act.this_binding;
                }
            }
        }
        TVal* result_slot = callee_result;
        vm.heap.tval_copy_ref(result_slot, &final_val);
    }

    // Restore valstack_top to match caller's nregs
    if (caller_act.func != null) {
        CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
        vm.valstack_top = caller_act.bottom + caller_func.num_regs;
    }

    return val;
}

// ============================================================================
// VM creation / destruction
// ============================================================================

/// Create and initialise a new VM.
fn Vm*? vm_create(Heap* heap) {
    void* raw = libc::malloc(Vm::size);
    if (raw == null) {
        return VM_ERROR~;
    }
    libc::memset(raw, 0, Vm::size);

    Vm* vm = (Vm*)raw;
    vm.heap = heap;

    // Allocate value stack
    void* vs_raw = libc::malloc((usz)INITIAL_VALSTACK * TVal::size);
    if (vs_raw == null) {
        libc::free(raw);
        return VM_ERROR~;
    }
    vm.valstack = (TVal*)vs_raw;
    vm.valstack_size = INITIAL_VALSTACK;
    vm.valstack_top = (TVal*)vs_raw;
    vm.valstack_end = (TVal*)((usz)vs_raw + (usz)INITIAL_VALSTACK * TVal::size);

    // Register valstack with heap for GC root scanning
    heap.valstack_base = vm.valstack;
    heap.valstack_top_ptr = &vm.valstack_top;
    heap.curr_thread = vm;
    heap.mark_activations_fn = &vm_mark_activations;

    // Create global environment
    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) {
        libc::free(vs_raw);
        libc::free(raw);
        return VM_ERROR~;
    }
    vm.global_env = global;

    // Register the global environment's bindings object as a GC root
    // so that mark-and-sweep never collects the global scope.
    heap.register_gc_root(global.bindings.as_header());

    // Register built-ins
    if (!builtins::register_builtins(global, heap)) {
        env::env_destroy(heap, global);
        libc::free(vs_raw);
        libc::free(raw);
        return VM_ERROR~;
    }

    vm.activation_count = 0;
    vm.has_error = false;
    vm.throw_pending = false;
    vm.current_func = null;
    vm.curr_pc = null;

    heap.call_handler_fn = &vm_call_handler_fn_impl;
    heap.call_fn = &vm_call_fn_impl;
    heap.microtask_after_fn = &builtins::promise_microtask_after;

    return vm;
}

/// Destroy a VM and release all owned resources.
fn void vm_destroy(Vm* vm) {
    if (vm == null) return;
    // env_destroy is NOT called here because all HObjects are tracked
    // in the heap_allocated linked list and freed by heap.destroy().
    // Calling env_destroy would double-free those tracked objects.
    if (vm.valstack != null) {
        libc::free(vm.valstack);
    }
    // Clear heap's valstack GC root pointers
    vm.heap.valstack_base = null;
    vm.heap.valstack_top_ptr = null;
    libc::free(vm);
}

/// Reset a VM for reuse with a freshly-reset heap.
/// Call heap.reset() first, then vm_reset() to reinitialise global env and
/// builtins. The valstack backing buffer is reused; only its top is rewound.
/// Returns false on failure (treat like vm_create failing).
fn bool vm_reset(Vm* vm, Heap* heap) {
    if (vm == null || heap == null) { return false; }

    // Rewind the value stack and clear stale TVal refs — after heap.reset(),
    // all HObject*/HString* are freed, so any lingering TVal heap pointer
    // would cause use-after-free when overwritten.
    for (uint i = 0; i < vm.valstack_size; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top    = vm.valstack;
    vm.valstack_bottom = vm.valstack;

    // Clear stale TVal/pointer refs in activations — all heap objects from the
    // previous run are freed, so this_binding, tv_func, etc. are dangling.
    for (uint i = 0; i < vm.activation_count; i++) {
        vm.activations[i].this_binding.set_undefined();
        vm.activations[i].tv_func.set_undefined();
        vm.activations[i].func = null;
        vm.activations[i].parent = null;
        vm.activations[i].var_env = null;
        vm.activations[i].lex_env = null;
        vm.activations[i].cat = null;
        vm.activations[i].new_target = null;
    }
    vm.activation_count = 0;
    vm.has_error        = false;
    vm.throw_pending    = false;
    vm.throw_value.set_undefined();
    vm.current_func     = null;
    vm.curr_pc          = null;
    vm.return_val.set_undefined();

    // Update heap's valstack GC root pointers
    vm.heap.valstack_base = vm.valstack;
    vm.heap.valstack_top_ptr = &vm.valstack_top;
    vm.heap.curr_thread = vm;
    vm.heap.mark_activations_fn = &vm_mark_activations;

    // Fresh global environment on the reset heap
    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) { return false; }
    vm.global_env = global;

    heap.register_gc_root(global.bindings.as_header());

    if (!builtins::register_builtins(global, heap)) { return false; }

    return true;
}

// ============================================================================
// Main execution loop
// ============================================================================

/// Execute a compiled function from the start.
/// Matches duk_js_execute_bytecode() outer/inner pattern.
/// Implementation of Heap.call_fn — calls a JS function with N arguments through the VM.
fn TVal vm_call_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();

    // Case 1: lightfunc — dispatch directly via BuiltinContext
    if (func.is_lightfunc()) {
        uint fn_idx = (uint)(usz)func.get_heapptr();

        // Temporary register layout: [this, arg0, arg1, ...]
        // Use stack-allocated array for up to 8 args
        uint total = 1 + nargs;
        if (total > 16) total = 16;

        TVal[16] temp_regs;
        temp_regs[0] = this_val;
        for (uint i = 0; i < nargs && i < 16; i++) {
            temp_regs[1 + i] = args[i];
        }

        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = (ushort)nargs;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = null;

        builtins::dispatch_builtin(fn_idx, &ctx);
        return *ctx.result;
    }

    // Case 2: HObject with builtin_fn_index — dispatch via BuiltinContext
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
            uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;

            uint total = 1 + nargs;
            if (total > 16) total = 16;

            TVal[16] temp_regs;
            temp_regs[0] = this_val;
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[1 + i] = args[i];
            }

            builtins::BuiltinContext ctx;
            ctx.vm = vm;
            ctx.regs = &temp_regs;
            ctx.base_reg = 1;
            ctx.argc = (ushort)nargs;
            ctx.result = &temp_regs[0];
            ctx.heap = vm.heap;
            ctx.this_val = this_val;
            ctx.is_constructor = false;
            ctx.needs_re_dispatch = false;
            ctx.re_nargs = 0;
            ctx.global_env = vm.global_env;
            ctx.should_throw = false;
            ctx.callee_obj = hobj;

            builtins::dispatch_builtin(fn_idx, &ctx);
            return *ctx.result;
        }
    }

    // Case 3: compiled function on HObject
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && (*hobj.extra_ptr()).func.comp_func != null) {
            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;
            uint nregs = target.num_regs;

            // Grow the valstack first (while activation_count is still the
            // caller's, so ensure_valstack_grow relocates all live pointers).
            // The callback frame is placed at the current valstack_top, above
            // all live caller registers — they are never touched.
            if (!ensure_valstack(vm, nregs)) {
                return undef;
            }

            // Save current VM state (after potential realloc)
            uint saved_act_count = vm.activation_count;
            TVal* saved_valstack_bottom = vm.valstack_bottom;
            TVal* saved_valstack_top = vm.valstack_top;
            TVal* saved_valstack = vm.valstack;
            CompiledFunction* saved_current_func = vm.current_func;

            Activation[MAX_CALLS] saved_acts;
            libc::memcpy(&saved_acts, &vm.activations, saved_act_count * Activation::size);

            TVal* frame = vm.valstack_top;

            // Set up activation[0] for the function
            Activation* act = &vm.activations[0];
            vm.activation_count = 1;
            EnvRecord* cfn_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_cfn = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { cfn_var_env = fv_cfn; }
            act.func = target;
            act.parent = null;
            act.var_env = cfn_var_env;
            act.lex_env = cfn_var_env;
            act.cat = null;
            act.curr_pc = target.code;
            act.bottom = frame;
            act.retval = null;
            act.flags = ACT_FLAG_STRICT;
            act.max_heap_reg = 0;
            act.caller_valstack_top = frame + nregs;
            // Raw assign: this_val is kept alive by the caller for the duration
            // of the call; the previous activation[0].this_binding bits are
            // restored verbatim below, so refcounts stay balanced.
            act.this_binding = this_val;

            // Initialize registers and copy args (slots are fresh — raw init)
            for (uint i = 0; i < nregs; i++) {
                frame[i].set_undefined();
            }
            uint copy_n = nargs < nregs ? nargs : nregs;
            for (uint i = 0; i < copy_n; i++) {
                vm.heap.tval_copy_ref(&frame[i], &args[i]);
            }
            vm.valstack_top = frame + nregs;
            vm.valstack_bottom = frame;
            vm.current_func = target;

            // Create arguments object if the function references 'arguments'
            if (target.uses_arguments()) {
                HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj = args_obj_raw) {
                    // Store arguments in dense array_part (avoids O(argc) string key allocs)
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj.set_array_idx(ai, frame[ai]);
                    }
                    // ES5 §10.6: [[Prototype]] is Object.prototype
                    args_obj.prototype = vm.heap.object_proto;
                    // ES5 §10.6: define 'callee' property (writable, non-enumerable, configurable)
                    HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key != null) {
                        TVal callee_tv;
                        callee_tv.set_object(hobj);
                        args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                    }
                    // ES5 §10.6: define 'length' property (writable, non-enumerable, configurable)
                    HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key != null) {
                        TVal length_tv;
                        length_tv.set_fastint((long)nargs);
                        args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                    }
                    // Declare 'arguments' in the function's var_env
                    HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name != null) {
                        TVal args_tv;
                        args_tv.set_object(args_obj);
                        env::env_declare(act.var_env, args_name, args_tv);
                    }
                }
            }

            // Run the function via Vm.run (skip Vm.execute init — we already set up state)
            TVal? result_opt = Vm.run(vm);
            TVal result;
            if (try r = result_opt) {
                result = r;
            } else {
                result = vm.return_val;
            }

            // If the nested run reallocated the valstack, relocate the saved
            // absolute pointers by the same delta (the saved snapshot was not
            // covered by ensure_valstack_grow's relocation pass).
            long reloc = (char*)vm.valstack - (char*)saved_valstack;
            if (reloc != 0) {
                saved_valstack_bottom = (TVal*)((char*)saved_valstack_bottom + reloc);
                saved_valstack_top = (TVal*)((char*)saved_valstack_top + reloc);
                for (uint i = 0; i < saved_act_count; i++) {
                    saved_acts[i].bottom = (TVal*)((char*)saved_acts[i].bottom + reloc);
                    if (saved_acts[i].retval != null) {
                        saved_acts[i].retval = (TVal*)((char*)saved_acts[i].retval + reloc);
                    }
                    if (saved_acts[i].caller_valstack_top != null) {
                        saved_acts[i].caller_valstack_top = (TVal*)((char*)saved_acts[i].caller_valstack_top + reloc);
                    }
                }
            }

            // Restore VM state (caller registers were never touched)
            vm.activation_count = saved_act_count;
            vm.current_func = saved_current_func;
            libc::memcpy(&vm.activations, &saved_acts, saved_act_count * Activation::size);
            vm.valstack_bottom = saved_valstack_bottom;
            vm.valstack_top = saved_valstack_top;

            // Drain microtasks after callback execution
            vm.heap.drain_microtasks((void*)vm);

            return result;
        }
    }

    return undef;
}

/// Implementation of Heap.call_handler_fn — delegates to vm_call_fn_impl.
fn TVal vm_call_handler_fn_impl(void* vm_ptr, TVal handler, TVal* arg) {
    TVal undef;
    undef.set_undefined();
    return vm_call_fn_impl(vm_ptr, handler, arg, 1, undef);
}

fn TVal? Vm.execute(Vm* vm, CompiledFunction* func) {
    // Set up initial activation (matches outer executor setup)
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = vm.global_env;
    entry_act.lex_env = vm.global_env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;  // Points into bytecode
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    // ES5 §10.4.1: at the top level of a script, the global `this` is the
    // global object in non-strict mode, and `undefined` in strict mode.
    entry_act.flags = func.is_strict() ? ACT_FLAG_STRICT : 0;

    TVal this_val;
    if (func.is_strict()) {
        this_val.set_undefined();
    } else {
        this_val.set_object(vm.global_env.bindings);
    }
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    // Allocate value stack slots for the function (nregs = total register count)
    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    // Initialize registers to undefined
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    // The top-level activation has no caller, but caller_valstack_top must be
    // set to a valid value so that RET restoring back to this activation
    // (after a compiled callee returns) doesn't corrupt vm.valstack_top.
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    // Drain microtask queue after top-level script execution
    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute the bytecode dispatch loop. Assumes activation stack and registers
/// are already set up by the caller.
fn TVal? Vm.run(Vm* vm) {
    Instruction* code_base;
    uint code_count;
    TVal* constants;
    Activation* act;
    Instruction* curr_pc;
    bool needs_restart;
    hobject::ICEntry* ic_base;
    hobject::VarICEntry* var_ic_base;
    uint nregs;

    // Outer restart loop: on ECMAScript-to-ECMAScript calls, reload state
    needs_restart = true;
    for (;;) {
        if (!needs_restart) {
            break;
        }
        needs_restart = false;

        act = &vm.activations[vm.activation_count - 1];
        vm.current_func = (CompiledFunction*)act.func;
        code_base = vm.current_func.code;
        code_count = vm.current_func.code_count;
        constants = vm.current_func.constants;
        ic_base = (hobject::ICEntry*)vm.current_func.ic_entries;
        var_ic_base = (hobject::VarICEntry*)vm.current_func.var_ic_entries;
        nregs = vm.current_func.num_regs;

        curr_pc = act.curr_pc;
        Instruction* code_end = code_base + code_count;

        TVal* regs_base = act.bottom;

        // Inner dispatch loop
        for (; !needs_restart; ) {
            if (curr_pc >= code_end) {
                // Inline handle_return for fall-off-end — avoids function call overhead.
                Activation* callee_act = &vm.activations[vm.activation_count - 1];
                TVal* callee_result = callee_act.retval;

                // Decref callee registers before popping
                decref_callee_regs(vm, callee_act);

                vm.activation_count--;

                if (vm.activation_count == 0) {
                    TVal undef_val;
                    undef_val.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                    return vm.return_val;
                }

                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;

                TVal undef_val;
                undef_val.set_undefined();
                TVal final_val = undef_val;
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (!final_val.is_object() || final_val.get_heapptr() == null) {
                        if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                            final_val = callee_act.this_binding;
                        }
                    }
                }
                vm.heap.tval_copy_ref(callee_result, &final_val);

                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;

                act = caller_act;
                vm.valstack_top = caller_act.caller_valstack_top;
                if (caller_func != vm.current_func) {
                    vm.current_func = caller_func;
                    code_base = caller_func.code;
                    code_count = caller_func.code_count;
                    code_end = code_base + code_count;
                    constants = caller_func.constants;
                    ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                    var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                    nregs = caller_func.num_regs;
                }
                curr_pc = act.curr_pc;
                regs_base = act.bottom;
                continue;
            }

            Instruction insn = *curr_pc;
            curr_pc++;

            Opcode op = insn.op;

            TVal* ra = regs_base + ((uint)insn.a);
            TVal* rb = regs_base + ((uint)insn.b);
            TVal* rc = regs_base + ((uint)insn.c);

        switch (op) {

        // === LOAD / STORE ===

        case Opcode.LDREG:
            // Fast path: if source is not a heap ref (fastint, undefined, etc.),
            // skip full refcounting — only decref dst if it held a heap pointer.
            if (!rb.is_heap_allocated()) {
                if (ra.is_heap_allocated()) {
                    vm.heap.decref_tval(ra);
                }
                *ra = *rb;
            } else {
                vm.heap.tval_copy_ref(ra, rb);
                track_heap_store(act, ra, (uint)insn.a);
            }
            break;

        case Opcode.LDCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                vm.heap.tval_copy_ref(ra, &constants[bc]);
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.LDINT:
            ra.set_fastint((long)insn.get_sbc());
            break;

        case Opcode.LDINTX: {
            long ix_high = ra.get_fastint();
            ra.set_fastint((ix_high << 16) | (long)insn.get_bc());
            break;
        }

        case Opcode.LDUNDEF:
            ra.set_undefined();
            break;

        case Opcode.LDNULL:
            ra.set_null();
            break;

        case Opcode.LDTRUE:
            ra.set_boolean(true);
            break;

        case Opcode.LDFALSE:
            ra.set_boolean(false);
            break;

        case Opcode.LDTHIS:
            vm.heap.tval_copy_ref(ra, &act.this_binding);
            track_heap_store(act, ra, (uint)insn.a);
            break;

        // === ARITHMETIC ===

        case Opcode.ADD: {
            // ES5 §11.6.1: ToPrimitive both, then string concat or numeric add
            // Fast path: FASTINT + FASTINT — most common in arithmetic benchmarks.
            // Check this BEFORE OBJECT/STRING to avoid unnecessary tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                long sum = rb.get_fastint() + rc.get_fastint();
                if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
                    ra.set_fastint(sum);
                } else {
                    ra.set_number((double)sum);
                }
                break;
            }
            // Fast path: STRING + FASTINT or FASTINT + STRING
            // Format the integer directly into the concat buffer, avoiding
            // the intermediate HString allocation for the integer.
            if ((rb.is_string() && rc.is_fastint()) || (rb.is_fastint() && rc.is_string())) {
                HString* str;
                long int_val;
                if (rb.is_string()) {
                    str = (HString*)rb.get_heapptr();
                    int_val = rc.get_fastint();
                } else {
                    str = (HString*)rc.get_heapptr();
                    int_val = rb.get_fastint();
                }
                if (str != null) {
                    char[32] int_buf;
                    int int_len = hstring::int_to_buf(int_val, &int_buf, 32);
                    if (int_len > 0) {
                        uint s_len = str.blen;
                        uint total = s_len + (uint)int_len;
                        char[544] stack_buf;
                        char* buf;
                        bool heap_allocated = false;
                        if (total <= 544) {
                            buf = &stack_buf;
                        } else {
                            buf = (char*)libc::malloc(total);
                            if (buf == null) { ra.set_undefined(); break; }
                            heap_allocated = true;
                        }
                        if (rb.is_string()) {
                            libc::memcpy(buf, str.get_cstr(), s_len);
                            libc::memcpy(buf + s_len, &int_buf, (usz)int_len);
                        } else {
                            libc::memcpy(buf, &int_buf, (usz)int_len);
                            libc::memcpy(buf + int_len, str.get_cstr(), s_len);
                        }
                        // Skip interning for accumulator (ra == source register),
                        // intern for new strings that may be used as property keys.
                        bool is_accum = (ra == rb || ra == rc);
                        if (is_accum) {
                            uint hash = vm.heap.hash_string(buf[:total]);
                            HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                            if (heap_allocated) libc::free(buf);
                            if (try s = maybe_s) {
                                vm.heap.set_reg_string(ra, s);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            HString* interned = intern_string(vm, buf[:total]);
                            if (heap_allocated) libc::free(buf);
                            vm.heap.set_reg_string(ra, interned);
                        }
                        break;
                    }
                }
                // Fall through to generic path if str is null or int_to_buf failed
            }
            TVal prim_b = *rb;
            TVal prim_c = *rc;
            // ES5 §11.6.1: + operator uses ToPrimitive with no hint (default "number")
            if (rb.get_tag() == OBJECT) { prim_b = to_primitive_value(vm, rb, false); }
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            if (rc.get_tag() == OBJECT) { prim_c = to_primitive_value(vm, rc, false); }
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            TValTag pt_b = prim_b.get_tag();
            TValTag pt_c = prim_c.get_tag();
            if (pt_b == STRING || pt_c == STRING) {
                HString*? left_str = vm_to_string(vm, &prim_b);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                    break;
                }
                HString*? right_str = vm_to_string(vm, &prim_c);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                    break;
                }
                if (try ls = left_str && try rs = right_str) {
                    uint a_len = ls.blen;
                    uint b_len = rs.blen;
                    uint total = a_len + b_len;

                    // Use stack buffer for small strings, heap for large
                    char[512] stack_buf;
                    char* buf;
                    bool heap_allocated = false;
                    if (total <= 512) {
                        buf = &stack_buf;
                    } else {
                        buf = (char*)libc::malloc(total);
                        if (buf == null) { ra.set_undefined(); break; }
                        heap_allocated = true;
                    }

                    // Copy both halves directly into buffer
                    if (a_len > 0) {
                        libc::memcpy(buf, ls.get_cstr(), a_len);
                    }
                    if (b_len > 0) {
                        libc::memcpy(buf + a_len, rs.get_cstr(), b_len);
                    }

                    // Skip interning for accumulator (ra == source register),
                    // intern for new strings that may be used as property keys.
                    bool is_accum = (ra == rb || ra == rc);
                    if (is_accum) {
                        uint hash = vm.heap.hash_string(buf[:total]);
                        HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                        if (heap_allocated) libc::free(buf);
                        if (try s = maybe_s) {
                            vm.heap.set_reg_string(ra, s);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        HString* interned = intern_string(vm, buf[:total]);
                        if (heap_allocated) libc::free(buf);
                        vm.heap.set_reg_string(ra, interned);
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                double add_b = vm_to_number(vm,&prim_b);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                double add_c = vm_to_number(vm,&prim_c);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(add_b + add_c);
            }
        }

        case Opcode.SUB:
            if (rb.is_fastint() && rc.is_fastint()) {
                long diff = rb.get_fastint() - rc.get_fastint();
                if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
                    ra.set_fastint(diff);
                } else {
                    ra.set_number((double)diff);
                }
            } else {
                double sub_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double sub_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(sub_b - sub_c);
            }
            break;

        case Opcode.MUL:
            if (rb.is_fastint() && rc.is_fastint()) {
                // Use 64-bit multiply and check overflow
                long mul_result = rb.get_fastint() * rc.get_fastint();
                if (mul_result >= types::FASTINT_MIN && mul_result <= types::FASTINT_MAX) {
                    ra.set_fastint(mul_result);
                } else {
                    ra.set_number((double)mul_result);
                }
            } else {
                double mul_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double mul_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(mul_b * mul_c);
            }
            break;

        case Opcode.DIV: {
            double div_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            double div_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_number(div_b / div_c);
            break;
        }

        case Opcode.MOD:
            if (rb.is_fastint() && rc.is_fastint() && rc.get_fastint() != 0) {
                long mod_result = rb.get_fastint() % rc.get_fastint();
                if (mod_result == 0 && rb.get_fastint() < 0) {
                    // -1 % 1 → -0: sign of zero matches dividend per ES5 §11.5.3
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(mod_result);
                }
            } else {
                double mod_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double mod_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number((mod_b % mod_c));
            }
            break;

        case Opcode.EXP: {
            double exp_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            double exp_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_number(math::pow(exp_b, exp_c));
            break;
        }

        // === UNARY ===

        case Opcode.UNP:
            if (rb.is_fastint()) {
                // Unary + on FASTINT stays FASTINT
                ra.set_fastint(rb.get_fastint());
            } else {
                double unp_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(unp_b);
            }
            break;

        case Opcode.UNM:
            if (rb.is_fastint()) {
                long unm_val = rb.get_fastint();
                if (unm_val == 0) {
                    // -0 must be NUMBER, not FASTINT (integers have no -0)
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(-unm_val);
                }
            } else {
                double unm_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(-unm_b);
            }
            break;

        case Opcode.BNOT:
            // Bitwise NOT always produces Int32, always fits in FASTINT
        {
            int bnot_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(~bnot_b));
            break;
        }

        case Opcode.LNOT:
            ra.set_boolean(!is_truthy(rb));
            break;

        case Opcode.TYPEOF: {
            HString* ts = typeof_string(vm, rb);
            vm.heap.set_reg_string(ra, ts);
            break;
        }

        case Opcode.VOID:
            ra.set_undefined();
            break;

        // === IN-PLACE FASTINT ++ / -- ===
        // Fused LDINT 1 + ADD/SUB pair. Hot for loop counters and similar.
        case Opcode.INC:
            if (ra.is_fastint()) {
                ra.set_fastint(ra.get_fastint() + 1L);
            } else {
                // Slow path: convert to number, increment, store back
                double d = vm_to_number(vm,ra);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(d + 1.0);
            }
            break;
        case Opcode.DEC:
            if (ra.is_fastint()) {
                ra.set_fastint(ra.get_fastint() - 1L);
            } else {
                double d = vm_to_number(vm,ra);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(d - 1.0);
            }
            break;

        // === VARIABLE ARITHMETIC FUSION ===
        // Fused GETVAR + INC/PUTVAR.  Reads a variable by name, increments
        // or decrements it, and writes it back in a single dispatch.
        // Hot for loop counters: `for (i = 0; i < N; i++) { ... }`
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR: {
            uint bc = insn.get_bc();
            if (bc >= vm.current_func.const_count) break;
            TVal name_val = constants[bc];
            if (!name_val.is_string()) break;
            void* key = name_val.get_heapptr();
            bool is_inc = (op == Opcode.INC_VAR);

            // --- Variable IC fast path (read + op + write) ---
            if (var_ic_base != null) {
                uint pc_off = (uint)(curr_pc - 1 - code_base);
                hobject::VarICEntry* vic = var_ic_base + pc_off;
                if (vic.env != null && vic.key == key && vic.search_head == (void*)act.lex_env) {
                    HObject* b = (HObject*)vic.bindings;
                    if (b.shape_id == vic.shape_id
                        && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                        TVal old_val = b.prop_values()[vic.prop_idx];
                        if (!env::is_tdz_sentinel(&old_val)
                            && b.get_prop_flags(vic.prop_idx).writable) {
                            if (old_val.is_fastint()) {
                                long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                                if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                    b.prop_values()[vic.prop_idx].set_fastint(v);
                                    ra.set_fastint(v);
                                } else {
                                    b.prop_values()[vic.prop_idx].set_number((double)v);
                                    ra.set_number((double)v);
                                }
                            } else {
                                double d = vm_to_number(vm,&old_val);
                                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                                double new_d = d + (is_inc ? 1.0 : -1.0);
                                b.prop_values()[vic.prop_idx].set_number(new_d);
                                ra.set_number(new_d);
                            }
                            break;
                        }
                        vic.env = null;
                    } else {
                        vic.env = null;
                    }
                }
            }

            // --- Slow path: full env walk + op + write ---
            bool found = false;
            EnvRecord* ic_env = null;
            int ic_prop_idx = -1;
            EnvRecord* cur = act.lex_env;
            while (cur != null) {
                int idx = cur.bindings.find_prop_idx(key);
                if (idx >= 0) {
                    TVal old_val = cur.bindings.prop_values()[idx];
                    if (env::is_tdz_sentinel(&old_val)) {
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.ref_err_proto;
                            char[types::ERROR_MSG_BUF] ebuf;
                            int elen = libc::snprintf(&ebuf, types::ERROR_MSG_BUF,
                                                      "%s is not defined", name_hstr.get_cstr());
                            if (elen > 0 && elen < types::ERROR_MSG_BUF) {
                                HString* emsg = intern_string(vm, ebuf[:elen]);
                                TVal emsg_val;
                                emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    if (!cur.bindings.get_prop_flags((uint)idx).writable) {
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            char[types::ERROR_MSG_BUF] ebuf;
                            int elen = libc::snprintf(&ebuf, types::ERROR_MSG_BUF,
                                                      "Assignment to constant variable '%s'",
                                                      name_hstr.get_cstr());
                            if (elen > 0 && elen < types::ERROR_MSG_BUF) {
                                HString* emsg = intern_string(vm, ebuf[:elen]);
                                TVal emsg_val;
                                emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    if (old_val.is_fastint()) {
                        long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                        if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                            cur.bindings.prop_values()[idx].set_fastint(v);
                            ra.set_fastint(v);
                        } else {
                            cur.bindings.prop_values()[idx].set_number((double)v);
                            ra.set_number((double)v);
                        }
                    } else {
                        double d = vm_to_number(vm,&old_val);
                        if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                        double new_d = d + (is_inc ? 1.0 : -1.0);
                        cur.bindings.prop_values()[idx].set_number(new_d);
                        ra.set_number(new_d);
                    }
                    found = true;
                    ic_env = cur;
                    ic_prop_idx = idx;
                    break;
                }
                cur = cur.parent;
            }

            if (!found) {
                // var_env fallback (with-blocks)
                if (act.lex_env != act.var_env) {
                    TVal? result = env::env_get(act.var_env, key);
                    if (try v2 = result) {
                        TVal new_val;
                        if (v2.is_fastint()) {
                            long v = v2.get_fastint() + (is_inc ? 1L : -1L);
                            if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                new_val.set_fastint(v);
                            } else {
                                new_val.set_number((double)v);
                            }
                        } else {
                            double d = vm_to_number(vm,&v2);
                            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                            new_val.set_number(d + (is_inc ? 1.0 : -1.0));
                        }
                        env::env_put(act.var_env, key, new_val);
                        vm.heap.tval_copy_ref(ra, &new_val);
                        found = true;
                    }
                }
                if (!found) {
                    // ReferenceError
                    HString* name_hstr = (HString*)key;
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.ref_err_proto;
                        char[types::ERROR_MSG_BUF] ebuf;
                        int elen = libc::snprintf(&ebuf, types::ERROR_MSG_BUF,
                                                  "%s is not defined", name_hstr.get_cstr());
                        if (elen > 0 && elen < types::ERROR_MSG_BUF) {
                            HString* emsg = intern_string(vm, ebuf[:elen]);
                            TVal emsg_val;
                            emsg_val.set_string(emsg);
                            HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val;
                        err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
            }

            // Populate IC for next time
            if (found && var_ic_base != null && ic_env != null) {
                uint pc_off = (uint)(curr_pc - 1 - code_base);
                hobject::VarICEntry* vic = var_ic_base + pc_off;
                vic.env = ic_env;
                vic.bindings = ic_env.bindings;
                vic.shape_id = ic_env.bindings.shape_id;
                vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                vic.prop_idx = (ushort)ic_prop_idx;
                if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                vic.key = key;
                if (key != null) { ((types::HeapHeader*)key).incref(); }
                vic.search_head = (void*)act.lex_env;
            }
            break;
        }

        // === BITWISE ===

        case Opcode.BAND:
            // Bitwise ops always produce Int32, always fit in FASTINT
        {
            int band_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int band_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(band_b & band_c));
            break;
        }

        case Opcode.BOR:
        {
            int bor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int bor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(bor_b | bor_c));
            break;
        }

        case Opcode.BXOR:
        {
            int bxor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int bxor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(bxor_b ^ bxor_c));
            break;
        }

        case Opcode.SHL:
        {
            int shl_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int shl_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(shl_b << (shl_c & 0x1F)));
            break;
        }

        case Opcode.SHR:
        {
            int shr_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int shr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(shr_b >> (shr_c & 0x1F)));
            break;
        }

        case Opcode.USHR:
        {
            uint ushr_b = (uint)toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int  ushr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(ushr_b >> (ushr_c & 0x1F)));
            break;
        }

        // === COMPARISON ===

        case Opcode.EQ:
            ra.set_boolean(abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            break;

        case Opcode.NEQ:
            ra.set_boolean(!abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            break;

        case Opcode.SEQ: {
            // Fast path: FASTINT === FASTINT — most common in loop counters and
            // arithmetic benchmarks. Short-circuit before full tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                ra.set_boolean(rb.get_fastint() == rc.get_fastint());
                break;
            }
            bool seq_r = false;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: seq_r = true; break;
                    case NULL_VAL:  seq_r = true; break;
                    case BOOLEAN:   seq_r = (rb.get_boolean() == rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            seq_r = false;
                        } else {
                            seq_r = (rb.get_number() == rc.get_number());
                        }
                        break;
                    case FASTINT:   seq_r = (rb.get_fastint() == rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        seq_r = sa != null && sb != null && sa.equals_hstring(sb);
                        break;
                    }
                    case OBJECT:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case LIGHTFUNC: seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case POINTER:   seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case BUFFER:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                seq_r = (nb == nc);
            }
            ra.set_boolean(seq_r);
            break;
        }

        case Opcode.SNEQ: {
            // Fast path: FASTINT !== FASTINT — short-circuit before full tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                ra.set_boolean(rb.get_fastint() != rc.get_fastint());
                break;
            }
            bool sneq_r = true;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: sneq_r = false; break;
                    case NULL_VAL:  sneq_r = false; break;
                    case BOOLEAN:   sneq_r = (rb.get_boolean() != rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            sneq_r = true;
                        } else {
                            sneq_r = (rb.get_number() != rc.get_number());
                        }
                        break;
                    case FASTINT:   sneq_r = (rb.get_fastint() != rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        sneq_r = !(sa != null && sb != null && sa.equals_hstring(sb));
                        break;
                    }
                    case OBJECT:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case LIGHTFUNC: sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case POINTER:   sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case BUFFER:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                sneq_r = (nb != nc);
            }
            ra.set_boolean(sneq_r);
            break;
        }

        case Opcode.LT: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double lt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double lt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = lt_b < lt_c;
            }
            ra.set_boolean(result);
            break;
        }

        case Opcode.LE: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double le_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double le_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = le_b <= le_c;
            }
            ra.set_boolean(result);
            break;
        }

        case Opcode.GT: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double gt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double gt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = gt_b > gt_c;
            }
            ra.set_boolean(result);
            break;
        }

        case Opcode.GE: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double ge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double ge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = ge_b >= ge_c;
            }
            ra.set_boolean(result);
            break;
        }

        // === FUSED COMPARE-AND-BRANCH ===
        // Each op replicates the corresponding compare's exact semantics, then
        // branches if the result is FALSE (i.e. branches when condition does NOT hold).
        // Offset in A (signed 8-bit, cast via char) is relative to the already-
        // incremented pc (same convention as IF_FALSE).
        // NaN: !(NaN op x) is always true, so the branch IS taken — correct because
        // we negate the same compare result that IF_FALSE would have tested.

        case Opcode.JMP_NLT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double jnlt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jnlt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jnlt_b < jnlt_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_NLE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double jnle_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jnle_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jnle_b <= jnle_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_NGT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double jngt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jngt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jngt_b > jngt_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_NGE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double jnge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jnge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jnge_b >= jnge_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_LT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double jlt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jlt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jlt_b < jlt_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_LE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double jle_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jle_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jle_b <= jle_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_GT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double jgt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jgt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jgt_b > jgt_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_GE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double jge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jge_b >= jge_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.LOOP_COMPILED: {
            // Header of a compiled loop. BC = total_skip.
            // curr_pc already points to header_pc+1.
            // Success: JIT ran the entire loop; advance by total_skip-1 to skip past JMP.
            // Fallback: execute saved_insn semantics and continue normally.
            uint loop_id = insn.a;
            int  total_skip = (int)insn.get_bc();
            jit::CompiledLoopTable* tbl = (jit::CompiledLoopTable*)vm.current_func.jit_data;
            if (tbl != null && loop_id < tbl.count) {
                jit::CompiledLoop* cloop = &tbl.entries[loop_id];
                if (!cloop.initialized) {
                    jit::jit_init_loop(cloop, vm.current_func, act.lex_env);
                }
                if (cloop.initialized && jit::jit_run_loop(cloop)) {
                    if (--vm.heap.bwd_gc_budget == 0) {
                        if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
                        vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
                    }
                    curr_pc = curr_pc + (total_skip - 1);
                    break;
                }
                // Fallback: execute saved_insn (the original header instruction)
                // so the loop body runs correctly for this iteration.
                {
                    Instruction si = cloop.saved_insn;
                    Opcode si_op = si.op;
                    TVal* si_ra = regs_base + (uint)si.a;

                    switch (si_op) {
                        case Opcode.INC_VAR:
                        case Opcode.DEC_VAR: {
                            uint si_bc = si.get_bc();
                            if (si_bc < vm.current_func.const_count) {
                                TVal nv2 = constants[si_bc];
                                if (nv2.is_string()) {
                                    void* key2 = nv2.get_heapptr();
                                    bool is_inc2 = (si_op == Opcode.INC_VAR);
                                    EnvRecord* cur2 = act.lex_env;
                                    while (cur2 != null) {
                                        int idx2 = cur2.bindings.find_prop_idx(key2);
                                        if (idx2 >= 0) {
                                            TVal old2 = cur2.bindings.prop_values()[idx2];
                                            if (!env::is_tdz_sentinel(&old2) && cur2.bindings.get_prop_flags((uint)idx2).writable) {
                                                if (old2.is_fastint()) {
                                                    long v2 = old2.get_fastint() + (is_inc2 ? 1L : -1L);
                                                    if (v2 >= types::FASTINT_MIN && v2 <= types::FASTINT_MAX) {
                                                        cur2.bindings.prop_values()[idx2].set_fastint(v2);
                                                        si_ra.set_fastint(v2);
                                                    } else {
                                                        cur2.bindings.prop_values()[idx2].set_number((double)v2);
                                                        si_ra.set_number((double)v2);
                                                    }
                                                }
                                            }
                                            break;
                                        }
                                        cur2 = cur2.parent;
                                    }
                                }
                            }
                        }
                        case Opcode.GETVAR: {
                            uint si_bc = si.get_bc();
                            if (si_bc < vm.current_func.const_count) {
                                TVal nv2 = constants[si_bc];
                                if (nv2.is_string()) {
                                    void* key2 = nv2.get_heapptr();
                                    EnvRecord* cur2 = act.lex_env;
                                    while (cur2 != null) {
                                        int idx2 = cur2.bindings.find_prop_idx(key2);
                                        if (idx2 >= 0) {
                                            TVal v2 = cur2.bindings.prop_values()[idx2];
                                            if (!env::is_tdz_sentinel(&v2)) {
                                                vm.heap.tval_copy_ref(si_ra, &v2);
                                            }
                                            break;
                                        }
                                        cur2 = cur2.parent;
                                    }
                                }
                            }
                        }
                        case Opcode.LDINT: {
                            si_ra.set_fastint((long)si.get_sbc());
                        }
                        case Opcode.LDREG: {
                            TVal* si_rb = regs_base + (uint)si.b;
                            if (!si_rb.is_heap_allocated()) {
                                *si_ra = *si_rb;
                            } else {
                                vm.heap.tval_copy_ref(si_ra, si_rb);
                            }
                        }
                        default: break;
                    }
                }
                // Continue from header+1 — interpreter executes remaining body normally.
                break;
            }
            break;
        }

        case Opcode.PROLOGUE_COMPILED: {
            // Fast parameter binding superinstruction. A = param_count.
            // Skips the consecutive DECLVAR instructions by advancing PC.
            // Falls back to normal instruction-by-instruction execution if needed.
            uint param_count = insn.a;
            // Skip param_count DECLVAR instructions
            if (param_count > 0) {
                curr_pc = curr_pc + param_count - 1;
            }
            break;
        }

        case Opcode.INSTANCEOF: {
            // ES5 §11.8.6: RelationalExpression instanceof ShiftExpression
            // ra may alias rb (compiler optimization), so read rb before writing ra.
            TVal lval = *rb;
            TVal rval = *rc;
            ra.set_boolean(false);

            if (rval.is_lightfunc()) {
                // LIGHTFUNC builtins are callable; look up their prototype
                uint fn_idx = (uint)(usz)rval.get_heapptr();
                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                if (proto_obj != null && lval.is_object()) {
                    HObject* lbh = (HObject*)lval.get_heapptr();
                    if (lbh.is_prototype_of(proto_obj)) {
                        ra.set_boolean(true);
                    }
                }
                break;
            }

            if (!rval.is_object()) {
                // TypeError: right-hand side must be an object
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* msg_val = intern_string(vm, "Right-hand side of instanceof is not an object");
                    TVal msg_tv;
                    msg_tv.set_string(msg_val);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* rfunc = (HObject*)rval.get_heapptr();
            if (rfunc == null || !rfunc.is_callable()) {
                // TypeError: right-hand side must be callable
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* msg_val = intern_string(vm, "Right-hand side of instanceof is not callable");
                    TVal msg_tv;
                    msg_tv.set_string(msg_val);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // ES6 §12.10.4: Check Symbol.hasInstance on the constructor
            if (vm.heap.hasinstance_symbol != null) {
                HString* hasinst_key = vm.heap.hasinstance_symbol;
                TVal? hasinst_val = rfunc.get_prop_proto(hasinst_key);
                if (try hasinst_fn = hasinst_val) {
                    bool hasinst_callable = hasinst_fn.is_lightfunc() ||
                        (hasinst_fn.is_object() && hasinst_fn.get_heapptr() != null &&
                         ((HObject*)hasinst_fn.get_heapptr()).is_callable());
                    if (hasinst_callable) {
                        // Call @@hasInstance with this=rval, arg=lval
                        TVal result = vm.heap.call_fn(vm, hasinst_fn, &lval, 1, rval);
                        if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                        ra.set_boolean(builtins::builtin_to_boolean(&result));
                        break;
                    }
                }
            }

            // §15.3.5.3 step 1: If Type(lval) is not Object → false
            if (!lval.is_object()) {
                break;
            }

            // Get rval.prototype
            HString* proto_key_str = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal proto_val = get_prop_with_proto(rfunc, proto_key_str);
            if (!proto_val.is_object()) {
                // ES5 §15.3.5.3 step 3: If Type(O) is not Object, throw a TypeError.
                // But gracefully handle missing .prototype by returning false.
                ra.set_boolean(false);
                break;
            }

            HObject* proto_obj = (HObject*)proto_val.get_heapptr();
            HObject* cur = (HObject*)lval.get_heapptr();
            if (cur.is_prototype_of(proto_obj)) {
                ra.set_boolean(true);
            }
            break;
        }

        case Opcode.IN: {
            // ES5 §11.8.7: RelationalExpression in ShiftExpression
            // Right side must be an object; TypeError otherwise.
            // Returns true if the object has a property with the given name
            // (own or inherited — check via [[HasProperty]]).
            //
            // NOTE: Read rb (key) BEFORE writing ra, because ra may alias rb
            // (compiler can emit IN r3, r3, r4 when result overwrites the key).
            if (!rc.is_object()) {
                ra.set_boolean(false);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* msg_val = intern_string(vm, "in requires an object");
                    TVal msg_tv;
                    msg_tv.set_string(msg_val);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* obj = (HObject*)rc.get_heapptr();

            // Fast path: dense array / arguments indexed check (numeric keys)
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && (rb.is_fastint() || rb.is_number())) {
                long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                if (idx_long >= 0 && idx_long < (long)obj.array_size) {
                    TVal? av = obj.get_array_idx((uint)idx_long);
                    if (try v = av) {
                        ra.set_boolean(true);
                        break;
                    }
                    // Array hole — fall through to prototype chain lookup
                } else {
                    // Index out of bounds — check prototype only
                    void* key = get_prop_key(vm, rb);
                    if (key != null) {
                        ra.set_boolean(obj.prototype != null && obj.prototype.has_prop_proto(key));
                    } else {
                        ra.set_boolean(false);
                    }
                    break;
                }
            }

            // Fast path: dense array with string key that might be an index
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && rb.is_string()) {
                HString* skey = (HString*)rb.get_heapptr();
                uint skey_idx = skey.array_index();
                if (skey_idx != hstring::ARRIDX_NONE && skey_idx < (uint)obj.array_size) {
                    TVal? av = obj.get_array_idx(skey_idx);
                    if (try v = av) {
                        ra.set_boolean(true);
                        break;
                    }
                }
            }

            void* key = get_prop_key(vm, rb);
            if (key != null) {
                // STRING exotic: integer index keys in [0, clen) are own properties served lazily.
                if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* key_hstr = (HString*)key;
                    if (key_hstr != null && key_hstr.is_arridx()) {
                        HString* prim_str = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                        if (prim_str != null && key_hstr.array_index() < prim_str.char_length()) {
                            ra.set_boolean(true);
                            break;
                        }
                    }
                }
                ra.set_boolean(obj.has_prop_proto(key));
            } else {
                ra.set_boolean(false);
            }
            break;
        }

        // === CONTROL FLOW ===

        case Opcode.JUMP: {
            int sabc = insn.get_sabc();
            int target = (int)((long)(curr_pc - code_base) + (long)sabc);
            if (target < (curr_pc - code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
            curr_pc = code_base + target;
            break;
        }

        case Opcode.IF_TRUE:
            if (is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(curr_pc - code_base) + (long)sbx);
                if (target < (curr_pc - code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                curr_pc = code_base + target;
            }
            break;

        case Opcode.IF_FALSE:
            if (!is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(curr_pc - code_base) + (long)sbx);
                if (target < (curr_pc - code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                curr_pc = code_base + target;
            }
            break;

        // === PROPERTY ACCESS ===

        case Opcode.GETPROP:
            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();

                // Inline Cache fast path: check shape + key + prop_values pointer
                // NOTE: We use prop_values() (not prop_alloc) because prop_alloc is
                // NULL for objects with ≤4 inline properties, making the check always
                // true for all small objects. prop_values() returns a unique pointer
                // per object even for inline properties.
                if (ic_base != null) {
                    uint pc_off = (uint)(curr_pc - 1 - code_base);
                    hobject::ICEntry* ic = ic_base + pc_off;
                    void* lookup_key = null;
                    if (rc.is_string()) lookup_key = rc.get_heapptr();
                    if (lookup_key != null && ic.key == lookup_key && ic.shape_id == hobj.shape_id) {
                        HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                        if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                            // Ultra-fast path: when the IC value is not a heap
                            // pointer (common for fastint/number results), skip
                            // decref/incref/track_heap_store entirely.
                            TVal ic_val = *ic.prop_value_ptr;
                            if (!ic_val.is_heap_allocated()) {
                                *ra = ic_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &ic_val);
                                track_heap_store(act, ra, (uint)insn.a);
                            }
                            break;
                        }
                    }
                }

                // Fast path: dense array indexed access (a[i] where i is a non-negative integer)
                // Also handles ARGUMENTS exotic objects for arguments[i] access
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS) && hobj.array_part() != null && (rc.is_fastint() || rc.is_number())) {
                    long idx_long = rc.is_fastint() ? rc.get_fastint() : (long)rc.get_number();
                    if (idx_long >= 0 && idx_long < (long)hobj.array_size) {
                        TVal? av = hobj.get_array_idx((uint)idx_long);
                        if (try v = av) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                            break;
                        }
                        // Array hole — fall through to prototype chain lookup
                    }
                }

                // ARRAY exotic: .length fast path — return array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rc.is_string() && rc.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    ra.set_fastint((long)*hobj.array_len_ptr());
                    break;
                }

                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    // ES5 strict mode: arguments.callee throws TypeError
                    if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                        && (act.flags & ACT_FLAG_STRICT) != 0
                        && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            HString* emsg = intern_string(vm, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode");
                            if (emsg != null) {
                                TVal emsg_val; emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    // STRING exotic: indexed access reads characters lazily from the primitive value.
                    // Handles both fastint/number keys (e.g. s[0]) and array-index string keys
                    // (e.g. s["0"]), avoiding the need to materialise per-character own properties.
                    if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                        long sidx = -1;
                        if (rc.is_fastint()) {
                            sidx = rc.get_fastint();
                        } else if (rc.is_number()) {
                            double d = rc.get_number();
                            if (d >= 0 && d == (double)(long)d) sidx = (long)d;
                        } else if (rc.is_string()) {
                            // String key that is a canonical array index (cached on HString)
                            HString* key_hstr = (HString*)rc.get_heapptr();
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                sidx = (long)key_hstr.array_index();
                            }
                        }
                        if (sidx >= 0) {
                            HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                            if (sidx < (long)prim_str.char_length()) {
                                uint cp = prim_str.char_at((uint)sidx);
                                char[4] sbuf;
                                uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                HString* interned = intern_string(vm, sbuf[:sblen]);
                                if (interned != null) {
                                    vm.heap.set_reg_string(ra, interned);
                                } else {
                                    return VM_ERROR~;
                                }
                                break;
                            }
                            // Out-of-range index on a string exotic: fall through to own-property
                            // lookup so that explicitly assigned out-of-range slots are still found.
                        }
                    }
                    // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                    hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                    if (mega != null) {
                        TVal mega_val = *mega.prop_value_ptr;
                        if (!mega_val.is_heap_allocated()) {
                            *ra = mega_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &mega_val);
                            track_heap_store(act, ra, (uint)insn.a);
                        }
                        break;
                    }
                    hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        TVal obj_val;
                        obj_val.set_object(hobj);
                        if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                          act, &curr_pc, &needs_restart, regs_base)) {
                            regs_base = act.bottom;
                            break;
                        }
                        break;
                    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                        vm.heap.tval_copy_ref(ra, &res.data_val);
                        track_heap_store(act, ra, (uint)insn.a);
                        // Populate IC for this site
                        if (res.owner != null && ic_base != null) {
                            uint pc_off = (uint)(curr_pc - 1 - code_base);
                            hobject::ICEntry* ic = ic_base + pc_off;
                            int owner_idx = res.owner.find_prop_idx(key);
                            if (owner_idx >= 0) {
                                ic.shape_id = hobj.shape_id;
                                ic.proto = res.owner == hobj ? null : (void*)res.owner;
                                ic.prop_idx = (ushort)owner_idx;
                                ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                ic.key = key;
                                if (key != null) { ((types::HeapHeader*)key).incref(); }
                                ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                // Also populate megamorphic cache for cross-site benefit
                                hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                            }
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_null() || rb.is_undefined()) {
                // TypeError: Cannot read properties of null/undefined
                HString* name_hstr = null;
                if (rc.is_string()) {
                    name_hstr = (HString*)rc.get_heapptr();
                }
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    if (name_hstr != null) {
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot read properties of %s (reading '%s')",
                                                 (rb.is_null() ? "null" : "undefined"),
                                                 name_hstr.get_cstr());
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
            } else if (rb.is_string()) {
                // Check if this is a Symbol (0xFF-prefixed string)
                HString* h_str = (HString*)rb.get_heapptr();
                if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                    // Auto-box symbol primitive: walk Symbol.prototype chain
                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        TVal? result = vm.heap.symbol_proto.get_prop_proto(key);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    // Auto-box string primitive
                    HString* str_prim = (HString*)rb.get_heapptr();

                    // Fast path: numeric index → character at index
                    long str_idx = -1;
                    if (rc.is_fastint()) {
                        str_idx = rc.get_fastint();
                    } else if (rc.is_number()) {
                        double d = rc.get_number();
                        if (d >= 0 && d == (double)(long)d) {
                            str_idx = (long)d;
                        }
                    }
                    if (str_idx >= 0 && str_idx < (long)str_prim.char_length()) {
                        uint cp = str_prim.char_at((uint)str_idx);
                        char[4] cbuf;
                        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                        HString* interned = intern_string(vm, cbuf[:cblen]);
                        if (interned != null) {
                            vm.heap.set_reg_string(ra, interned);
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }

                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        // Fast path: .length → string character count
                        if (key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra.set_fastint((long)h_str.char_length());
                            break;
                        }
                        // Slow path: walk String.prototype chain
                        if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto(key);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                }
            } else if (rb.is_number() || rb.is_fastint()) {
                // Auto-box number primitive: walk Number.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.number_proto != null) {
                    TVal? result = vm.heap.number_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_boolean()) {
                // Auto-box boolean primitive: walk Boolean.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.bool_proto != null) {
                    TVal? result = vm.heap.bool_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_lightfunc()) {
                // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (key.equals("name")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.name.len > 0) {
                                HString* name_str = intern_string(vm, meta.name);
                                vm.heap.set_reg_string(ra, name_str);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("length")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.arity >= 0) {
                                ra.set_number(meta.arity);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("prototype")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                            // Resolve .prototype for constructor lightfuncs (Boolean, Number, etc.)
                            HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                            if (proto_obj != null) {
                                ra.set_object(proto_obj);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (vm.heap.function_proto != null) {
                        // Walk Function.prototype for .call, .apply, .bind, etc.
                        TVal? result = vm.heap.function_proto.get_prop_proto(key);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;

        case Opcode.GETPROPC:
            // Fused LDCONST+GETPROP: key comes from constant pool (always a string).
            {
                TVal key_tval = constants[(uint)insn.c];
                HString* key_hstr = (HString*)key_tval.get_heapptr();
                if (rb.is_object()) {
                    HObject* hobj = (HObject*)rb.get_heapptr();

                    // Inline Cache fast path: key is always non-null, skip lookup_key check.
                    if (ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::ICEntry* ic = ic_base + pc_off;
                        if (ic.key == (void*)key_hstr && ic.shape_id == hobj.shape_id) {
                            HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                            if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                                TVal ic_val = *ic.prop_value_ptr;
                                if (!ic_val.is_heap_allocated()) {
                                    *ra = ic_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra, &ic_val);
                                    track_heap_store(act, ra, (uint)insn.a);
                                }
                                break;
                            }
                        }
                    }

                    // ARRAY exotic: .length fast path
                    if (hobj.get_class() == hobject::ObjClass.ARRAY && (void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        ra.set_fastint((long)*hobj.array_len_ptr());
                        break;
                    }

                    void* key = (void*)key_hstr;
                    if (key != null) {
                        // ES5 strict mode: arguments.callee throws TypeError
                        if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                            && (act.flags & ACT_FLAG_STRICT) != 0
                            && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* emsg = intern_string(vm, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode");
                                if (emsg != null) {
                                    TVal emsg_val; emsg_val.set_string(emsg);
                                    HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        // STRING exotic: string-key indexed access (array-index string keys like "0")
                        if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                long sidx = (long)key_hstr.array_index();
                                HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                                if (sidx < (long)prim_str.char_length()) {
                                    uint cp = prim_str.char_at((uint)sidx);
                                    char[4] sbuf;
                                    uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                    HString* interned = intern_string(vm, sbuf[:sblen]);
                                    if (interned != null) {
                                        vm.heap.set_reg_string(ra, interned);
                                    } else {
                                        return VM_ERROR~;
                                    }
                                    break;
                                }
                            }
                        }
                        // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                        hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                        if (mega != null) {
                            TVal mega_val = *mega.prop_value_ptr;
                            if (!mega_val.is_heap_allocated()) {
                                *ra = mega_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &mega_val);
                                track_heap_store(act, ra, (uint)insn.a);
                            }
                            break;
                        }
                        hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                        if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal obj_val;
                            obj_val.set_object(hobj);
                            if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                              act, &curr_pc, &needs_restart, regs_base)) {
                                regs_base = act.bottom;
                                break;
                            }
                            break;
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(act, ra, (uint)insn.a);
                            // Populate IC for this site
                            if (res.owner != null && ic_base != null) {
                                uint pc_off = (uint)(curr_pc - 1 - code_base);
                                hobject::ICEntry* ic = ic_base + pc_off;
                                int owner_idx = res.owner.find_prop_idx(key);
                                if (owner_idx >= 0) {
                                    ic.shape_id = hobj.shape_id;
                                    ic.proto = res.owner == hobj ? null : (void*)res.owner;
                                    ic.prop_idx = (ushort)owner_idx;
                                    ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                    if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                    ic.key = key;
                                    if (key != null) { ((types::HeapHeader*)key).incref(); }
                                    ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                    ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                    // Upgrade to cached variant now that IC is populated
                                    // Keep A, B, C operands the same, just change the opcode
                                    curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC_CACHED,
                                                                      (uint)insn.a, (uint)insn.b, (uint)insn.c);
                                    // Also populate megamorphic cache for cross-site benefit
                                    hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_null() || rb.is_undefined()) {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.type_err_proto;
                        char[types::ERROR_MSG_BUF] buf;
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot read properties of %s (reading '%s')",
                                                 (rb.is_null() ? "null" : "undefined"),
                                                 key_hstr != null ? key_hstr.get_cstr() : "?");
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val;
                        err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                } else if (rb.is_string()) {
                    HString* h_str = (HString*)rb.get_heapptr();
                    if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key_hstr != null) {
                            TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        // Auto-box string primitive: constant string key — skip numeric-index fast path
                        if (key_hstr != null) {
                            // Fast path: .length → string character count
                            if ((void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                                ra.set_fastint((long)h_str.char_length());
                                break;
                            }
                            if (vm.heap.string_proto != null) {
                                TVal? result = vm.heap.string_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) {
                                    vm.heap.tval_copy_ref(ra, &v);
                                    track_heap_store(act, ra, (uint)insn.a);
                                } else {
                                    ra.set_undefined();
                                }
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    }
                } else if (rb.is_number() || rb.is_fastint()) {
                    if (key_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_boolean()) {
                    if (key_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_lightfunc()) {
                    // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                    uint fn_idx = (uint)(usz)rb.get_heapptr();
                    if (key_hstr != null) {
                        if (key_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, meta.name);
                                    vm.heap.set_reg_string(ra, name_str);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.arity >= 0) {
                                    ra.set_number(meta.arity);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                                if (proto_obj != null) {
                                    ra.set_object(proto_obj);
                                    track_heap_store(act, ra, (uint)insn.a);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            // Walk Function.prototype for .call, .apply, .bind, etc.
                            TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            }
            break;

        case Opcode.GETPROPC_CACHED: {
            // Specialized GETPROPC: IC is known warm. Only checks shape_id + prop_alloc.
            // Falls back to GETPROPC if the check fails (shape changed or props reallocated).
            TVal key_tval = constants[(uint)insn.c];
            HString* key_hstr = (HString*)key_tval.get_heapptr();
            if (rb.is_object() && ic_base != null) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                uint pc_off = (uint)(curr_pc - 1 - code_base);
                hobject::ICEntry* ic = ic_base + pc_off;
                if (ic.shape_id == hobj.shape_id) {
                    HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                    if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                        TVal ic_val = *ic.prop_value_ptr;
                        if (!ic_val.is_heap_allocated()) {
                            *ra = ic_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &ic_val);
                            track_heap_store(act, ra, (uint)insn.a);
                        }
                        break;
                    }
                }
            }
            // IC miss or ic_base null: downgrade back to GETPROPC and re-execute
            curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC,
                                            (uint)insn.a, (uint)insn.b, (uint)insn.c);
            curr_pc--;
            continue;
        }

        case Opcode.PUTPROP:
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();

                // Fast path: dense array indexed store (a[i] = v where i is a valid array index)
                // ES5 §15.4: array index P satisfies ToString(ToUint32(P))===P && ToUint32(P)≠2^32−1
                // Cap at 2^24 to avoid insane allocations for sparse arrays with huge indices.
                // Guard with array_part() != null — after seal/freeze the array part is
                // abandoned and elements live as named properties with proper flags.
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS)
                    && hobj.array_part() != null
                    && (rb.is_fastint() || rb.is_number())) {
                    long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                    if (idx_long >= 0 && idx_long < 0xFFFFFFFFL && idx_long < 0x1000000L) {
                        uint idx = (uint)idx_long;
                        if (hobj.set_array_idx(idx, *rc)) {
                            // Update .length fast: use array_length field directly (ARRAY only)
                            if (hobj.get_class() == hobject::ObjClass.ARRAY && idx >= *hobj.array_len_ptr()) {
                                *hobj.array_len_ptr() = idx + 1;
                            }
                            break;
                        }
                        // Dense write failed (index beyond capacity cap) — fall through to put_prop.
                    }
                }

                // Inline Cache fast path for own property writes (string keys only)
                if (ic_base != null && rb.is_string()) {
                    uint pc_off = (uint)(curr_pc - 1 - code_base);
                    hobject::ICEntry* ic = ic_base + pc_off;
                    void* wkey = rb.get_heapptr();
                    if (wkey != null && ic.key == wkey && ic.shape_id == hobj.shape_id && ic.proto == null) {
                        if (ic.cached_prop_alloc == (void*)hobj.prop_values()
                            && !ic.prop_flags.is_accessor
                            && ic.prop_flags.writable) {
                            vm.heap.tval_copy_ref(ic.prop_value_ptr, rc);
                            break;
                        }
                    }
                }

                // ARRAY exotic: .length write fast path — update array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rb.is_string() && rb.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    // ES5 §15.4.5.1 step 2 (ArraySetLength): validate the new length value
                    // before truncating. ToUint32(v) must equal ToNumber(v), and the result
                    // must be < 2^32. Otherwise throw RangeError.
                    bool length_valid = true;
                    uint new_len = 0;
                    if (rc.is_undefined()) {
                        // Step 2a: undefined value throws TypeError
                        length_valid = true; // signal to throw TypeError below
                        new_len = 0;
                    } else if (rc.is_fastint()) {
                        long v = rc.get_fastint();
                        if (v < 0L || v > 0xFFFFFFFFL) {
                            length_valid = false;
                        } else {
                            new_len = (uint)v;
                        }
                    } else if (rc.is_number()) {
                        double raw = rc.get_number();
                        // NaN, ±Infinity, or non-integer, or negative, or > 2^32-1
                        if (raw != raw || raw < 0.0 || raw > 4294967295.0 || raw != math::floor(raw)) {
                            length_valid = false;
                        } else {
                            new_len = (uint)raw;
                        }
                    } else {
                        // For non-numeric values, fall through to slow path (Put → DefineOwnProperty)
                        // so the regular [[Set]] machinery handles coercion.
                        // We can't throw from here without breaking object property writes.
                        length_valid = true;
                        new_len = 0; // placeholder, will be overwritten by put_prop
                    }
                    if (!length_valid) {
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.range_err_proto;
                            HString* emsg = intern_string(vm, "Invalid array length");
                            if (emsg != null) {
                                TVal emsg_val; emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    if (rc.is_undefined()) {
                        // TypeError: undefined is not a valid length
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            HString* emsg = intern_string(vm, "Invalid array length: undefined");
                            if (emsg != null) {
                                TVal emsg_val; emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    // Only update if the value is a valid number (skip if fell through)
                    if (rc.is_fastint() || rc.is_number()) {
                        *hobj.array_len_ptr() = new_len;
                        // Also update the prop table for spec correctness
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        int len_slot = hobj.find_prop_idx(len_str);
                        if (len_slot >= 0) {
                            TVal new_len_tv;
                            new_len_tv.set_fastint((long)new_len);
                            TVal* props = hobj.prop_values();
                            vm.heap.tval_copy_ref(&props[len_slot], &new_len_tv);
                        }
                    }
                    break;
                }

                void* key = get_prop_key(vm, rb);
                if (key != null) {
                    // Save the value before ensure_valstack may reallocate
                    TVal put_val = *rc;

                    // Single find_prop_idx call for both existence check and accessor check
                    int exist_idx = hobj.find_prop_idx(key);
                    if (exist_idx >= 0) {
                        TVal* entry = &hobj.prop_values()[exist_idx];
                        hobject::PropFlags exist_flags = hobj.get_prop_flags((uint)exist_idx);
                        if (exist_flags.is_accessor) {
                            // Accessor property — invoke setter
                            TVal setter_fn = hobject::hobject_access_setter(*entry);
                            if (setter_fn.is_object() && setter_fn.get_heapptr() != null) {
                                HObject* setter_obj = (HObject*)setter_fn.get_heapptr();
                                if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                    CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;

                                    // Stage the call frame above the caller's live registers:
                                    // PUTPROP's A/B/C are arbitrary live locals, so A+1.. cannot
                                    // be used as scratch (unlike GETPROP where A is a fresh temp).
                                    // Note: vm.valstack_top is not reliable here (builtin calls
                                    // may leave it below bottom + num_regs), so use num_regs.
                                    uint callee_reg = act.func != null
                                        ? ((CompiledFunction*)act.func).num_regs
                                        : (uint)(vm.valstack_top - act.bottom);
                                    uint frame_start = callee_reg + 2;
                                    TVal* new_bottom = act.bottom + frame_start;
                                    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                    if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                        new_bottom = act.bottom + frame_start;
                                        TVal* caller_regs = act.bottom;

                                        // Raw stores: these slots are above the initialized frame,
                                        // so tval_copy_ref would decref stale garbage. The setter fn
                                        // and object are kept alive by the property entry and ra.
                                        caller_regs[callee_reg] = setter_fn;
                                        TVal obj_tv;
                                        obj_tv.set_object(hobj);
                                        caller_regs[callee_reg + 1] = obj_tv;

                                        Activation* new_act = &vm.activations[vm.activation_count];
                                        vm.activation_count++;
                                        new_act.max_heap_reg = 0;
                                        new_act.caller_valstack_top = vm.valstack_top;

                                        EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                        if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                        new_act.parent = act;
                                        new_act.func = target;
                                        new_act.var_env = setter_var_env;
                                        new_act.lex_env = setter_var_env;
                                        new_act.cat = null;
                                        new_act.curr_pc = target.code;
                                        new_act.bottom = new_bottom;
                                        new_act.retval = null;  // setter return value is discarded
                                        new_act.flags = target.is_strict() ? ACT_FLAG_STRICT : 0;
                                        vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                        TVal* new_regs = new_act.bottom;
                                        libc::memset(new_regs, 0, (usz)target.num_regs * TVal::size);
                                        vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                        vm.valstack_top = new_regs + target.num_regs;
                                        vm.valstack_bottom = new_act.bottom;

                                        act.curr_pc = curr_pc;

                                        needs_restart = true;
                                        break;
                                    }
                                }
                            }
                        } else if (!exist_flags.writable) {
                            if (act.flags & ACT_FLAG_STRICT) {
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.type_err_proto;
                                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    HString* msg_val = intern_string(vm, "Cannot assign to read only property");
                                    TVal msg_tv;
                                    msg_tv.set_string(msg_val);
                                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return VM_ERROR~;
                                    }
                                } else {
                                    return VM_ERROR~;
                                }
                            }
                            break;
                        } else {
                            // Update value, preserve existing flags
                            vm.heap.tval_copy_ref(entry, &put_val);
                        }
                    } else {
                        // Property doesn't exist: check prototype for accessors
                        hobject::AccessorResult acc = hobj.find_accessor_proto(key, false);
                        if (acc.found && acc.accessor_fn.is_object() && acc.accessor_fn.get_heapptr() != null) {
                            // Invoke setter from prototype
                            HObject* setter_obj = (HObject*)acc.accessor_fn.get_heapptr();
                            if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;

                                // Stage the call frame above the caller's live registers
                                // (see own-property setter path above).
                                uint callee_reg = act.func != null
                                    ? ((CompiledFunction*)act.func).num_regs
                                    : (uint)(vm.valstack_top - act.bottom);
                                uint frame_start = callee_reg + 2;
                                TVal* new_bottom = act.bottom + frame_start;
                                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                    new_bottom = act.bottom + frame_start;
                                    TVal* caller_regs = act.bottom;

                                    caller_regs[callee_reg] = acc.accessor_fn;
                                    TVal obj_tv;
                                    obj_tv.set_object(acc.this_obj);
                                    caller_regs[callee_reg + 1] = obj_tv;

                                    Activation* new_act = &vm.activations[vm.activation_count];
                                    vm.activation_count++;
                                    new_act.max_heap_reg = 0;
                                    new_act.caller_valstack_top = vm.valstack_top;

                                    EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                    if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                    new_act.parent = act;
                                    new_act.func = target;
                                    new_act.var_env = setter_var_env;
                                    new_act.lex_env = setter_var_env;
                                    new_act.cat = null;
                                    new_act.curr_pc = target.code;
                                    new_act.bottom = new_bottom;
                                    new_act.retval = null;  // setter return value is discarded
                                    new_act.flags = target.is_strict() ? ACT_FLAG_STRICT : 0;
                                    vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                    TVal* new_regs = new_act.bottom;
                                    libc::memset(new_regs, 0, (usz)target.num_regs * TVal::size);
                                    vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                    vm.valstack_top = new_regs + target.num_regs;
                                    vm.valstack_bottom = new_act.bottom;

                                    act.curr_pc = curr_pc;

                                    needs_restart = true;
                                    break;
                                }
                            }
                        } else {
                            // No accessor: insert new property
                            if (hobj.flags.extensible) {
                                hobj.put_prop(key, put_val, hobject::PROP_FLAGS_WEC);
                            } else if (act.flags & ACT_FLAG_STRICT) {
                                // ES5 §9.1.2 step 5b: if O is not extensible, throw TypeError
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.type_err_proto;
                                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    HString* msg_val = intern_string(vm, "Cannot add property to non-extensible object");
                                    TVal msg_tv;
                                    msg_tv.set_string(msg_val);
                                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return VM_ERROR~;
                                    }
                                } else {
                                    return VM_ERROR~;
                                }
                            }
                        }
                    }
                }
            } else if (ra.is_null() || ra.is_undefined()) {
                // TypeError: Cannot set properties of null/undefined
                HString* name_hstr = null;
                if (rb.is_string()) {
                    name_hstr = (HString*)rb.get_heapptr();
                }
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    if (name_hstr != null) {
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot set properties of %s (setting '%s')",
                                                 (ra.is_null() ? "null" : "undefined"),
                                                 name_hstr.get_cstr());
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
            }
            break;

        case Opcode.DELPROP: {
            // ES5 §11.4.1: delete operator
            // A = delete B[C], where B = object, C = property key
            // Returns boolean: true if deleted or not found,
            // false if the property exists and is non-configurable.
            ra.set_boolean(true);

            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (!hobj.es_delete_prop(key)) {
                        ra.set_boolean(false);
                        if (act.flags & ACT_FLAG_STRICT) {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "Delete failed: property is non-configurable");
                                TVal msg_tv;
                                msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val;
                                err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                    } else {
                        ra.set_boolean(true);
                    }
                }
            } else if (rb.is_lightfunc()) {
                // Handle deletion of virtual properties (name, length, prototype).
                // These are configurable:true per ES5 §15.3.5.1, so delete returns true.
                // Mark as deleted so subsequent GETPROP/hasOwn check the bitset.
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    int bit = heap::lf_key_to_prop_bit(key);
                    if (bit >= 0) {
                        heap::lf_mark_deleted(&vm.heap.lf_deleted_props[0], fn_idx, (uint)bit);
                    }
                }
            }
            // For null, undefined, and other primitives:
            // [[Delete]] on a non-object base always returns true.
            break;
        }

        // === OBJECT / ARRAY CREATION ===

        case Opcode.NEWOBJ: {
            HObject*? new_obj = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try o = new_obj) {
                o.prototype = vm.heap.object_proto;
                ra.set_object(o);
                track_heap_store(act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.NEWARR: {
            HObject*? new_arr = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try a = new_arr) {
                a.prototype = vm.heap.array_proto;
                ra.set_object(a);
                track_heap_store(act, ra, (uint)insn.a);
                if (insn.a == 251) {
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.NEWREGEXP: {
            // A = dest register, BC = constant pool index of "/pattern/flags" string
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal raw_tv = constants[bc];
                if (raw_tv.is_string()) {
                    HString* raw_hs = (HString*)raw_tv.get_heapptr();
                    char[] raw = raw_hs.get_data();
                    usz len = raw.len;

                    // Parse "/pattern/flags" by finding the closing '/'
                    // Flags are only letters, so scan backwards past them
                    usz end_slash = len - 1;
                    while (end_slash > 0 &&
                           ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
                            (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
                        end_slash--;
                    }

                    if (end_slash > 0 && raw[0] == '/' && raw[end_slash] == '/') {
                        char[] pattern_data = raw[1..end_slash - 1];
                        char[] flag_data = {};
                        if (end_slash + 1 < len) {
                            flag_data = raw[end_slash + 1..len - 1];
                        }

                        // Convert JS flags to libregexp flag bits
                        int flags = 0;
                        int js_flags = 0;  // 1=g, 2=i, 4=m, 8=s, 16=u, 32=y
                        for (usz i = 0; i < flag_data.len; i++) {
                            char f = flag_data[i];
                            if (f == 'g') {
                                js_flags |= 1;
                            } else if (f == 'i') {
                                flags |= re_bindings::RE_FLAG_IGNORECASE;
                                js_flags |= 2;
                            } else if (f == 'm') {
                                flags |= re_bindings::RE_FLAG_MULTILINE;
                                js_flags |= 4;
                            } else if (f == 's') {
                                flags |= re_bindings::RE_FLAG_DOTALL;
                                js_flags |= 8;
                            } else if (f == 'u') {
                                js_flags |= 16;
                            } else if (f == 'y') {
                                js_flags |= 32;
                            }
                        }

                        // Compile the regexp
                        // lre_compile requires a null-terminated pattern string
                        char[256] pattern_buf;
                        usz copy_len = pattern_data.len < 255 ? pattern_data.len : 255;
                        libc::memcpy(&pattern_buf, pattern_data.ptr, copy_len);
                        pattern_buf[copy_len] = 0;
                        char[128] error_buf;
                        void* compiled = re_bindings::re_compile(
                            &pattern_buf, copy_len,
                            flags, &error_buf, 128
                        );

                        if (compiled != null) {
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                (*obj.extra_ptr()).regexp.regexp_data = compiled;
                                (*obj.extra_ptr()).regexp.flags = js_flags;
                                // Store pattern string as primitive_value
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                                // Set lastIndex (ES5 §15.10.7) — only own data property
                                HString* lastindex_key = intern_string(vm, "lastIndex");
                                TVal lastindex_tv;
                                lastindex_tv.set_fastint(0);
                                obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);
                                ra.set_object(obj);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                // If alloc failed, free the compiled regexp
                                re_bindings::re_free(compiled);
                                ra.set_undefined();
                            }
                        } else {
                            // re_compile failed — still create an empty regexp object
                            // so typeof works correctly
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                (*obj.extra_ptr()).regexp.regexp_data = null;
                                (*obj.extra_ptr()).regexp.flags = js_flags;
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                                ra.set_object(obj);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.SETALEN: {
            // A = array register, BC = element count (high-water mark)
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                uint count = insn.get_bc();
                *hobj.array_len_ptr() = count;
                HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_val;
                len_val.set_fastint((long)count);
                hobj.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
            }
            break;
        }

        case Opcode.ARRSPRD: {
            // A = target array reg, B = index reg (in/out), C = source reg
            // Uses ES6 iterator protocol (§12.2.5.3 ArrayAccumulation SpreadElement)
            if (!ra.is_object() || ra.get_heapptr() == null) break;
            HObject* target = (HObject*)ra.get_heapptr();
            TVal src_tv = *rc;

            // null/undefined → TypeError: not iterable
            if (src_tv.is_null() || src_tv.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_str = intern_string(vm, "cannot spread null/undefined");
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                } else { return VM_ERROR~; }
                break;
            }

            // Get current target index
            long idx = 0;
            if (rb.is_fastint()) {
                idx = rb.get_fastint();
            } else if (rb.is_number()) {
                idx = (long)rb.get_number();
            }

            // --- Iterator protocol ---
            HString* iter_sym = vm.heap.iterator_symbol;
            TVal iter_method;
            bool has_method = false;
            if (iter_sym != null) {
                TVal? method_opt;
                if (src_tv.is_object() && src_tv.get_heapptr() != null) {
                    method_opt = ((HObject*)src_tv.get_heapptr()).get_prop_proto(iter_sym);
                } else if (src_tv.is_string() && vm.heap.string_proto != null) {
                    method_opt = vm.heap.string_proto.get_prop_proto(iter_sym);
                }
                if (try m = method_opt) {
                    iter_method = m;
                    bool callable = iter_method.is_lightfunc() ||
                        (iter_method.is_object() && iter_method.get_heapptr() != null &&
                         ((HObject*)iter_method.get_heapptr()).is_callable());
                    has_method = callable;
                }
            }
            if (!has_method) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_str = intern_string(vm, "xxx is not iterable");
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) { return VM_ERROR~; }
                } else { return VM_ERROR~; }
                break;
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm_check_call_fn_error(vm)) return VM_ERROR~;
            if (!iterator.is_object() || iterator.get_heapptr() == null) { break; }

            // Loop: next() → {value, done}
            HString* next_key = intern_string(vm, "next");
            HString* done_key = intern_string(vm, "done");
            HString* value_key = intern_string(vm, "value");
            uint k = 0;
            while (vm.heap.call_fn != null) {
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                TVal? next_opt = iter_obj.get_prop_proto(next_key);
                TVal next_method;
                if (try nm = next_opt) { next_method = nm; } else { break; }
                bool callable = next_method.is_lightfunc() ||
                    (next_method.is_object() && next_method.get_heapptr() != null &&
                     ((HObject*)next_method.get_heapptr()).is_callable());
                if (!callable) { break; }

                TVal result = vm.heap.call_fn(vm, next_method, null, 0, iterator);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();
                TVal? done_opt = result_obj.get_prop_proto(done_key);
                bool done = false;
                if (try dv = done_opt) { done = builtins::builtin_to_boolean(&dv); }
                if (done) { break; }

                TVal? value_opt = result_obj.get_prop_proto(value_key);
                if (try vv = value_opt) {
                    HString* pk = vm.heap.int_to_hstring(idx + (long)k);
                    if (pk != null) {
                        target.put_prop(pk, vv, hobject::PROP_FLAGS_WEC);
                    }
                    k++;
                } else { break; }
            }
            // Update index register with elements actually inserted
            rb.set_fastint(idx + (long)k);
            break;
        }

        case Opcode.SPREAD_ARG: {
            // A = dest start reg, B = count out reg, C = source reg
            // Uses ES6 iterator protocol (§12.3.5.1 ArgumentListEvaluation SpreadElement)
            TVal src_tv = *rc;

            // null/undefined → TypeError
            if (src_tv.is_null() || src_tv.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_str = intern_string(vm, "cannot spread null/undefined");
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                } else { return VM_ERROR~; }
                break;
            }

            // --- Iterator protocol ---
            HString* iter_sym = vm.heap.iterator_symbol;
            TVal iter_method;
            bool has_method = false;
            if (iter_sym != null) {
                TVal? method_opt;
                if (src_tv.is_object() && src_tv.get_heapptr() != null) {
                    method_opt = ((HObject*)src_tv.get_heapptr()).get_prop_proto(iter_sym);
                } else if (src_tv.is_string() && vm.heap.string_proto != null) {
                    method_opt = vm.heap.string_proto.get_prop_proto(iter_sym);
                }
                if (try m = method_opt) {
                    iter_method = m;
                    bool callable = iter_method.is_lightfunc() ||
                        (iter_method.is_object() && iter_method.get_heapptr() != null &&
                         ((HObject*)iter_method.get_heapptr()).is_callable());
                    has_method = callable;
                }
            }
            if (!has_method) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_str = intern_string(vm, "xxx is not iterable");
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                } else { return VM_ERROR~; }
                break;
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm_check_call_fn_error(vm)) return VM_ERROR~;
            if (!iterator.is_object() || iterator.get_heapptr() == null) { break; }

            uint dest_start = insn.a;
            uint count_reg = insn.b;

            // Loop: next() → {value, done}
            HString* next_key = intern_string(vm, "next");
            HString* done_key = intern_string(vm, "done");
            HString* value_key = intern_string(vm, "value");
            uint k = 0;
            while (vm.heap.call_fn != null) {
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                TVal? next_opt = iter_obj.get_prop_proto(next_key);
                TVal next_method;
                if (try nm = next_opt) { next_method = nm; } else { break; }
                bool callable = next_method.is_lightfunc() ||
                    (next_method.is_object() && next_method.get_heapptr() != null &&
                     ((HObject*)next_method.get_heapptr()).is_callable());
                if (!callable) { break; }

                TVal result = vm.heap.call_fn(vm, next_method, null, 0, iterator);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();
                TVal? done_opt = result_obj.get_prop_proto(done_key);
                bool done = false;
                if (try dv = done_opt) { done = builtins::builtin_to_boolean(&dv); }
                if (done) { break; }

                TVal? value_opt = result_obj.get_prop_proto(value_key);
                if (try vv = value_opt) {
                    TVal* dest_slot = regs_base + dest_start + k;
                    *dest_slot = vv;
                    k++;
                } else { break; }
            }

            // Store count in output register
            TVal* count_slot = regs_base + count_reg;
            count_slot.set_fastint((long)k);
            break;
        }

        // === FUNCTION CALLS ===
        // Duktape CALL: A=result_reg, B=callee_reg, C=nargs
        // Layout: valstack[base] = callee, valstack[base+1] = this, valstack[base+2..base+1+nargs] = args
        //
        // CALL_S: same layout but nargs is read from valstack[C] at runtime

        case Opcode.CALL:
        case Opcode.CALL_S: {
            // Safe point: run deferred GC before entering callee
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs (or nargs_reg for CALL_S)
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.CALL_S) {
                // Read nargs from the register at index C
                TVal* nargs_slot = regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* func_slot = regs_base + callee_reg;
            TVal func_val = *func_slot;

            // === Fast path: direct compiled HObject call (most common) ===
            if (func_val.is_object()) {
                HObject* hobj_fast = (HObject*)func_val.get_heapptr();
                if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.callable_kind() == hobject::CallableKind.COMPILED_FN) {
                    CompiledFunction* target_fast = (*hobj_fast.extra_ptr()).func.comp_func;
                    if (target_fast == null) { regs_base[result_reg].set_undefined(); break; }
                    if (!target_fast.is_generator()) {

                    // New callee frame starts right after func and this in the caller frame
                    uint frame_start = callee_reg + 2;
                    TVal* new_bottom = regs_base + frame_start;
                    uint needed = (uint)(new_bottom - vm.valstack) + target_fast.num_regs;

                    if (!ensure_valstack(vm, needed)) {
                        regs_base[result_reg].set_undefined();
                        break;
                    }

                    regs_base = act.bottom;
                    // Recompute new_bottom after realloc (act.bottom may have moved)
                    new_bottom = regs_base + frame_start;

                    if (vm.activation_count >= MAX_CALLS) {
                        {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.range_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                                TVal msg_tv; msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                        break;
                    }

                    // Save the 'this' value before clearing the slot, so that GC
                    // during env creation doesn't follow a stale object pointer
                    // from a previous call in the sliding-window model.
                    TVal saved_this = regs_base[callee_reg + 1];
                    regs_base[callee_reg + 1].set_undefined();

                    Activation* new_act = &vm.activations[vm.activation_count];

                    EnvRecord* fast_var_env;
                    // Skip env allocation when the callee has no local bindings —
                    // the parent's env is sufficient (no var hoisting needed).
                    if (target_fast.needs_env()) {
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                        if (try fv_f = env::env_create_function_scope(vm.heap, (*hobj_fast.extra_ptr()).func.var_env)) { fast_var_env = fv_f; }
                    } else {
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                    }
                    if (fast_var_env == null) {
                        regs_base[result_reg].set_undefined();
                        break;
                    }
                    new_act.parent = act;
                    new_act.func = target_fast;
                    new_act.var_env = fast_var_env;
                    new_act.lex_env = fast_var_env;
                    new_act.cat = null;
                    new_act.curr_pc = target_fast.code;
                    new_act.bottom = new_bottom;
                    new_act.retval = regs_base + result_reg;
                    new_act.flags = target_fast.is_strict() ? ACT_FLAG_STRICT : 0;
                    new_act.max_heap_reg = 0;
                    new_act.caller_valstack_top = vm.valstack_top;
                    // Arrow functions use lexical this (inherited from enclosing scope)
                    // Fast path: skip refcounting when this value is not a heap ref
                    {
                        TVal* this_src = target_fast.is_arrow() ? &act.this_binding : &saved_this;
                        if (!this_src.is_heap_allocated()) {
                            if (new_act.this_binding.is_heap_allocated()) {
                                vm.heap.decref_tval(&new_act.this_binding);
                            }
                            new_act.this_binding = *this_src;
                        } else {
                            vm.heap.tval_copy_ref(&new_act.this_binding, this_src);
                        }
                    }

                    // Activation fully initialized — now make it visible to GC.
                    vm.activation_count++;

                    TVal* new_regs = new_act.bottom;
                    uint new_nregs = target_fast.num_regs;

                    // Copy args: in the sliding-window model new_regs == old_args
                    // Values are already in place — set missing parameter registers
                    // to undefined so default parameter checks (param !== undefined) work.
                    uint formals = (uint)target_fast.num_formals;
                    if (target_fast.has_rest()) {
                        // Build rest array from overflow args (indices formals..nargs-1)
                        uint rest_idx = formals;
                        uint overflow = (nargs > formals) ? (nargs - formals) : 0;
                        HObject*? rest_arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                        if (try rest_arr = rest_arr_raw) {
                            rest_arr.prototype = vm.heap.array_proto;
                            for (uint ri = 0; ri < overflow; ri++) {
                                HString* rkey = vm.heap.int_to_hstring((long)ri);
                                if (rkey != null) {
                                    rest_arr.put_prop(rkey, new_regs[rest_idx + ri], hobject::PROP_FLAGS_WEC);
                                }
                            }
                            HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            TVal len_val;
                            len_val.set_fastint((long)overflow);
                            rest_arr.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
                            new_regs[rest_idx].set_object(rest_arr);
                        } else {
                            new_regs[rest_idx].set_undefined();
                        }
                        // Set missing formals (after rest) to undefined
                        if (nargs < formals) {
                            for (uint i = nargs; i < formals; i++) {
                                new_regs[i].set_undefined();
                            }
                        }
                        // Zero remaining registers (temps after rest)
                        uint zero_start = rest_idx + 1;
                        if (zero_start < new_nregs) {
                            zero_regs_undefined(new_regs, zero_start, new_nregs);
                        }
                    } else {
                        uint undef_limit = formals < new_nregs ? formals : new_nregs;
                        if (nargs < undef_limit) {
                            zero_regs_undefined(new_regs, nargs, undef_limit);
                        }
                        // Zero remaining registers (temps), but skip past any
                        // actual arguments already in the sliding-window slots.
                        uint zero_start = undef_limit > nargs ? undef_limit : nargs;
                        if (zero_start < new_nregs) {
                            zero_regs_undefined(new_regs, zero_start, new_nregs);
                        }
                    }

                    vm.valstack_top = new_regs + new_nregs;
                    vm.valstack_bottom = new_act.bottom;

                    // Save caller resume point before switching activations
                    act.curr_pc = curr_pc;

                    // Direct dispatch to new activation (avoid restart overhead)
                    act = new_act;
                    vm.current_func = target_fast;
                    code_base = target_fast.code;
                    code_count = target_fast.code_count;
                    code_end = code_base + code_count;
                    ic_base = (hobject::ICEntry*)target_fast.ic_entries;
                    var_ic_base = (hobject::VarICEntry*)target_fast.var_ic_entries;
                    constants = target_fast.constants;
                    nregs = target_fast.num_regs;
                    curr_pc = act.curr_pc;
                    regs_base = act.bottom;

                    // Create arguments object if the function references 'arguments'
                    if (target_fast.uses_arguments()) {
                        HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                        if (try args_obj = args_obj_raw) {
                            // Store arguments in dense array_part (avoids O(argc) string key allocs)
                            for (uint ai = 0; ai < nargs; ai++) {
                                args_obj.set_array_idx(ai, regs_base[ai]);
                            }
                            // ES5 §10.6: [[Prototype]] is Object.prototype
                            args_obj.prototype = vm.heap.object_proto;
                            // ES5 §10.6: define 'callee' property (writable, non-enumerable, configurable)
                            HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                            if (callee_key != null) {
                                TVal callee_tv;
                                callee_tv.set_object(hobj_fast);
                                args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                            }
                            // ES5 §10.6: define 'length' property (writable, non-enumerable, configurable)
                            HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            if (length_key != null) {
                                TVal length_tv;
                                length_tv.set_fastint((long)nargs);
                                args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                            }
                            // Declare 'arguments' in the function's var_env
                            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                            if (args_name != null) {
                                TVal args_tv;
                                args_tv.set_object(args_obj);
                                env::env_declare(new_act.var_env, args_name, args_tv);
                            }
                        }
                    }

                    continue;
                    }
                }
            }

            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = regs_base[callee_reg + 1];
                ctx.is_constructor = false;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                ctx.callee_obj = null;

                builtins::dispatch_builtin(fn_idx, &ctx);

                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                    break;
                }

                if (ctx.needs_re_dispatch) {
                    // Builtin (.call/.apply/bound) modified the stack — re-dispatch
                    func_val = regs_base[callee_reg];
                    nargs = ctx.re_nargs;
                    // Fall through to OBJECT handling
                } else {
                    break;
                }
            }

            if (!func_val.is_object()) {
                // TypeError: value is not a function
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a function",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // === OBJECT CALL HANDLING ===
            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable()) {
                // TypeError: object is not callable (e.g., a non-function object)
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a function",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = regs_base[callee_reg];
                        hobj = (HObject*)func_val.get_heapptr();
                        nargs = ctx.re_nargs;
                        // Fall through to compiled function handling below
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        // Re-dispatch from bound function: re-read target from stack
                        func_val = regs_base[callee_reg];
                        hobj = (HObject*)func_val.get_heapptr();
                        nargs = ctx.re_nargs;
                        // Only support re-dispatch to compiled functions from here;
                        // if the target is another builtin, just break
                        if ((*hobj.extra_ptr()).func.comp_func != null) {
                            // Continue to compiled function handling below (skip error)
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                } else {
                    // Callable object with no compiled function and no builtin index: error
                    HString* type_str = typeof_string(vm, &func_val);
                    HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err2 = err_raw2) {
                        err2.prototype = vm.heap.type_err_proto;
                        char[types::ERROR_MSG_BUF] buf;
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a function",
                                                 type_str.get_cstr());
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val2;
                        err_val2.set_object(err2);
                        if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    break;
                }
            }

            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;

            // === Generator function handling (ES6 §25.3) ===
            if (target.is_generator()) {
                // Resume path: .next()/.throw()/.return() set heap.resume_gen
                if (vm.heap.resume_gen != null && (CompiledFunction*)vm.heap.resume_gen.func == target) {
                    GeneratorState* gs = vm.heap.resume_gen;

                    if (gs.state == GEN_COMPLETED) {
                        vm.heap.resume_gen = null;
                        regs_base[result_reg].set_undefined();
                        break;
                    }

                    // Set state to EXECUTING
                    gs.state = GEN_EXECUTING;

                    // Calculate register layout
                    uint frame_start_r = callee_reg + 2;
                    TVal* new_bottom_r = regs_base + frame_start_r;
                    uint needed_r = (uint)(new_bottom_r - vm.valstack) + target.num_regs;

                    if (!ensure_valstack(vm, needed_r)) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        regs_base[result_reg].set_undefined();
                        break;
                    }

                    regs_base = act.bottom;
                    // Recompute new_bottom after realloc (act.bottom may have moved)
                    new_bottom_r = regs_base + frame_start_r;

                    if (vm.activation_count >= MAX_CALLS) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.range_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                                TVal msg_tv; msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                        break;
                    }

                    // Push activation
                    Activation* new_act_r = &vm.activations[vm.activation_count];
                    vm.activation_count++;
                    new_act_r.max_heap_reg = 0;
                    new_act_r.caller_valstack_top = vm.valstack_top;

                    new_act_r.parent = act;
                    new_act_r.func = target;
                    new_act_r.var_env = gs.var_env;
                    new_act_r.lex_env = gs.lex_env;
                    new_act_r.cat = gs.cat;
                    new_act_r.curr_pc = gs.saved_pc;
                    new_act_r.bottom = new_bottom_r;
                    new_act_r.retval = regs_base + result_reg;
                    new_act_r.flags = ACT_FLAG_STRICT | ACT_FLAG_PREVENT_YIELD;
                    vm.heap.tval_copy_ref(&new_act_r.this_binding, &gs.this_binding);

                    // Copy saved registers to valstack
                    TVal* new_regs_r = new_act_r.bottom;
                    uint new_nregs_r = target.num_regs;
                    for (uint i = 0; i < new_nregs_r; i++) {
                        vm.heap.tval_copy_ref(&new_regs_r[i], &gs.saved_regs[i]);
                    }

                    vm.valstack_top = new_regs_r + new_nregs_r;
                    vm.valstack_bottom = new_act_r.bottom;

                    // Save caller resume point before switching activation
                    act.curr_pc = curr_pc;

                    needs_restart = true;
                    break;
                }

                // Initial call: create generator object, don't execute body
                // Calculate register layout
                uint frame_start = callee_reg + 2;
                TVal* new_bottom = regs_base + frame_start;
                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                if (!ensure_valstack(vm, needed)) {
                    regs_base[result_reg].set_undefined();
                    break;
                }

                regs_base = act.bottom;
                // Recompute new_bottom after realloc (act.bottom may have moved)
                new_bottom = regs_base + frame_start;

                // Allocate GeneratorState
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) {
                    regs_base[result_reg].set_undefined();
                    break;
                }
                GeneratorState* gs = (GeneratorState*)gs_raw;
                libc::memset(gs_raw, 0, GeneratorState::size);

                gs.state = GEN_SUSPENDED_START;
                gs.func = target;
                gs.num_regs = target.num_regs;
                gs.saved_pc = target.code;
                gs.var_env = (*hobj.extra_ptr()).gen.var_env;
                gs.lex_env = (*hobj.extra_ptr()).gen.lex_env;
                vm.heap.tval_copy_ref(&gs.this_binding, &regs_base[callee_reg + 1]);

                // Allocate and copy saved registers
                usz regs_bytes = (usz)target.num_regs * TVal::size;
                void* regs_raw = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                if (regs_raw == null) {
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    regs_base[result_reg].set_undefined();
                    break;
                }
                gs.saved_regs = (TVal*)regs_raw;
                libc::memset(regs_raw, 0, regs_bytes);

                // Initialize registers with args (rest = undefined for extra slots)
                TVal* base = new_bottom;
                TVal* old_args = regs_base + callee_reg + 2;
                uint copy_count = target.has_rest() ? (uint)target.num_formals : nargs;
                if (copy_count > target.num_regs) copy_count = target.num_regs;
                for (uint i = 0; i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&base[i], &old_args[i]);
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &old_args[i]);
                }
                for (uint i = copy_count; i < target.num_regs; i++) {
                    base[i].set_undefined();
                    gs.saved_regs[i].set_undefined();
                }

                // Handle rest parameter: build rest array and store in saved_regs
                if (target.has_rest() && nargs > (uint)target.num_formals) {
                    uint rest_idx = (uint)target.num_formals;
                    uint overflow = nargs - (uint)target.num_formals;

                    HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                    if (try a = arr_raw) {
                        a.prototype = vm.heap.array_proto;
                        for (uint i = 0; i < overflow; i++) {
                            HString* key = vm.heap.int_to_hstring((long)i);
                            if (key != null) {
                                a.put_prop(key, old_args[(uint)target.num_formals + i], hobject::PROP_FLAGS_WEC);
                            }
                        }
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        TVal len_val;
                        len_val.set_fastint((long)overflow);
                        a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                        base[rest_idx].set_object(a);
                        gs.saved_regs[rest_idx].set_object(a);
                    }
                }

                // Create Generator HObject
                HObject*? gen_obj_raw = vm.heap.alloc_object(hobject::ObjClass.GENERATOR);
                HObject* gen_obj;
                if (try go = gen_obj_raw) {
                    gen_obj = go;
                } else {
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    regs_base[result_reg].set_undefined();
                    break;
                }
                gen_obj.prototype = vm.heap.generator_proto;
                (*gen_obj.extra_ptr()).gen.generator_data = gs;

                // Return generator object as the call result
                TVal* result_slot = regs_base + result_reg;
                result_slot.set_object(gen_obj);
                break;
            }

            // New callee frame starts right after func and this in the caller frame
            // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                regs_base[result_reg].set_undefined();
                break;
            }

            regs_base = act.bottom;
            // Recompute new_bottom after realloc (act.bottom may have moved)
            new_bottom = regs_base + frame_start;

            if (vm.activation_count >= MAX_CALLS) {
                {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.range_err_proto;
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                        TVal msg_tv; msg_tv.set_string(msg_val);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        TVal err_val; err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* call_var_env2 = (*hobj.extra_ptr()).func.var_env;
            if (target.needs_env()) {
                if (try fv_c2 = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { call_var_env2 = fv_c2; }
            }
            new_act.parent = act;
            new_act.func = target;
            new_act.var_env = call_var_env2;
            new_act.lex_env = call_var_env2;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = regs_base + result_reg;
            bool is_strict = target.is_arrow() ? (act.flags & ACT_FLAG_STRICT) != 0 : target.is_strict();
            new_act.flags = is_strict ? ACT_FLAG_STRICT : 0;
            // Arrow functions use lexical this (inherited from enclosing scope)
            if (target.is_arrow()) {
                vm.heap.tval_copy_ref(&new_act.this_binding, &act.this_binding);
            } else {
                // ES5 §10.4.3: non-strict mode this coercion
                TVal raw_this = regs_base[callee_reg + 1];
                if (!is_strict) {
                    // null or undefined → global object
                    if (raw_this.is_null() || raw_this.is_undefined()) {
                        TVal global_this;
                        global_this.set_object(vm.global_env.bindings);
                        vm.heap.tval_copy_ref(&new_act.this_binding, &global_this);
                    }
                    // Primitives → ToObject wrapper
                    else if (raw_this.is_boolean()) {
                        HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                        if (try w = wrapped) {
                            w.prototype = vm.heap.bool_proto;
                            (*w.extra_ptr()).prim.primitive_value.set_boolean(raw_this.get_boolean());
                            TVal boxed; boxed.set_object(w);
                            vm.heap.tval_copy_ref(&new_act.this_binding, &boxed);
                        } else {
                            vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
                        }
                    } else if (raw_this.is_string()) {
                        HString* prim_str = (HString*)raw_this.get_heapptr();
                        HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                        if (try w = wrapped) {
                            w.flags.exotic_stringobj = true;
                            w.prototype = vm.heap.string_proto;
                            (*w.extra_ptr()).prim.primitive_value.set_string(prim_str);
                            HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            TVal len_tv; len_tv.set_fastint((long)prim_str.char_length());
                            w.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
                            TVal boxed; boxed.set_object(w);
                            vm.heap.tval_copy_ref(&new_act.this_binding, &boxed);
                        } else {
                            vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
                        }
                    } else if (raw_this.is_number() || raw_this.is_fastint()) {
                        HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                        if (try w = wrapped) {
                            w.prototype = vm.heap.number_proto;
                            vm.heap.tval_copy_ref(&(*w.extra_ptr()).prim.primitive_value, &raw_this);
                            TVal boxed; boxed.set_object(w);
                            vm.heap.tval_copy_ref(&new_act.this_binding, &boxed);
                        } else {
                            vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
                        }
                    } else {
                        vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
                    }
                } else {
                    vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
                }
            }

            TVal* new_regs = new_act.bottom;
            uint new_nregs = target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
            if (target.has_rest()) {
                // Only copy the formal parameters (not the rest parameter)
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }

                // Set missing formals to undefined (for default param checks)
                for (uint i = nargs; i < copy_count; i++) {
                    new_regs[i].set_undefined();
                }

                // Build rest array from overflow args
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a = arr_raw) {
                    a.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint i = 0; i < overflow; i++) {
                        HString* key = vm.heap.int_to_hstring((long)i);
                        if (key != null) {
                            TVal elem = old_args[copy_count + i];
                            a.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    // Set .length
                    HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)overflow);
                    a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                    new_regs[rest_idx].set_object(a);
                } else {
                    new_regs[rest_idx].set_undefined();
                }

                // Fill remaining registers with UNDEFINED (after the rest param)
                if (rest_idx + 1 < new_nregs) {
                    libc::memset(&new_regs[rest_idx + 1], 0, (usz)(new_nregs - rest_idx - 1) * TVal::size);
                }
            } else {
                // Args are already in position (new_regs == old_args, sliding window).
                // Skip self-copy when they point to the same location.
                if (new_regs != old_args) {
                    for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                        vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                    }
                }
                if (nargs < new_nregs) {
                    // Set missing parameter registers to undefined (for default param checks).
                    // Only formal parameter slots need undefined; temp registers can stay zero.
                    uint formals = (uint)target.num_formals;
                    uint undef_limit = formals < new_nregs ? formals : new_nregs;
                    if (nargs < undef_limit) {
                        for (uint zi = nargs; zi < undef_limit; zi++) {
                            new_regs[zi].set_undefined();
                        }
                    }
                    // Zero remaining registers (temps)
                    if (undef_limit < new_nregs) {
                        libc::memset(&new_regs[undef_limit], 0, (usz)(new_nregs - undef_limit) * TVal::size);
                    }
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activations
            act.curr_pc = curr_pc;

            // Direct dispatch to new activation (avoid restart overhead)
            act = new_act;
            vm.current_func = target;
            code_base = target.code;
            code_count = target.code_count;
            code_end = code_base + code_count;
            ic_base = (hobject::ICEntry*)target.ic_entries;
            var_ic_base = (hobject::VarICEntry*)target.var_ic_entries;
            constants = target.constants;
            nregs = target.num_regs;
            curr_pc = act.curr_pc;
            regs_base = act.bottom;
            continue;
        }

        case Opcode.CALL_PROP:
            ra.set_undefined();
            break;

        case Opcode.SETPROTO: {
            // A.[[Prototype]] = B
            // ABC format: A=obj_reg, B=proto_reg
            if (!ra.is_object() || !rb.is_object()) {
                // Non-object operands — silently ignore or error
                break;
            }
            HObject* obj = (HObject*)ra.get_heapptr();
            HObject* proto = (HObject*)rb.get_heapptr();
            if (obj != null && proto != null) {
                obj.prototype = proto;
            }
            break;
        }

        case Opcode.SUPER_CALL: {
            // A = super(B, args...) — call superclass constructor
            // Uses current activation's new.target
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs = insn.c;

            TVal* super_slot = regs_base + callee_reg;
            TVal super_val = *super_slot;

            if (!super_val.is_object()) {
                // TypeError: superclass is not a constructor
                HString* type_str = typeof_string(vm, &super_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            HObject* super_hobj = (HObject*)super_val.get_heapptr();
            if (super_hobj == null || !super_hobj.is_callable()) {
                // TypeError: not callable
                HString* type_str = typeof_string(vm, &super_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len2 = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                              type_str.get_cstr());
                    if (len2 > 0 && len2 < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len2]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            // Use new.target from the current activation (set by NEW_OBJ)
            HObject* new_target = act.new_target;
            if (new_target == null) {
                // Not in a constructor — new.target is undefined
                // Fall back to simple call behavior
                // This shouldn't normally happen since super() is only valid in constructors
                ra.set_undefined();
                break;
            }

            // Handle builtin super constructors
            if (super_hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*super_hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*super_hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                }
                break;
            }

            CompiledFunction* super_target = (*super_hobj.extra_ptr()).func.comp_func;

            // Set up activation frame for superclass constructor
            // The 'this' slot should already have new_target (set by caller)
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + super_target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ra.set_undefined();
                break;
            }

            regs_base = act.bottom;
            // Recompute new_bottom after realloc (act.bottom may have moved)
            new_bottom = regs_base + frame_start;

            if (vm.activation_count >= MAX_CALLS) {
                {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.range_err_proto;
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                        TVal msg_tv; msg_tv.set_string(msg_val);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        TVal err_val; err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* super_var_env = (*super_hobj.extra_ptr()).func.var_env;
            if (try fv_su = env::env_create_function_scope(vm.heap, (*super_hobj.extra_ptr()).func.var_env)) { super_var_env = fv_su; }
            new_act.parent = act;
            new_act.func = super_target;
            new_act.var_env = super_var_env;
            new_act.lex_env = super_var_env;
            new_act.cat = null;
            new_act.curr_pc = super_target.code;
            new_act.bottom = new_bottom;
            new_act.retval = regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT | (super_target.is_strict() ? ACT_FLAG_STRICT : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &regs_base[callee_reg + 1]);
            new_act.new_target = new_target;  // Pass through new.target

            TVal* new_regs = new_act.bottom;
            uint new_nregs = super_target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
            if (super_target.has_rest()) {
                uint copy_count = (uint)super_target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                HObject*? rest_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try rest_obj = rest_obj_raw) {
                    rest_obj.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint j = 0; j < overflow; j++) {
                        HString* key = vm.heap.int_to_hstring((long)j);
                        if (key != null) {
                            TVal elem = old_args[copy_count + j];
                            rest_obj.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    // Set .length
                    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)overflow);
                    rest_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
                    new_regs[rest_idx].set_object(rest_obj);
                } else {
                    new_regs[rest_idx].set_undefined();
                }
                for (uint i = copy_count + 1; i < new_nregs; i++) {
                    new_regs[i].set_undefined();
                }
            } else {
                for (uint i = 0; i < nargs && i < new_nregs; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }
                if (nargs < new_nregs) {
                    libc::memset(&new_regs[nargs], 0, (usz)(new_nregs - nargs) * TVal::size);
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activation
            act.curr_pc = curr_pc;

            needs_restart = true;
            break;
        }

        case Opcode.NEWTARGET: {
            // A = new.target
            HObject* nt = act.new_target;
            if (nt != null) {
                ra.set_object(nt);
                track_heap_store(act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.NEW_OBJ: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs = insn.c;

            TVal* func_slot = regs_base + callee_reg;
            TVal func_val = *func_slot;

            // Handle lightfunc built-in constructors (Error, TypeError, etc.)
            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                // Check if this lightfunc is actually constructable.
                // lightfunc_get_proto returns null for non-constructors
                // (e.g. Object.seal, Object.freeze, Math.max, etc.)
                HObject* ctor_proto = lightfunc_get_proto(vm, fn_idx);
                if (ctor_proto == null) {
                    HString* type_str = typeof_string(vm, &func_val);
                    HObject*? err_raw_nc = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err_nc = err_raw_nc) {
                        err_nc.prototype = vm.heap.type_err_proto;
                        char[types::ERROR_MSG_BUF] buf;
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                                 type_str.get_cstr());
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err_nc.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val_nc;
                        err_val_nc.set_object(err_nc);
                        if (!vm_throw_value(vm, err_val_nc, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    break;
                }

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((uint)(act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = regs_base[callee_reg + 1];
                ctx.is_constructor = true;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                builtins::dispatch_builtin(fn_idx, &ctx);
                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                    break;
                }
                break;
            }

            if (!func_val.is_object()) {
                // TypeError: value is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable()) {
                // TypeError: object is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = regs_base[callee_reg];
                        hobj = (HObject*)func_val.get_heapptr();
                        nargs = ctx.re_nargs;
                        // Fall through to compiled function handling below
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    break;
                }
                // Object claims to be callable but has no compiled function
                // and no builtin index — treat as non-constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;

            // Arrow functions cannot be used as constructors (ES6 §14.2.2)
            if (target.is_arrow()) {
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw3 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err3 = err_raw3) {
                    err3.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err3.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val3;
                    err_val3.set_object(err3);
                    if (!vm_throw_value(vm, err_val3, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Step 1: Create new object
            HObject*? new_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err = new_obj_raw) {
                regs_base[result_reg].set_undefined();
                break;
            }
            HObject* new_obj = new_obj_raw;

            // Step 2: Set prototype from constructor.prototype
            HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal? proto_val = hobj.get_prop_proto(proto_key);
            if (try pv = proto_val) {
                if (pv.is_object() && pv.get_heapptr() != null) {
                    new_obj.prototype = (HObject*)pv.get_heapptr();
                }
            }

            // Step 3: Place new object in this-slot
            TVal this_tval;
            this_tval.set_object(new_obj);
            vm.heap.tval_copy_ref(&regs_base[callee_reg + 1], &this_tval);
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                regs_base[result_reg].set_undefined();
                break;
            }

            regs_base = act.bottom;
            // Recompute new_bottom after realloc (act.bottom may have moved)
            new_bottom = regs_base + frame_start;
            func_slot = regs_base + callee_reg;

            if (vm.activation_count >= MAX_CALLS) {
                {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.range_err_proto;
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                        TVal msg_tv; msg_tv.set_string(msg_val);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        TVal err_val; err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* ctor_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_ct = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { ctor_var_env = fv_ct; }
            new_act.parent = act;
            new_act.func = target;
            new_act.var_env = ctor_var_env;
            new_act.lex_env = ctor_var_env;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT | (target.is_strict() ? ACT_FLAG_STRICT : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &this_tval);
            new_act.new_target = hobj;  // constructor function, not instance

            TVal* new_regs2 = new_act.bottom;
            uint new_nregs2 = target.num_regs;

            // Copy args
            TVal* old_args2 = regs_base + callee_reg + 2;
            if (target.has_rest()) {
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs2[i], &old_args2[i]);
                }

                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr2_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a2 = arr2_raw) {
                    a2.prototype = vm.heap.array_proto;
                    for (uint i = 0; i < overflow; i++) {
                        HString* key2 = vm.heap.int_to_hstring((long)i);
                        if (key2 != null) {
                            TVal elem2 = old_args2[copy_count + i];
                            a2.put_prop(key2, elem2, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    HString* len_str2 = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val2;
                    len_val2.set_fastint((long)overflow);
                    a2.put_prop(len_str2, len_val2, hobject::PROP_FLAGS_WEC);

                    new_regs2[rest_idx].set_object(a2);
                } else {
                    new_regs2[rest_idx].set_undefined();
                }

                if (rest_idx + 1 < new_nregs2) {
                    libc::memset(&new_regs2[rest_idx + 1], 0, (usz)(new_nregs2 - rest_idx - 1) * TVal::size);
                }
            } else {
                for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                    vm.heap.tval_copy_ref(&new_regs2[i], &old_args2[i]);
                }
                if (nargs < new_nregs2) {
                    zero_regs_undefined(new_regs2, nargs, new_nregs2);
                }
            }

            vm.valstack_top = (TVal*)((usz)new_regs2 + (usz)new_nregs2 * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom;

            act.curr_pc = curr_pc;
            needs_restart = true;
            break;
        }

        case Opcode.TAILCALL:
            break;

        // === GENERATORS ===

        case Opcode.LOAD_RESUME: {
            // LOAD_RESUME A — load the value passed to .next(val) into A.
            // Emitted after YIELD so the yield expression evaluates to the
            // resume value. Also handles throw/return injection: for THROW,
            // call vm_throw_value to find the nearest catcher; for RETURN,
            // mark the generator complete and return to the caller.
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_lr = vm.heap.resume_gen;
                ResumeKind rk = gs_lr.resume_kind;

                if (rk == THROW) {
                    // Inject exception: find the nearest catcher in the generator
                    TVal throw_val = gs_lr.throw_value;

                    if (!vm_throw_value(vm, throw_val, act, &curr_pc, &needs_restart)) {
                        // No catcher in generator — pop activation and
                        // propagate error to the caller's catcher chain.
                        vm.heap.resume_gen = null;
                        gs_lr.state = GEN_COMPLETED;

                        if (vm.activation_count > 0) {
                            vm.activation_count--;
                            if (vm.activation_count > 0) {
                                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                                vm.valstack_bottom = caller_act.bottom;
                                if (caller_act.func != null) {
                                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                    vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                                }

                                // Try to find a catcher in the caller's chain
                                if (!vm_throw_value(vm, throw_val, caller_act,
                                                    &caller_act.curr_pc, &needs_restart)) {
                                    // Unhandled — set error for the VM to return
                                    vm.has_error = true;
                                    vm.heap.has_error = true;
                                    if (caller_act.retval != null) {
                                        vm.heap.tval_copy_ref(caller_act.retval, &throw_val);
                                    }
                                }
                            }
                        }
                    } else {
                        // Catcher found in generator — the exception will be caught.
                        // Keep resume_gen set but switch to NEXT so the next YIELD
                        // properly saves state and sets gs.state = GEN_SUSPENDED_YIELD.
                        gs_lr.resume_kind = NEXT;
                        gs_lr.resume_value.set_undefined();
                    }
                    needs_restart = true;
                    break;
                }

                if (rk == RETURN) {
                    // Inject return: mark generator complete, return to caller
                    TVal ret_val_raw = gs_lr.return_value;
                    gs_lr.state = GEN_COMPLETED;
                    gs_lr.resume_kind = NEXT;
                    vm.heap.resume_gen = null;

                    // Wrap in IteratorResult {value: ret_val, done: true}
                    HObject*? robj_raw2 = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal ret_val;
                    if (try robj2 = robj_raw2) {
                        robj2.prototype = vm.heap.object_proto;
                        HString* val_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (val_key2 != null) robj2.put_prop(val_key2, ret_val_raw, hobject::PROP_FLAGS_WEC);
                        HString* done_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                        TVal done_val2;
                        done_val2.set_boolean(true);
                        if (done_key2 != null) robj2.put_prop(done_key2, done_val2, hobject::PROP_FLAGS_WEC);
                        ret_val.set_object(robj2);
                    } else {
                        ret_val = ret_val_raw;
                    }

                    // Pop the generator activation
                    if (vm.activation_count > 0) {
                        Activation* gen_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = gen_act.retval;
                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act.bottom;
                            if (caller_act.func != null) {
                                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                            }

                            if (ret_byteoff != null) {
                                vm.heap.tval_copy_ref(ret_byteoff, &ret_val);
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                // Normal NEXT — load resume value
                vm.heap.tval_copy_ref(&ra[0], &gs_lr.resume_value);
            } else {
                ra[0].set_undefined();
            }
            break;
        }

        case Opcode.YIELD: {
            // YIELD A — suspend generator and return {value: A, done: false}
            // heap.resume_gen was set by the .next()/.throw()/.return() builtin
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs = vm.heap.resume_gen;

                // Save current state
                TVal* regs_base_r = act.bottom;
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &regs_base_r[i]);
                }
                gs.saved_pc = curr_pc;  // curr_pc already points past YIELD
                gs.var_env = act.var_env;
                gs.lex_env = act.lex_env;
                gs.cat = act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &act.this_binding);
                gs.state = GEN_SUSPENDED_YIELD;

                // Store the yielded value
                vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);

                // Check resume kind for throw/return injection
                ResumeKind rkind = gs.resume_kind;

                if (rkind == THROW) {
                    // .throw() — inject exception at yield point
                    // Pop activation, set has_error so the outer loop
                    // re-enters the generator with an exception pending
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = true;

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = yield_act.retval;

                        // Write the exception as the result (will be caught by try/catch inside generator)
                        TVal* ret_slot = ret_byteoff;
                        vm.heap.tval_copy_ref(&ret_slot[0], &gs.throw_value);

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                if (rkind == RETURN) {
                    // .return() — inject return at yield point
                    // Mark generator as completed, return {value: rv, done: true}
                    gs.state = GEN_COMPLETED;
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = false;

                    HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal wrapped_val;
                    if (try robj = robj_raw) {
                        robj.prototype = vm.heap.object_proto;
                        HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (val_key != null) robj.put_prop(val_key, gs.return_value, hobject::PROP_FLAGS_WEC);
                        HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                        TVal done_val;
                        done_val.set_boolean(true);
                        if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                        wrapped_val.set_object(robj);
                    } else {
                        wrapped_val = gs.return_value;
                    }

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = yield_act.retval;
                        TVal* ret_slot = ret_byteoff;
                        vm.heap.tval_copy_ref(ret_slot, &wrapped_val);

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                // Normal .next() — clear resume_gen so CALL handler doesn't try to resume again
                vm.heap.resume_gen = null;
            }

            vm.heap.did_yield = true;

            // Store the yielded value for IteratorResult creation below
            vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);

            // Pop activation and return to caller (the .next() builtin's context)
            if (vm.activation_count > 0) {
                Activation* yield_act = &vm.activations[vm.activation_count - 1];
                TVal* ret_byteoff = yield_act.retval;

                // Create IteratorResult {value: yieldVal, done: false}
                HObject*? result_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                TVal wrapped_val;
                if (try robj = result_obj_raw) {
                    robj.prototype = vm.heap.object_proto;
                    HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    if (val_key != null) robj.put_prop(val_key, vm.heap.yield_value, hobject::PROP_FLAGS_WEC);
                    HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    TVal done_val;
                    done_val.set_boolean(false);
                    if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                    wrapped_val.set_object(robj);
                } else {
                    wrapped_val = vm.heap.yield_value;
                }

                // Write wrapped result to caller's frame
                TVal* ret_slot = ret_byteoff;
                vm.heap.tval_copy_ref(&ret_slot[0], &wrapped_val);

                vm.activation_count--;
                if (vm.activation_count > 0) {
                    Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = caller_act2.bottom;
                    if (caller_act2.func != null) {
                        CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                        vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                    }
                }
            }
            needs_restart = true;
            break;
        }

        case Opcode.YIELD_STAR: {
            // yield* iterable — this opcode should NOT be reached in normal
            // execution. The compiler transforms yield* into a loop of
            // GETIDX + YIELD instructions. If we get here, just set undefined.
            ra[0].set_undefined();
            break;
        }

        // === RETURNS ===

        case Opcode.RET: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers: if we're returning through
            // a try-finally, save the return value and jump to the finally
            // handler.  After ENDFINALLY, the saved value will be used.
            Catcher* ret_cat = (Catcher*)act.cat;
            if (ret_cat != null && ret_cat.finally_pc != null) {
                // Save return value
                ret_cat.return_val = *ra;
                // If PENDING_RETURN is already set, we're inside the finally
                // block that was entered due to an earlier return.  Just update
                // the return value and let execution continue normally —
                // ENDFINALLY at the end of the finally block will complete the
                // return with the new value.  Without this check, we'd loop
                // infinitely back to the same finally block.
                if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    // Jump to finally handler
                    curr_pc = ret_cat.finally_pc;
                    act.curr_pc = curr_pc;
                }
                break;
            }

            // Inline handle_return — eliminates function call overhead on every return.
            TVal val = *ra;
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // Protect the return value: if its only reference lives in a
            // callee register, decref_callee_regs below would free it.
            bool val_pinned = false;
            if (val.is_heap_allocated() && val.get_heapptr() != null) {
                ((HeapHeader*)val.get_heapptr()).incref();
                val_pinned = true;
            }

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &val);
                if (val_pinned) vm.heap.decref_tval(&val);
                return vm.return_val;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: if callee returned an object, use it; otherwise use 'this'
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (val.is_object()) {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                    }
                } else {
                    // Fast path: skip refcounting when return value is not a heap ref
                    if (!val.is_heap_allocated()) {
                        if (callee_result.is_heap_allocated()) {
                            vm.heap.decref_tval(callee_result);
                        }
                        *callee_result = val;
                    } else if (val_pinned) {
                        // Transfer the pin reference: decref dst, raw write.
                        vm.heap.decref_tval(callee_result);
                        *callee_result = val;
                        val_pinned = false;
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    }
                }
            }
            if (val_pinned) vm.heap.decref_tval(&val);
            // Restore caller state inline — skip outer loop restart.
            act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = act.bottom;
            vm.valstack_top = act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                code_base = caller_func.code;
                code_count = caller_func.code_count;
                code_end = code_base + code_count;
                constants = caller_func.constants;
                ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                nregs = caller_func.num_regs;
            }
            curr_pc = act.curr_pc;
            regs_base = act.bottom;
            continue;
        }

        case Opcode.RETUNDEF: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers (same as RET)
            Catcher* ret2_cat = (Catcher*)act.cat;
            if (ret2_cat != null && ret2_cat.finally_pc != null) {
                ret2_cat.return_val.set_undefined();
                if (!(ret2_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret2_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    curr_pc = ret2_cat.finally_pc;
                    act.curr_pc = curr_pc;
                }
                break;
            }

            TVal undef_val;
            undef_val.set_undefined();

            // Inline handle_return — eliminates function call overhead.
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                return vm.return_val;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: return 'this' (the newly created object)
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                } else {
                    // undef_val is never a heap ref — only decref dst if needed
                    if (callee_result.is_heap_allocated()) {
                        vm.heap.decref_tval(callee_result);
                    }
                    *callee_result = undef_val;
                }
            }
            // Restore caller state inline — skip outer loop restart.
            act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = act.bottom;
            vm.valstack_top = act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                code_base = caller_func.code;
                code_count = caller_func.code_count;
                code_end = code_base + code_count;
                constants = caller_func.constants;
                ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                nregs = caller_func.num_regs;
            }
            curr_pc = act.curr_pc;
            regs_base = act.bottom;
            continue;
        }

        case Opcode.RET_GEN: {
            // Generator return: mark completed, wrap in IteratorResult
            GeneratorState* gs = vm.heap.resume_gen;
            gs.state = GEN_COMPLETED;
            vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);
            vm.heap.did_yield = false;
            vm.heap.resume_gen = null;

            HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            TVal wrapped_val;
            if (try robj = robj_raw) {
                robj.prototype = vm.heap.object_proto;
                HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                if (val_key != null) robj.put_prop(val_key, ra[0], hobject::PROP_FLAGS_WEC);
                HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                TVal done_val;
                done_val.set_boolean(true);
                if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                wrapped_val.set_object(robj);
            } else {
                wrapped_val = ra[0];
            }

            Activation* ret_act = &vm.activations[vm.activation_count - 1];
            TVal* ret_byteoff = ret_act.retval;
            TVal* ret_slot = ret_byteoff;
            vm.heap.tval_copy_ref(&ret_slot[0], &wrapped_val);

            vm.activation_count--;
            if (vm.activation_count > 0) {
                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;
                if (caller_act.func != null) {
                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                    vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                }
            }
            needs_restart = true;
            break;
        }

        case Opcode.RETUNDEF_GEN: {
            // Generator return undefined: mark completed
            GeneratorState* gs2 = vm.heap.resume_gen;
            gs2.state = GEN_COMPLETED;
            vm.heap.did_yield = false;
            vm.heap.resume_gen = null;

            // Wrap in IteratorResult {value: undefined, done: true}
            HObject*? robj_raw2 = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            TVal wrapped_val2;
            if (try robj2 = robj_raw2) {
                robj2.prototype = vm.heap.object_proto;
                HString* val_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                TVal undef_val2;
                undef_val2.set_undefined();
                if (val_key2 != null) robj2.put_prop(val_key2, undef_val2, hobject::PROP_FLAGS_WEC);
                HString* done_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                TVal done_val2;
                done_val2.set_boolean(true);
                if (done_key2 != null) robj2.put_prop(done_key2, done_val2, hobject::PROP_FLAGS_WEC);
                wrapped_val2.set_object(robj2);
            } else {
                TVal undef_val2;
                undef_val2.set_undefined();
                wrapped_val2 = undef_val2;
            }

            Activation* ret_act2 = &vm.activations[vm.activation_count - 1];
            TVal* ret_byteoff2 = ret_act2.retval;
            TVal* ret_slot2 = ret_byteoff2;
            vm.heap.tval_copy_ref(&ret_slot2[0], &wrapped_val2);

            vm.activation_count--;
            if (vm.activation_count > 0) {
                Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act2.bottom;
                if (caller_act2.func != null) {
                    CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                    vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                }
            }
            needs_restart = true;
            break;
        }

        // === VARIABLE ACCESS ===

        case Opcode.GETVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                TVal v = b.prop_values()[vic.prop_idx];
                                if (!env::is_tdz_sentinel(&v)) {
                                    vm.heap.tval_copy_ref(ra, &v);
                                    track_heap_store(act, ra, (uint)insn.a);
                                    break;
                                }
                                // TDZ: fall through to slow path (error)
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full environment chain walk ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            TVal v = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v)) {
                                HString* name_hstr = (HString*)key;
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.ref_err_proto;
                                    char[types::ERROR_MSG_BUF] buf;
                                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot access '%s' before initialization",
                                                             name_hstr.get_cstr());
                                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                                        HString* msg_str = intern_string(vm, buf[:len]);
                                        TVal msg_val;
                                        msg_val.set_string(msg_str);
                                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                    }
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return VM_ERROR~;
                                    }
                                    found = true; // prevent duplicate error
                                } else {
                                    return VM_ERROR~;
                                }
                            } else {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found && act.lex_env != act.var_env) {
                        // Not in lex_env — search var_env (only needed with `with` blocks)
                        TVal? result = env::env_get(act.var_env, key);
                        if (try v2 = result) {
                            vm.heap.tval_copy_ref(ra, &v2);
                            track_heap_store(act, ra, (uint)insn.a);
                            found = true;
                        }
                    }

                    if (found) {
                        // Populate IC
                        if (var_ic_base != null && ic_env != null) {
                            uint pc_off = (uint)(curr_pc - 1 - code_base);
                            hobject::VarICEntry* vic = var_ic_base + pc_off;
                            vic.env = ic_env;
                            vic.bindings = ic_env.bindings;
                            vic.shape_id = ic_env.bindings.shape_id;
                            vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                            vic.prop_idx = (ushort)ic_prop_idx;
                            if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                            vic.key = key;
                            if (key != null) { ((types::HeapHeader*)key).incref(); }
                            vic.search_head = (void*)act.lex_env;
                        }
                    } else {
                        // ReferenceError: variable not declared
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.ref_err_proto;
                            char[types::ERROR_MSG_BUF] buf;
                            int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not defined",
                                                     name_hstr.get_cstr());
                            if (len > 0 && len < types::ERROR_MSG_BUF) {
                                HString* msg_str = intern_string(vm, buf[:len]);
                                TVal msg_val;
                                msg_val.set_string(msg_str);
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.TYPEOFIDENT: {
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // instead of throwing ReferenceError.
            // ES6: typeof on a TDZ variable THROWS ReferenceError.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                TVal v = b.prop_values()[vic.prop_idx];
                                if (!env::is_tdz_sentinel(&v)) {
                                    HString* ts = typeof_string(vm, &v);
                                    vm.heap.set_reg_string(ra, ts);
                                    break;
                                }
                                // TDZ: fall through to slow path (error)
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            TVal v = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v)) {
                                // TDZ: throw ReferenceError (ES6 behavior)
                                HString* name_hstr = (HString*)key;
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.ref_err_proto;
                                    char[types::ERROR_MSG_BUF] buf;
                                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot access '%s' before initialization",
                                                             name_hstr.get_cstr());
                                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                                        HString* msg_str = intern_string(vm, buf[:len]);
                                        TVal msg_val;
                                        msg_val.set_string(msg_str);
                                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                    }
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return VM_ERROR~;
                                    }
                                } else {
                                    return VM_ERROR~;
                                }
                            } else {
                                HString* ts = typeof_string(vm, &v);
                                vm.heap.set_reg_string(ra, ts);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found) {
                        // Not in lex_env — search var_env
                        TVal? result = env::env_get(act.var_env, key);
                        if (try v2 = result) {
                            HString* ts = typeof_string(vm, &v2);
                            vm.heap.set_reg_string(ra, ts);
                            found = true;
                        } else {
                            // Unresolvable reference → "undefined" (no error)
                            HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                            vm.heap.set_reg_string(ra, ts);
                        }
                    }

                    // Populate IC (skip for unresolvable — no env to cache)
                    if (found && var_ic_base != null && ic_env != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        vic.env = ic_env;
                        vic.bindings = ic_env.bindings;
                        vic.shape_id = ic_env.bindings.shape_id;
                        vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                        vic.prop_idx = (ushort)ic_prop_idx;
                        if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                        vic.key = key;
                        if (key != null) { ((types::HeapHeader*)key).incref(); }
                        vic.search_head = (void*)act.lex_env;
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    // Combined single-walk: check lex_env, writability, and update in one pass
                    int put_result = env::env_try_put_lex(act.lex_env, key, *ra);
                    if (put_result == -1) {
                        // Const violation — throw TypeError
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            char[types::ERROR_MSG_BUF] buf;
                            int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Assignment to constant variable '%s'",
                                                     name_hstr.get_cstr());
                            if (len > 0 && len < types::ERROR_MSG_BUF) {
                                HString* msg_str = intern_string(vm, buf[:len]);
                                TVal msg_val;
                                msg_val.set_string(msg_str);
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == 0) {
                        // Not in lex_env — fall through to var_env
                        env::env_put(act.var_env, key, *ra);
                    }
                    // put_result == 1: already updated in lex_env
                    // Release ra's ref — the binding now owns the reference.
                    // Without this, ra holds a stale ref into the next iteration,
                    // causing strings to leak (not reach rc=0 on binding overwrite).
                    vm.heap.decref_tval(ra);
                    ra.set_undefined();
                }
            }
            break;
        }

        case Opcode.DECLVAR: {
            // Declare a `var` binding in the immediate var_env only (no chain walk).
            // Skip entirely for non-global functions with needs_env=false: all var
            // accesses in those functions are register-based (resolve_var found them),
            // so writing to the env is unnecessary — no closure or eval reads it.
            if (!vm.current_func.needs_env() && !vm.current_func.is_global_fn()) break;
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- VarIC fast path: skip find_prop_idx on repeat calls ---
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        if (vic.env == (void*)act.var_env && vic.key == key) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b != null && b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Direct write — skip find_prop_idx + put_prop overhead
                                TVal* pv = &b.prop_values()[vic.prop_idx];
                                if (hobject::_active_heap != null && pv.is_string()) {
                                    ((heap::Heap*)hobject::_active_heap).decref_tval(pv);
                                }
                                *pv = *ra;
                                if (hobject::_active_heap != null && ra.is_string()) {
                                    void* ptr = ra.get_heapptr();
                                    if (ptr != null) ((types::HeapHeader*)ptr).incref();
                                }
                                break;
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full env_declare ---
                    env::env_declare(act.var_env, key, *ra);

                    // Populate VarIC for next time
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        HObject* b = act.var_env.bindings;
                        if (b != null) {
                            int idx = b.find_prop_idx(key);
                            if (idx >= 0) {
                                vic.env = (void*)act.var_env;
                                vic.bindings = (void*)b;
                                vic.shape_id = b.shape_id;
                                vic.generation = vm.heap.shapes[b.shape_id].generation;
                                vic.prop_idx = (ushort)idx;
                                vic.key = key;
                                vic.search_head = null;
                            }
                        }
                    }
                }
            }
            break;
        }

        case Opcode.PUTLEX: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    env::env_declare_lex(act.lex_env, key, *ra);
                }
            }
            break;
        }

        case Opcode.PUTLEX_C: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    act.lex_env.bindings.put_prop(key, *ra, hobject::PROP_FLAGS_EC);
                }
            }
            break;
        }

        case Opcode.INITTZ: {
            // Store the TDZ sentinel for a variable name in the current
            // lexical environment.  This marks the binding as uninitialized
            // so that GETVAR throws a ReferenceError (temporal dead zone)
            // if the variable is accessed before its PUTLEX/PUTLEX_C.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    TVal tdz = env::tdz_sentinel();
                    act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC);
                }
            }
            break;
        }

        case Opcode.DELVAR:
            ra.set_boolean(true);
            break;

        // === CLOSURES ===

        case Opcode.CLOSURE: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.inner_count) {
                CompiledFunction* template = vm.current_func.inner_funcs[bc];

                HObject*? func_obj_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (try func_obj = func_obj_raw) {
                    func_obj.prototype = vm.heap.function_proto;
                    func_obj.flags.callable = true;
                    func_obj.flags.constructable = template.is_constructable();
                    (*func_obj.extra_ptr()).func.comp_func = template;
                    (*func_obj.extra_ptr()).func.var_env = act.var_env;
                    (*func_obj.extra_ptr()).func.lex_env = act.lex_env;

                    // Set .name property (ES6 §14.1.20: non-writable, non-enumerable, configurable)
                    // Always set name — anonymous functions get "" per spec
                    char[] name_data = template.get_name();
                    HString* name_hstr;
                    if (name_data.len > 0) {
                        name_hstr = intern_string(vm, name_data);
                    } else {
                        name_hstr = (HString*)vm.heap.strs[heap::BuiltinStr.EMPTY];
                    }
                    if (name_hstr != null) {
                        TVal name_tv;
                        name_tv.set_string(name_hstr);
                        func_obj.put_prop((HString*)vm.heap.strs[heap::BuiltinStr.NAME], name_tv, hobject::PROP_FLAGS_NWC);
                    }

                    // Set .length property (ES5 §15.3.5.1: non-writable, non-enumerable, configurable)
                    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)template.num_formals);
                    func_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_NWC);

                    // Arrow functions don't get a .prototype property (ES6 §14.2.16)
                    if (!template.is_arrow()) {
                        // ES5 §13.2: create .prototype property (plain object with .constructor)
                        HObject*? proto_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                        if (try proto_obj = proto_obj_raw) {
                            proto_obj.prototype = vm.heap.object_proto;
                            // Set .constructor on the prototype object
                            HString* constr_key = (HString*)vm.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
                            TVal constr_val;
                            constr_val.set_object(func_obj);
                            proto_obj.put_prop(constr_key, constr_val, hobject::PROP_FLAGS_WEC);
                            // Set .prototype on the function
                            HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                            TVal proto_tv;
                            proto_tv.set_object(proto_obj);
                            func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WEC);
                        }
                    }

                    ra.set_object(func_obj);
                    track_heap_store(act, ra, (uint)insn.a);
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.GETBOUND: {
            uint bc = insn.get_bc();
            // Constants[bc] = FASTINT depth, constants[bc+1] = STRING name
            if (bc + 1 < vm.current_func.const_count) {
                TVal depth_val = constants[bc];
                TVal name_val = constants[bc + 1];
                if ((depth_val.is_fastint() || depth_val.is_number()) && name_val.is_string()) {
                    uint depth = (uint)(depth_val.is_fastint() ? depth_val.get_fastint() : (long)depth_val.get_number());
                    void* key = name_val.get_heapptr();
                    TVal? result = env::env_get_at_depth(act.lex_env, depth, key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(act, ra, (uint)insn.a);
                    } else {
                        // Also check var_env if different
                        if (act.lex_env != act.var_env) {
                            result = env::env_get_at_depth(act.var_env, depth, key);
                            if (try v2 = result) {
                                vm.heap.tval_copy_ref(ra, &v2);
                                track_heap_store(act, ra, (uint)insn.a);
                                break;
                            }
                        }
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        // === ITEraTOR ===

        case Opcode.INITFOR: {
            // ra = object to enumerate, rb = iter_state (output)
            // null/undefined → skip loop (rb = null marker)
            if (ra.is_null() || ra.is_undefined()) {
                rb.set_null();
                break;
            }

            // Get the object (ToObject for primitives)
            HObject* obj;
            if (ra.is_object()) {
                obj = (HObject*)ra.get_heapptr();
            } else if (ra.is_boolean()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                (*obj.extra_ptr()).prim.primitive_value.set_boolean(ra.get_boolean());
            } else if (ra.is_string()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.flags.exotic_stringobj = true;
                obj.prototype = vm.heap.string_proto;
                HString* prim_str = (HString*)ra.get_heapptr();
                (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
                // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable.
                // Indexed character properties are served lazily via exotic_stringobj during enumeration.
                HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv;
                len_tv.set_fastint((long)prim_str.char_length());
                obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            } else if (ra.is_number() || ra.is_fastint()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                vm.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, ra);
            } else {
                rb.set_null();
                break;
            }

            // Collect enumerable keys
            ForInState* state = collect_forin_keys(vm, obj);
            if (state == null) {
                rb.set_null();
                break;
            }
            rb.set_pointer(state);
            break;
        }

        case Opcode.NEXTFOR: {
            // ra = iter_var (output key), rb = has_next (output bool)
            // rc = iter_state (input ForInState*)
            ForInState* state = (ForInState*)rc.get_heapptr();
            if (state == null || state.index >= state.count) {
                // No more keys — clean up and signal done
                if (state != null) {
                    libc::free(state.keys);
                    libc::free(state);
                }
                rb.set_boolean(false);
                ra.set_undefined();
                break;
            }

            // Return the next key
            vm.heap.set_reg_string(ra, state.keys[state.index]);
            state.index++;
            rb.set_boolean(true);
            break;
        }

        // === EXCEPTION HANDLING ===

        case Opcode.TRY: {
            // Encoding: A = flags (bit0=catch, bit1=finally)
            //           BC = catch_offset (from TRY PC to CATCH instruction)
            // The next instruction word stores finally_offset in its BC field.
            uint flags = insn.a;
            uint catch_offset = insn.get_bc();

            // Read the jump slot (next instruction word) for finally_offset
            Instruction jump_slot = *curr_pc;
            curr_pc++;
            act.curr_pc = curr_pc;
            uint finally_offset = jump_slot.get_bc(); // BC field stores finally offset

            // Compute absolute handler PCs
            Instruction* base_pc = curr_pc - 2; // back to TRY instruction
            Instruction* catch_pc = base_pc + (int)catch_offset;
            Instruction* finally_pc = (finally_offset != 0)
                ? (base_pc + (int)finally_offset)
                : null;

            // Allocate catcher
            Catcher* cat = (Catcher*)libc::malloc(Catcher::size);
            if (cat == null) {
                // Out of memory — skip catcher creation, try block will run unprotected
                break;
            }
            cat.parent = (Catcher*)act.cat;
            cat.flags = flags;
            cat.thrown_val.set_undefined();
            cat.catch_pc = catch_pc;
            cat.finally_pc = finally_pc;

            act.cat = (void*)cat;
            break;
        }

        case Opcode.ENDTRY: {
            // Pop the catcher (normal exit from try block)
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null) {
                act.cat = (void*)cat.parent;
                libc::free(cat);
            }
            break;
        }

        case Opcode.THROW: {
            TVal thrown_val = *ra;
            if (!vm_throw_value(vm, thrown_val, act, &curr_pc, &needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &thrown_val);
                vm.heap.tval_copy_ref(&vm.return_val, &thrown_val);
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.CATCH: {
            // Read the thrown exception from the nearest catcher
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null) {
                vm.heap.tval_copy_ref(ra, &cat.thrown_val);
                track_heap_store(act, ra, (uint)insn.a);

                // Clear thrown value
                cat.thrown_val.set_undefined();

                // Clear VM-level error flags — the throw has been caught.
                // Without this, a phantom vm.has_error from a deep throw
                // persists and causes phantom errors in subsequent call_fn
                // invocations (e.g., ToPrimitive valueOf/toString).
                vm.has_error = false;
                vm.heap.has_error = false;

                // If no finally handler, pop the catcher now.
                // If there IS a finally, keep the catcher on the chain so that
                // re-throws in the catch block are handled by the finally handler.
                if (cat.finally_pc == null) {
                    act.cat = (void*)cat.parent;
                    libc::free(cat);
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.FINALLY:
            // No-op marker — the catcher's finally_pc points here.
            // When entered via normal fall-through (after catch or via jump),
            // there may or may not be a catcher on the chain.
            // Mark the catcher as "in finally" so that vm_throw_value skips it
            // if a throw occurs inside the finally block (prevents infinite loop).
            {
                Catcher* fin_cat = (Catcher*)act.cat;
                if (fin_cat != null) {
                    fin_cat.flags |= CATCHER_FLAG_IN_FINALLY;
                }
            }
            break;

        case Opcode.ENDFINALLY: {
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null && (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save pending state before freeing the catcher
                bool has_pending_exc = (!cat.thrown_val.is_undefined());
                TVal pending_exc_val = cat.thrown_val;
                bool has_pending_ret = (cat.flags & CATCHER_FLAG_PENDING_RETURN) != 0;
                TVal saved_ret_val = cat.return_val;
                bool has_pending_break = (cat.flags & CATCHER_FLAG_PENDING_BREAK) != 0;
                bool has_pending_continue = (cat.flags & CATCHER_FLAG_PENDING_CONTINUE) != 0;
                Instruction* saved_pending_pc = cat.pending_pc;
                Catcher* parent_cat = (Catcher*)cat.parent;

                // Pop the finally catcher
                act.cat = (void*)parent_cat;
                libc::free(cat);

                if (has_pending_ret) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending return through it before completing.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.return_val = saved_ret_val;
                        parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                        curr_pc = parent_cat.finally_pc;
                        act.curr_pc = curr_pc;
                        break;
                    }
                    // Complete the return that was intercepted by the finally block.
                    TVal val = saved_ret_val;
                    Activation* callee_act = &vm.activations[vm.activation_count - 1];
                    TVal* callee_result = callee_act.retval;

                    bool val_pinned = false;
                    if (val.is_heap_allocated() && val.get_heapptr() != null) {
                        ((HeapHeader*)val.get_heapptr()).incref();
                        val_pinned = true;
                    }

                    decref_callee_regs(vm, callee_act);

                    vm.activation_count--;

                    if (vm.activation_count == 0) {
                        vm.heap.tval_copy_ref(&vm.return_val, &val);
                        if (val_pinned) vm.heap.decref_tval(&val);
                        return vm.return_val;
                    }
                    if (callee_result != null) {
                        if (!val.is_heap_allocated()) {
                            if (callee_result.is_heap_allocated()) {
                                vm.heap.decref_tval(callee_result);
                            }
                            *callee_result = val;
                        } else if (val_pinned) {
                            vm.heap.decref_tval(callee_result);
                            *callee_result = val;
                            val_pinned = false;
                        } else {
                            vm.heap.tval_copy_ref(callee_result, &val);
                        }
                    }
                    if (val_pinned) vm.heap.decref_tval(&val);
                    act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = act.bottom;
                    vm.valstack_top = act.caller_valstack_top;
                    CompiledFunction* caller_func = (CompiledFunction*)act.func;
                    if (caller_func != vm.current_func) {
                        vm.current_func = caller_func;
                        code_base = caller_func.code;
                        code_count = caller_func.code_count;
                        code_end = code_base + code_count;
                        constants = caller_func.constants;
                        ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                        var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                        nregs = caller_func.num_regs;
                    }
                    curr_pc = act.curr_pc;
                    regs_base = act.bottom;
                    break;
                }

                if (has_pending_break || has_pending_continue) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending break/continue through it first.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.pending_pc = saved_pending_pc;
                        if (has_pending_break) {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                        } else {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                        }
                        curr_pc = parent_cat.finally_pc;
                        act.curr_pc = curr_pc;
                        break;
                    }
                    // All finally blocks have run — complete the break/continue
                    // by jumping to the saved target.
                    curr_pc = saved_pending_pc;
                    act.curr_pc = curr_pc;
                    break;
                }

                if (has_pending_exc) {
                    // Re-throw the pending exception
                    if (!vm_throw_value(vm, pending_exc_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                }
            }
            break;
        }

        // === MISC ===

        case Opcode.NOP:
            break;

        case Opcode.DEBUGGER:
            break;

        case Opcode.BREAK:
        case Opcode.CONTINUE: {
            // Compute the jump target from the signed 24-bit offset
            int sabc = insn.get_sabc();
            int target = (int)((long)(curr_pc - code_base) + (long)sabc);
            Instruction* target_pc = code_base + target;

            // Check if any active catcher has a finally handler that
            // would be bypassed by this jump.  If so, save the target
            // and redirect to the finally handler.
            Catcher* bc_cat = (Catcher*)act.cat;
            if (bc_cat != null && bc_cat.finally_pc != null
                && (bc_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save the pending jump target and flag on the catcher
                bc_cat.pending_pc = target_pc;
                if (insn.op == Opcode.BREAK) {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                } else {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                }
                // Jump to the finally handler
                curr_pc = bc_cat.finally_pc;
                act.curr_pc = curr_pc;
                break;
            }
            // No active finally handler — jump directly to target
            if (target < (curr_pc - code_base)) {
                if (--vm.heap.bwd_gc_budget == 0) {
                    if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
                    vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
                }
            }
            curr_pc = target_pc;
            break;
        }

        case Opcode.INITGET: {
            // A=object, B=key, C=getter_function
            // Define a getter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal getter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initget_props = hobj.prop_values();
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's getter
                        hobject::hobject_set_access_getter(initget_props[idx], getter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, getter_val, undef), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
            }
            break;
        }

        case Opcode.INITSET: {
            // A=object, B=key, C=setter_function
            // Define a setter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal setter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initset_props = hobj.prop_values();
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's setter
                        hobject::hobject_set_access_setter(initset_props[idx], setter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, undef, setter_val), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
            }
            break;
        }

        case Opcode.INITSETI:
            break;

        case Opcode.CSVARI:
            break;

        // === WITH STATEMENT ===

        case Opcode.WITH_START: {
            // Register A holds the with-object.  Call ToObject
            // (primitives are wrapped), then push a new env record onto
            // the current activation's var_env chain.
            TVal obj_val = *ra;
            HObject* obj;

            if (obj_val.is_object()) {
                obj = (HObject*)obj_val.get_heapptr();
            } else if (obj_val.is_null() || obj_val.is_undefined()) {
                // TypeError: with cannot be applied to null/undefined
                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[80] buf;
                    int len = libc::snprintf(&buf, 80,
                        "Cannot use 'with' on %s",
                        (obj_val.is_null() ? "null" : "undefined"));
                    if (len > 0 && len < 80) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            } else if (obj_val.is_boolean()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                (*obj.extra_ptr()).prim.primitive_value.set_boolean(obj_val.get_boolean());
            } else if (obj_val.is_string()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { break; }
                obj = wrapped;
                obj.flags.exotic_stringobj = true;
                obj.prototype = vm.heap.string_proto;
                HString* prim_str = (HString*)obj_val.get_heapptr();
                (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
                // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable.
                // Indexed character properties are served lazily via exotic_stringobj during enumeration.
                HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv;
                len_tv.set_fastint((long)prim_str.char_length());
                obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            } else if (obj_val.is_number() || obj_val.is_fastint()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                vm.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, &obj_val);
            } else {
                // POINTER or BUFFER
                break;
            }

            // Create a with-env record wrapping the object and push it
            // onto the current activation's var_env.
            EnvRecord*? env_raw = env::env_create_with_object(vm.heap, act.var_env, obj);
            if (try new_env = env_raw) {
                act.var_env = new_env;
            } else {
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.WITH_END: {
            // Pop the current with-env from the scope chain.
            // NOTE: we do NOT free the env record here because a closure
            // created inside the `with` block may have captured it via
            // (*func_obj.extra_ptr()).func.var_env = act.var_env (see CLOSURE opcode).
            // Freeing it would leave a dangling pointer in the closure
            // and crash on subsequent env_get calls.
            if (act.var_env != null && act.var_env.parent != null) {
                act.var_env = act.var_env.parent;
            }
            break;
        }

        case Opcode.PUSH_LEX: {
            // Push a new declarative environment record onto act.lex_env.
            EnvRecord*? env_raw = env::env_create_declarative(vm.heap, act.lex_env);
            if (try new_env = env_raw) {
                act.lex_env = new_env;
            } else {
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.POP_LEX: {
            // Pop the current lexical environment from the scope chain.
            if (act.lex_env != null && act.lex_env.parent != null) {
                act.lex_env = act.lex_env.parent;
            }
            break;
        }

        default:
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}