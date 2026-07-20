module dispatchbench3;
import std::io;
import std::time;

// Hybrid: a handful of truly hot scalars as direct args (pc, regs, code, code_end)
// plus one pointer for "cold" state (nregs, ic_base, act, etc — read rarely).
// Mimics the real Dispatch struct's 13 fields split into hot/cold.

struct Instruction3 {
    char op;
    char a;
    char b;
    char c;
}

enum Op3 : char {
    LDINT, ADD, SUB, JMP_NLE, LDREG, RET,
}

const int NREGS3 = 8;

struct ColdState {
    uint nregs;
    void* ic_base;
    void* var_ic_base;
    void* act;
    void* vm;
    TValStub halt_value;
}
struct TValStub { long a; long b; }

alias HandlerFn3 = fn long(Instruction3*, Instruction3*, long*, ColdState*);
// args: pc, code_end, regs, cold

HandlerFn3[6] handlers3;

fn long h3_ldint(Instruction3* pc, Instruction3* code_end, long* regs, ColdState* cold) {
    Instruction3 insn = *pc;
    pc++;
    regs[insn.a] = (long)insn.b;
    if (pc >= code_end) return regs[0];
    Instruction3 next = *pc;
    return handlers3[next.op](pc, code_end, regs, cold);
}

fn long h3_add(Instruction3* pc, Instruction3* code_end, long* regs, ColdState* cold) {
    Instruction3 insn = *pc;
    pc++;
    regs[insn.a] = regs[insn.b] + regs[insn.c];
    if (pc >= code_end) return regs[0];
    Instruction3 next = *pc;
    return handlers3[next.op](pc, code_end, regs, cold);
}

fn long h3_sub(Instruction3* pc, Instruction3* code_end, long* regs, ColdState* cold) {
    Instruction3 insn = *pc;
    pc++;
    regs[insn.a] = regs[insn.b] - regs[insn.c];
    if (pc >= code_end) return regs[0];
    Instruction3 next = *pc;
    return handlers3[next.op](pc, code_end, regs, cold);
}

fn long h3_jmp_nle(Instruction3* pc, Instruction3* code_end, long* regs, ColdState* cold) {
    Instruction3 insn = *pc;
    pc++;
    if (regs[insn.a] > regs[insn.b]) {
        // Fixed 6-instruction program: jump target index == insn.c, addressed
        // relative to code_end (code_end - 6 == code base).
        pc = code_end - 6 + (int)insn.c;
    }
    if (pc >= code_end) return regs[0];
    Instruction3 next = *pc;
    return handlers3[next.op](pc, code_end, regs, cold);
}

fn long h3_ldreg(Instruction3* pc, Instruction3* code_end, long* regs, ColdState* cold) {
    Instruction3 insn = *pc;
    pc++;
    regs[insn.a] = regs[insn.b];
    if (pc >= code_end) return regs[0];
    Instruction3 next = *pc;
    return handlers3[next.op](pc, code_end, regs, cold);
}

fn long h3_ret(Instruction3* pc, Instruction3* code_end, long* regs, ColdState* cold) {
    Instruction3 insn = *pc;
    return regs[insn.a];
}

fn long run_threaded3(Instruction3* code, usz code_len, long* regs, ColdState* cold) {
    if (code_len == 0) return 0;
    Instruction3* code_end = code + code_len;
    return handlers3[code[0].op](code, code_end, regs, cold);
}

fn Instruction3[] build_program3() {
    Instruction3[] prog = mem::new_array(Instruction3, 6);
    prog[0] = { .op = (char)Op3.LDINT.ordinal, .a = 3, .b = 1, .c = 0 };
    prog[1] = { .op = (char)Op3.ADD.ordinal, .a = 0, .b = 0, .c = 1 };
    prog[2] = { .op = (char)Op3.SUB.ordinal, .a = 1, .b = 1, .c = 3 };
    prog[3] = { .op = (char)Op3.LDINT.ordinal, .a = 4, .b = 0, .c = 0 };
    prog[4] = { .op = (char)Op3.JMP_NLE.ordinal, .a = 1, .b = 4, .c = 1 };
    prog[5] = { .op = (char)Op3.RET.ordinal, .a = 0, .b = 0, .c = 0 };
    return prog;
}

fn void main() {
    handlers3[0] = &h3_ldint;
    handlers3[1] = &h3_add;
    handlers3[2] = &h3_sub;
    handlers3[3] = &h3_jmp_nle;
    handlers3[4] = &h3_ldreg;
    handlers3[5] = &h3_ret;

    Instruction3[] prog = build_program3();
    int n = 200_000_000;

    long[NREGS3] regs;
    regs[1] = (long)n;
    ColdState cold;
    Clock c = clock::now();
    long result = run_threaded3(prog.ptr, prog.len, &regs[0], &cold);
    double elapsed = c.to_now().to_ms();
    io::printfn("threaded3(hybrid-4arg): result=%d  time=%.2fms", result, elapsed);
}
