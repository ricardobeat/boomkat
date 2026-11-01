module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::re_bindings;
import boomkat::dtoa_bindings;
import std::io;
import std::math;

// ============================================================================
// Helpers
// ============================================================================

// Convert a value known to be numeric (FASTINT or NUMBER) to double.
fn double tval_numeric_to_double(TVal* val) @inline {
    return val.is_fastint() ? (double)val.get_fastint() : val.get_number();
}

// ECMA-262 ToNumber: https://tc39.es/ecma262/#sec-tonumber
fn double vm_to_number(Vm* vm, TVal* val) {
    switch (val.get_tag()) {
        case FASTINT: return (double)val.get_fastint();
        case NUMBER:  return val.get_number();
        case BOOLEAN: return val.get_boolean() ? 1.0 : 0.0;
        case UNDEFINED: return double::nan;
        case NULL_VAL:  return 0.0;
        case STRING: {
            HString* hstr = (HString*)val.get_heapptr();
            if (hstr != null && hstr.is_symbol()) {
                vm_set_type_error(vm, "Cannot convert a Symbol value to a number");
                return double::nan;
            }
            return builtins::builtin_string_to_number(hstr);
        }
        case BIGINT:
            vm_set_type_error(vm, "Cannot convert a BigInt value to a number");
            return double::nan;
        case OBJECT: {
            // ToPrimitive with hint "number". The hint matters because Date's
            // @@toPrimitive treats only "default" as string-first.
            TVal prim = to_primitive_value(vm, val, 2);
            if (prim.get_tag() == OBJECT) return double::nan;
            return vm_to_number(vm, &prim);
        }
        default: return double::nan;
    }
}

// ECMA-262 ToInt32: https://tc39.es/ecma262/#sec-toint32
fn int toint32(double d) @inline {
    // Fast path for values that fit in int32. The range check must precede the cast:
    // (int)d is undefined for out-of-range d, and at -O2 LLVM may fold away the
    // `(double)i == d` guard.
    if (d >= -2147483648.0 && d <= 2147483647.0) {
        int i = (int)d;
        if ((double)i == d) return i;
    }
    // NaN / ±Infinity → 0
    if (math::is_nan(d) || !math::is_finite(d)) return 0;
    // Spec: posInt = sign(d) * floor(abs(d)); int32bit = posInt mod 2^32
    double abs_d = math::abs(d);
    double pos_int = math::floor(abs_d);
    if (d < 0.0) pos_int = -pos_int;
    double q = pos_int * (1.0 / 4294967296.0);
    q = math::floor(q);
    double r = pos_int - q * 4294967296.0;   // r in [0, 2^32)
    if (r >= 2147483648.0) r -= 4294967296.0;
    return (int)r;
}

// ECMA-262 IsLessThan: https://tc39.es/ecma262/#sec-islessthan
// Returns -1, +1 or 0. Sets *is_undef when either operand is NaN. Sets vm.throw_pending
// on a ToPrimitive failure; the caller must check it.
fn int vm_relational_compare(Vm* vm, TVal* x, TVal* y, bool* is_undef) {
    *is_undef = false;
    TVal px = *x;
    TVal py = *y;
    if (px.get_tag() == OBJECT) {
        px = to_primitive_value(vm, x, 2);  // hint: number
        if (vm.throw_pending) return 0;
    }
    if (py.get_tag() == OBJECT) {
        py = to_primitive_value(vm, y, 2);
        if (vm.throw_pending) return 0;
    }
    // Symbols are string-tagged internally, so exclude them from the lexical compare.
    if (px.is_string() && py.is_string()) {
        HString* sx = (HString*)px.get_heapptr();
        HString* sy = (HString*)py.get_heapptr();
        if (!(sx != null && sx.is_symbol()) && !(sy != null && sy.is_symbol())) {
            int c = hstring::units_compare(sx, sy);
            return c < 0 ? -1 : (c > 0 ? 1 : 0);
        }
    }

    // === BigInt operands: compare by mathematical value ===
    if (px.is_bigint() || py.is_bigint()) {
        int r = vm_bigint_relational(vm, &px, &py, is_undef);
        return r;
    }

    double dx = vm_to_number(vm, &px);
    if (vm.throw_pending) return 0;
    double dy = vm_to_number(vm, &py);
    if (vm.throw_pending) return 0;
    if (math::is_nan(dx) || math::is_nan(dy)) { *is_undef = true; return 0; }
    if (dx < dy) return -1;
    if (dx > dy) return 1;
    return 0;
}

