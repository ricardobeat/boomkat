// The compiler admits only a straight-line, proven Number-only region.
module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;

fn Instruction* execute_numeric_region(Vm* vm, CompiledFunction* func,
                                       TVal* regs, Instruction* entry) {
    // Every read was proven initialized by the compiler pass.
    double[32] values @noinit;
    // Guards read tags only. Refusal performs no conversion or register write,
    // and resumes ordinary JS at the instruction immediately after the guard.
    for (uint i = 0; i < entry.a; i++) {
        if (!regs[i].is_fastint() && !regs[i].is_number()) return entry + 1;
        values[i] = regs[i].get_number_or_fastint();
    }
    for (Instruction* pc = entry + 1;; pc++) {
        Instruction ins = *pc;
        // Each bytecode operation is evaluated separately in source order.
        // The scratch array stores binary64 intermediates: no reassociation,
        // integer truncation or widening of the JavaScript Number domain.
        switch (ins.op) {
            case Opcode.RET:
                double result = values[ins.a];
                // Optional ablation: keep callers on their existing fastint
                // path when the exact binary64 return value can use that tag.
                // Exclude negative zero before the cast; NaN/Infinity fail
                // the bounds. Every intermediate still rounded as binary64.
                if (entry.b != 0 && result >= (double)types::FASTINT_MIN
                    && result <= (double)types::FASTINT_MAX
                    && bitcast(result, ulong) != 0x8000000000000000) {
                    long integer = (long)result;
                    if ((double)integer == result) {
                        vm.heap.set_reg_fastint(regs + ins.a, integer);
                        return pc;
                    }
                }
                vm.heap.set_reg_number(regs + ins.a, result);
                return pc;
            case Opcode.LDINT: values[ins.a] = (double)ins.get_sbc();
            case Opcode.LDCONST: values[ins.a] = func.constants[ins.get_bc()].get_number_or_fastint();
            case Opcode.LDREG: values[ins.a] = values[ins.b];
            case Opcode.ADD: case Opcode.ADD_FUSED: values[ins.a] = values[ins.b] + values[ins.c];
            case Opcode.SUB: values[ins.a] = values[ins.b] - values[ins.c];
            case Opcode.MUL: values[ins.a] = values[ins.b] * values[ins.c];
            case Opcode.DIV: values[ins.a] = values[ins.b] / values[ins.c];
            case Opcode.ADDI: values[ins.a] = values[ins.b] + (double)ins.c;
            case Opcode.SUBI: values[ins.a] = values[ins.b] - (double)ins.c;
            case Opcode.MULI: values[ins.a] = values[ins.b] * (double)(ichar)ins.c;
            default: unreachable("Invalid proven numeric region");
        }
    }
}
