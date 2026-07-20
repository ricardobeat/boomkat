module dispatchbench;
import std::io;
import std::time;

// Mimics vm_execute.c3's Instruction layout: op(8) | a(8) | b(8) | c(8) packed in a uint.
struct Instruction {
    char op;
    char a;
    char b;
    char c;
}

enum Op : char {
    LDINT,   // reg[a] = sbc (b<<8|c as signed small int, simplified: reg[a] = b)
    ADD,     // reg[a] = reg[b] + reg[c]
    SUB,     // reg[a] = reg[b] - reg[c]
    JMP_NLE, // if reg[a] > reg[b]: pc = c (jump target as absolute index)
    LDREG,   // reg[a] = reg[b]
    RET,     // halt, result = reg[a]
}

const int NREGS = 8;

struct DispatchState {
    long* regs;
    Instruction* code;
    usz pc;
    usz code_len;
    bool needs_restart;
    bool halted;
    long result;
}

// ============ SWITCH-BASED DISPATCH (mirrors current vm_execute.c3 shape) ============

fn long run_switch(Instruction* code, usz code_len, long[NREGS]* regs_in) {
    long[NREGS] regs = *regs_in;
    DispatchState ds;
    ds.regs = &regs[0];
    ds.code = code;
    ds.code_len = code_len;
    ds.pc = 0;
    ds.needs_restart = false;
    ds.halted = false;
    ds.result = 0;

    for (; !ds.needs_restart;) {
        if (ds.halted) return ds.result;
        if (ds.pc >= ds.code_len) return ds.result;

        Instruction insn = ds.code[ds.pc];
        ds.pc++;

        long* ra = &ds.regs[insn.a];
        long* rb = &ds.regs[insn.b];
        long* rc = &ds.regs[insn.c];

        switch ((Op)insn.op) @jump {
            case Op.LDINT:
                *ra = (long)insn.b;
                continue;
            case Op.ADD:
                *ra = *rb + *rc;
                continue;
            case Op.SUB:
                *ra = *rb - *rc;
                continue;
            case Op.JMP_NLE:
                if (*ra > *rb) {
                    ds.pc = (usz)insn.c;
                }
                continue;
            case Op.LDREG:
                *ra = *rb;
                continue;
            case Op.RET:
                ds.result = *ra;
                ds.halted = true;
                continue;
        }
    }
    return ds.result;
}

// ============ CPS / DIRECT-THREADED DISPATCH ============
// Each handler decodes its own instruction, executes, then tail-calls the
// handler for the NEXT instruction via a function-pointer table indexed by
// the next opcode. No shared loop head to return to.

alias HandlerFn = fn long(DispatchState*);

HandlerFn[6] handlers;

fn long h_ldint(DispatchState* ds) {
    Instruction insn = ds.code[ds.pc];
    ds.pc++;
    ds.regs[insn.a] = (long)insn.b;
    if (ds.pc >= ds.code_len) return ds.result;
    Instruction next = ds.code[ds.pc];
    return handlers[next.op](ds);
}

fn long h_add(DispatchState* ds) {
    Instruction insn = ds.code[ds.pc];
    ds.pc++;
    ds.regs[insn.a] = ds.regs[insn.b] + ds.regs[insn.c];
    if (ds.pc >= ds.code_len) return ds.result;
    Instruction next = ds.code[ds.pc];
    return handlers[next.op](ds);
}

fn long h_sub(DispatchState* ds) {
    Instruction insn = ds.code[ds.pc];
    ds.pc++;
    ds.regs[insn.a] = ds.regs[insn.b] - ds.regs[insn.c];
    if (ds.pc >= ds.code_len) return ds.result;
    Instruction next = ds.code[ds.pc];
    return handlers[next.op](ds);
}

fn long h_jmp_nle(DispatchState* ds) {
    Instruction insn = ds.code[ds.pc];
    ds.pc++;
    if (ds.regs[insn.a] > ds.regs[insn.b]) {
        ds.pc = (usz)insn.c;
    }
    if (ds.pc >= ds.code_len) return ds.result;
    Instruction next = ds.code[ds.pc];
    return handlers[next.op](ds);
}

fn long h_ldreg(DispatchState* ds) {
    Instruction insn = ds.code[ds.pc];
    ds.pc++;
    ds.regs[insn.a] = ds.regs[insn.b];
    if (ds.pc >= ds.code_len) return ds.result;
    Instruction next = ds.code[ds.pc];
    return handlers[next.op](ds);
}