// ECMA-262 ToBoolean. An [[IsHTMLDDA]] object is also falsy (Annex B).
macro bool is_truthy(TVal* val, Heap* h) {
    if (val.is_object()) {
        return h.htmldda_obj == null || val.get_heapptr() != (void*)h.htmldda_obj;
    }
    // BigInt is falsy only when it is 0n.
    if (val.is_bigint()) {
        return !val.get_bigint().is_zero();
    }
$if types::USE_NANBOX:
    ulong tag = val.bits >> 48;
    if (tag == types::TAG_UNDEFINED ||
        tag == types::TAG_NULL_VAL ||
        val.bits == (types::TAG_BOOLEAN << 48)) {
        return false;
    }
    // Fastint: sign-extend the 48-bit payload.
    if (tag == types::TAG_FASTINT) {
        long fi = ((long)(val.bits & types::NANBOX_PAYLOAD_MASK) << 16) >> 16;
        return fi != 0;
    }
    if (types::nanbox_is_double(val.bits)) {
        double d = bitcast(val.bits, double);
        return d != 0.0 && !math::is_nan(d);
    }
    if (tag == types::TAG_STRING) {
        HString* s = (HString*)(val.bits & types::NANBOX_PAYLOAD_MASK);
        return s.is_truthy();
    }
    return true;
$else
    switch (val.get_tag()) {
        case UNDEFINED: return false;
        case NULL_VAL:  return false;
        case BOOLEAN:   return val.get_boolean();
        case NUMBER:    return val.get_number() != 0.0 && !math::is_nan(val.get_number());
        case FASTINT:   return val.get_fastint() != 0;
        case STRING:    return ((HString*)val.get_heapptr()).is_truthy();
        case OBJECT:    return true;
        case LIGHTFUNC: return true;
        default:        return true;
    }
$endif
}

// Ensure the value stack holds at least `needed` slots from its base. `needed` is an
// absolute index, the end of the frame being entered, not a count from the current top.
fn bool ensure_valstack(Vm* vm, uint needed) @inline {
    // Native calls publish four scratch slots above the register window.
    needed += 4;
    if (needed <= (uint)(vm.valstack_end - vm.valstack)) {
        return true;
    }
    return ensure_valstack_grow(vm, needed);
}

fn bool ensure_valstack_grow(Vm* vm, uint needed) {
    TVal* old_base = vm.valstack;
    uint new_size = vm.valstack_size;
    while (new_size < needed) {
        new_size *= 2;
    }
    usz old_bytes = (usz)vm.valstack_size * TVal::size;
    usz new_bytes = (usz)new_size * TVal::size;
    void* new_raw;
    if (vm.async_stack_state != null) {
        new_raw = vm.heap.alloc_generator_registers(new_bytes);
        if (new_raw != null) {
            mem::copy(new_raw, vm.valstack, (sz)old_bytes);
            vm.heap.free_scanned(vm.valstack, old_bytes);
            vm.async_stack_state.saved_regs = (TVal*)new_raw;
            vm.async_stack_state.async_regs_capacity = new_size;
        }
    } else {
        new_raw = vm.heap.realloc_func(vm.heap.heap_udata, vm.valstack, new_bytes);
    }
    if (new_raw == null) {
        return false;
    }
    // realloc does not zero the grown tail, and stale bits there would be read as live heap
    // pointers by tval_copy_ref's destination decref. vm_create zeroes its first allocation too.
    mem::clear((char*)new_raw + old_bytes, (sz)(new_bytes - old_bytes));
    TVal* new_base = (TVal*)new_raw;
    long diff = (char*)new_base - (char*)old_base;

    vm.valstack = new_base;
    vm.valstack_size = new_size;
    vm.valstack_top = (TVal*)((char*)vm.valstack_top + diff);
    vm.valstack_end = (TVal*)((char*)new_base + (usz)(new_size * TVal::size));
    vm.valstack_bottom = (TVal*)((char*)vm.valstack_bottom + diff);

    // Rebase activation pointers into the old buffer. A stale caller_valstack_top would be
    // restored into valstack_top on RET, desyncing it from valstack.
    for (uint i = 0; i < vm.activation_count; i++) {
        Activation* a = &vm.activations[i];
        a.bottom = (TVal*)((char*)a.bottom + diff);
        if (a.retval != null) {
            a.retval = (TVal*)((char*)a.retval + diff);
        }
        if (a.caller_valstack_top != null) {
            a.caller_valstack_top = (TVal*)((char*)a.caller_valstack_top + diff);
        }
    }
    // Rebase only shadow frames whose segment lives in the buffer that grew.
    for (ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
         shadow != null; shadow = (ShadowActFrame*)shadow.prev) {
        if (shadow.stack_base != old_base) continue;
        shadow.stack_base = new_base;
        shadow.stack_end = new_base + new_size;
        for (uint i = 0; i < shadow.count; i++) {
            Activation* a = &shadow.acts[i];
            if (a.bottom != null) a.bottom = (TVal*)((char*)a.bottom + diff);
            if (a.retval != null) a.retval = (TVal*)((char*)a.retval + diff);
            if (a.caller_valstack_top != null) {
                a.caller_valstack_top = (TVal*)((char*)a.caller_valstack_top + diff);
            }
        }
    }

    // Update heap's valstack GC root pointers (base may have moved)
    vm.heap.valstack_base = vm.valstack;
    // valstack_top_ptr still points to vm.valstack_top (stable struct field)

    return true;
}

