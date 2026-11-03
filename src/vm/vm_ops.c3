module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::env;

// Operation functions: one callable implementation per opcode, or per group
// of opcodes sharing a body, each performing its instruction against the
// current frame. The switch in vm_dispatch calls them, and so can any other
// dispatcher that holds a Dispatch and a decoded instruction.

// What an operation function did to the dispatch state. NEXT: the frame is
// unchanged and execution continues at ds.curr_pc. RESTART: ds.needs_restart
// is set (a frame was pushed or popped, or an exception unwound), and the
// caller reloads the frame. HALT: the run ends with ds.halt_value. FAULT: the
// run fails with ds.failure.
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
