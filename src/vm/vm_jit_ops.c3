// Helpers baseline code calls directly for the operations whose threaded
// handler completes them but whose inline path would be long: each runs the
// handler's own logic without the thunk's frame and returns false, with the
// registers untouched, when the operation function has to run it.
module boomkat::vm @feat(SLJIT);

import boomkat::bytecode;
import boomkat::types;

// `v instanceof F` for the instruction before `next`, through th_instanceof.
fn bool jit_instanceof(Dispatch* ds, Instruction* next) {
    if (!jit_relay_ready) jit_relay_init();
    ds.curr_pc = next;
    return th_instanceof(next - 1, &jit_stop_table, ds.regs_base, &ds.cold) == next;
}

// An ADD whose operands are not both numbers, for the instruction before
// `next`: the concatenations th_add_concat completes, with the operand classes
// recorded as jit_relay records them.
fn bool jit_add_concat(Dispatch* ds, Instruction* next) {
    if (ds.ic_base == null) return false;
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    ds.curr_pc = next;
    note_feedback(ds, { .op = pc.op, .a = pc.a, .b = pc.b, .c = pc.c }, false);
    return vm_concat_add(ds.vm, ds.act, regs + pc.a, regs + pc.b, regs + pc.c, (uint)pc.a, next, ds.code_end)
        == ConcatStatus.DONE;
}