// Get the current activation. Returns null if no activations.
fn Activation* curr_act(Vm* vm) @inline {
    if (vm.activation_count == 0) return null;
    assert(vm.activation_count <= vm.activation_capacity);
    return &vm.activations[vm.activation_count - 1];
}

// Convert a TVal to an interned string key, per ECMA-262 ToPropertyKey.
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
        case BIGINT:
            if (try s = vm_bigint_to_string(vm, val.get_bigint())) return s;
            return null;
        case BOOLEAN:
            if (val.get_boolean()) return h.strs[heap::BuiltinStr.TRUE];
            return h.strs[heap::BuiltinStr.FALSE];
        case UNDEFINED: return h.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:  return h.strs[heap::BuiltinStr.NULL_STR];
        case OBJECT: {
            // Objects take ToPrimitive with hint "string". Sets throw_pending on failure.
            TVal prim = to_primitive_value(vm, val, 1);
            if (vm != null && vm.throw_pending) return null;
            if (prim.get_tag() != OBJECT) {
                TVal tmp = prim;
                return get_prop_key(vm, &tmp);
            }
            if (vm != null) vm_set_toprimitive_error(vm);
            return null;
        }
        default:        return h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

// Returns the .prototype object of a builtin constructor, or null for other indices.
fn HObject* lightfunc_get_proto(Vm* vm, uint fn_idx) {
    switch (fn_idx) {
        case builtins::Builtin.ERROR.ordinal:           return vm.heap.err_proto;
        case builtins::Builtin.TYPE_ERROR.ordinal:      return vm.heap.type_err_proto;
        case builtins::Builtin.RANGE_ERROR.ordinal:     return vm.heap.range_err_proto;
        case builtins::Builtin.REFERENCE_ERROR.ordinal: return vm.heap.ref_err_proto;
        case builtins::Builtin.SYNTAX_ERROR.ordinal:    return vm.heap.syntax_err_proto;
        case builtins::Builtin.EVAL_ERROR.ordinal:      return vm.heap.eval_err_proto;
        case builtins::Builtin.BOOLEAN.ordinal:         return vm.heap.bool_proto;
        case builtins::Builtin.STRING.ordinal:          return vm.heap.string_proto;
        case builtins::Builtin.NUMBER.ordinal:          return vm.heap.number_proto;
        case builtins::Builtin.OBJECT.ordinal:          return vm.heap.object_proto;
        case builtins::Builtin.ARRAY.ordinal:           return vm.heap.array_proto;
        case builtins::Builtin.FUNCTION.ordinal:        return vm.heap.function_proto;
        case builtins::Builtin.DATE.ordinal:            return vm.heap.date_proto;
        case builtins::Builtin.REGEXP.ordinal:          return vm.heap.regexp_proto;
        case builtins::Builtin.MAP.ordinal:             return vm.heap.map_proto;
        case builtins::Builtin.SET.ordinal:             return vm.heap.set_proto;
        case builtins::Builtin.WEAKMAP.ordinal:         return vm.heap.weakmap_proto;
        case builtins::Builtin.WEAKSET.ordinal:         return vm.heap.weakset_proto;
        case builtins::Builtin.WEAKREF.ordinal:         return vm.heap.weakref_proto;
        case builtins::Builtin.FINALIZATION_REGISTRY.ordinal: return vm.heap.finalization_registry_proto;
        case builtins::Builtin.SYMBOL.ordinal:          return vm.heap.symbol_proto;
        case builtins::Builtin.PROMISE.ordinal:         return vm.heap.promise_proto;
        case builtins::Builtin.GENERATOR_FUNCTION.ordinal: return vm.heap.generator_proto;
        case builtins::Builtin.URI_ERROR.ordinal: return vm.heap.uri_err_proto;
        case builtins::Builtin.AGGREGATE_ERROR.ordinal: return vm.heap.aggregate_err_proto;
        default: return null;
    }
}

