module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::esm;
import boomkat::compiler;
import std::math;

// Operation functions: one callable implementation per opcode, or per group
// of opcodes sharing a body, each performing its instruction against the
// current frame. The switch in vm_dispatch calls them, and so can any other
// dispatcher that holds a Dispatch and a decoded instruction.

// What an operation function did to the dispatch state. NEXT: the frame is
// unchanged and execution continues at ds.curr_pc, which is the following
// instruction unless a throw the frame caught moved it; a caller that assumed
// the following instruction compares. RESTART: ds.needs_restart is set (a
// frame was pushed or popped, or an exception unwound), and the caller reloads
// the frame. HALT: the run ends with ds.halt_value. FAULT: the run fails with
// ds.failure.
enum OpStatus : char { NEXT, RESTART, HALT, FAULT }

// Fail the run with `err`.
fn OpStatus op_fail(Dispatch* ds, fault err) {
    ds.failure = err;
    return FAULT;
}

// Record `err_val` as the uncaught exception and fail the run with it.
fn OpStatus op_uncaught(Dispatch* ds, TVal* err_val) {
    if (catch err = vm_uncaught_error(ds.vm, err_val)) return op_fail(ds, err);
    return NEXT;
}

// === LOAD / STORE ===
fn OpStatus op_ldreg(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    // Fast path: if source is not a heap ref (fastint, undefined, etc.),
    // skip full refcounting and decref dst only if it held a heap pointer.
    if (!rb.is_heap_allocated()) {
        if (ra.is_heap_allocated()) {
            vm.heap.decref_tval(ra);
        }
        *ra = *rb;
    } else {
        vm.heap.tval_copy_ref(ra, rb);
        track_heap_store(ds.act, ra, (uint)insn.a);
    }
    return NEXT;
}

fn OpStatus op_ldconst(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        vm.heap.tval_copy_ref(ra, &ds.constants[bc]);
    } else {
        vm.heap.set_reg_undefined(ra);
    }
    return NEXT;
}

fn OpStatus op_setconst(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        vm.heap.tval_copy_ref(&ds.constants[bc], ra);
        vm.heap.root_store_tval(*ra);
    }
    return NEXT;
}

fn OpStatus op_ldint(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_fastint(ds.regs_base + insn.a, (long)insn.get_sbc());
    return NEXT;
}

fn OpStatus op_ldintx(Dispatch* ds, DecodedInsn insn) {
    TVal* ra = ds.regs_base + insn.a;
    // Always immediately preceded by the LDINT writing ra's high
    // bits, so ra is a fastint here and holds no old heap reference.
    long ix_high = ra.get_fastint();
    ds.vm.heap.set_reg_fastint(ra, (ix_high << 16) | (long)insn.get_bc());
    return NEXT;
}

fn OpStatus op_ldundef(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_undefined(ds.regs_base + insn.a);
    return NEXT;
}

fn OpStatus op_ldnull(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_null(ds.regs_base + insn.a);
    return NEXT;
}

fn OpStatus op_ldtrue(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_boolean(ds.regs_base + insn.a, true);
    return NEXT;
}

fn OpStatus op_ldfalse(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_boolean(ds.regs_base + insn.a, false);
    return NEXT;
}

