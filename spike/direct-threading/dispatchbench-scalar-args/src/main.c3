module dispatchbench2;
import std::io;
import std::time;

// Same as dispatchbench but threaded handlers take hot state as scalar
// arguments (pc, code ptr, regs ptr, code_len) instead of a struct pointer,
// to see if LLVM can keep them in registers across tail calls the way it
// does across loop iterations in the switch version.

struct Instruction2 {
    char op;
    char a;
    char b;
    char c;
}

enum Op2 : char {
    LDINT, ADD, SUB, JMP_NLE, LDREG, RET,
}

const int NREGS2 = 8;

alias HandlerFn2 = fn long(Instruction2*, usz, long*, usz);

HandlerFn2[6] handlers2;

fn long h2_ldint(Instruction2* code, usz pc, long* regs, usz code_len) {
    Instruction2 insn = code[pc];
    pc++;
    regs[insn.a] = (long)insn.b;
    if (pc >= code_len) return regs[0];
    Instruction2 next = code[pc];
    return handlers2[next.op](code, pc, regs, code_len);
}

fn long h2_add(Instruction2* code, usz pc, long* regs, usz code_len) {
    Instruction2 insn = code[pc];
    pc++;
    regs[insn.a] = regs[insn.b] + regs[insn.c];
    if (pc >= code_len) return regs[0];
    Instruction2 next = code[pc];
    return handlers2[next.op](code, pc, regs, code_len);
}

fn long h2_sub(Instruction2* code, usz pc, long* regs, usz code_len) {
    Instruction2 insn = code[pc];
    pc++;
    regs[insn.a] = regs[insn.b] - regs[insn.c];
    if (pc >= code_len) return regs[0];
    Instruction2 next = code[pc];
    return handlers2[next.op](code, pc, regs, code_len);
}

fn long h2_jmp_nle(Instruction2* code, usz pc, long* regs, usz code_len) {
    Instruction2 insn = code[pc];
    pc++;
    if (regs[insn.a] > regs[insn.b]) {
        pc = (usz)insn.c;
    }
    if (pc >= code_len) return regs[0];
    Instruction2 next = code[pc];
    return handlers2[next.op](code, pc, regs, code_len);
}

fn long h2_ldreg(Instruction2* code, usz pc, long* regs, usz code_len) {
    Instruction2 insn = code[pc];
    pc++;
    regs[insn.a] = regs[insn.b];
    if (pc >= code_len) return regs[0];
    Instruction2 next = code[pc];
    return handlers2[next.op](code, pc, regs, code_len);
}

fn long h2_ret(Instruction2* code, usz pc, long* regs, usz code_len) {
    Instruction2 insn = code[pc];
    return regs[insn.a];
}

fn long run_threaded2(Instruction2* code, usz code_len, long* regs) {
    if (code_len == 0) return 0;
    Instruction2 first = code[0];
    return handlers2[first.op](code, 0, regs, code_len);
}

fn Instruction2[] build_program2() {
    Instruction2[] prog = mem::new_array(Instruction2, 6);
    prog[0] = { .op = (char)Op2.LDINT.ordinal, .a = 3, .b = 1, .c = 0 };
    prog[1] = { .op = (char)Op2.ADD.ordinal, .a = 0, .b = 0, .c = 1 };
    prog[2] = { .op = (char)Op2.SUB.ordinal, .a = 1, .b = 1, .c = 3 };
    prog[3] = { .op = (char)Op2.LDINT.ordinal, .a = 4, .b = 0, .c = 0 };
    prog[4] = { .op = (char)Op2.JMP_NLE.ordinal, .a = 1, .b = 4, .c = 1 };
    prog[5] = { .op = (char)Op2.RET.ordinal, .a = 0, .b = 0, .c = 0 };
    return prog;
}

fn void main() {
    handlers2[0] = &h2_ldint;
    handlers2[1] = &h2_add;
    handlers2[2] = &h2_sub;
    handlers2[3] = &h2_jmp_nle;
    handlers2[4] = &h2_ldreg;
    handlers2[5] = &h2_ret;

    Instruction2[] prog = build_program2();
    int n = 200_000_000;

    long[NREGS2] regs;
    regs[1] = (long)n;
    Clock c = clock::now();
    long result = run_threaded2(prog.ptr, prog.len, &regs[0]);
    double elapsed = c.to_now().to_ms();
    io::printfn("threaded2(scalar-args): result=%d  time=%.2fms", result, elapsed);
}