// True when the builtin at `fn_idx` is a constructor. The FUNCTION object flag cannot tell
// them apart (all builtins are allocated constructable), so classify by index: the lightfunc
// constructor table, then the Builtin enum's `constructable` value.
fn bool builtin_fn_is_constructor(Vm* vm, uint fn_idx) {
    // Host functions carry their own flag. Checked first because lightfunc_get_proto
    // would index its table with a host index.
    if (fn_idx >= builtins::HOST_FN_BASE) {
        if (vm == null || vm.heap == null) return false;
        heap::HostFnEntry* entry = vm.heap.host_fn_at(fn_idx - builtins::HOST_FN_BASE);
        return entry != null && entry.constructable;
    }
    if (lightfunc_get_proto(vm, fn_idx) != null) return true;
    if (fn_idx >= builtins::Builtin.LAST.ordinal) {
        $if !$feat(TEMPORAL):
            return false;
        $else
            return builtins::temporal_is_constructor(fn_idx);
        $endif
    }
    return ((builtins::Builtin)fn_idx).constructable;
}

fn TVal get_prop_with_proto(HObject* obj, void* key, Heap* h) {
    TVal? result = obj.get_prop_proto(key, h);
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

fn HString* intern_string(Vm* vm, char[] data) {
    return vm.heap.str_intern(data);
}

// ECMA-262 typeof: https://tc39.es/ecma262/#sec-typeof-operator
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
            // An [[IsHTMLDDA]] object reports "undefined" even when callable (Annex B).
            if (hobj != null && hobj == h.htmldda_obj) {
                return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
            }
            if (hobj != null && hobj.is_callable()) {
                return (HString*)h.strs[heap::BuiltinStr.FUNCTION];
            }
            return (HString*)h.strs[heap::BuiltinStr.OBJECT];
        case LIGHTFUNC: return (HString*)h.strs[heap::BuiltinStr.FUNCTION];
        case BIGINT:    return (HString*)h.strs[heap::BuiltinStr.BIGINT];
        default:        return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

// Name for a value in an "X is not iterable" TypeError: the typeof name, except that null
// names itself rather than "object".
fn HString* iterable_value_desc(Vm* vm, TVal* val) {
    if (val.is_null()) return (HString*)vm.heap.strs[heap::BuiltinStr.NULL_STR];
    return typeof_string(vm, val);
}

// Convert a double to an interned HString* using shortest round-trip formatting.
fn HString*? vm_number_to_string(Vm* vm, double val) {
    if (math::is_nan(val)) {
        return (HString*)vm.heap.strs[heap::BuiltinStr.NAN_STR];
    }
    if (math::is_inf(val)) {
        return (HString*)((val > 0.0)
            ? vm.heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
            : vm.heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY]);
    }

    // -0 converts to "0".
    if (val == 0.0) {
        return vm.heap.int_to_hstring(0);
    }

    // Integers below 2^53 are exact, so their digits are already the shortest round-trip form.
    // Larger values go through dtoa.
    if (val == math::trunc(val) && val > -9007199254740992.0 && val < 9007199254740992.0) {
        return vm.heap.int_to_hstring((long)val);
    }

    // The dtoa shortest-digit routine emits the shortest round-trip decimal in ECMA-262
    // Number::toString format. A truncate-and-retry loop cannot produce e.g.
    // "7.300000000000001" from "7.3000000000000007".
    char[64] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::boomkat_js_dtoa(&buf, val, 10, 0,
        dtoa_bindings::JS_DTOA_FORMAT_FREE, &tmp);
    if (len <= 0 || len >= 64) {
        return null;
    }
    return vm.heap.str_intern(buf[:len]);
}