// LDTHIS, GETTHISC, PUTTHISC
fn OpStatus op_ldthis(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rc = ds.regs_base + insn.c;
    // Derived constructors have an uninitialized `this` (TDZ sentinel)
    // until super() is called. Accessing `this` before super() → ReferenceError.
    if (env::is_tdz_sentinel(&ds.act.this_binding)) {
        if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                "Must call super constructor in derived class before accessing 'this' or returning from derived constructor",
                ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    if (insn.op == Opcode.LDTHIS) {
        vm.heap.tval_copy_ref(ra, &ds.act.this_binding);
        track_heap_store(ds.act, ra, (uint)insn.a);
    } else {
        // The fused property forms read and write through the binding
        // itself: GETTHISC into A, PUTTHISC from A.
        TVal this_value = ds.act.this_binding;
        if (insn.op == Opcode.GETTHISC) {
            if (catch err = dispatch_property(ds, insn.op, ra, &this_value, rc, insn)) return op_fail(ds, err);
        } else if (catch err = dispatch_property(ds, Opcode.PUTPROP, &this_value, &ds.constants[insn.c], ra, insn)) {
            return op_fail(ds, err);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// === ARITHMETIC ===
// The register operand C, or for an immediate form (arithmetic, bitwise,
// shift or compare-and-branch) the immediate as a number operand in C's
// place. `imm` holds the immediate and must outlive the use of the result.
fn TVal* op_operand_c(Dispatch* ds, DecodedInsn insn, TVal* imm) {
    if (!bytecode::is_imm_form(insn.op) && !is_cmp_branch_imm(insn.op)) return ds.regs_base + insn.c;
    imm.set_fastint(bytecode::imm_value(insn.op, insn.c));
    return imm;
}

// Whether `op` is one whose operand classes the optimizing tier reads: the
// arithmetic, bitwise, shift, compare and step instructions with register
// or immediate operands.
fn bool has_feedback(Opcode op) @inline {
    return (op.ordinal >= Opcode.ADD.ordinal && op.ordinal <= Opcode.MOD.ordinal)
        || (op.ordinal >= Opcode.BAND.ordinal && op.ordinal <= Opcode.GE.ordinal)
        || bytecode::is_imm_form(op) || bytecode::is_cmp_branch(op)
        || op == Opcode.INC || op == Opcode.DEC || op == Opcode.INC_LT || op == Opcode.UNM || op == Opcode.UNP
        || op == Opcode.BNOT || op == Opcode.TONUMERIC || op == Opcode.ADD_FUSED;
}

// Record the operand classes `insn` met, which a tier reached off its integer
// path, in the instruction's inline cache entry (ICEntry.feedback). Both
// operands integers means the result left the fastint range, when the
// instruction was `declined` by a handler that would have completed it.
fn void note_feedback(Dispatch* ds, DecodedInsn insn, bool declined = true) {
    if (ds.ic_base == null) return;
    TVal* regs = ds.regs_base;
    TVal imm;
    char bits;
    switch (insn.op) {
        case Opcode.INC:
        case Opcode.DEC:
        case Opcode.INC_LT:
            bits = hobject::fb_class(regs + insn.a);
        case Opcode.UNM:
        case Opcode.UNP:
        case Opcode.BNOT:
        case Opcode.TONUMERIC:
            bits = hobject::fb_class(regs + insn.b);
        default:
            bits = hobject::fb_class(regs + insn.b) | hobject::fb_class(op_operand_c(ds, insn, &imm));
    }
    if (bits == 0 && declined) {
        // Two integers off the integer path means the result left the fastint
        // range, for the operators that can; a compare or bit operation that
        // reached here only had no integer path of its own.
        switch (insn.op) {
            case Opcode.ADD: case Opcode.ADD_FUSED: case Opcode.SUB: case Opcode.MUL: case Opcode.DIV:
            case Opcode.MOD: case Opcode.ADDI: case Opcode.SUBI: case Opcode.MULI: case Opcode.INC:
            case Opcode.DEC: case Opcode.INC_LT: case Opcode.UNM:
                bits = hobject::FB_OVF;
            default:
                return;
        }
    }
    if (bits != 0) (ds.ic_base + (uint)(ds.curr_pc - 1 - ds.code_base)).feedback |= bits;
}

// ADD_FUSED, ADD
fn OpStatus op_add(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    // The FASTINT + FASTINT fast path, which dominates arithmetic benchmarks.
    // Check this BEFORE OBJECT/STRING to avoid unnecessary tag dispatch.
    if (types::both_fastint(rb, rc)) {
        long sum = rb.get_fastint() + rc.get_fastint();
        if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
            vm.heap.set_reg_fastint(ra, sum);
        } else {
            vm.heap.set_reg_number(ra, (double)sum);
        }
        return NEXT;
    }
    ConcatStatus concat = vm_concat_add(vm, ds.act, ra, rb, rc, (uint)insn.a, ds.curr_pc, ds.code_end);
    if (concat == ConcatStatus.TOO_LONG) {
        if (!vm_concat_overflow(vm, ds)) return op_fail(ds, VM_ERROR);
        if (ds.needs_restart) return RESTART;
    }
    if (concat != ConcatStatus.NOT_APPLICABLE) return NEXT;
    TVal prim_b = *rb;
    TVal prim_c = *rc;
    // ECMA-262 §11.6.1: + operator uses ToPrimitive with no hint (default "number")
    if (rb.get_tag() == OBJECT) { prim_b = to_primitive_value(vm, rb, 0); }
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    // A primitive that came out of a call is owned by the call-result slot
    // alone, which the right operand's ToPrimitive overwrites. Hold it.
    bool hold_b = rc.get_tag() == OBJECT;
    heap::ValueRoot held_b;
    if (hold_b) vm.heap.push_value_root(&held_b, prim_b);
    defer if (hold_b) vm.heap.pop_value_root(&held_b);
    if (hold_b) prim_c = to_primitive_value(vm, rc, 0);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    TValTag pt_b = prim_b.get_tag();
    TValTag pt_c = prim_c.get_tag();
    if (pt_b == STRING || pt_c == STRING) {
        HString*? left_str = vm_to_string(vm, &prim_b);
        if (vm.throw_pending) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            return NEXT;
        }
        HString*? right_str = vm_to_string(vm, &prim_c);
        if (vm.throw_pending) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            return NEXT;
        }
        if (try ls = left_str && try rs = right_str) {
            if (vm_concat(vm, ds.act, ra, rb, ls, ls.units(), rs.units(), (uint)insn.a,
                          ds.curr_pc, ds.code_end, rs) == ConcatStatus.TOO_LONG) {
                if (!vm_concat_overflow(vm, ds)) return op_fail(ds, VM_ERROR);
                if (ds.needs_restart) return RESTART;
                return NEXT;
            }
        } else {
            vm.heap.set_reg_undefined(ra);
        }
    } else if (prim_b.is_bigint() || prim_c.is_bigint()) {
        // ECMA-262 §12.8.5: neither primitive is a String → numeric add.
        // BigInt operands: both must be BigInt (else TypeError).
        if (vm_bigint_binop(vm, Opcode.ADD, ra, &prim_b, &prim_c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
    } else {
        double add_b = vm_to_number(vm,&prim_b);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        double add_c = vm_to_number(vm,&prim_c);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        vm.heap.set_reg_number(ra, add_b + add_c);
    }
    return NEXT;
}

fn OpStatus op_sub(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    if (types::both_fastint(rb, rc)) {
        long diff = rb.get_fastint() - rc.get_fastint();
        if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
            vm.heap.set_reg_fastint(ra, diff);
        } else {
            vm.heap.set_reg_number(ra, (double)diff);
        }
        return NEXT;
    }
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.SUB, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double sub_b = vm_to_number(vm, ops.b);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    double sub_c = vm_to_number(vm, ops.c);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    vm.heap.set_reg_number(ra, sub_b - sub_c);
    return NEXT;
}

fn OpStatus op_addi(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    // A = B + imm.  C is a signed 8-bit immediate (-128..127), the folded
    // constant from a fused LDINT+ADD.  Operand types are only known at
    // runtime, so the fastint check is a correctness dispatch, not a
    // fallback hedge: fastint B takes the branch-free path; everything
    // else routes through the shared numeric/bigint coercion with the
    // immediate synthesized as a fastint TVal.
    long imm = (long)(ichar)insn.c;
    if (rb.is_fastint()) {
        long sum = rb.get_fastint() + imm;
        vm.heap.set_reg_fastint_or_number(ra, sum);
        return NEXT;
    }
    // ECMA-262 §11.6.1: `+` is string concatenation, not numeric addition,
    // when either operand is a string after ToPrimitive. The fusion
    // pass folds LDINT+ADD into ADDI on register and opcode shape
    // alone, so this mirrors ADD's STRING + FASTINT case. The
    // immediate is always the right operand: FUSION_ADDI_SUBI folds
    // `rS + imm` only and leaves `imm + rS` as LDINT+ADD, because
    // ADDI has no field to record which side the immediate came from.
    HString* str = plain_string_of(rb);
    if (str != null) {
        char[32] int_buf;
        int int_len = hstring::int_to_buf(imm, &int_buf, int_buf.len);
        if (int_len > 0) {
            if (vm_concat(vm, ds.act, ra, rb, str, str.units(), hstring::narrow_units(int_buf[:int_len]), (uint)insn.a,
                          ds.curr_pc, ds.code_end) == ConcatStatus.TOO_LONG) {
                if (!vm_concat_overflow(vm, ds)) return op_fail(ds, VM_ERROR);
                if (ds.needs_restart) return RESTART;
            }
            return NEXT;
        }
    }
    TVal immv; immv.set_fastint(imm);
    // Object operand: ToPrimitive(rb, hint number) per ECMA-262 §11.6.1
    // before choosing string concatenation over numeric addition, mirroring ADD's
    // object handling. The immediate is always a plain number, so
    // (unlike ADD, which must ToPrimitive both sides) only rb can
    // ever be an object here.
    TVal prim_b = *rb;
    if (rb.get_tag() == OBJECT) {
        prim_b = to_primitive_value(vm, rb, 0);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
        if (prim_b.is_string() && prim_b.get_heapptr() != null && !((HString*)prim_b.get_heapptr()).is_symbol()) {
            HString*? left_str_opt = vm_to_string(vm, &prim_b);
            if (vm.throw_pending) {
                if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
                return NEXT;
            }
            if (try left_str = left_str_opt) {
                char[32] int_buf;
                int int_len = hstring::int_to_buf(imm, &int_buf, 32);
                if (int_len > 0) {
                    if (vm_concat(vm, ds.act, ra, rb, null, left_str.units(),
                                  hstring::narrow_units(int_buf[:int_len]), (uint)insn.a,
                                  ds.curr_pc, ds.code_end) == ConcatStatus.TOO_LONG) {
                        if (!vm_concat_overflow(vm, ds)) return op_fail(ds, VM_ERROR);
                        if (ds.needs_restart) return RESTART;
                    }
                    return NEXT;
                }
            }
            vm.heap.set_reg_undefined(ra);
            return NEXT;
        }
    }
    if (prim_b.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.ADD, ra, &prim_b, &immv) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double add_b = vm_to_number(vm, &prim_b);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    vm.heap.set_reg_number(ra, add_b + (double)imm);
    return NEXT;
}

// STRJOIN, STRJOIN_LENGTH
fn OpStatus op_strjoin(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    // A slot usually holds a string: the compiler converts every
    // substitution whose ToString can be observable (objects and
    // symbols) at its source position, left to right. A slot may also
    // hold a raw primitive — a string, fastint, double, bigint,
    // boolean, null, or undefined — when the compiler deferred the
    // conversion: the final part is deferrable unconditionally (no
    // later expression or conversion exists to reorder past) and any
    // provably-primitive expression may defer regardless of position.
    // ToString on a primitive is pure and cannot throw, so converting
    // here instead of at the source position is not observable.
    uint count = (uint)insn.c;
    TVal* parts = rb;

    // Materialize non-string/non-fastint slots first. Objects and
    // symbols can only arrive in the final slot, so this coercion
    // runs in source order; for a primitive it is pure. vm_to_string
    // can reallocate the valstack (object/symbol paths), so refresh
    // the register pointers afterwards.
    //
    // A Symbol is a STRING-tagged HString, so a bare tag test would
    // treat it as an already-converted string and copy its bytes into
    // a plain result instead of running ToString, which must throw
    // TypeError (ECMA-262 §7.1.12). Route symbols through vm_to_string.
    bool conversion_threw = false;
    for (uint i = 0; i < count; i++) {
        TValTag tag = parts[i].get_tag();
        if (tag == TValTag.FASTINT) continue;
        if (tag == TValTag.STRING) {
            HString* hs = (HString*)parts[i].get_heapptr();
            if (hs != null && !hs.is_symbol()) continue;
        }
        HString*? str = vm_to_string(vm, &parts[i]);
        ds.regs_base = ds.act.bottom;
        ra = &ds.regs_base[insn.a];
        parts = ds.regs_base + (uint)insn.b;
        if (vm.throw_pending) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            conversion_threw = true;
            break;
        }
        if (try s = str) {
            TVal str_tv;
            str_tv.set_string_borrowed(s);
            vm.heap.tval_copy_ref(&parts[i], &str_tv);
            track_heap_store(ds.act, &parts[i], (uint)insn.b + i);
        }
    }
    if (conversion_threw) {
        if (ds.needs_restart) return RESTART;
        return NEXT;
    }

    // Everything is a string or fastint now: sum the lengths, widening
    // before the add so two lengths near the cap cannot wrap.
    ulong total64 = 0;
    ulong char_length = 0;
    bool wide = false;
    for (uint i = 0; i < count; i++) {
        TVal part_val = parts[i];
        if (part_val.get_tag() == TValTag.FASTINT) {
            uint digits = hstring::int_string_length(part_val.get_fastint());
            total64 += (ulong)digits;
            if (insn.op == Opcode.STRJOIN_LENGTH) char_length += digits;
        } else {
            HString* part = (HString*)part_val.get_heapptr();
            total64 += (ulong)part.length;
            wide = wide || part.is_wide();
            if (insn.op == Opcode.STRJOIN_LENGTH) char_length += part.unit_len();
        }
    }
    if (hstring::length_exceeds_max(total64)) {
        if (!vm_throw_error(vm, vm.heap.range_err_proto, "Invalid string length", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        if (ds.needs_restart) return RESTART;
        return NEXT;
    }
    uint total = (uint)total64;

    if (insn.op == Opcode.STRJOIN_LENGTH) {
        vm.heap.set_reg_fastint(ra, (long)char_length);
        return NEXT;
    }

    HString* result = vm.heap.alloc_concat_join(parts[:count], total, wide);
    if (result == null) { vm.heap.set_reg_undefined(ra); return NEXT; }
    vm.heap.set_reg_string(ra, result);
    // A non-interned result is a pure refcounted leaf with no
    // string-table/GC backstop. Raise heap_reg_count so
    // decref_callee_regs releases the register's reference at frame
    // teardown instead of leaking it.
    track_heap_store(ds.act, ra, (uint)insn.a);
    return NEXT;
}

fn OpStatus op_subi(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    // A = B - imm.  C is a signed 8-bit immediate (-128..127).
    long imm = (long)(ichar)insn.c;
    if (rb.is_fastint()) {
        long diff = rb.get_fastint() - imm;
        vm.heap.set_reg_fastint_or_number(ra, diff);
        return NEXT;
    }
    TVal immv; immv.set_fastint(imm);
    // ToNumeric(rb) first, so an object whose valueOf yields a BigInt takes the
    // BigInt path. The immediate is always a plain number.
    TVal prim_b;
    if (!vm_to_numeric(vm, rb, &prim_b)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    if (prim_b.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.SUB, ra, &prim_b, &immv) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    vm.heap.set_reg_number(ra, prim_b.get_number() - (double)imm);
    return NEXT;
}

// MUL, MULI
fn OpStatus op_mul(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    if (types::both_fastint(rb, rc)) {
        // 48-bit operands can overflow 64-bit signed long (2^47 * 2^47 = 2^94).
        // Guard: if both operands fit in 31 bits the product fits in 62 bits
        // and is safely range-checked; otherwise fall through to double path.
        long mul_b = rb.get_fastint();
        long mul_c = rc.get_fastint();
        if (mul_b >= -0x40000000L && mul_b <= 0x3FFFFFFFL &&
            mul_c >= -0x40000000L && mul_c <= 0x3FFFFFFFL) {
            long mul_result = mul_b * mul_c;
            if (mul_result == 0 && (mul_b ^ mul_c) < 0) {
                // A zero product with operands of opposite sign is -0,
                // which no fastint can represent (ECMA-262 6.1.6.1.4).
                vm.heap.set_reg_number(ra, -0.0);
            } else if (mul_result >= types::FASTINT_MIN && mul_result <= types::FASTINT_MAX) {
                vm.heap.set_reg_fastint(ra, mul_result);
            } else {
                vm.heap.set_reg_number(ra, (double)mul_result);
            }
        } else {
            vm.heap.set_reg_number(ra, (double)mul_b * (double)mul_c);
        }
        return NEXT;
    }
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.MUL, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double mul_b = vm_to_number(vm, ops.b);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    double mul_c = vm_to_number(vm, ops.c);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    vm.heap.set_reg_number(ra, mul_b * mul_c);
    return NEXT;
}

fn OpStatus op_div(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.DIV, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double div_b = vm_to_number(vm, ops.b);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    double div_c = vm_to_number(vm, ops.c);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    vm.heap.set_reg_number(ra, div_b / div_c);
    return NEXT;
}

fn OpStatus op_mod(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    if (types::both_fastint(rb, rc) && rc.get_fastint() != 0) {
        long mod_result = rb.get_fastint() % rc.get_fastint();
        if (mod_result == 0 && rb.get_fastint() < 0) {
            // -1 % 1 → -0: sign of zero matches dividend per ECMA-262 §11.5.3
            vm.heap.set_reg_number(ra, -0.0);
        } else {
            vm.heap.set_reg_fastint(ra, mod_result);
        }
        return NEXT;
    }
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.MOD, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double mod_b = vm_to_number(vm, ops.b);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    double mod_c = vm_to_number(vm, ops.c);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    vm.heap.set_reg_number(ra, (mod_b % mod_c));
    return NEXT;
}

fn OpStatus op_exp(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.EXP, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double exp_b = vm_to_number(vm, ops.b);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    double exp_c = vm_to_number(vm, ops.c);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    // ECMA-262 §12.6.4 (same result as Math.pow): a NaN exponent is NaN
    // even for base 1, and abs(base) == 1 with a ±Infinity exponent is
    // NaN. C99 pow returns 1 for both, so patch them here.
    double exp_r;
    if (math::abs(exp_b) == 1.0 && !math::is_finite(exp_c)) {
        exp_r = double::nan;
    } else {
        exp_r = math::pow(exp_b, exp_c);
    }
    vm.heap.set_reg_number(ra, exp_r);
    return NEXT;
}

// === UNARY ===
// UNP, UNM, BNOT, LNOT, TYPEOF, VOID, TONUMERIC, INC, INC_LT, DEC, PUTARG,
// INC_VAR, DEC_VAR, INC_GLOBAL, DEC_GLOBAL
fn OpStatus op_unary(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_unary(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

// === BITWISE ===
// BAND, BANDI
// Bitwise ops always produce Int32, always fit in FASTINT. ECMA-262 §12.12.3:
// ToNumeric both operands BEFORE dispatching on BigInt, so an object whose
// valueOf, toString, or Symbol.toPrimitive yields a BigInt (e.g.
// `Object(1n) & 1n`) is recognized as BigInt-typed.
fn OpStatus op_band(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    @bitop(ra, rb, rc, Opcode.BAND, vm, ds) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    };
    return NEXT;
}

// BOR, BORI
// See op_band.
fn OpStatus op_bor(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    @bitop(ra, rb, rc, Opcode.BOR, vm, ds) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    };
    return NEXT;
}

// BXOR, BXORI
// See op_band.
fn OpStatus op_bxor(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    @bitop(ra, rb, rc, Opcode.BXOR, vm, ds) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    };
    return NEXT;
}

// SHL, SHLI
// See op_band.
fn OpStatus op_shl(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    @bitop(ra, rb, rc, Opcode.SHL, vm, ds) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    };
    return NEXT;
}

// SHR, SHRI
// See op_band.
fn OpStatus op_shr(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    @bitop(ra, rb, rc, Opcode.SHR, vm, ds) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    };
    return NEXT;
}

// USHR, USHRI
fn OpStatus op_ushr(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    // See BAND above. ECMA-262 §12.9.4 step 6 makes >>> throw TypeError when
    // EITHER ToNumeric result is a BigInt (no BigInt unsigned shift exists),
    // which vm_bigint_binop(USHR, ...) encodes.
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.USHR, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    uint ushr_b = (uint)types::toint32(vm_to_number(vm, ops.b));
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    int  ushr_c = types::toint32(vm_to_number(vm, ops.c));
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    vm.heap.set_reg_fastint(ra, (long)(ushr_b >> (ushr_c & 0x1F)));
    return NEXT;
}

// The immediate compare-and-branch forms JMP_NLTI..JMP_SNEQI.
fn bool is_cmp_branch_imm(Opcode op) @inline => op.ordinal >= Opcode.JMP_NLTI.ordinal && op.ordinal <= Opcode.JMP_SNEQI.ordinal;
// === COMPARISON ===
fn OpStatus op_eq(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    vm.heap.set_reg_boolean(ra, abstract_eq(vm, rb, rc));
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_neq(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    vm.heap.set_reg_boolean(ra, !abstract_eq(vm, rb, rc));
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_seq(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_boolean(ds.regs_base + insn.a, strict_eq(ds.regs_base + insn.b, ds.regs_base + insn.c));
    return NEXT;
}

fn OpStatus op_sneq(Dispatch* ds, DecodedInsn insn) {
    ds.vm.heap.set_reg_boolean(ds.regs_base + insn.a, !strict_eq(ds.regs_base + insn.b, ds.regs_base + insn.c));
    return NEXT;
}

// LT, LE, GT, GE
fn OpStatus op_lt(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    uint order = vm_relational_order(vm, rb, rc);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    // LT..GE share their outcome sets with JMP_LT..JMP_GE.
    char on = CMP_BRANCH_ON[Opcode.JMP_LT.ordinal - Opcode.JMP_NLT.ordinal + insn.op.ordinal - Opcode.LT.ordinal];
    vm.heap.set_reg_boolean(ra, ((on >> order) & 1) != 0);
    return NEXT;
}

// JMP_NLT..JMP_SNEQ and their immediate forms JMP_NLTI..JMP_SNEQI.
// Fused compare-and-branch: A is the signed branch offset, relative to
// the next instruction. The outcome sets are CMP_BRANCH_ON's.
fn OpStatus op_jmp_cmp(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    Opcode op = is_cmp_branch_imm(insn.op) ? bytecode::reg_form(insn.op) : insn.op;
    uint order;
    if (op >= Opcode.JMP_SEQ) {
        order = strict_eq(rb, rc) ? ORDER_EQ : ORDER_UN;
    } else {
        order = vm_relational_order(vm, rb, rc);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
    }
    if (((CMP_BRANCH_ON[op.ordinal - Opcode.JMP_NLT.ordinal] >> order) & 1) != 0) {
        if (!vm_branch(ds, (int)(ichar)insn.a)) return op_fail(ds, VM_ERROR);
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// JMP_EQ, JMP_NEQ
// Loose-equality branches. abstract_eq may run user code, so a throw is
// checked before the branch decision.
fn OpStatus op_jmp_eq(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    bool equal = abstract_eq(vm, rb, rc);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    if (equal == (insn.op == Opcode.JMP_EQ)) {
        if (!vm_branch(ds, (int)(ichar)insn.a)) return op_fail(ds, VM_ERROR);
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// JMP_NULL, JMP_NNULL
// Comparison with null or undefined never coerces: C repeats B.
fn OpStatus op_jmp_null(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* rb = ds.regs_base + insn.b;
    bool nullish = rb.is_nullish() || (rb.is_object() && rb.get_heapptr() == (void*)vm.heap.htmldda_obj);
    if (nullish == (insn.op == Opcode.JMP_NULL)) {
        if (!vm_branch(ds, (int)(ichar)insn.a)) return op_fail(ds, VM_ERROR);
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_instanceof(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    // ECMA-262 §11.8.6: RelationalExpression instanceof ShiftExpression
    // ra may alias rb (compiler optimization), so read rb before writing ra.
    TVal lval = *rb;
    TVal rval = *rc;
    vm.heap.set_reg_boolean(ra, false);

    // OrdinaryHasInstance walks the LEFT operand's prototype chain and
    // answers false for a non-Object. A LIGHTFUNC builtin is an Object,
    // and its chain runs through Function.prototype, so it has to be
    // promoted before that test rather than silently answering false
    // for `JSON.parse instanceof Function`.
    builtins::promote_lightfunc_tval(vm.heap, &lval);

    if (rval.is_lightfunc()) {
        // LIGHTFUNC builtins are callable; look up their prototype
        uint fn_idx = (uint)(usz)rval.get_heapptr();
        HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
        if (proto_obj != null && lval.is_object()) {
            HObject* lbh = (HObject*)lval.get_heapptr();
            if (lbh.is_prototype_of(proto_obj)) {
                vm.heap.set_reg_boolean(ra, true);
            }
        }
        return NEXT;
    }

    if (!rval.is_object()) {
        // TypeError: right-hand side must be an object
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Right-hand side of instanceof is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }

    HObject* rfunc = (HObject*)rval.get_heapptr();

    // The common case: an ordinary function inheriting the intrinsic
    // @@hasInstance. These lookups fill the megamorphic cache, which lets
    // the threaded handler answer later visits.
    if (lval.is_object() && instanceof_default(vm, rfunc, (HObject*)lval.get_heapptr(), ra)) return NEXT;

    // ECMA-262 §12.9.4 makes GetMethod(C, @@hasInstance) step 2, so it must run
    // BEFORE the IsCallable check (step 5). Get() must invoke any
    // accessor getter and propagate its error (test get-err).
    if (vm.heap.hasinstance_symbol != null) {
        HString* hasinst_key = vm.heap.hasinstance_symbol;
        TVal hasinst_val;
        hasinst_val.set_undefined();
        bool have_value = false;
        AccessorResult hi_acc = rfunc.find_accessor_proto(hasinst_key, true, vm.heap);
        if (hi_acc.found) {
            // Accessor property: invoke the getter (this = original
            // receiver = rfunc). A throwing getter propagates.
            TVal this_for_getter;
            this_for_getter.set_object(rfunc);
            TVal getter_result = vm.heap.call_fn(vm, hi_acc.accessor_fn, null, 0, this_for_getter);
            if (vm_check_call_fn_error(vm)) {
                if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
                return ds.needs_restart ? RESTART : NEXT;
            }
            hasinst_val = getter_result;
            have_value = true;
        } else {
            // Data property (or not present). Read raw value via the
            // prototype chain; fall back to undefined if missing.
            TVal? raw = rfunc.get_prop_proto(hasinst_key, vm.heap);
            if (try raw_v = raw) {
                hasinst_val = raw_v;
                have_value = true;
            }
        }
        // ECMA-262 §7.3.9 GetMethod: undefined/null → no method (fall through).
        // Anything else must be callable; otherwise TypeError.
        if (have_value && !hasinst_val.is_undefined() && !hasinst_val.is_null()) {
            bool hasinst_callable = hasinst_val.is_lightfunc() ||
                (hasinst_val.is_object() && hasinst_val.get_heapptr() != null &&
                 ((HObject*)hasinst_val.get_heapptr()).is_callable());
            if (!hasinst_callable) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Symbol.hasInstance value is not a function", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            }
            // Call @@hasInstance with this=C(rval), arg=O(lval)
            TVal result = vm.heap.call_fn(vm, hasinst_val, &lval, 1, rval);
            if (vm_check_call_fn_error(vm)) {
                if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
                return ds.needs_restart ? RESTART : NEXT;
            }
            vm.heap.set_reg_boolean(ra, builtins::builtin_to_boolean(&result));
            return NEXT;
        }
    }

    // Proxy exotic on the RHS: OrdinaryHasInstance with [[Get]] of
    // "prototype" routed through the proxy.
    if (rfunc.is_proxy()) {
        if (!lval.is_object()) { return NEXT; }
        HString* pk = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal pproto;
        if (!builtins::proxy_mop_get(vm, vm.heap, rfunc, pk, rval, &pproto)) {
            TVal perr = vm.heap.error_value;
            vm.heap.has_error = false;
            if (!vm_throw_value(vm, perr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_uncaught(ds, &perr);
            }
            return ds.needs_restart ? RESTART : NEXT;
        }
        if (!pproto.is_object()) {
            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'prototype' property is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_fail(ds, VM_ERROR);
            }
            return ds.needs_restart ? RESTART : NEXT;
        }
        HObject* pproto_obj = (HObject*)pproto.get_heapptr();
        HObject* pcur = (HObject*)lval.get_heapptr();
        if (!instanceof_walk_chain(vm, ds, pcur, pproto_obj, ra)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }

    // ECMA-262 §12.9.4 step 5: If IsCallable(C) is false, throw TypeError.
    // (Reached only when @@hasInstance is undefined/missing.)
    if (!rfunc.is_callable()) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Right-hand side of instanceof is not callable", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }

    // §15.3.5.3 step 1: If Type(lval) is not Object → false
    if (!lval.is_object()) {
        return NEXT;
    }

    // Read rval.prototype, which is ECMA-262 §7.3.19 OrdinaryHasInstance step 4.
    // Get() must invoke accessor getters (per ECMA-262 §7.3.1), so we first
    // check for an accessor property in the prototype chain and call
    // its getter; otherwise fall back to the raw data-property value.
    HString* proto_key_str = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_val;
    AccessorResult acc = rfunc.find_accessor_proto(proto_key_str, true, vm.heap);
    if (acc.found) {
        // ECMA-262 §7.3.1 Get(O, P): an accessor's getter is called with
        // `this` bound to the original receiver (rfunc). The getter
        // may throw or return any value.
        TVal this_for_getter;
        this_for_getter.set_object(rfunc);
        proto_val = vm.heap.call_fn(vm, acc.accessor_fn, null, 0, this_for_getter);
        if (vm_check_call_fn_error(vm)) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            return ds.needs_restart ? RESTART : NEXT;
        }
    } else {
        proto_val = get_prop_with_proto(rfunc, proto_key_str, vm.heap);
    }
    if (!proto_val.is_object()) {
        // ECMA-262 §7.3.19 OrdinaryHasInstance step 6: If Type(P) is not
        // Object, throw a TypeError exception. The spec does NOT
        // allow the silent-false fallback, since the result must always
        // be defined (or an abrupt completion).
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'prototype' property is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }

    HObject* proto_obj = (HObject*)proto_val.get_heapptr();
    HObject* cur = (HObject*)lval.get_heapptr();
    if (!instanceof_walk_chain(vm, ds, cur, proto_obj, ra)) {
        return op_fail(ds, VM_ERROR);
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_in(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    // ECMA-262 §11.8.7: RelationalExpression in ShiftExpression
    // Right side must be an object; TypeError otherwise.
    // Returns true if the object has a property with the given name
    // (own or inherited, checked through [[HasProperty]]).
    //
    // NOTE: Read rb (key) BEFORE writing ra, because ra may alias rb
    // (compiler can emit IN r3, r3, r4 when result overwrites the key).
    // `in` requires an Object on the right, and a LIGHTFUNC builtin is
    // one, so promote before the type test. The promoted value stays a
    // local: writing it back into the register would need the store
    // barrier and ownership tracking that a plain TVal copy does not do,
    // and the cache makes re-promoting on the next iteration a lookup.
    TVal rin = *rc;
    builtins::promote_lightfunc_tval(vm.heap, &rin);
    if (!rin.is_object()) {
        vm.heap.set_reg_boolean(ra, false);
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "in requires an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }

    HObject* obj = (HObject*)rin.get_heapptr();

    // Deferred namespace (import defer): [[HasProperty]] with a
    // string key evaluates the module first.
    if (obj.flags.exotic_deferred_ns) {
        void* dkey = get_prop_key(vm, rb);
        if (!esm::deferred_trigger_exempt_key((HString*)dkey)) {
            if (!esm::force_deferred_namespace(vm.heap, vm, obj)) {
                TVal derr = vm.heap.error_value;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, derr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_uncaught(ds, &derr);
                }
                return ds.needs_restart ? RESTART : NEXT;
            }
        }
    }

    // Proxy exotic: route through [[Has]].
    if (obj.is_proxy()) {
        void* pkey = get_prop_key(vm, rb);
        bool has = false;
        if (pkey != null) {
            if (!builtins::proxy_mop_has(vm, vm.heap, obj, (HString*)pkey, &has)) {
                TVal perr = vm.heap.error_value;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, perr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_uncaught(ds, &perr);
                }
                return ds.needs_restart ? RESTART : NEXT;
            }
        }
        vm.heap.set_reg_boolean(ra, has);
        return NEXT;
    }

    // TypedArray: numeric index membership (0..length-1, not detached).
    if (builtins::is_typed_array_class(obj.get_class())) {
        long idx_long = -1;
        bool is_int_idx = false;
        if (rb.is_fastint()) { idx_long = rb.get_fastint(); is_int_idx = true; }
        else if (rb.is_number()) {
            double d = rb.get_number();
            idx_long = (long)d;
            is_int_idx = (d == (double)idx_long);
        } else if (rb.is_string()) {
            HString* skey = (HString*)rb.get_heapptr();
            if (skey != null && skey.is_arridx()) { idx_long = (long)skey.array_index(); is_int_idx = true; }
        }
        if (is_int_idx) {
            HObject* buf = (*obj.extra_ptr()).view.buffer;
            uint shift = builtins::ta_elem_shift(obj.get_class());
            uint elem_count = (buf != null && (*buf.extra_ptr()).ab.resizable)
                ? builtins::ta_element_count(obj)
                : (*obj.extra_ptr()).view.byte_length >> shift;
            vm.heap.set_reg_boolean(ra, idx_long >= 0 && buf != null && (*buf.extra_ptr()).ab.data != null
                && (ulong)idx_long < (ulong)elem_count);
            return NEXT;
        }
    }

    // Fast path: dense array / arguments indexed check (numeric keys)
    if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && (rb.is_fastint() || rb.is_number())) {
        long idx_long = -1;
        bool dense_index = false;
        if (rb.is_fastint()) {
            idx_long = rb.get_fastint();
            dense_index = idx_long >= 0 && idx_long < (long)obj.array_size;
        } else {
            double numeric_key = rb.get_number();
            if (numeric_key >= 0.0
                && numeric_key < (double)obj.array_size
                && numeric_key == (double)(long)numeric_key) {
                idx_long = (long)numeric_key;
                dense_index = true;
            }
        }
        if (dense_index) {
            TVal? av = obj.get_array_idx((uint)idx_long);
            if (try v = av) {
                vm.heap.set_reg_boolean(ra, true);
                return NEXT;
            }
            // A hole or dense miss may still be an own named property
            // (including an explicit `undefined`) or a prototype hit.
        }
    }

    // Fast path: dense array with string key that might be an index
    if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && rb.is_string()) {
        HString* skey = (HString*)rb.get_heapptr();
        uint skey_idx = skey.array_index();
        if (skey_idx != hstring::ARRIDX_NONE && skey_idx < (uint)obj.array_size) {
            TVal? av = obj.get_array_idx(skey_idx);
            if (try v = av) {
                vm.heap.set_reg_boolean(ra, true);
                return NEXT;
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
                if (prim_str != null && key_hstr.array_index() < prim_str.unit_len()) {
                    vm.heap.set_reg_boolean(ra, true);
                    return NEXT;
                }
            }
        }
        vm.heap.set_reg_boolean(ra, obj.has_prop_proto(key, vm.heap));
    } else {
        vm.heap.set_reg_boolean(ra, false);
    }
    return NEXT;
}

// === CONTROL FLOW ===
fn OpStatus op_jump(Dispatch* ds, DecodedInsn insn) {
    if (!vm_branch(ds, insn.get_sabc())) return op_fail(ds, VM_ERROR);
    return ds.needs_restart ? RESTART : NEXT;
}

// IF_TRUE, IF_FALSE
fn OpStatus op_if(Dispatch* ds, DecodedInsn insn) {
    if (is_truthy(ds.regs_base + insn.a, ds.vm.heap) == (insn.op == Opcode.IF_TRUE)) {
        if (!vm_branch(ds, insn.get_sbc())) return op_fail(ds, VM_ERROR);
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// === PROPERTY ACCESS ===
// GETPROPC_CACHED, GETPROP, GETPROP_CACHE, GETPROPC, PUTPROP, PUTPROP_NE,
// PUTPROP_SUPER, GETPROP_SUPER, DELPROP
fn OpStatus op_property(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_property(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

// PUTPROP with the key in constant C and the value in register B.
fn OpStatus op_putpropc(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_property(ds, Opcode.PUTPROP, regs + insn.a, &ds.constants[insn.c], regs + insn.b, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_topropkey(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // In-place ToPropertyKey coercion (see bytecode.c3 doc comment).
    // Mirrors dispatch_property's GETPROP key-coercion cache-back so a
    // later GETPROP/PUTPROP on this same register is a no-op re-coercion.
    if (!ra.is_string()) {
        void* key = get_prop_key(vm, ra);
        if (key == null && vm.throw_pending) {
            vm.throw_pending = false;
            if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_uncaught(ds, &vm.throw_value);
            }
            return ds.needs_restart ? RESTART : NEXT;
        }
        if (key != null) {
            TVal key_tv;
            key_tv.set_string_borrowed(key);
            vm.heap.tval_copy_ref(ra, &key_tv);
            track_heap_store(ds.act, ra, (uint)insn.a);
        }
    }
    return NEXT;
}

fn OpStatus op_tostr(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // STRJOIN formats this copied primitive directly into its result.
    // Other substitutions retain their source-position coercion.
    if (ra.is_fastint()) return NEXT;
    // In-place ToString coercion (see the bytecode.c3 doc comment), used
    // by template literal substitutions, which call ToString directly
    // rather than going through ToPrimitive(default) like `+`.
    if (!ra.is_string() || (ra.get_heapptr() != null && ((HString*)ra.get_heapptr()).is_symbol())) {
        HString*? str = vm_to_string(vm, ra);
        // vm_to_string may call user code (toString/@@toPrimitive) that
        // reallocates the valstack, so refresh before touching ra again.
        ds.regs_base = ds.act.bottom;
        ra = &ds.regs_base[insn.a];
        if (vm.throw_pending) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            return ds.needs_restart ? RESTART : NEXT;
        }
        if (try s = str) {
            TVal str_tv;
            str_tv.set_string_borrowed(s);
            vm.heap.tval_copy_ref(ra, &str_tv);
            track_heap_store(ds.act, ra, (uint)insn.a);
        }
    }
    return NEXT;
}

fn OpStatus op_retest(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = vm_retest(ds, regs + insn.a, regs + insn.b, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_hof_guard(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (vm_hof_guard(ds, regs + insn.a, regs + insn.b, insn.c)) ds.curr_pc++;
    return NEXT;
}

fn OpStatus op_hof_elem(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    bool? present = vm_hof_elem(ds, regs + insn.a, regs + insn.b, regs + insn.c, true);
    if (catch err = present) return op_fail(ds, err);
    if (present) ds.curr_pc++;
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_hof_get(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = vm_hof_elem(ds, regs + insn.a, regs + insn.b, regs + insn.c, false)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_hof_newarr(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = vm_hof_newarr(ds, regs + insn.a, regs + insn.b, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_hof_put(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = vm_hof_put(ds, regs + insn.a, regs + insn.b, regs + insn.c)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

// === OBJECT / ARRAY CREATION ===
// SPREAD_PROJECTION, NEWOBJ_SHAPE, INIT_SLOT, NEWOBJ, NEWARR, NEWARR_CONST, NEWARR_FILL,
// NEWREGEXP, SETALEN, FREEZEOBJ, ARRSPRD, OBJSPRD, OBJREST, SPREAD_ARG,
// FWD_ARGS, APPLY_ARGS
fn OpStatus op_objects(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_objects(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    // Getters, iterator closes and other user code may reallocate the
    // valstack; refresh regs_base unless the outer loop reloads it.
    if (!ds.needs_restart) {
        ds.regs_base = ds.act.bottom;
        return NEXT;
    }
    return RESTART;
}

// === FUNCTION CALLS ===
// CALL, CALL_S, CALL_UNDEF_THIS, CALL_VAR, CALL_GLOBAL, TAILCALL_UNDEF_THIS,
// TAILCALL_VAR, TAILCALL_GLOBAL, TAILCALL_CALL, TAILCALL_CALL_S
fn OpStatus op_call(Dispatch* ds, DecodedInsn insn) {
    // Inline the direct-compiled-function fast path (the fib/recursion
    // shape) so the hot loop avoids the `bl dispatch_calls` + its own
    // inner-switch dispatch entirely. Guard checks live inside the
    // @inline helper itself; anything that doesn't fit (generators,
    // class ctors called without new, bound/builtin/lightfunc callees,
    // non-callables) falls back to dispatch_calls unchanged.
    bool fast_handled = false;
    TVal? fast_result = try_fast_compiled_call(ds, insn.op, insn, &fast_handled);
    if (fast_handled) {
        if (catch err = fast_result) return op_fail(ds, err);
        return ds.needs_restart ? RESTART : NEXT;
    }
    return op_calls(ds, insn);
}

// CALL_PROP, SETPROTO, GETPROTO, SUPER_CALL, SUPER_CALL_S, NEWTARGET,
// CLASS_SCALAR_GUARD, NEW_OBJ, NEW_OBJ_S, TAILCALL
fn OpStatus op_calls(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_calls(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    if (ds.halt) return HALT;
    // Refresh regs_base after builtin calls that may have triggered valstack
    // reallocation via heap.call_fn (compiled-function paths set needs_restart
    // and reload via the outer loop; builtin paths return without setting it).
    if (!ds.needs_restart) {
        ds.regs_base = ds.act.bottom;
        return NEXT;
    }
    return RESTART;
}

// === GENERATORS ===
// LOAD_RESUME, AWAIT, YIELD, YIELD_STAR, YIELD_STAR_ASYNC, GEN_START
fn OpStatus op_generators(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_generators(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    if (ds.halt) return HALT;
    // yield* calls the delegate's methods inline, which may reallocate the valstack.
    if (!ds.needs_restart) {
        ds.regs_base = ds.act.bottom;
        return NEXT;
    }
    return RESTART;
}

// === DYNAMIC IMPORT ===
// DYN_IMPORT, DYN_IMPORT_DEFER, DYN_IMPORT_SOURCE
fn OpStatus op_dyn_import(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    if (!Opcode.DYN_IMPORT_SOURCE.is_enabled()) return op_fail(ds, VM_ERROR);
    // Read the specifier before any write to A (A may reuse B's slot).
    TVal spec_tv = *rb;
    HString*? spec_opt = vm_to_string(vm, &spec_tv);
    // vm_to_string can call a user toString, re-entering the VM, so refresh.
    ds.regs_base = ds.act.bottom;
    // §13.3.10 step 6-7: an abrupt completion from ToString(specifier)
    // does not throw synchronously; IfAbruptRejectPromise rejects the
    // returned promise with the thrown value. Capture it, clear the
    // pending throw, and hand back an already-rejected promise.
    if (vm.throw_pending) {
        TVal reason = vm.throw_value;
        vm.throw_pending = false;
        vm.throw_value.set_undefined();
        TVal? rej_opt = esm::dynamic_import_reject(vm.heap, vm, &reason);
        ds.regs_base = ds.act.bottom;
        vm.heap.decref_tval(&reason);
        if (catch err = rej_opt) {
            if (!vm_throw_error(vm, vm.heap.type_err_proto, "dynamic import failed", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_fail(ds, VM_ERROR);
            }
            return ds.needs_restart ? RESTART : NEXT;
        }
        TVal rej_tv = rej_opt;
        TVal* rej_dst = ds.regs_base + (uint)insn.a;
        vm.heap.tval_copy_ref(rej_dst, &rej_tv);
        vm.heap.decref_tval(&rej_tv);
        return NEXT;
    }
    HString* spec_str = null;
    if (try s = spec_opt) spec_str = s;
    if (spec_str == null) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "invalid dynamic import specifier", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    // §13.3.10 GetImportAttributes: validate the options argument (C
    // operand). A non-object options/with, a throwing `with`/attribute
    // getter or `ownKeys`, or a non-String attribute value rejects the
    // promise (IfAbruptRejectPromise) rather than throwing. Snapshot the
    // string data first: validation can re-enter the VM and move the
    // interned string's backing, and rc reads from the register file.
    TVal opts_tv = *rc;
    TVal opt_reason;
    opt_reason.set_undefined();
    compiler::ModuleAttrType attr_type = compiler::ModuleAttrType.NONE;
    if (!esm::validate_import_options(vm.heap, vm, &opts_tv, &opt_reason, &attr_type)) {
        ds.regs_base = ds.act.bottom;
        TVal? orej_opt = esm::dynamic_import_reject(vm.heap, vm, &opt_reason);
        ds.regs_base = ds.act.bottom;
        vm.heap.decref_tval(&opt_reason);
        if (catch err = orej_opt) {
            if (!vm_throw_error(vm, vm.heap.type_err_proto, "dynamic import failed", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_fail(ds, VM_ERROR);
            }
            return ds.needs_restart ? RESTART : NEXT;
        }
        TVal orej_tv = orej_opt;
        TVal* orej_dst = ds.regs_base + (uint)insn.a;
        vm.heap.tval_copy_ref(orej_dst, &orej_tv);
        vm.heap.decref_tval(&orej_tv);
        return NEXT;
    }
    ds.regs_base = ds.act.bottom;
    builtins::StrBuf spec_text;
    spec_text.init(vm.heap);
    defer spec_text.free();
    TVal? prom_opt = esm::dynamic_import(vm.heap, vm, builtins::utf8_text(&spec_text, spec_str), attr_type,
                                         insn.op == Opcode.DYN_IMPORT_DEFER,
                                         insn.op == Opcode.DYN_IMPORT_SOURCE);
    // The nested module evaluation may have reallocated the valstack.
    ds.regs_base = ds.act.bottom;
    if (catch err = prom_opt) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "dynamic import failed", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    TVal prom_tv = prom_opt;
    TVal* dst = ds.regs_base + (uint)insn.a;
    vm.heap.tval_copy_ref(dst, &prom_tv);
    // Drop the caller-owned reference dynamic_import returned.
    vm.heap.decref_tval(&prom_tv);
    return NEXT;
}

fn OpStatus op_import_meta(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    if (!Opcode.IMPORT_META.is_enabled()) return op_fail(ds, VM_ERROR);
    // `import.meta` (ECMA-262 §13.3.12). GetActiveScriptOrModule returns
    // the defining module of the running function, so a function that
    // returns import.meta yields its own module's object even when called
    // from another module. The active function's filename carries the
    // owning module's normalized name (stamped by stamp_module_filename);
    // fall back to heap.current_module_name for the module body itself.
    char[] owner_name = vm.heap.current_module_name;
    CompiledFunction* act_func = (CompiledFunction*)ds.act.func;
    if (act_func != null) {
        char[] fn_name = act_func.get_filename();
        if (fn_name.len > 0) owner_name = fn_name;
    }
    esm::ModuleDef* mod = esm::heap_find_loaded_module(vm.heap, owner_name);
    if (mod == null) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "import.meta is not available outside module code", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    HObject*? meta_opt = esm::get_import_meta(vm.heap, mod);
    ds.regs_base = ds.act.bottom;
    if (catch err = meta_opt) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto, "failed to create import.meta", ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    TVal meta_tv;
    meta_tv.set_object(meta_opt);
    TVal* meta_dst = ds.regs_base + (uint)insn.a;
    vm.heap.tval_copy_ref(meta_dst, &meta_tv);
    return NEXT;
}

// === RETURNS ===
// RET, RETUNDEF
fn OpStatus op_ret(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // The threaded return handlers take the common pops; this is the
    // full return, for every frame they decline.
    TVal val;
    if (insn.op == Opcode.RET) {
        val = *ra;
    } else {
        val.set_undefined();
    }
    // Safe point: run deferred GC before returning to caller
    vm.heap.safepoint_gc_on_call();
    // Check for active finally catchers: if we're returning through
    // a try-finally, save the return value and jump to the finally
    // handler.  After ENDFINALLY, the saved value will be used.
    // Walk up to the nearest catcher with a finally. The innermost
    // catcher may be a catch-only try (no finally_pc), in which case
    // the return must still route through an enclosing finally.
    Catcher* ret_cat = find_and_unlink_finally_catcher(vm, ds.act);
    if (ret_cat != null && ret_cat.finally_pc != null) {
        // Save return value
        catcher_set_return(vm.heap, ret_cat, val);
        // If PENDING_RETURN is already set, we're inside the finally
        // block that was entered due to an earlier return.  Just update
        // the return value and let execution continue normally, since
        // ENDFINALLY at the end of the finally block will complete the
        // return with the new value.  Without this check, we'd loop
        // infinitely back to the same finally block.
        if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
            ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
            // Only jump to finally_pc if we're NOT already executing
            // the finally body. The finally block can be entered via
            // a throw from the try (caught by catch which then throws,
            // landing us in finally via vm_throw_value), or via the
            // catch handler returning. In those paths PENDING_RETURN
            // is not yet set when the first RET inside the finally
            // body runs. Jumping to finally_pc again would re-enter
            // the FINALLY opcode and re-execute the finally body.
            if ((ret_cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                ds.curr_pc = ret_cat.finally_pc;
                ds.act.curr_pc = ds.curr_pc;
            } else if (ret_cat.endfinally_pc != null) {
                // A `return` executed inside the finally body itself.
                // It overrides the finally's earlier pending completion
                // and must abort the remaining finally statements, so
                // jump straight to ENDFINALLY (which will complete this
                // return), mirroring break/continue/throw.
                ds.curr_pc = ret_cat.endfinally_pc;
                ds.act.curr_pc = ds.curr_pc;
            }
        } else if ((ret_cat.flags & CATCHER_FLAG_IN_FINALLY) != 0
                   && ret_cat.endfinally_pc != null) {
            // PENDING_RETURN was already set (the finally was entered
            // because of an earlier return) and now a second `return`
            // runs inside the finally body.  The new value already
            // overwrote return_val above; abort the rest of the body
            // and jump to ENDFINALLY to complete with it.
            ds.curr_pc = ret_cat.endfinally_pc;
            ds.act.curr_pc = ds.curr_pc;
        }
        return NEXT;
    }

    Activation* callee_act = &vm.activations[vm.activation_count - 1];
    TVal* callee_result = callee_act.retval;

    // ECMA-262 §9.2.2 step 13.c: derived constructor returning a non-object
    // non-undefined value must throw a TypeError, but the throw must be
    // raised in the caller's context (not catchable inside the constructor),
    // so we set a flag to throw after restoring the caller frame.
    bool derived_return_error = (callee_act.flags & ACT_FLAG_CONSTRUCT) != 0
            && (callee_act.flags & ACT_FLAG_DERIVED) != 0
            && !val.is_object()
            && !val.is_undefined();

    // `return undefined;` from a derived constructor is equivalent to
    // bare `return;` (RETUNDEF), where the same TDZ check applies.
    bool derived_this_error = val.is_undefined() && derived_ctor_returns_undefined_uninitialized(callee_act);
    if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) record_constructor_capacity(callee_act);

    // Protect the return value: if its only reference lives in a
    // callee register, decref_callee_regs below would free it.
    bool val_pinned = false;
    if (val.is_heap_allocated() && val.get_heapptr() != null) {
        ((HeapHeader*)val.get_heapptr()).incref();
        val_pinned = true;
    }

    // Free catchers a return-from-try left on the chain: an early
    // return never reaches CATCH/ENDTRY's pop paths, and this frame
    // is now popping for good.
    free_catcher_chain(vm, callee_act);
    // Decref callee registers before popping
    decref_callee_regs(vm, callee_act);

    vm.activation_count--;
    vm.gc_root_frame_count_changed();

    // Async function: resolve the promise with the return value and
    // return the promise. This must go through promise_resolve_with_value
    // (not a bare promise_settle) so that a returned thenable/Promise is
    // adopted per ECMA-262 §25.5.5.4 AsyncFunctionStart and §27.2.1.3.2, so the
    // async function's promise takes on the eventual settlement of the
    // returned promise rather than fulfilling with the promise object.
    if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
        builtins::promise_resolve_with_value(callee_act.async_promise, val, vm.heap, (void*)vm);
        // Release pin on original return value (promise now holds a ref)
        if (val_pinned) {
            vm.heap.decref_tval(&val);
        }
        // Replace val with the promise. set_object increfs, so this is
        // a genuine owned reference and val_pinned stays accurate: the
        // writeback below either transfers it into callee_result (the
        // val_pinned branch: decref dst, raw write, clear the flag) or
        // the trailing `if (val_pinned) decref_tval(&val)` releases it.
        // The promise's birth ref is a separate reference held by
        // callee_act.async_promise, and vm_calls.c3 pre-installed one
        // more into the result register; do not conflate the three.
        val.set_object(callee_act.async_promise);
        val_pinned = true;
    }

    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        if (val_pinned) vm.heap.decref_tval(&val);
        callee_act.release_callee(vm.heap);
        ds.halt_value = vm.return_val;
        return HALT;
    }
    // Write return value to caller's result register. A borrowed callee's
    // old value there is an uncounted closure, so the copy's release of it
    // is a no-op; a register destination takes no count, and the pin below
    // then queues a string only the caller's register holds.
    if (callee_result != null) {
        // Constructor: if callee returned an object, use it; otherwise use 'this'.
        // (Derived non-object non-undefined case was already converted to a throw above.)
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0 && !val.is_object()) {
            vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
        } else {
            vm.heap.tval_copy_ref(callee_result, &val);
        }
    }
    if (val_pinned) vm.heap.decref_tval(&val);
    callee_act.release_refs(vm.heap);
    // Restore the caller state inline, skipping the outer loop restart.
    ds.act = &vm.activations[vm.activation_count - 1];
    vm.valstack_bottom = ds.act.bottom;
    vm.valstack_top = callee_act.caller_valstack_top;
    // The write-back above may have parked a heap reference (e.g. a
    // large non-interned string transferred via the pin) in a caller
    // register the caller itself never tracked. Raise the caller's
    // heap_reg_count so its eventual decref_callee_regs sweep releases
    // the reference instead of leaking it. Gated on val/construct so
    // the dominant primitive-return path (deep numeric recursion)
    // skips the slot reload: a heap value can only have landed in the
    // slot from `val` itself or from a construct call's this_binding.
    if ((val.is_heap_allocated() || (callee_act.flags & ACT_FLAG_CONSTRUCT) != 0)
        && callee_result != null && callee_result >= ds.act.bottom
        && callee_result.is_heap_allocated()) {
        track_heap_store(ds.act, callee_result, (uint)(callee_result - ds.act.bottom));
    }
    CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
    vm.heap.enter_realm(caller_func.realm);
    if (caller_func != vm.current_func) {
        vm.current_func = caller_func;
        ds.code_base = caller_func.code;
        ds.code_count = caller_func.code_count;
        ds.code_end = ds.code_base + ds.code_count;
        ds.constants = caller_func.constants;
        ds.bind_caches(caller_func);
        ds.nregs = caller_func.num_regs;
    }
    ds.curr_pc = ds.act.curr_pc;
    ds.regs_base = ds.act.bottom;

    // After a super-constructor returns (callee was CONSTRUCT, caller is DERIVED),
    // initialize the derived constructor's this_binding with the constructed object.
    // This is §9.2.2's initialized state, after which LDTHIS succeeds.
    bool super_already_bound = false;
    Activation* super_bound_act = null;
    if ((callee_act.flags & ACT_FLAG_SUPER_CTOR) != 0
            && vm.activation_count > 0
            && callee_result != null && callee_result.is_object()) {
        // §8.1.1.3.1 BindThisValue step 3, escaped-arrow case: if the
        // caller's `this_binding` already carries the "super was called"
        // flag (stamped on the derived ctor's this by the first super()
        // and re-resolved via captured_this for arrows), the derived
        // ctor's `this` was already initialised, so re-binding throws
        // ReferenceError. Without this, the live-frame walk returns
        // false when the derived ctor's frame is gone.
        if ((callee_act.flags & ACT_FLAG_SUPER_REBIND) != 0) {
            super_already_bound = true;
        }
        // The result of super() is in callee_result (already written
        // above). The immediate caller may be an arrow or a method the
        // arrow was invoked through, so walk up to the derived ctor.
        if (!super_already_bound) {
            super_already_bound = super_init_this_chain(vm, &vm.activations[vm.activation_count - 1], callee_result, &super_bound_act);
        }
    }

    // ECMA-262 §9.2.2 step 13.c: now in the caller's context, throw TypeError.
    // The activation has already been popped, so this throw is not catchable
    // inside the constructor's own try-catch handlers.
    if (derived_this_error) {
        if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                "Must call super constructor before returning from derived constructor",
                ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    if (derived_return_error) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto,
                "Derived constructors may only return object or undefined",
                ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    // §8.1.1.3.1 BindThisValue step 3: this_binding was already
    // initialized by a prior super() call, so the superclass constructor
    // still ran (its side effects already happened above), but binding
    // the result to `this` a second time is a ReferenceError.
    if (super_already_bound) {
        if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                "Super constructor may only be called once",
                ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    // Private class fields (ECMA-262 §9.2.2 step 8 InitializeInstanceElements,
    // called for DERIVED constructors right after `this` is bound by super()).
    if (super_bound_act != null) {
        CompiledFunction* super_bound_target = (CompiledFunction*)super_bound_act.func;
        if (catch verr = vm_init_private_members(vm, super_bound_act.lex_env, super_bound_act.var_env,
                super_bound_target, super_bound_act.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// RET_GEN, RETUNDEF_GEN
fn OpStatus op_ret_gen(Dispatch* ds, DecodedInsn insn) {
    if (catch err = dispatch_returns(ds, insn.op, ds.regs_base + insn.a)) return op_fail(ds, err);
    if (ds.halt) return HALT;
    return ds.needs_restart ? RESTART : NEXT;
}


fn OpStatus op_resolvevar(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    uint bc = insn.get_bc();
    bool found = false;
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            // --- VarIC fast path: skip the env-chain walk on repeat
            // resolutions (hot strict-mode global-assignment loops).
            // Only existence is captured here, since TDZ, const, and
            // accessor state are PUTVAR_ASSIGN's business, so a hit
            // needs no flag checks, only the shape and recycle-epoch
            // guard (a delete moves the bindings object to a different
            // shape id, so the walk runs again).
            if (ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                if (vic.env != null && vic.search_head == (void*)ds.act.lex_env) {
                    HObject* b = (HObject*)vic.bindings;
                    if (b.shape_id == vic.shape_id
                    && vm.heap.shape_recycle_epoch == vic.recycle_epoch) {
                    // The readers of this register (THROW_UNRESOLVED,
                    // PUTVAR_ASSIGN) route on a non-null EnvRecord*
                    // pointer, not a boolean: null means unresolvable.
                    vm.heap.set_reg_envref(ra, vic.env);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                    return NEXT;
                    }
                    vic.env = null;
                }
            }

            // --- Slow path: walk the chains, remembering the owning
            // env so the IC can serve the next execution.
            EnvRecord* owner = null;
            int owner_idx = -1;
            EnvRecord* cur = ds.act.lex_env;
            while (cur != null) {
                if (cur.is_with()) {
                    if (cur.bindings.has_prop_proto(key, vm.heap)) {
                        // Mark found but do not populate IC (the
                        // prototype-chain hit is too dynamic to cache
                        // — a put on the with object or any prototype
                        // can re-shape the lookup).
                        owner = cur;
                        owner_idx = 0;
                        break;
                    }
                    cur = cur.parent;
                    continue;
                }
                int idx = cur.bindings.find_prop_idx(key, vm.heap);
                if (idx >= 0) { owner = cur; owner_idx = idx; break; }
                cur = cur.parent;
            }
            if (owner == null && ds.act.lex_env != ds.act.var_env) {
                cur = ds.act.var_env;
                while (cur != null) {
                    if (cur.is_with()) {
                        if (cur.bindings.has_prop_proto(key, vm.heap)) {
                            owner = cur;
                            owner_idx = 0;
                            break;
                        }
                        cur = cur.parent;
                        continue;
                    }
                    int idx = cur.bindings.find_prop_idx(key, vm.heap);
                    if (idx >= 0) { owner = cur; owner_idx = idx; break; }
                    cur = cur.parent;
                }
            }
            // The global object record's HasBinding is HasProperty
            // (§9.1.1.4.2), so an inherited name resolves even though the
            // env walks test own properties only. owner_idx stays -1:
            // there is no own slot to cache, and the write goes through
            // the global object (vm_bareword_put). A throwing `has` trap
            // is treated as a miss, as global_proto_lookup does.
            if (owner == null && vm.global_env != null && vm.global_env.bindings != null) {
                found = vm.global_env.bindings.has_prop_proto(key, vm.heap);
                if (vm.heap.has_error) { vm.heap.has_error = false; found = false; }
                if (found) owner = vm.global_env;
            }
            // Only populate the IC for an own-property hit, never for
            // a with-env or global-prototype walk (owner_idx is -1 there).
            bool owner_is_own = owner != null && !owner.is_with() && owner_idx >= 0;
            found = owner != null;
            if (found && owner_is_own && ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::var_ic_fill(ds.var_ic_base + pc_off, (void*)owner,
                    (void*)owner.bindings, owner.bindings.shape_id, (uint)owner_idx,
                    (void*)ds.act.lex_env, false, vm.heap);
            }
            // Encode the resolution outcome in A's TVal so PUTVAR_ASSIGN
            // (and any later reader) can tell *which* env held the binding.
            // ECMA-262 §6.2.5.6 PutValue step 5 needs the env record itself
            // to route the write to the right SetMutableBinding; for
            // with-env specifically, the resolved env is also the one whose
            // SetMutableBinding throws ReferenceError if the RHS later
            // deletes the binding (§9.1.1.2.5 step 3). A null pointer =
            // unresolvable; a non-null EnvRecord* = resolvable.
            if (found) {
                vm.heap.set_reg_envref(ra, (void*)owner);
            } else {
                vm.heap.set_reg_envref(ra, null);
            }
        }
    }
    track_heap_store(ds.act, ra, (uint)insn.a);
    return NEXT;
}

fn OpStatus op_throw_unresolved(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // Pairs with RESOLVEVAR (strict plain assignment, ECMA-262
    // §13.15.2 step 1 + §6.2.5.6 PutValue step 5): the LHS
    // Reference's resolvability was captured in register A BEFORE
    // the RHS ran, so an RHS side effect that created the binding
    // (sloppy implicit global) still proceeds — the value will land
    // via PUTGLOBAL/PUTVAR_ASSIGN's resolver-fallthrough at plans/083
    // phase 2. Strict code keeps the original §6.2.5.6 throw.
    if (ra.is_envref() && ra.get_heapptr() != null) { return NEXT; }
    if (((CompiledFunction*)ds.act.func).is_strict()) {
        uint bc = insn.get_bc();
        HString* nm = vm.heap.str(heap::BuiltinStr.EMPTY);
        if (bc < vm.current_func.const_count) {
            TVal name_val = ds.constants[bc];
            if (name_val.is_string()) {
                nm = (HString*)name_val.get_heapptr();
            }
        }
        if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "'%s' is not defined", nm, ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// === VARIABLE ACCESS ===
fn OpStatus op_getvar(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    Opcode op = insn.op;
    uint bc = insn.get_bc();
    if (op == Opcode.GETCAP) {
        hobject::PropValue* captured = capture_value_slot(ds.act, bc, vm.heap);
        if (captured != null) {
            vm.heap.copy_slot_to_tval(ra, captured);
            track_heap_store(ds.act, ra, (uint)insn.a);
            return NEXT;
        }
        bc = vm.current_func.capture_names[bc];
    }
    if (bc >= vm.current_func.const_count || !ds.constants[bc].is_string()) {
        vm.heap.set_reg_undefined(ra);
        return NEXT;
    }
    void* key = ds.constants[bc].get_heapptr();
    // TYPEOFIDENT has no threaded handler, so its cache hit lives here.
    if (op == Opcode.TYPEOFIDENT && ds.var_ic_base != null) {
        hobject::VarICEntry* vic = ds.var_ic_base + (ds.curr_pc - 1 - ds.code_base);
        if (vic.env != null && vic.search_head == (void*)ds.act.lex_env
            && ((HObject*)vic.bindings).shape_id == vic.shape_id
            && vm.heap.shape_recycle_epoch == vic.recycle_epoch
            && !vic.prop_flags.is_accessor) {
            TVal v = vic.slot().get();
            if (!env::is_tdz_sentinel(&v)) {
                vm.heap.set_reg_string(ra, typeof_string(vm, &v));
                return NEXT;
            }
        }
    }
    $if $feat(OP_PROFILE):
        opprof_name(op, key, ds.var_ic_base != null ? ds.var_ic_base + (ds.curr_pc - 1 - ds.code_base) : null, ds.act.lex_env);
    $endif
    TVal value;
    BindingRead? read_raw = vm_read_binding(ds, key, &value);
    if (catch err = read_raw) return op_fail(ds, err);
    BindingRead read = read_raw;
    if (op == Opcode.TYPEOFIDENT) {
        // ECMA-262 §13.5.3.1: typeof an unresolvable reference is
        // "undefined" rather than a ReferenceError.
        if (read != BindingRead.THREW) {
            vm.heap.set_reg_string(ra, read == BindingRead.FOUND
                ? typeof_string(vm, &value)
                : (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED]);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    switch (read) {
        case BindingRead.FOUND:
            vm.heap.tval_copy_ref(ra, &value);
            track_heap_store(ds.act, ra, (uint)insn.a);
        case BindingRead.UNRESOLVABLE:
            HString* name_hstr = (HString*)key;
            if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr,
                    ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_fail(ds, VM_ERROR);
            }
        case BindingRead.THREW:
            break;
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_putglobal(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // User assignment to a top-level global binding (TDZ + const-throw
    // like PUTVAR_ASSIGN), specialized to the global objects with the
    // same slot IC as GETGLOBAL for the write-back.
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra, true);
            if (put_result == -1) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == -4) {
                // Non-strict immutable binding (fnexpr own name,
                // CreateImmutableBinding(N, false)): sloppy drops
                // silently, strict throws (§9.1.1.1.5 step 5.2).
                bool strict_a = ds.act.func != null
                    && ((CompiledFunction*)ds.act.func).is_strict();
                if (strict_a) {
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                }
                vm.heap.set_reg_undefined(ra);
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == -2) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == 0) {
                // Not in lex or var env. ECMA-262 §8.1.1.4.7 PutValue step
                // 1: throw ReferenceError when unresolvable. Sloppy
                // bodies fall back to ECMA-262 §15.1.8 step 2.b:
                // create a configurable own property on the global
                // object (Annex B.3.2). env_put on the global env
                // chain that walks back to vm.global_env records the
                // property there, matching the spec.
                int bres = vm_bareword_put(vm, ds, key, *ra);
                if (bres < 0) { return op_fail(ds, VM_ERROR); }
                if (bres == 0) { return ds.needs_restart ? RESTART : NEXT; }
            }
            vm.heap.set_reg_undefined(ra);

            // Populate the slot IC (data, writable, non-accessor only).
            if (ds.var_ic_base != null) {
                EnvRecord* owner = null;
                int owner_idx = -1;
                if (put_result == 1) {
                    EnvRecord* pcur = ds.act.lex_env;
                    while (pcur != null) {
                        int idx = pcur.bindings.find_prop_idx(key, vm.heap);
                        if (idx >= 0) { owner = pcur; owner_idx = idx; break; }
                        pcur = pcur.parent;
                    }
                } else {
                    int idx = ds.act.var_env.bindings.find_prop_idx(key, vm.heap);
                    if (idx >= 0) { owner = ds.act.var_env; owner_idx = idx; }
                }
                if (owner != null && owner_idx >= 0) {
                    hobject::PropFlags fl = owner.bindings.get_prop_flags((uint)owner_idx, vm.heap);
                    if (fl.writable && !fl.is_accessor) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        // Only a writable, non-configurable data global
                        // has an immutable descriptor safe for the
                        // re-check-free store path.
                        hobject::var_ic_fill(ds.var_ic_base + pc_off, (void*)owner,
                            (void*)owner.bindings, owner.bindings.shape_id, (uint)owner_idx,
                            (void*)ds.act.lex_env, !fl.configurable, vm.heap);
                    }
                }
            }
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_putvar(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();
            // ENV_STRICT TODO: own-vs-parent check for lex_env and var_env walks.
            // Would need to introspect env_try_put_lex or rewrite walk here.
            // Combined single-walk: check lex_env, writability, and update in one pass
            int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra, false);
            if (put_result == -1) {
                // A strict-immutable binding (const) throws in BOTH
                // modes: SetMutableBinding promotes strict to true for
                // a strict binding before the immutable check
                // (ECMA-262 §9.1.1.1.5 steps 2 and 5.2).
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == -4) {
                // Non-strict immutable binding (fnexpr own name):
                // sloppy silently drops, strict throws.
                if (((CompiledFunction*)ds.act.func).is_strict()) {
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
                // Sloppy: silent no-op. Release the ra reference so the
                // rax doesn't pin a string the binding never accepted.
                vm.heap.decref_tval(ra);
                ra.set_undefined();
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == 0) {
                // Not in lex_env, so fall through to var_env.
                env::env_put(ds.act.var_env, key, *ra);
            }
            // put_result == 1: already updated in lex_env
            // Release ra's reference, since the binding now owns one.
            // Without this, ra holds a stale ref into the next iteration,
            // causing strings to leak (not reach rc=0 on binding overwrite).
            vm.heap.decref_tval(ra);
            ra.set_undefined();
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_putvar_assign(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    Opcode op = insn.op;
    // User assignment: like PUTVAR but throws ReferenceError for a
    // let/const binding still in its temporal dead zone.
    uint bc = insn.get_bc();
    if (op == Opcode.PUTCAP) {
        HObject* cap_owner;
        hobject::PropValue* captured = capture_value_slot(ds.act, bc, vm.heap, true, &cap_owner);
        if (captured != null) {
            vm.heap.tval_move_slot_fast(cap_owner, captured, ra);
            return NEXT;
        }
        bc = vm.current_func.capture_names[bc];
    }
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            // --- VarIC fast path: skip the env-chain walk on repeat writes ---
            // Mirrors the GETVAR/INC_VAR ICs. Only hits for a binding that
            // already resolved (below) to a writable, non-accessor, non-TDZ
            // slot; const/TDZ/accessor cases never populate, so they always
            // take the slow path (which throws or invokes a setter). The
            // search_head guard ties the cache to the current lex_env chain,
            // so a shadowing let/const in an enclosing block invalidates it.
            if (ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                if (vic.env != null && vic.search_head == (void*)ds.act.lex_env) {
                    HObject* b = (HObject*)vic.bindings;
                    if (b.shape_id == vic.shape_id
                        && vm.heap.shape_recycle_epoch == vic.recycle_epoch) {
                        hobject::PropValue* pv = vic.slot();
                        hobject::PropFlags fl = vic.prop_flags;
                        if (!slot_is_tdz(pv) && fl.writable && !fl.is_accessor) {
                            // Move ra's value into the slot: the binding
                            // takes a count, the old value is released, and
                            // ra is cleared.
                            vm.heap.tval_move_slot_fast(b, pv, ra);
                            return NEXT;
                        }
                    }
                    vic.env = null;
                }
            }

            // Spec check before env_try_put_lex walks past
            // with-envs: if the LHS resolved to a with-env (the
            // probe register B holds that env's pointer), and the
            // with-env's bindingObject no longer has the binding,
            // SetMutableBinding on the resolved env must throw
            // ReferenceError (strict) or silently drop (sloppy)
            // — NOT fall through to a parent env's const
            // (test262 set-mutable-binding-binding-deleted-with-
            // typed-array-in-proto-chain-strict-mode.js,
            // set-mutable-binding-binding-deleted-in-get-
            // unscopables-strict-mode.js).
            EnvRecord* resolved_env = null;
            if ((uint)insn.b < ds.nregs) {
                TVal bv = ds.regs_base[(uint)insn.b];
                if (bv.is_envref()) resolved_env = (EnvRecord*)bv.get_heapptr();
            }
            if (resolved_env != null && resolved_env.is_with()
                && !resolved_env.bindings.has_prop_proto(key, vm.heap)) {
                HString* name_hstr = (HString*)key;
                bool is_strict_act = ds.act.func != null
                    && ((CompiledFunction*)ds.act.func).is_strict();
                if (is_strict_act) {
                    if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto,
                            "%s is not defined", name_hstr,
                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
                // Sloppy: silently drop.
                vm.heap.decref_tval(ra);
                ra.set_undefined();
                return ds.needs_restart ? RESTART : NEXT;
            }

            int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra, true);
            if (put_result == -3) {
                // Unscopables getter (or observable RHS effect on
                // HasProperty in the spec sense) deleted the
                // binding after RESOLVEVAR found it. Strict
                // throws ReferenceError; sloppy silently drops.
                // Per ECMA-262 §9.1.1.2.5 SetMutableBinding step 4,
                // never fall through to the parent env when the
                // resolved env had the binding and now does not.
                HString* name_hstr = (HString*)key;
                bool is_strict_act = ds.act.func != null
                    && ((CompiledFunction*)ds.act.func).is_strict();
                if (is_strict_act) {
                    if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto,
                            "%s is not defined", name_hstr,
                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
                vm.heap.decref_tval(ra);
                ra.set_undefined();
                return ds.needs_restart ? RESTART : NEXT;
            }
            if (put_result == -1) {
                // Strict-immutable binding (const): always throws;
                // §9.1.1.1.5 step 2 promotes strict for strict
                // bindings before the immutable check.
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == -4) {
                // Non-strict immutable binding (fnexpr own name):
                // sloppy drops silently, strict throws.
                bool strict_b = ds.act.func != null
                    && ((CompiledFunction*)ds.act.func).is_strict();
                if (strict_b) {
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                }
                vm.heap.decref_tval(ra);
                ra.set_undefined();
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == -2) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            } else if (put_result == 0) {
                // Not in lex env, so check var env. ECMA-262 §8.1.1.4.7
                // step 1 throws ReferenceError for an unresolvable
                // reference; sloppy bodies fall back to ECMA-262
                // §15.1.8 step 2.b (implicit global on the global
                // object).
                int bres = vm_bareword_put(vm, ds, key, *ra);
                if (bres < 0) { return op_fail(ds, VM_ERROR); }
                if (bres == 0) { return ds.needs_restart ? RESTART : NEXT; }
            }
            vm.heap.decref_tval(ra);
            ra.set_undefined();

            // Populate the VarIC for next time. The binding just resolved
            // either in the lex chain (put_result == 1) or in var_env
            // (put_result == 0); cache whichever env actually owns it so a
            // shadowing same-named binding elsewhere can never be picked up.
            // Only writable, non-accessor slots are cached, since the fast path's
            // guard trusts a plain write.
            if (ds.var_ic_base != null) {
                EnvRecord* owner = null;
                int owner_idx = -1;
                if (put_result == 1) {
                    EnvRecord* cur = ds.act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key, vm.heap);
                        if (idx >= 0) { owner = cur; owner_idx = idx; break; }
                        cur = cur.parent;
                    }
                } else {
                    int idx = ds.act.var_env.bindings.find_prop_idx(key, vm.heap);
                    if (idx >= 0) { owner = ds.act.var_env; owner_idx = idx; }
                }
                if (owner != null && owner_idx >= 0) {
                    hobject::PropFlags fl = owner.bindings.get_prop_flags((uint)owner_idx, vm.heap);
                    if (fl.writable && !fl.is_accessor) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::var_ic_fill(ds.var_ic_base + pc_off, (void*)owner,
                            (void*)owner.bindings, owner.bindings.shape_id, (uint)owner_idx,
                            (void*)ds.act.lex_env, false, vm.heap);
                        var_ic_note_rearm(ds.var_ic_base + pc_off, ds.act.lex_env, owner, vm.heap);
                    }
                }
            }
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_putvar_snap(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    Opcode op = insn.op;
    // A = value register, B = probe env register, C = name constant.
    // Pairs with RESOLVEVAR, which stored the Reference's owning
    // EnvRecord* in B before the right-hand side ran. SetMutableBinding
    // walks from THAT env, so a binding the RHS introduced more locally
    // (a sloppy direct eval's `var x`) cannot capture the store —
    // ECMA-262 §13.15.2 PutValue step 5 uses the initially created
    // Reference. A null probe (unresolvable Reference) falls back to
    // PUTVAR_ASSIGN's implicit-global / ReferenceError handling.
    uint name_idx = insn.c;
    if (op == Opcode.PUTCAP_SNAP) {
        HObject* cap_owner;
        hobject::PropValue* captured = capture_value_slot(ds.act, name_idx, vm.heap, true, &cap_owner);
        if (captured != null) {
            vm.heap.tval_move_slot_fast(cap_owner, captured, ra);
            return NEXT;
        }
        name_idx = vm.current_func.capture_names[name_idx];
    }
    EnvRecord* snap_env = null;
    if ((uint)insn.b < ds.nregs) {
        TVal bv = ds.regs_base[(uint)insn.b];
        if (bv.is_envref()) snap_env = (EnvRecord*)bv.get_heapptr();
    }
    if (name_idx < vm.current_func.const_count) {
        TVal name_val = ds.constants[name_idx];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();
            bool is_strict_act = ds.act.func != null
                && ((CompiledFunction*)ds.act.func).is_strict();
            bool unresolvable = snap_env == null;
            if (snap_env != null && snap_env.is_with()) {
                bool? threw_raw = vm_write_with_binding(ds, snap_env.bindings, (HString*)key, *ra);
                if (catch err = threw_raw) return op_fail(ds, err);
                bool threw = threw_raw;
                if (!threw) {
                    vm.heap.decref_tval(ra);
                    ra.set_undefined();
                }
                return ds.needs_restart ? RESTART : NEXT;
            }
            if (snap_env != null) {
                // Cache a writable data binding of the captured owner for
                // th_putvar_snap, then store as usual.
                if (ds.var_ic_base != null) {
                    HObject* bindings = snap_env.bindings;
                    int idx = bindings.find_prop_idx(key, vm.heap);
                    if (idx >= 0) {
                        hobject::PropFlags flags = bindings.get_prop_flags((uint)idx, vm.heap);
                        if (flags.writable && !flags.is_accessor
                            && !slot_is_tdz(&bindings.prop_values()[idx])) {
                            uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                            hobject::var_ic_fill(ds.var_ic_base + pc_off, (void*)snap_env,
                                (void*)bindings, bindings.shape_id, (uint)idx,
                                (void*)snap_env, false, vm.heap);
                        }
                    }
                }
                int put_result = env::env_try_put_lex(snap_env, key, *ra, true);
                if (put_result == 1) {
                } else if (put_result == 0) {
                    unresolvable = true;
                } else if (put_result == -3) {
                    // Unscopables getter deleted the binding after
                    // RESOLVEVAR found it (§9.1.1.2.5 step 4).
                    if (is_strict_act) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto,
                                "%s is not defined", name_hstr,
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return op_fail(ds, VM_ERROR);
                        }
                        return ds.needs_restart ? RESTART : NEXT;
                    }
                } else if (put_result == -2) {
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                } else if (put_result == -1 || (put_result == -4 && is_strict_act)) {
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
                // -4 in sloppy: an immutable non-strict binding drops
                // the write silently.
            }
            if (unresolvable) {
                int bres = vm_bareword_put(vm, ds, key, *ra);
                if (bres < 0) { return op_fail(ds, VM_ERROR); }
                if (bres == 0) { return ds.needs_restart ? RESTART : NEXT; }
            }
            vm.heap.decref_tval(ra);
            ra.set_undefined();
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_declglobalfunc(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // Instantiate a top-level FunctionDeclaration binding in the
    // immediate var_env (no chain walk). Unlike DECLVAR this never
    // uses the VarIC: it runs once per declaration, and an IC hit
    // would write the value while leaving stale attributes in place
    // where CreateGlobalFunctionBinding wants a full redefinition.
    uint fdecl_bc = insn.get_bc();
    if (fdecl_bc < vm.current_func.const_count) {
        TVal fdecl_name = ds.constants[fdecl_bc];
        if (fdecl_name.is_string()) {
            $if types::ENV_STRICT:
            if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: DECLGLOBALFUNC"); }
            $endif
            void* fdecl_key = fdecl_name.get_heapptr();
            bool is_global_fn_env = ds.act.var_env == vm.global_env;
            bool is_eval_fn = ((CompiledFunction*)ds.act.func).is_eval_fn();
            // ECMA-262 §18.2.1.2 EvalDeclarationInstantiation step 8 +
            // §9.1.1.4.17 CanDeclareGlobalFunction + §9.1.1.4.18
            // CreateGlobalFunctionBinding:
            //   step 8 — CanDeclareGlobalFunction: throws TypeError if the
            //     existing property is non-configurable AND not a writable
            //     data descriptor (catches `NaN`, `Infinity`, `undefined`,
            //     non-writable accessors). Without the early throw, the eval
            //     would proceed and partially create sibling declarations
            //     before failing.
            //   step 14 — CreateGlobalFunctionBinding: when the property IS
            //     definable but happens to be non-configurable (e.g., a
            //     writable, configurable=false data descriptor like
            //     `var-env-func-init-global-update-non-configurable.js`),
            //     just update the value and preserve existing attributes.
            //     env_declare_global_func carries out that step.
            if (is_global_fn_env && is_eval_fn) {
                if (!env::env_can_declare_global_func(ds.act.var_env, fdecl_key)) {
                    HString* type_str = typeof_string(vm, (TVal*)&fdecl_name);
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto,
                            "Cannot declare global function '%s'", type_str,
                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    ds.halt_value = (TVal){};
                    return HALT;
                }
            }
            env::env_declare_global_func(ds.act.var_env, fdecl_key, *ra, is_global_fn_env, is_eval_fn);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_declb33global(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // Per-evaluation publish of a block-nested function declaration
    // at global scope (Annex B.3.2: genvRec.SetMutableBinding). An
    // existing property keeps its attributes: only the value is
    // replaced, so a pre-existing non-enumerable global stays
    // non-enumerable (Annex B.3.3.3). A missing binding is created
    // { writable: true, enumerable: true, configurable: true }.
    // Accessor and non-writable targets drop silently: this opcode
    // only emits for sloppy functions (SetMutableBinding S=false).
    uint b33_bc = insn.get_bc();
    if (b33_bc < vm.current_func.const_count) {
        TVal b33_name = ds.constants[b33_bc];
        if (b33_name.is_string()) {
            $if types::ENV_STRICT:
            if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: DECLB33GLOBAL"); }
            $endif
            void* b33_key = b33_name.get_heapptr();
            EnvRecord* b33_venv = ds.act.var_env;
            if (b33_venv == vm.global_env) {
                int b33_idx = b33_venv.bindings.find_prop_idx(b33_key, vm.heap);
                if (b33_idx >= 0) {
                    hobject::PropFlags b33_fl = b33_venv.bindings.get_prop_flags((uint)b33_idx, vm.heap);
                    if (!b33_fl.is_accessor && b33_fl.writable) {
                        hobject::PropValue* b33_pv = &b33_venv.bindings.prop_values()[b33_idx];
                        vm.heap.tval_move_slot_fast(b33_venv.bindings, b33_pv, ra);
                    }
                } else {
                    b33_venv.bindings.put_prop(b33_key, *ra, hobject::PROP_FLAGS_WEC, vm.heap);
                }
            } else {
                env::env_declare_global_func(b33_venv, b33_key, *ra, false, ((CompiledFunction*)ds.act.func).is_eval_fn());
            }
        }
    }
    return NEXT;
}

fn OpStatus op_declvar_hoist(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // Initializer-less `var` stub. Deliberately skips the VarIC: the
    // fast path writes unconditionally, which would overwrite a live
    // global with undefined when the stub sits in a loop body and
    // re-executes with a warm cache. env_declare_var applies the
    // CanDeclareGlobalVar skip, and a hoist stub is cold enough that
    // the cache buys nothing.
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();
            // `var arguments` in a function with an arguments object
            // is not a fresh binding when the body shares the
            // parameter environment: §10.2.11 step 28.f only
            // initializes var names that are not already bound, so
            // stubbing would clobber the call-entry object with
            // undefined. The declaration site's DECLVAR still performs
            // the write for `var arguments = v`, and an arrow (no own
            // arguments object) keeps the normal stub.
            //
            // A parameter expression splits the body into its own
            // varEnv (PUSH_VAR), and that env does NOT have the
            // binding. Step 28.f.ii then creates it there, seeded with
            // the value the enclosing chain resolves to — the
            // parameter scope's arguments object. Skipping the
            // declaration instead would leave the body's assignments
            // resolving up into the parameter scope, visible to the
            // closures a default expression created.
            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
            if (((CompiledFunction*)ds.act.func).uses_arguments()
                && args_name != null && key == (void*)args_name) {
                if (ds.act.var_env == null
                    || ds.act.var_env.bindings.has_prop(key, vm.heap)) {
                    return NEXT;
                }
                TVal seed = env::env_get(ds.act.var_env, key) ?? *ra;
                env::env_declare_var(ds.act.var_env, key, seed,
                    ds.act.var_env == vm.global_env,
                    ((CompiledFunction*)ds.act.func).is_eval_fn(), false);
                return NEXT;
            }
            declare_scope_var(ds, key, *ra, true);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_declvar(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    // Declare a `var` binding in the immediate var_env only (no chain walk).
    // WITH_START pushes the with-env onto lex_env only (never var_env:
    // `var` inside `with` binds the enclosing variable environment per
    // ECMA-262 §13.11), so the immediate var_env is always the right
    // target here.
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            $if types::ENV_STRICT:
            if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: DECLVAR"); }
            $endif

            // --- VarIC fast path: skip find_prop_idx on repeat calls ---
            if (ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                if (vic.env == (void*)ds.act.var_env) {
                    HObject* b = (HObject*)vic.bindings;
                    if (b != null && b.shape_id == vic.shape_id
                        && vm.heap.shape_recycle_epoch == vic.recycle_epoch) {
                        // A direct write skips find_prop_idx and put_prop.
                        hobject::PropValue* pv = vic.slot();
                        if (pv.get().is_string()) {
                            vm.heap.decref_slot(pv);
                        }
                        vm.heap.store_slot(b, pv, *ra);
                        if (ra.is_string()) {
                            void* ptr = ra.get_heapptr();
                            if (ptr != null) ((types::HeapHeader*)ptr).incref();
                        }
                        return NEXT;
                    }
                    vic.env = null;
                }
            }

            // --- Slow path: full env_declare ---
            // Global-scope var/function declarations install a
            // non-configurable own property on the global object for
            // Script code, but a configurable one for eval code
            // (ECMA-262 §8.1.1.4.15/.17, §15.1.11 vs §18.2.1.2).
            declare_scope_var(ds, key, *ra, false);

            // Populate VarIC for next time
            if (ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                HObject* b = ds.act.var_env.bindings;
                if (b != null) {
                    int idx = b.find_prop_idx(key, vm.heap);
                    if (idx >= 0) {
                        hobject::var_ic_fill(vic, (void*)ds.act.var_env, (void*)b,
                            b.shape_id, (uint)idx, null, false, vm.heap);
                    }
                }
            }
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_putlex(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            $if types::ENV_STRICT:
            if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: PUTLEX"); }
            $endif

            env::env_declare_lex(ds.act.lex_env, key, *ra);
        }
    }
    return NEXT;
}

fn OpStatus op_putlex_c(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            $if types::ENV_STRICT:
            if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: PUTLEX_C"); }
            $endif

            // Like env_declare_lex, but non-writable: CreateImmutable
            // -style const binding, non-configurable so `delete x`
            // reports false (§9.1.1.1.7) and immut_nonstrict stays
            // clear so any assignment throws.
            hobject::PropFlags const_flags = {
                .writable = false, .enumerable = true, .configurable = false
            };
            ds.act.lex_env.bindings.put_prop(key, *ra, const_flags, vm.heap);
        }
    }
    return NEXT;
}

fn OpStatus op_inittz(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    // Store the TDZ sentinel for a variable name in the current
    // lexical environment.  This marks the binding as uninitialized
    // so that GETVAR throws a ReferenceError (temporal dead zone)
    // if the variable is accessed before its PUTLEX/PUTLEX_C.
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();

            // No ENV_STRICT trap here: INITTZ targets the innermost
            // PUSH_LEX block environment, which exists even for
            // needs_env=false functions, since the elide pass keeps a
            // sentinel alive when a TYPEOFIDENT references its name.

            TVal tdz = env::tdz_sentinel();
            ds.act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC, vm.heap);
        }
    }
    return NEXT;
}

fn OpStatus op_chkglobal(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    Opcode op = insn.op;
    // GlobalDeclarationInstantiation static checks (ECMA-262 §15.1.11),
    // run before any binding is instantiated so a collision throws
    // with no observable side effects.
    uint bc = insn.get_bc();
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();
            HObject* globals = vm.global_env.bindings;
            HObject* lex = vm.global_lex_env != null ? vm.global_lex_env.bindings : null;

            bool has_lex = lex != null && lex.find_prop_idx(key, vm.heap) >= 0;
            int gidx = globals.find_prop_idx(key, vm.heap);
            bool has_global = gidx >= 0;

            if (op == Opcode.CHKGLOBALLEX) {
                // A lexical name may not collide with an existing var
                // binding (own global property) or global lexical
                // binding, nor a restricted (non-configurable) global
                // property (HasRestrictedGlobalProperty).
                bool restricted = has_global
                    && !globals.get_prop_flags((uint)gidx, vm.heap).configurable;
                if (has_lex || restricted) {
                    HString* nm = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.syntax_err_proto,
                        "Identifier '%s' has already been declared", nm,
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
            } else if (op == Opcode.CHKGLOBALVAR) {
                // A var name may not collide with a global lexical
                // binding (SyntaxError); otherwise CanDeclareGlobalVar
                // must hold (TypeError when the global is not
                // extensible and has no matching own property).
                if (has_lex) {
                    HString* nm = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.syntax_err_proto,
                        "Identifier '%s' has already been declared", nm,
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
                if (!has_global && !globals.is_extensible()) {
                    HString* nm = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto,
                        "Cannot declare global variable '%s'", nm,
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
            } else {
                // CHKGLOBALFUNC: a function name is a var-declared
                // name, so it may not collide with a global lexical
                // binding (SyntaxError); otherwise
                // CanDeclareGlobalFunction must hold: definable when no
                // own prop and extensible, or the prop is configurable,
                // or it is a writable+enumerable data property; else
                // TypeError.
                if (has_lex) {
                    HString* nm = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.syntax_err_proto,
                        "Identifier '%s' has already been declared", nm,
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
                bool definable;
                if (!has_global) {
                    definable = globals.is_extensible();
                } else {
                    hobject::PropFlags pf = globals.get_prop_flags((uint)gidx, vm.heap);
                    definable = pf.configurable
                        || (!pf.is_accessor && pf.writable && pf.enumerable);
                }
                if (!definable) {
                    HString* nm = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto,
                        "Cannot declare global function '%s'", nm,
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    return ds.needs_restart ? RESTART : NEXT;
                }
            }
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_delvar(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    if (!Opcode.DELVAR.is_enabled()) return op_fail(ds, VM_ERROR);
    // `delete x`: ECMA-262 §14.7.5 step 1 + Annex B.3.2.
    // The compiler emits DELVAR with BC = the operand's name constant
    // in every case (the operand GETVAR/GETGLOBAL, when present, is
    // patched to NOP so it doesn't throw on an unresolved binding).
    //
    // BC out of range: sloppy returns true (no name → Annex B.3.2 says
    //                    the deletion is trivially successful).
    // BC in range: lex walk. If unresolvable → true.
    //              If bound to a non-configurable var/function → false.
    //              If bound to a configurable global → delete and true.
    uint bc = insn.get_bc();
    if (bc >= vm.current_func.const_count) {
        vm.heap.set_reg_boolean(ra, true);
        return NEXT;
    }
    TVal name_val = ds.constants[bc];
    if (!name_val.is_string()) {
        vm.heap.set_reg_boolean(ra, false);
        return NEXT;
    }
    void* key = name_val.get_heapptr();
    HString* name_hstr = (HString*)key;
    bool is_strict_d = ((CompiledFunction*)ds.act.func).is_strict();

    // Walk the lex chain. A `with`-env hit is `delete obj.x`: drop the property
    // from the with object and report success. A non-with hit is a
    // var/function binding (Annex B.3.2), non-configurable by spec, so
    // the answer is false regardless of strictness. Functions and sloppy
    // direct evals run with lex_env != var_env (the function's lexical
    // scope vs its variable scope), so a var-declared parameter or
    // local binding lives in var_env, not lex_env — the lex walk
    // misses it, and the spec still requires the deletion to report
    // false. Walk var_env next when the lex walk finds nothing.
    EnvRecord* cur = ds.act.lex_env;
    bool found = false;
    int found_idx = -1;
    while (cur != null) {
        if (cur.is_with()) {
            if (cur.bindings.has_prop_proto(key, vm.heap)) {
                // @@unscopables hides the binding (ECMA-262 §9.1.1.2.5
                // HasBinding): skip to the enclosing scope instead of
                // deleting from the with object.
                if (vm_with_unscopables_blocks(vm, cur, key)) {
                    cur = cur.parent;
                    continue;
                }
                if (vm.heap.has_error) {
                    if (!vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                    continue;
                }
                // delete obj.x inside `with`: [[Delete]] the own
                // property and report its boolean result. The with-env
                // hit is a property delete, not a var-binding delete,
                // so it must not fall through to the logic below.
                vm.heap.set_reg_boolean(ra, cur.bindings.es_delete_prop(key, vm.heap));
                track_heap_store(ds.act, ra, (uint)insn.a);
                found = true;
                break;
            }
            cur = cur.parent;
            continue;
        }
        int idx = cur.bindings.find_prop_idx(key, vm.heap);
        if (idx >= 0) { found = true; found_idx = idx; break; }
        cur = cur.parent;
    }
    // var_env walk (Annex B.3.2 + ECMA-262 §10.2.1.2): a var-declared
    // parameter or local of an enclosing function lives in var_env.
    // Sloppy direct evals inherit the caller's var_env for vars, so
    // those land here as well. The deletion still answers false (var
    // bindings are non-configurable); do not actually drop the
    // property, which would break re-entrant calls.
    if (!found && cur == null && ds.act.lex_env != ds.act.var_env) {
        EnvRecord* vcur = ds.act.var_env;
        while (vcur != null) {
            if (vcur.is_with()) {
                if (vcur.bindings.has_prop_proto(key, vm.heap)) {
                    // Same @@unscopables skip as the lex walk above.
                    if (vm_with_unscopables_blocks(vm, vcur, key)) {
                        vcur = vcur.parent;
                        continue;
                    }
                    if (vm.heap.has_error) {
                        if (!vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                        continue;
                    }
                    vm.heap.set_reg_boolean(ra, vcur.bindings.es_delete_prop(key, vm.heap));
                    track_heap_store(ds.act, ra, (uint)insn.a);
                    found = true;
                    break;
                }
                vcur = vcur.parent;
                continue;
            }
            int vidx = vcur.bindings.find_prop_idx(key, vm.heap);
            if (vidx >= 0) {
                // Non-configurable per Annex B.3.2 → false. An
                // eval-created binding is configurable
                // (CreateMutableBinding(N, true), §18.2.1.2) and is
                // deleted for real, returning true.
                hobject::PropFlags vflags = vcur.bindings.get_prop_flags((uint)vidx, vm.heap);
                if (vflags.configurable) {
                    vm.heap.set_reg_boolean(ra, vcur.bindings.es_delete_prop(key, vm.heap));
                } else {
                    vm.heap.set_reg_boolean(ra, false);
                }
                track_heap_store(ds.act, ra, (uint)insn.a);
                found = true;
                break;
            }
            vcur = vcur.parent;
        }
    }
    if (found && cur != null && cur.is_with()) {
        return ds.needs_restart ? RESTART : NEXT;
    }
    if (!found && !is_strict_d) {
        // Annex B.3.2: unresolvable → true. GetValue on a missing name
        // would throw, but DeleteValue's reference check accepts the
        // unresolvable form silently here.
        vm.heap.set_reg_boolean(ra, true);
        return ds.needs_restart ? RESTART : NEXT;
    }
    if (is_strict_d && !found) {
        if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "'%s' is not defined", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    // Found. The lex walk lands on a declarative env whose record
    // holds the binding. Annex B.3.2 says var/function bindings are
    // non-configurable, so the answer is false. Declarative env
    // records store var/function/let/const bindings — there is no
    // configurability check to make, the binding simply exists.
    //
    // For object envs (the global), ECMA-262 §14.7.5 step 4 checks
    // [[Configurable]]: a configurable global (e.g. a built-in like
    // JSON whose declaration flags include C: true) returns true and
    // the property is removed; a non-configurable one (built-ins like
    // undefined, Infinity) returns false. cur.is_with() is false here
    // because the with branch above breaks first; the global env is
    // the only object env a script activation sees in Phase 5.
    if (cur != null && !cur.flags.is_declarative && found_idx >= 0) {
        hobject::PropFlags flags = cur.bindings.get_prop_flags((uint)found_idx, vm.heap);
        if (flags.configurable) {
            vm.heap.set_reg_boolean(ra, cur.bindings.es_delete_prop(key, vm.heap));
            track_heap_store(ds.act, ra, (uint)insn.a);
            return ds.needs_restart ? RESTART : NEXT;
        }
        vm.heap.set_reg_boolean(ra, false);
        return ds.needs_restart ? RESTART : NEXT;
    }
    // Found on a declarative env. Annex B.3.2 answers false for
    // var/function bindings (non-configurable), but a binding an
    // eval created is configurable (CreateMutableBinding(N, true),
    // ECMA-262 §18.2.1.2) and is deleted for real, returning true.
    // Ordinary function var bindings, let/const/class, and function
    // declarations are non-configurable → plain false. The top-level
    // lexical env is a GlobalDeclarationInstantiation §10.2.1.8.
    // CreateMutableBinding(dn, false): the engine stores it as a
    // plain property, but the spec keeps it in the declarative
    // record, so [[Configurable]] is false and `delete x` is false
    // even though the property bit says configurable.
    if (found_idx >= 0) {
        bool is_global_lex = cur == vm.global_lex_env;
        hobject::PropFlags dflags = cur.bindings.get_prop_flags((uint)found_idx, vm.heap);
        if (dflags.configurable && !is_global_lex) {
            vm.heap.set_reg_boolean(ra, cur.bindings.es_delete_prop(key, vm.heap));
            track_heap_store(ds.act, ra, (uint)insn.a);
            return ds.needs_restart ? RESTART : NEXT;
        }
        vm.heap.set_reg_boolean(ra, false);
        return ds.needs_restart ? RESTART : NEXT;
    }
    // Found on the var_env walk (Annex B.3.2): function var/param
    // bindings are non-configurable → false; an eval-created one is
    // configurable and deleted (checked in the vcur walk below).
    vm.heap.set_reg_boolean(ra, false);
    return ds.needs_restart ? RESTART : NEXT;
}

// === WITH STATEMENT (plans/083 phase 4) ===
// ECMA-262 §13.11.1: WithStatement pushes an Object Environment Record
// onto the running execution context's LexicalEnvironment (not
// VariableEnvironment). This is what makes reads inside `with`
// intercept lookup-time and assignments to with-object properties
// update them in place: GETVAR walks lex_env, PUTVAR tries lex_env
// via env_try_put_lex, and an is-with lex record walks the prototype
// chain via env_get/has/put.
//
// WITH_START: ToObject the operand (primitives wrap, null/undefined
// throw TypeError), then push a with-env onto act.lex_env.
// WITH_END: pop the with-env from act.lex_env. The env record is NOT
// returned to the pool: a closure created inside `with` captures
// act.lex_env (CLOSURE), and freeing would leave a dangling pointer.
fn OpStatus op_with_start(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    if (!Opcode.WITH_START.is_enabled()) return op_fail(ds, VM_ERROR);
    TVal obj_val = *ra;
    HObject* obj;

    if (obj_val.is_object()) {
        obj = (HObject*)obj_val.get_heapptr();
    } else if (obj_val.is_null() || obj_val.is_undefined()) {
        if (try err = vm_create_error(vm, vm.heap.type_err_proto,
                obj_val.is_null() ? "Cannot use 'with' on null" : "Cannot use 'with' on undefined")) {
            TVal err_val;
            err_val.set_object(err);
            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_fail(ds, VM_ERROR);
            }
        } else {
            return op_fail(ds, VM_ERROR);
        }
        return ds.needs_restart ? RESTART : NEXT;
    } else if (obj_val.is_boolean()) {
        HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch _err = wrapped) { return op_fail(ds, VM_ERROR); }
        obj = wrapped;
        obj.prototype = vm.heap.bool_proto;
        (*obj.extra_ptr()).prim.primitive_value.set_boolean(obj_val.get_boolean());
    } else if (obj_val.is_string()) {
        HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch _err = wrapped) { return op_fail(ds, VM_ERROR); }
        obj = wrapped;
        obj.flags.exotic_stringobj = true;
        obj.prototype = vm.heap.string_proto;
        HString* prim_str = (HString*)obj_val.get_heapptr();
        (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
        HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.unit_len());
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC, vm.heap);
    } else if (obj_val.is_number() || obj_val.is_fastint()) {
        HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch _err = wrapped) { return op_fail(ds, VM_ERROR); }
        obj = wrapped;
        obj.prototype = vm.heap.number_proto;
        vm.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, &obj_val);
    } else {
        // POINTER or BUFFER: spec says throw; treat as a no-op so a
        // malformed operand does not abort the VM.
        return ds.needs_restart ? RESTART : NEXT;
    }

    EnvRecord*? env_raw = env::env_create_with_object(vm.heap, ds.act.lex_env, obj);
    if (try new_env = env_raw) {
        ds.act.lex_env = new_env;
        ds.vm.heap.shade_root_env(ds.act.lex_env);
        // `var` declarations inside `with` hoist past the with-env
        // (ECMA-262 §13.11), so keep var_env BELOW it: DECLVAR walks
        // past with-envs anyway, and reads/writes inside the body go
        // through lex_env. Pushing here too would leave stale
        // with-envs on var_env after WITH_END pops only lex_env.
    } else {
        return op_fail(ds, VM_ERROR);
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_with_end(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    if (!Opcode.WITH_END.is_enabled()) return op_fail(ds, VM_ERROR);
    // Pop the current with-env from the lex chain. Do not return
    // the record to the pool: a closure created inside the `with`
    // block may have captured it via func.lex_env (CLOSURE captures
    // act.lex_env directly), and freeing would leave a dangling
    // pointer in the closure.
    if (ds.act.lex_env != null && ds.act.lex_env.parent != null) {
        ds.act.lex_env = ds.act.lex_env.parent;
        ds.vm.heap.shade_root_env(ds.act.lex_env);
    }
    return NEXT;
}

fn OpStatus op_withget(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    if (!Opcode.WITHGET.is_enabled()) return op_fail(ds, VM_ERROR);
    // SnapshotReference read for a read-modify-write on an
    // identifier inside `with` (ECMA-262 §11.13.2 step 4: PutValue uses
    // the initially-created Reference even when the value getter
    // deletes the binding). A = value register (the rewritten LHS
    // GETVAR's register), B = base register, C = name constant.
    // Resolves per HasBinding, then reads: on a with-env hit B holds
    // the bindings object and A the HasProperty-checked current
    // value (the base lands before the getter runs, so a deleting
    // getter still routes the store here). Otherwise B stays undefined
    // (the env-record base: a paired WTWR takes the env walk, and a
    // caller reading B as a call receiver gets the spec's
    // WithBaseObject() of undefined). B gains a register-external
    // reference (increfed below), released by the WTWR scrub.
    // Unscopables-throw, TDZ, and getter-throw surface through the
    // standard throw paths.
    uint c_idx = insn.c;
    void* key = null;
    if (c_idx < vm.current_func.const_count) {
        TVal name_val = ds.constants[c_idx];
        if (name_val.is_string()) { key = name_val.get_heapptr(); }
    }
    if (key == null) {
        vm.heap.set_reg_undefined(ra);
        vm.heap.set_reg_undefined(rb);
        return NEXT;
    }
    // B starts undefined so a declarative hit (which sets only A) or
    // an unresolvable name leaves the env-record base, not whatever
    // dead value the reserved register happened to hold.
    vm.heap.set_reg_undefined(rb);
    EnvRecord* cur = ds.act.lex_env;
    bool threw_pending = false;
    bool resolved = false;
    while (cur != null) {
        if (cur.is_with()) {
            // §9.1.1.2.1 HasBinding step 2: HasProperty through the
            // Proxy-aware OrdinaryHasProperty path so the proxy's
            // `has` trap fires. has_prop_proto walks the prototype
            // chain directly and silently misses the trap.
            bool has_hit = false;
            if (!builtins::js_has_property(vm, vm.heap, cur.bindings, (HString*)key, &has_hit)) {
                if (vm.heap.has_error && !vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                threw_pending = true;
                break;
            }
            if (!has_hit) { cur = cur.parent; continue; }
            // §9.1.1.2.1 HasBinding step 5: @@unscopables gate.
            if (vm_with_unscopables_blocks_dispatch(ds, cur, key)) {
                cur = cur.parent;
                continue;
            }
            if (ds.needs_restart) { threw_pending = true; break; }
            if (vm.heap.has_error) {
                if (!vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                threw_pending = true;
                break;
            }
            // §9.1.1.2.6 GetBindingValue step 2: re-check HasProperty
            // after the observable @@unscopables getter ran. For a
            // Proxy bindings object the `has` trap fires again, matching
            // the test262 expectations (.../with/*-with-proxy-env.js).
            bool still_hit = false;
            if (!builtins::js_has_property(vm, vm.heap, cur.bindings, (HString*)key, &still_hit)) {
                if (vm.heap.has_error && !vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                threw_pending = true; break;
            }
            if (!still_hit) {
                vm.heap.set_reg_undefined(ra);
                track_heap_store(ds.act, ra, (uint)insn.a);
                resolved = true;
                break;
            }
            // Capture the base first: the value getter below may
            // delete the binding, and the paired WTWR must still
            // write to this object (ECMA-262 §11.13.2 step 4).
            vm.heap.set_reg_object(rb, cur.bindings);
            void* wbase = rb.get_heapptr();
            if (wbase != null) { ((types::HeapHeader*)wbase).incref(); }
            track_heap_store(ds.act, rb, (uint)insn.b);
            // HasBinding resolved to this env; when the unscopables
            // getter deleted the binding, GetValue yields undefined.
            hobject::PropProtoResult proto =
                cur.bindings.get_prop_proto_full(key, vm.heap);
            if (proto.found) {
                if (proto.is_accessor) {
                    TVal getter = hobject::hobject_access_getter(proto.value);
                    if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                        TVal this_tv;
                        this_tv.set_object(proto.owner != null ? proto.owner : cur.bindings);
                        TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                        if (vm.heap.has_error) {
                            vm.heap.has_error = false;
                            TVal err_val = vm.heap.error_value;
                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                vm.has_error = true;
                                vm.heap.has_error = true;
                                return op_fail(ds, VM_ERROR);
                            }
                            threw_pending = true;
                            break;
                        }
                        vm.heap.tval_copy_ref(ra, &getter_val);
                    } else {
                        vm.heap.set_reg_undefined(ra);
                    }
                } else {
                    vm.heap.tval_copy_ref(ra, &proto.value);
                }
            } else {
                vm.heap.set_reg_undefined(ra);
            }
            track_heap_store(ds.act, ra, (uint)insn.a);
            resolved = true;
            break;
        }
        int idx = cur.bindings.find_prop_idx(key, vm.heap);
        if (idx >= 0) {
            // Read the value here so compound-assign callers see
            // the current binding value, mirroring the with-env
            // hit path above. Pair with WTWR: B stays unset so
            // WTWR walks the lex chain again and writes back to
            // this same declarative binding.
            TVal v_raw = cur.bindings.prop_values()[idx].get();
            if (env::is_tdz_sentinel(&v_raw)) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                threw_pending = true;
                break;
            }
            if (cur.bindings.get_prop_flags((uint)idx, vm.heap).is_accessor) {
                TVal getter = hobject::hobject_access_getter(v_raw);
                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                    TVal this_tv;
                    this_tv.set_object(cur.bindings);
                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                    if (vm.heap.has_error) {
                        vm.heap.has_error = false;
                        TVal err_val = vm.heap.error_value;
                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            vm.has_error = true;
                            vm.heap.has_error = true;
                            return op_fail(ds, VM_ERROR);
                        }
                        threw_pending = true;
                        break;
                    }
                    vm.heap.tval_copy_ref(ra, &getter_val);
                } else {
                    vm.heap.set_reg_undefined(ra);
                }
            } else {
                vm.heap.tval_copy_ref(ra, &v_raw);
            }
            track_heap_store(ds.act, ra, (uint)insn.a);
            resolved = true;
            break;
        }
        cur = cur.parent;
    }
    if (threw_pending) { return ds.needs_restart ? RESTART : NEXT; }
    if (!resolved) {
        // Declarative hit elsewhere, unscopables-blocked, or
        // unresolvable: B is already undefined (set above), so the
        // paired WTWR takes the env walk. A still needs the current
        // value; reuse the GETVAR slow path's value semantics: walk
        // the chain for a declarative/TDZ/accessor hit, else undefined
        // in sloppy or a ReferenceError in strict.
        bool done = false;
        EnvRecord* vcur = ds.act.lex_env;
        while (vcur != null) {
            if (vcur.is_with()) { vcur = vcur.parent; continue; }
            int vidx = vcur.bindings.find_prop_idx(key, vm.heap);
            if (vidx < 0) { vcur = vcur.parent; continue; }
            TVal v_raw = vcur.bindings.prop_values()[vidx].get();
            if (env::is_tdz_sentinel(&v_raw)) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                threw_pending = true;
                break;
            }
            if (vcur.bindings.get_prop_flags((uint)vidx, vm.heap).is_accessor) {
                TVal getter = hobject::hobject_access_getter(v_raw);
                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                    TVal this_tv;
                    this_tv.set_object(vcur.bindings);
                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                    if (vm.heap.has_error) {
                        vm.heap.has_error = false;
                        TVal err_val = vm.heap.error_value;
                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            vm.has_error = true;
                            vm.heap.has_error = true;
                            return op_fail(ds, VM_ERROR);
                        }
                        threw_pending = true;
                        break;
                    }
                    vm.heap.tval_copy_ref(ra, &getter_val);
                } else {
                    vm.heap.set_reg_undefined(ra);
                }
            } else {
                vm.heap.tval_copy_ref(ra, &v_raw);
            }
            track_heap_store(ds.act, ra, (uint)insn.a);
            done = true;
            break;
        }
        if (threw_pending) { return ds.needs_restart ? RESTART : NEXT; }
        if (!done) {
            bool is_strict_act = ds.act.func != null
                && ((CompiledFunction*)ds.act.func).is_strict();
            if (is_strict_act) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "'%s' is not defined", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                return ds.needs_restart ? RESTART : NEXT;
            }
            vm.heap.set_reg_undefined(ra);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_withbase(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    if (!Opcode.WITHBASE.is_enabled()) return op_fail(ds, VM_ERROR);
    // SnapshotReference base for a plain assignment inside `with`
    // (ECMA-262 §9.1.1.2.5 SetMutableBinding steps 1-2: the base is
    // fixed by HasBinding before the RHS runs). Captures only the
    // base per HasBinding, running no value getter: on a with-env
    // hit A holds the bindings object; on a declarative/global hit A
    // holds the owning EnvRecord* so the paired WTWR writes there
    // directly (an RHS that re-shapes the chain, e.g. by creating a
    // property on the with object, must not capture the store); on an
    // unresolvable Reference A is undefined and WTWR takes the env
    // walk. The captured reference is released by the WTWR scrub; the
    // unscopables-throw path surfaces through the standard throw
    // machinery.
    uint bc = insn.get_bc();
    HObject* base = null;
    EnvRecord* owner_env = null;
    bool threw = false;
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) {
            void* key = name_val.get_heapptr();
            EnvRecord* cur = ds.act.lex_env;
            while (cur != null) {
                if (cur.is_with()) {
                    // HasBinding order (§9.1.1.2.1 steps 2-9): the
                    // HasProperty check runs first, and the
                    // @@unscopables getter is read only on a hit. A
                    // deleting getter does not unresolve the
                    // Reference: the base stays this bindings
                    // object, and the paired WTWR creates the
                    // property on it (SetMutableBinding steps 2-4:
                    // stillExists false, then Set). The Proxy-aware
                    // js_has_property fires the `has` trap so
                    // test262 set-mutable-binding-idref-with-proxy-
                    // env.js sees HasBinding step 2.
                    bool has_hit = false;
                    if (!builtins::js_has_property(vm, vm.heap, cur.bindings, (HString*)key, &has_hit)) {
                        if (vm.heap.has_error && !vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                        threw = true;
                        break;
                    }
                    if (!has_hit) { cur = cur.parent; continue; }
                    if (vm_with_unscopables_blocks_dispatch(ds, cur, key)) {
                        cur = cur.parent;
                        continue;
                    }
                    if (ds.needs_restart) { threw = true; break; }
                    if (vm.heap.has_error) {
                        if (!vm_throw_pending(vm, ds)) return op_fail(ds, VM_ERROR);
                        threw = true;
                        break;
                    }
                    base = cur.bindings;
                    break;
                }
                if (cur.bindings.find_prop_idx(key, vm.heap) >= 0) { owner_env = cur; break; }
                cur = cur.parent;
            }
        }
    }
    if (!threw) {
        if (base != null) {
            vm.heap.set_reg_object(ra, base);
            ((types::HeapHeader*)base).incref();
            track_heap_store(ds.act, ra, (uint)insn.a);
        } else if (owner_env != null) {
            vm.heap.set_reg_envref(ra, (void*)owner_env);
            track_heap_store(ds.act, ra, (uint)insn.a);
        } else {
            vm.heap.set_reg_undefined(ra);
        }
    }
    return ds.needs_restart ? RESTART : NEXT;
}

fn OpStatus op_wtwr(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    if (!Opcode.WTWR.is_enabled()) return op_fail(ds, VM_ERROR);
    // SnapshotPutValue: A = value register, B = base register the
    // paired WITHGET captured, C = name constant. On a bindings
    // object base the write goes through [[Set]] on that object
    // (creating the property when the read-side getter deleted it,
    // per ECMA-262 §11.13.2 step 4). Otherwise B holds the global object
    // and this behaves as PUTVAR_ASSIGN (TDZ/const throws, sloppy
    // implicit global). A failed strict [[Set]] throws TypeError;
    // sloppy ignores it (§8.7.2 step 5). B's ownership ends here:
    // B held a non-register reference (WITHGET increfed, PUTPROP-style
    // clears never ran on it), so scrub it back to undefined without
    // touching A's value.
    uint bc = insn.c;
    void* key = null;
    if (bc < vm.current_func.const_count) {
        TVal name_val = ds.constants[bc];
        if (name_val.is_string()) { key = name_val.get_heapptr(); }
    }
    bool threw = false;
    if (key != null && rb.is_object() && vm.global_env != null
        && (HObject*)rb.get_heapptr() != vm.global_env.bindings) {
        bool? threw_raw = vm_write_with_binding(ds, (HObject*)rb.get_heapptr(), (HString*)key, *ra);
        if (catch err = threw_raw) return op_fail(ds, err);
        threw = threw_raw;
    } else if (key != null && rb.is_envref()) {
        // WITHBASE captured the owning EnvRecord*: the Reference did
        // not resolve through a with-env, so SetMutableBinding runs
        // against that declarative/global env directly. An RHS that
        // re-shaped the chain (e.g. created a property on the with
        // object, test262 S11.13.1_A6_T3) must not capture the store.
        EnvRecord* senv = (EnvRecord*)rb.get_heapptr();
        bool senv_strict = ds.act.func != null
            && ((CompiledFunction*)ds.act.func).is_strict();
        if (senv != null) {
            int put_result = env::env_try_put_lex(senv, key, *ra, true);
            if (put_result == -1 || (put_result == -4 && senv_strict)) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                threw = true;
            } else if (put_result == -2) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                threw = true;
            } else if (put_result == -3 && senv_strict) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                threw = true;
            } else if (put_result == 0) {
                int bres = vm_bareword_put(vm, ds, key, *ra);
                if (bres < 0) { return op_fail(ds, VM_ERROR); }
                if (bres == 0) { threw = true; }
            }
        }
        vm.heap.decref_tval(ra);
        ra.set_undefined();
    } else if (key != null) {
            int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra, true);
            if (put_result == -1) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return op_fail(ds, VM_ERROR);
                }
                threw = true;
            } else if (put_result == -4) {
                // Non-strict immutable binding (fnexpr own name):
                // sloppy drops silently, strict throws.
                bool strict_c = ds.act.func != null
                    && ((CompiledFunction*)ds.act.func).is_strict();
                if (strict_c) {
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt_str(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return op_fail(ds, VM_ERROR);
                    }
                    threw = true;
                }
            } else if (put_result == -2) {
            HString* name_hstr = (HString*)key;
            if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return op_fail(ds, VM_ERROR);
            }
            threw = true;
        } else if (put_result == 0) {
            int bres = vm_bareword_put(vm, ds, key, *ra);
            if (bres < 0) { return op_fail(ds, VM_ERROR); }
            if (bres == 0) { threw = true; }
        }
        vm.heap.decref_tval(ra);
        ra.set_undefined();
    }
    if (rb.is_heap_allocated()) {
        void* ptr = rb.get_heapptr();
        if (ptr != null) { vm.heap.decref((types::HeapHeader*)ptr); }
        rb.set_undefined();
    }
    return ds.needs_restart ? RESTART : NEXT;
}

// === CLOSURES ===
// NEWCELLS, GETCELL, SETCELL, MOVECELL
fn OpStatus op_cells(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_cells(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

// CLOSURE, GETBOUND
fn OpStatus op_closure(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_closures(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

// === ITERATOR ===
// INITFOR, NEXTFOR, ITER_NEXT_FAST, ITER_ENTRY_FAST, ARRAY_PATTERN_GUARD,
// ITER_OPEN_FAST, DESTRUCT_ARRAY_FAST, DESTRUCT_ARRAY_REST_FAST
fn OpStatus op_iterator(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_iterator(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    return ds.needs_restart ? RESTART : NEXT;
}

// === EXCEPTION HANDLING ===
// TRY, ENDTRY, THROW, THROW_REF, THROW_SYNTAX, CATCH, FINALLY, ENDFINALLY
fn OpStatus op_exceptions(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_exceptions(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    if (ds.halt) return HALT;
    return ds.needs_restart ? RESTART : NEXT;
}

// === MISC ===
// NOP, DEBUGGER, BREAK, CONTINUE, the INIT* family, PUSH/POP_LEX/VAR, the
// CHK* guards, iterator closes, private names and brands
fn OpStatus op_misc(Dispatch* ds, DecodedInsn insn) {
    TVal* regs = ds.regs_base;
    if (catch err = dispatch_misc(ds, insn.op, regs + insn.a, regs + insn.b, regs + insn.c, insn)) return op_fail(ds, err);
    // Getters, iterator closes and other user code may reallocate the
    // valstack; refresh regs_base unless the outer loop reloads it.
    if (!ds.needs_restart) {
        ds.regs_base = ds.act.bottom;
        return NEXT;
    }
    return RESTART;
}
