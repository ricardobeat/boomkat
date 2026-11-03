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
            return op_uncaught(ds, &vm.throw_value);
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
    if (rc.get_tag() == OBJECT) { prim_c = to_primitive_value(vm, rc, 0); }
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
    if (rb.is_bigint() || rc.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.SUB, ra, rb, rc) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    if (types::both_fastint(rb, rc)) {
        long diff = rb.get_fastint() - rc.get_fastint();
        if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
            vm.heap.set_reg_fastint(ra, diff);
        } else {
            vm.heap.set_reg_number(ra, (double)diff);
        }
    } else {
        double sub_b = vm_to_number(vm,rb);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
        double sub_c = vm_to_number(vm,rc);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        vm.heap.set_reg_number(ra, sub_b - sub_c);
    }
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
    if (rb.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.SUB, ra, rb, &immv) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double sub_b = vm_to_number(vm, rb);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    vm.heap.set_reg_number(ra, sub_b - (double)imm);
    return NEXT;
}

// MUL, MULI
fn OpStatus op_mul(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal imm_operand;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = op_operand_c(ds, insn, &imm_operand);
    if (rb.is_bigint() || rc.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.MUL, ra, rb, rc) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
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
    } else {
        double mul_b = vm_to_number(vm,rb);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
        double mul_c = vm_to_number(vm,rc);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        vm.heap.set_reg_number(ra, mul_b * mul_c);
    }
    return NEXT;
}

fn OpStatus op_div(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    if (rb.is_bigint() || rc.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.DIV, ra, rb, rc) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double div_b = vm_to_number(vm,rb);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    double div_c = vm_to_number(vm,rc);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    vm.heap.set_reg_number(ra, div_b / div_c);
    return NEXT;
}

fn OpStatus op_mod(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    if (rb.is_bigint() || rc.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.MOD, ra, rb, rc) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    if (types::both_fastint(rb, rc) && rc.get_fastint() != 0) {
        long mod_result = rb.get_fastint() % rc.get_fastint();
        if (mod_result == 0 && rb.get_fastint() < 0) {
            // -1 % 1 → -0: sign of zero matches dividend per ECMA-262 §11.5.3
            vm.heap.set_reg_number(ra, -0.0);
        } else {
            vm.heap.set_reg_fastint(ra, mod_result);
        }
    } else {
        double mod_b = vm_to_number(vm,rb);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        if (ds.needs_restart) return RESTART;
        double mod_c = vm_to_number(vm,rc);
        if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
        vm.heap.set_reg_number(ra, (mod_b % mod_c));
    }
    return NEXT;
}

fn OpStatus op_exp(Dispatch* ds, DecodedInsn insn) {
    Vm* vm = ds.vm;
    TVal* ra = ds.regs_base + insn.a;
    TVal* rb = ds.regs_base + insn.b;
    TVal* rc = ds.regs_base + insn.c;
    if (rb.is_bigint() || rc.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.EXP, ra, rb, rc) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    double exp_b = vm_to_number(vm,rb);
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    double exp_c = vm_to_number(vm,rc);
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
    // See BAND above. Note ECMA-262 §12.9.4 step 6 makes >>> throw
    // TypeError when EITHER ToNumeric result is BigInt (no BigInt
    // unsigned-shift exists), and vm_bigint_binop(USHR, ...) already
    // encodes that, so routing an object-that-yields-BigInt through
    // the same is_bigint() dispatch below is correct here too.
    TVal* eb = rb; TVal* ec = rc;
    TVal ushr_prim_b; TVal ushr_prim_c;
    if (rb.get_tag() == OBJECT || rc.get_tag() == OBJECT) {
        if (!vm_bitwise_to_primitive(vm, rb, rc, &ushr_prim_b, &ushr_prim_c)) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        eb = &ushr_prim_b; ec = &ushr_prim_c;
    }
    if (eb.is_bigint() || ec.is_bigint()) {
        if (vm_bigint_binop(vm, Opcode.USHR, ra, eb, ec) == BigIntOpResult.THREW) {
            if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
            if (ds.needs_restart) return RESTART;
        }
        return NEXT;
    }
    uint ushr_b = (uint)types::toint32(vm_to_number(vm,eb));
    if (!@tonum_ok(vm, ds)) return op_uncaught(ds, &vm.throw_value);
    if (ds.needs_restart) return RESTART;
    int  ushr_c = types::toint32(vm_to_number(vm,ec));
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
// SPREAD_PROJECTION, NEWOBJ_SHAPE, INIT_SLOT, NEWOBJ, NEWARR, NEWARR_CONST,
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
    // Write return value to caller's result register
    if (callee_result != null) {
        // Borrowed callee (CALL_VAR from a global binding): the old
        // value in callee_result is the borrowed closure, which this
        // frame never incref'd it, so overwrite raw and never decref.
        bool ret_borrowed = (callee_act.flags & ACT_FLAG_BORROWED_CALLEE) != 0;
        // Constructor: if callee returned an object, use it; otherwise use 'this'.
        // (Derived non-object non-undefined case was already converted to a throw above.)
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
            if (val.is_object()) {
                vm.heap.tval_copy_ref(callee_result, &val);
            } else {
                vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
            }
        } else {
            // Fast path: skip refcounting when return value is not a heap ref
            if (!val.is_heap_allocated()) {
                if (!ret_borrowed && callee_result.is_heap_allocated()) {
                    vm.heap.decref_tval(callee_result);
                }
                *callee_result = val;
            } else if (val_pinned) {
                // Transfer the pin reference: decref dst, raw write.
                if (!ret_borrowed) vm.heap.decref_tval(callee_result);
                *callee_result = val;
                val_pinned = false;
            } else if (ret_borrowed) {
                // Incref new value, raw-overwrite the borrowed old value.
                ((HeapHeader*)val.get_heapptr()).incref();
                *callee_result = val;
            } else {
                vm.heap.tval_copy_ref(callee_result, &val);
            }
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
            return op_uncaught(ds, &vm.throw_value);
        }
        return ds.needs_restart ? RESTART : NEXT;
    }
    if (derived_return_error) {
        if (!vm_throw_error(vm, vm.heap.type_err_proto,
                "Derived constructors may only return object or undefined",
                ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return op_uncaught(ds, &vm.throw_value);
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
            return op_uncaught(ds, &vm.throw_value);
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