// Convert a BigInt to an interned decimal HString*.
// (BigInt.prototype.toString handles non-decimal radices separately.)
fn HString*? vm_bigint_to_string(Vm* vm, hbigint::HBigInt* val) {
    char[48] buf;
    char* heap_buf;
    char[] s = hbigint::hbigint_to_decimal(vm.heap, val, buf[..], &heap_buf);
    defer if (heap_buf != null) vm.heap.free((void*)heap_buf);
    return vm.heap.str_intern(s);
}

// Convert a FASTINT to an interned HString*.
fn HString*? vm_fastint_to_string(Vm* vm, long val) {
    HString* s = vm.heap.int_to_hstring(val);
    if (s == null) return null;
    return s;
}

// Convert a TVal to an interned HString*.
fn HString*? vm_to_string(Vm* vm, TVal* val) {
    Heap* h = vm.heap;
    switch (val.get_tag()) {
        case STRING: {
            HString* hstr = (HString*)val.get_heapptr();
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
        case BIGINT:
            return vm_bigint_to_string(vm, val.get_bigint());
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
            // ECMA-262 ToString: ToPrimitive with hint "string", then ToString. Going through
            // to_primitive_value honors accessor-defined toString and valueOf.
            if (vm != null && vm.heap.call_fn != null && val.get_heapptr() != null) {
                TVal prim = to_primitive_value(vm, val, 1);
                if (vm.throw_pending) return null;
                if (prim.get_tag() != OBJECT) {
                    if (try result_str = vm_to_string(vm, &prim)) {
                        return result_str;
                    }
                    return null;
                }
            }
            return (HString*)h.strs[heap::BuiltinStr.OBJECT_OBJECT];
        }
        case LIGHTFUNC: {
            // Built-in functions stringify as NativeFunction source. Call ECMA-262
            // Function.prototype.toString with the lightfunc as `this`.
            if (vm != null && vm.heap.call_fn != null) {
                HString* to_str_key = (HString*)h.strs[heap::BuiltinStr.TO_STRING];
                if (to_str_key != null) {
                    TVal lf_tv = *val;
                    // Lightfuncs inherit from Function.prototype; get toString there.
                    if (h.function_proto != null) {
                        if (try toString_fn = h.function_proto.get_prop(to_str_key, vm.heap)) {
                            if (toString_fn.is_lightfunc()) {
                                TVal result = h.call_fn(vm, toString_fn, null, 0, lf_tv);
                                if (!vm_check_call_fn_error(vm)) {
                                    if (try rs = vm_to_string(vm, &result)) return rs;
                                }
                                // If the call failed, clear error and fall through to fallback.
                                vm.heap.has_error = false;
                            }
                        }
                    }
                }
            }
            return (HString*)h.strs[heap::BuiltinStr.FUNCTION_STR];
        }
        default:
            return (HString*)h.strs[heap::BuiltinStr.UNDEFINED];
    }
}

// ECMA-262 StringToNumber: https://tc39.es/ecma262/#sec-stringtonumber
// A symbol has no numeric value.
fn double hstring_to_number(HString* hstr) {
    if (hstr.is_symbol()) return double::nan;
    return builtins::builtin_string_to_number(hstr);
}

// Extract [[PrimitiveValue]] from Boolean/Number/String wrapper objects.
// After calling vm_to_number, check and throw if ToPrimitive failed.
// Returns false if a throw was initiated (caller should break out of handler).
fn bool vm_check_to_number_throw(Vm* vm, Activation* act, Instruction** curr_pc, bool* needs_restart) {
    if (vm.throw_pending) {
        vm.throw_pending = false;
        return vm_throw_value(vm, vm.throw_value, act, curr_pc, needs_restart);
    }
    return true;
}