fn long h_ret(DispatchState* ds) {
    Instruction insn = ds.code[ds.pc];
    ds.pc++;
    ds.result = ds.regs[insn.a];
    ds.halted = true;
    return ds.result;
}

fn long run_threaded(Instruction* code, usz code_len, long[NREGS]* regs_in) {
    long[NREGS] regs = *regs_in;
    DispatchState ds;
    ds.regs = &regs[0];
    ds.code = code;
    ds.code_len = code_len;
    ds.pc = 0;
    ds.needs_restart = false;
    ds.halted = false;
    ds.result = 0;

    if (code_len == 0) return 0;
    Instruction first = code[0];
    return handlers[first.op](&ds);
}

// ============ BENCHMARK DRIVER ============
// Builds a small loop: sum = 0; i = 0; while (i < N) { sum += i; i -= (-1); } ; ret sum
// registers: r0=sum, r1=i, r2=N, r3=one(=-1 trick unused), r4=tmp/limit-cmp, r5=jmptarget unused
// program:
// 0: LDINT r0, 0          ; sum = 0
// 1: LDINT r1, 0          ; i = 0
// 2: LDINT r3, 1          ; one = 1
// 3: JMP_NLE r1,r2,7   -> if i > N-ish... we'll structure as a countdown instead for simplicity.
// Simpler: countdown loop using r1 = N, r3 = 1
// 0: LDINT r1, <N>        ; r1 = N  (loaded at runtime since N up to ~200M doesn't fit char; we patch b via ADD trick)
// Use a tight 5-instruction loop body executed as a flat unrolled-free real loop via JMP back.

fn Instruction[] build_program(int n_iters_lo /* unused, dynamic loop count via register pre-set externally */) {
    // program layout (indices):
    // 0: LDINT r3, 1          r3 = 1  (decrement amount)
    // 1: ADD   r0, r0, r1     sum += i     (loop body start = pc 1)
    // 2: SUB   r1, r1, r3     i -= 1
    // 3: LDINT r4, 0          r4 = 0 (zero const for compare)
    // 4: JMP_NLE r4, r1, 1    if 0 <= i (i.e. r4 > r1 is false... ) -- see note below
    // 5: RET r0
    // We want: loop while i > 0. JMP_NLE semantics: if reg[a] > reg[b] then pc = c.
    // We test "not (i <= 0)" -> if r1 > r4(=0) then jump back to 1.
    Instruction[] prog = mem::new_array(Instruction, 6);
    prog[0] = { .op = (char)Op.LDINT.ordinal, .a = 3, .b = 1, .c = 0 };
    prog[1] = { .op = (char)Op.ADD.ordinal, .a = 0, .b = 0, .c = 1 };
    prog[2] = { .op = (char)Op.SUB.ordinal, .a = 1, .b = 1, .c = 3 };
    prog[3] = { .op = (char)Op.LDINT.ordinal, .a = 4, .b = 0, .c = 0 };
    prog[4] = { .op = (char)Op.JMP_NLE.ordinal, .a = 1, .b = 4, .c = 1 };
    prog[5] = { .op = (char)Op.RET.ordinal, .a = 0, .b = 0, .c = 0 };
    return prog;
}

fn void main() {
    handlers[0] = &h_ldint;
    handlers[1] = &h_add;
    handlers[2] = &h_sub;
    handlers[3] = &h_jmp_nle;
    handlers[4] = &h_ldreg;
    handlers[5] = &h_ret;

    Instruction[] prog = build_program(0);

    int n = 200_000_000;

    // --- switch dispatch ---
    {
        long[NREGS] regs;
        regs[1] = (long)n;
        Clock c = clock::now();
        long result = run_switch(prog.ptr, prog.len, &regs);
        double elapsed = c.to_now().to_ms();
        io::printfn("switch:   result=%d  time=%.2fms", result, elapsed);
    }

    // --- threaded dispatch ---
    {
        long[NREGS] regs;
        regs[1] = (long)n;
        Clock c = clock::now();
        long result = run_threaded(prog.ptr, prog.len, &regs);
        double elapsed = c.to_now().to_ms();
        io::printfn("threaded: result=%d  time=%.2fms", result, elapsed);
    }
}