// The opcode handler dispatches the pending throw after coercion returns.
fn void vm_set_error(Vm* vm, HObject* proto, char[] msg) @noinline {
    if (try err = vm_create_error(vm, proto, msg)) {
        TVal value;
        value.set_object(err);
        vm.heap.tval_copy_ref(&vm.throw_value, &value);
    }
    vm.throw_pending = true;
}

fn void vm_set_toprimitive_error(Vm* vm) =>
    vm_set_type_error(vm, "Cannot convert object to primitive value");

fn void vm_set_type_error(Vm* vm, char[] msg) => vm_set_error(vm, vm.heap.type_err_proto, msg);
fn void vm_set_range_error(Vm* vm, char[] msg) => vm_set_error(vm, vm.heap.range_err_proto, msg);

// Moves an error left by call_fn (vm.has_error or heap.has_error, with the thrown value in
// vm.return_val) into the pending throw. Returns true if there was one; the caller returns early.
fn bool vm_check_call_fn_error(Vm* vm) @inline {
    // vm.has_error is cleared at the call_fn/construct_fn boundary so it cannot leak into
    // the caller's dispatch. heap.has_error is the persistent flag.
    if (vm.has_error || vm.heap.has_error) {
        vm.heap.tval_copy_ref(&vm.throw_value, &vm.return_val);
        vm.throw_pending = true;
        vm.has_error = false;
        vm.heap.has_error = false;
        return true;
    }
    return false;
}

// True when `proto`'s own `name` is still the built-in with ordinal `want_ordinal`. The wrapper
// fast path in to_primitive_value skips valueOf/toString, so it is valid only while they are
// original.
fn bool wrapper_proto_method_is_original(Heap* hp, HObject* proto, HString* name, int want_ordinal) {
    if (proto == null || name == null) return false;
    TVal? val = proto.get_prop(name, hp);
    if (catch val) return false;
    TVal v = val;
    if (v.is_lightfunc()) return (int)(usz)v.get_heapptr() == want_ordinal;
    if (!v.is_object() || v.get_heapptr() == null) return false;
    HObject* fn_obj = (HObject*)v.get_heapptr();
    if (!fn_obj.is_callable()) return false;
    return (*fn_obj.extra_ptr()).func.builtin_fn_index == want_ordinal;
}

// ECMA-262 ToPrimitive: https://tc39.es/ecma262/#sec-toprimitive
// Calls @@toPrimitive if present, else OrdinaryToPrimitive. Sets vm.throw_pending when the
// result is an object.
// hint: 0 = default, 1 = string, 2 = number
fn TVal to_primitive_value(Vm* vm, TVal* val, int hint = 0) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        hobject::ObjClass cls = obj.get_class();
        // Fast path: wrapper objects unwrap directly.
        Heap* hp = (vm != null) ? vm.heap : null;
        bool can_fast_unwrap = (hp != null);
        if (can_fast_unwrap) {
            // An own valueOf, toString or @@toPrimitive must run, so skip the fast path.
            HString* vo_key = (HString*)hp.strs[heap::BuiltinStr.VALUE_OF];
            HString* ts_key = (HString*)hp.strs[heap::BuiltinStr.TO_STRING];
            if (vo_key != null && obj.has_prop((void*)vo_key, vm.heap)) can_fast_unwrap = false;
            if (can_fast_unwrap && ts_key != null && obj.has_prop((void*)ts_key, vm.heap)) can_fast_unwrap = false;
            if (can_fast_unwrap && hp.toprimitive_symbol != null
                && obj.has_prop((void*)hp.toprimitive_symbol, vm.heap)) can_fast_unwrap = false;
        }
        if (can_fast_unwrap) {
            // The prototype methods the fast path stands in for must still be the originals.
            HString* vo_name = (HString*)hp.strs[heap::BuiltinStr.VALUE_OF];
            HString* ts_name = (HString*)hp.strs[heap::BuiltinStr.TO_STRING];
            if (cls == hobject::ObjClass.BOOLEAN &&
                (*obj.extra_ptr()).prim.primitive_value.is_boolean()
                && wrapper_proto_method_is_original(hp, hp.bool_proto, vo_name,
                       (int)builtins::Builtin.BOOLEAN_PROTO_VALUEOF.ordinal)
                && wrapper_proto_method_is_original(hp, hp.bool_proto, ts_name,
                       (int)builtins::Builtin.BOOLEAN_PROTO_TOSTRING.ordinal)) {
                TVal result;
                result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
                return result;
            }
            if (cls == hobject::ObjClass.NUMBER &&
                ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())
                && wrapper_proto_method_is_original(hp, hp.number_proto, vo_name,
                       (int)builtins::Builtin.NUMBER_PROTO_VALUEOF.ordinal)
                && wrapper_proto_method_is_original(hp, hp.number_proto, ts_name,
                       (int)builtins::Builtin.NUMBER_PROTO_TOSTRING.ordinal)) {
                TVal result;
                result.set_number((*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint());
                return result;
            }
            if (cls == hobject::ObjClass.STRING &&
                (*obj.extra_ptr()).prim.primitive_value.is_string()
                && wrapper_proto_method_is_original(hp, hp.string_proto, vo_name,
                       (int)builtins::Builtin.STRING_PROTO_VALUEOF.ordinal)
                && wrapper_proto_method_is_original(hp, hp.string_proto, ts_name,
                       (int)builtins::Builtin.STRING_PROTO_TOSTRING.ordinal)) {
                TVal result;
                result.set_string_borrowed((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
                return result;
            }
            // Symbol wrapper: unwrap directly. Symbol.prototype[@@toPrimitive] ignores the hint and
            // returns [[SymbolData]], so this matches calling it while that method is original.
            if (cls == hobject::ObjClass.SYMBOL &&
                (*obj.extra_ptr()).prim.primitive_value.is_string()
                && builtins::symbol_proto_toprimitive_is_original(hp)) {
                HString* s = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                if (s != null && s.is_symbol()) {
                    TVal result;
                    result.set_string_borrowed(s);
                    return result;
                }
            }
        }
        // @@toPrimitive
        if (vm != null && vm.heap.call_fn != null && vm.heap.toprimitive_symbol != null) {
            Heap* h = vm.heap;
            HString* toprim_key = h.toprimitive_symbol;
            // Accessors must be invoked, so use find_accessor_proto.
            hobject::AccessorResult acc = obj.find_accessor_proto(toprim_key, true, vm.heap);
            TVal toprim_fn;
            if (acc.found) {
                TVal getter_this;
                getter_this.set_object(acc.this_obj);
                toprim_fn = h.call_fn(vm, acc.accessor_fn, null, 0, getter_this);
                if (vm_check_call_fn_error(vm)) return *val;
            } else {
                TVal? toprim_val = obj.get_prop_proto(toprim_key, vm.heap);
                if (try tv = toprim_val) {
                    toprim_fn = tv;
                } else {
                    toprim_fn.set_undefined();
                }
            }
            bool toprim_callable = builtins::tval_is_callable(toprim_fn);
            if (toprim_callable) {
                HString* hint_str = (hint == 1)
                    ? vm.heap.str(heap::BuiltinStr.STRING)
                    : ((hint == 2)
                        ? vm.heap.str(heap::BuiltinStr.NUMBER)
                        : intern_string(vm, "default"));
                TVal hint_val;
                hint_val.set_string_borrowed(hint_str);
                TVal[1] hint_args;
                hint_args[0] = hint_val;
                TVal prim = h.call_fn(vm, toprim_fn, &hint_args[0], 1, *val);
                if (vm_check_call_fn_error(vm)) return *val;
                if (!prim.is_object()) return prim;
                // An object result is a TypeError, reported through throw_pending.
                vm_set_toprimitive_error(vm);
                return *val;
            } else if (!toprim_fn.is_undefined() && !toprim_fn.is_null()) {
                // A non-callable Symbol.toPrimitive is a TypeError.
                vm_set_type_error(vm, "Symbol.toPrimitive is not a function");
                return *val;
            }
        }
        // OrdinaryToPrimitive: hint "string" tries toString first, otherwise valueOf first.
        // There is no Date special case: Date.prototype[@@toPrimitive] handles the "default" hint,
        // and without it "default" takes valueOf first.
        if (vm != null && vm.heap.call_fn != null) {
            Heap* h = vm.heap;
            bool use_string_first = (hint == 1);
            HString* first_key = use_string_first
                ? (HString*)h.strs[heap::BuiltinStr.TO_STRING]
                : (HString*)h.strs[heap::BuiltinStr.VALUE_OF];
            HString* second_key = use_string_first
                ? (HString*)h.strs[heap::BuiltinStr.VALUE_OF]
                : (HString*)h.strs[heap::BuiltinStr.TO_STRING];
            // Looks up each method through the prototype chain, invoking getters.
            if (first_key != null) {
                TVal first_fn;
                bool first_found = false;
                hobject::PropLookupResult first_res = obj.get_prop_or_accessor_proto((void*)first_key, true, vm.heap);
                if (first_res.kind == hobject::PropLookupKind.PROP_DATA) {
                    first_fn = first_res.data_val;
                    first_found = true;
                } else if (first_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal getter_this;
                    getter_this.set_object(first_res.acc.this_obj);
                    first_fn = h.call_fn(vm, first_res.acc.accessor_fn, null, 0, getter_this);
                    if (vm_check_call_fn_error(vm)) return *val;
                    first_found = true;
                }
                if (first_found) {
                    if (builtins::tval_is_callable(first_fn)) {
                        TVal prim = h.call_fn(vm, first_fn, null, 0, *val);
                        if (vm_check_call_fn_error(vm)) return *val;
                        if (!prim.is_object()) return prim;
                    }
                }
            }
            if (second_key != null) {
                TVal second_fn;
                bool second_found = false;
                hobject::PropLookupResult second_res = obj.get_prop_or_accessor_proto((void*)second_key, true, vm.heap);
                if (second_res.kind == hobject::PropLookupKind.PROP_DATA) {
                    second_fn = second_res.data_val;
                    second_found = true;
                } else if (second_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal getter_this;
                    getter_this.set_object(second_res.acc.this_obj);
                    second_fn = h.call_fn(vm, second_res.acc.accessor_fn, null, 0, getter_this);
                    if (vm_check_call_fn_error(vm)) return *val;
                    second_found = true;
                }
                if (second_found) {
                    if (builtins::tval_is_callable(second_fn)) {
                        TVal prim = h.call_fn(vm, second_fn, null, 0, *val);
                        if (vm_check_call_fn_error(vm)) return *val;
                        if (!prim.is_object()) return prim;
                    }
                }
            }
            // Neither valueOf nor toString returned a primitive.
            vm_set_toprimitive_error(vm);
        }
    }
    return *val;
}

// ECMA-262 ToNumeric (hint number) for both operands of a bitwise or shift op:
// lval is fully converted before rval is touched, so a Symbol lval throws before rval's
// ToPrimitive runs. Converting first also catches an object whose ToPrimitive yields a
// BigInt, which a BigInt check on the raw operands would miss (e.g. `Object(1n) << 1n`).
//
// Writes BigInts as-is and other values as NUMBER into *out_b/*out_c. Returns false with
// vm.throw_pending set if either step throws.
fn bool vm_bitwise_to_primitive(Vm* vm, TVal* rb, TVal* rc, TVal* out_b, TVal* out_c) {
    if (!vm_to_numeric_bitwise(vm, rb, out_b)) return false;
    if (!vm_to_numeric_bitwise(vm, rc, out_c)) return false;
    return true;
}

// ToNumeric for one operand: ToPrimitive (hint number), then BigInt passes through and
// everything else goes through ToNumber, which throws on a Symbol.
fn bool vm_to_numeric_bitwise(Vm* vm, TVal* val, TVal* out) {
    TVal prim = *val;
    if (val.get_tag() == OBJECT) {
        prim = to_primitive_value(vm, val, 2);
        if (vm.throw_pending) return false;
    }
    if (prim.is_bigint()) {
        *out = prim;
        return true;
    }
    double num = vm_to_number(vm, &prim);
    if (vm.throw_pending) return false;
    out.set_number(num);
    return true;
}
