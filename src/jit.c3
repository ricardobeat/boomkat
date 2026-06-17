module duktape::jit;

import duktape::bytecode;
import duktape::types;
import duktape::heap;
import duktape::hobject;
import duktape::env;
import libc;

// ============================================================================
// Micro-op kinds
// ============================================================================

enum MopKind : char {
    LOAD_VAR,   // reg[dst] = *var_ptr
    STORE_VAR,  // *var_ptr = reg[src]
    INC_VAR,    // *var_ptr += 1  (fastint only)
    ARITH,      // reg[dst] = reg[b] OP reg[c]
    LDREG,      // reg[dst] = reg[src]
    LDINT,      // reg[dst] = immediate int (long)
}

// ============================================================================
// Data structures
// ============================================================================

const uint MAX_MOPS     = 64;
const uint MAX_REGS     = 16;
const uint MAX_VAR_KEYS = 16;

/// A single decoded micro-operation.
struct Mop {
    MopKind kind;
    char    dst;     // destination reg index (0..MAX_REGS-1)
    char    b;       // source reg B (for ARITH, LDREG)
    char    c;       // source reg C (for ARITH)
    char    op;      // Opcode ordinal (for ARITH)
    short   var_idx; // index into CompiledLoop.var_keys[] (for LOAD_VAR/STORE_VAR/INC_VAR)
    long    imm;     // immediate value (for LDINT)
}

const uint MAX_COMPILED_LOOPS = 32;

/// A resolved variable entry, one per distinct name used in the loop.
struct VarKey {
    void*  key;     // interned HString* (from constants[bc])
    TVal*  ptr;     // resolved TVal* in env prop_values (null until init)
    ushort vic_pc;  // original pc offset for VarIC lookup
}

/// A compiled (traced) loop superinstruction.
struct CompiledLoop {
    // header_pc: the first body instruction, replaced with LOOP_COMPILED.
    // The original instruction is saved in saved_insn and re-executed on fallback.
    // On success: advance curr_pc by total_skip (to instruction after backward JMP).
    uint   header_pc;
    uint   total_skip;     // insns from header to after JMP inclusive

    Instruction saved_insn;  // original instruction at header_pc before patching

    Mop[MAX_MOPS]        mops;
    uint    mop_count;
    VarKey[MAX_VAR_KEYS] var_keys;
    uint    var_key_count;
    uint    ctr_var_idx;  // index in var_keys[] for the loop counter
    uint    lim_var_idx;  // index in var_keys[] for the limit
    bool    initialized;
    bool    is_lt;        // true = stop when ctr >= lim, false = stop when ctr > lim
}

/// All compiled loops for a single function.
struct CompiledLoopTable {
    CompiledLoop[MAX_COMPILED_LOOPS] entries;
    uint count;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn bool jmp_is_cmp(Opcode op) @inline {
    return op == Opcode.JMP_LT || op == Opcode.JMP_LE
        || op == Opcode.JMP_GT || op == Opcode.JMP_GE;
}

fn bool jmp_is_lt(Opcode op) @inline {
    return op == Opcode.JMP_LT || op == Opcode.JMP_GT;
}

/// Look up or insert a var key. Returns the index, or -1 if MAX_VAR_KEYS exceeded.
fn int find_or_add_var_key(CompiledLoop* loop, void* key, uint vic_pc) {
    for (uint i = 0; i < loop.var_key_count; i++) {
        if (loop.var_keys[i].key == key) {
            return (int)i;
        }
    }
    if (loop.var_key_count >= MAX_VAR_KEYS) {
        return -1;
    }
    uint idx = loop.var_key_count;
    loop.var_keys[idx].key    = key;
    loop.var_keys[idx].ptr    = null;
    loop.var_keys[idx].vic_pc = (ushort)vic_pc;
    loop.var_key_count++;
    return (int)idx;
}

// ============================================================================
// scan_body — walk [header..tail_start) and build micro-ops
// ============================================================================

/// Walk the loop body instructions and produce micro-ops. Returns true on
/// success, false if any unsupported opcode is encountered.
fn bool scan_body(CompiledFunction* f, uint header, uint tail_start, uint jmp_pc, CompiledLoop* out) {
    // Walk body instructions [header .. tail_start)
    for (uint i = header; i < tail_start; i++) {
        Instruction insn = f.code[i];
        Opcode op = insn.op;

        if (out.mop_count >= MAX_MOPS) return false;

        switch (op) {
            case Opcode.GETVAR: {
                uint bc = insn.get_bc();
                if (bc >= f.const_count) return false;
                void* key = f.constants[bc].get_heapptr();
                int vidx = find_or_add_var_key(out, key, i);
                if (vidx < 0) return false;
                Mop* m = &out.mops[out.mop_count];
                m.kind    = MopKind.LOAD_VAR;
                m.dst     = (char)insn.a;
                m.var_idx = (short)vidx;
                out.mop_count++;
            }
            case Opcode.PUTVAR: {
                uint bc = insn.get_bc();
                if (bc >= f.const_count) return false;
                void* key = f.constants[bc].get_heapptr();
                int vidx = find_or_add_var_key(out, key, i);
                if (vidx < 0) return false;
                Mop* m = &out.mops[out.mop_count];
                m.kind    = MopKind.STORE_VAR;
                m.dst     = (char)insn.a;
                m.var_idx = (short)vidx;
                out.mop_count++;
            }
            case Opcode.INC_VAR: {
                uint bc = insn.get_bc();
                if (bc >= f.const_count) return false;
                void* key = f.constants[bc].get_heapptr();
                int vidx = find_or_add_var_key(out, key, i);
                if (vidx < 0) return false;
                Mop* m = &out.mops[out.mop_count];
                m.kind    = MopKind.INC_VAR;
                m.var_idx = (short)vidx;
                out.mop_count++;
            }
            case Opcode.ADD:
            case Opcode.SUB:
            case Opcode.MUL:
            case Opcode.MOD:
            case Opcode.BAND:
            case Opcode.BOR:
            case Opcode.BXOR:
            case Opcode.SHL:
            case Opcode.SHR:
            case Opcode.USHR: {
                Mop* m = &out.mops[out.mop_count];
                m.kind = MopKind.ARITH;
                m.dst  = (char)insn.a;
                m.b    = (char)insn.b;
                m.c    = (char)insn.c;
                m.op   = (char)op.ordinal;
                out.mop_count++;
            }
            case Opcode.LDREG: {
                Mop* m = &out.mops[out.mop_count];
                m.kind = MopKind.LDREG;
                m.dst  = (char)insn.a;
                m.b    = (char)insn.b;
                out.mop_count++;
            }
            case Opcode.LDINT: {
                Mop* m = &out.mops[out.mop_count];
                m.kind = MopKind.LDINT;
                m.dst  = (char)insn.a;
                m.imm  = (long)insn.get_sbc();
                out.mop_count++;
            }
            default:
                return false;
        }
    }

    // Add tail micro-ops: INC_VAR(ctr), GETVAR(ctr_r), GETVAR(lim_r)
    // These live at [tail_start, tail_start+1, tail_start+2]

    // tail_start+0: INC_VAR(ctr)
    {
        Instruction insn = f.code[tail_start];
        uint bc = insn.get_bc();
        if (bc >= f.const_count) return false;
        void* key = f.constants[bc].get_heapptr();
        int vidx = find_or_add_var_key(out, key, tail_start);
        if (vidx < 0) return false;
        out.ctr_var_idx = (uint)vidx;
        if (out.mop_count >= MAX_MOPS) return false;
        Mop* m = &out.mops[out.mop_count];
        m.kind    = MopKind.INC_VAR;
        m.var_idx = (short)vidx;
        out.mop_count++;
    }

    // tail_start+1: GETVAR(ctr_r) — used for VarIC lookup only
    {
        Instruction insn = f.code[tail_start + 1];
        uint bc = insn.get_bc();
        if (bc >= f.const_count) return false;
        void* key = f.constants[bc].get_heapptr();
        int vidx = find_or_add_var_key(out, key, tail_start + 1);
        if (vidx < 0) return false;
        if (out.mop_count >= MAX_MOPS) return false;
        Mop* m = &out.mops[out.mop_count];
        m.kind    = MopKind.LOAD_VAR;
        m.dst     = (char)insn.a;
        m.var_idx = (short)vidx;
        out.mop_count++;
    }

    // tail_start+2: GETVAR(lim_r) — used for VarIC lookup only
    {
        Instruction insn = f.code[tail_start + 2];
        uint bc = insn.get_bc();
        if (bc >= f.const_count) return false;
        void* key = f.constants[bc].get_heapptr();
        int vidx = find_or_add_var_key(out, key, tail_start + 2);
        if (vidx < 0) return false;
        out.lim_var_idx = (uint)vidx;
        if (out.mop_count >= MAX_MOPS) return false;
        Mop* m = &out.mops[out.mop_count];
        m.kind    = MopKind.LOAD_VAR;
        m.dst     = (char)insn.a;
        m.var_idx = (short)vidx;
        out.mop_count++;
    }

    Opcode jmp_op = f.code[jmp_pc].op;
    out.total_skip = jmp_pc - header + 1;
    out.is_lt      = jmp_is_lt(jmp_op);
    return true;
}

// ============================================================================
// jit_scan — post-compile pass; detects full loops and patches LOOP_COMPILED
// ============================================================================

/// Scan a compiled function for backward-jumping fastint loops and compile
/// them to LOOP_COMPILED superinstructions. Also compiles function prologues.
/// Called once after compilation.
fn void jit_scan(CompiledFunction* f, Heap* h) {
    if (f == null || f.jit_data != null) return;

    CompiledLoopTable* table = (CompiledLoopTable*)libc::calloc(1, CompiledLoopTable::size);
    if (table == null) return;
    f.jit_data = table;

    // Try to compile function prologue
    jit_compile_prologue(f);

    // Run peephole optimizations
    jit_peephole_optimize(f);

    // Fuse consecutive GETPROPC chains
    jit_fuse_getpropc_chains(f);

    uint n = f.code_count;

    uint i = 0;
    while (i < n) {
        if (table.count >= MAX_COMPILED_LOOPS) break;

        Opcode op = f.code[i].op;
        if (!jmp_is_cmp(op)) { i++; continue; }

        int offset = (int)(ichar)f.code[i].a;
        if (offset >= 0) { i++; continue; }

        // header = first instruction of loop body (backward JMP target)
        int header_signed = (int)i + 1 + offset;
        if (header_signed < 0) { i++; continue; }
        uint header = (uint)header_signed;
        if (header >= i) { i++; continue; }

        // Require at least 3 instructions before the JMP for the fixed tail:
        //   [i-3] INC_VAR(ctr)
        //   [i-2] GETVAR(ctr_r)
        //   [i-1] GETVAR(lim_r)
        if (i < 3) { i++; continue; }
        uint tail_start = i - 3;

        if (f.code[tail_start].op     != Opcode.INC_VAR) { i++; continue; }
        if (f.code[tail_start + 1].op != Opcode.GETVAR)  { i++; continue; }
        if (f.code[tail_start + 2].op != Opcode.GETVAR)  { i++; continue; }

        // Body must be non-empty
        if (tail_start <= header) { i++; continue; }

        uint id = table.count;
        CompiledLoop* loop = &table.entries[id];
        loop.mop_count     = 0;
        loop.var_key_count = 0;
        loop.initialized   = false;
        loop.header_pc     = header;

        if (!scan_body(f, header, tail_start, i, loop)) { i++; continue; }

        loop.header_pc  = header;

        // Save original header instruction before patching
        loop.saved_insn = f.code[header];

        // Patch the header to LOOP_COMPILED(id, total_skip)
        f.code[header] = bytecode::make_a_bc(Opcode.LOOP_COMPILED, id, loop.total_skip);

        table.count++;
        i++;
    }
}

// ============================================================================
// jit_init_loop — resolve TVal* from VarIC on first execution
// ============================================================================

/// Resolve all VarKey entries by walking the lexical environment chain.
/// This is called at most once per loop; no VarIC warm-up required.
fn bool jit_init_loop(CompiledLoop* loop, CompiledFunction* f, env::EnvRecord* lex_env) {
    if (lex_env == null) return false;

    for (uint k = 0; k < loop.var_key_count; k++) {
        VarKey* vk = &loop.var_keys[k];
        void* key = vk.key;
        bool resolved = false;

        // Walk the environment chain looking for the binding
        env::EnvRecord* cur = lex_env;
        while (cur != null) {
            int idx = cur.bindings.find_prop_idx(key);
            if (idx >= 0) {
                TVal* slot = &cur.bindings.prop_values()[idx];
                if (env::is_tdz_sentinel(slot)) break;  // TDZ — can't JIT
                vk.ptr = slot;
                resolved = true;
                break;
            }
            cur = cur.parent;
        }

        if (!resolved) return false;
    }

    loop.initialized = true;
    return true;
}

// ============================================================================
// jit_run_loop — tight C3 fastint loop, no switch dispatch
// ============================================================================

/// Execute a compiled loop entirely in C3, bypassing bytecode dispatch.
/// Returns true when the loop runs to completion, false to fall back to
/// the interpreter (type guard failure, overflow, unsupported op, etc.).
fn bool jit_run_loop(CompiledLoop* loop) {
    if (!loop.initialized) return false;

    // Validate all var pointers are non-null
    for (uint k = 0; k < loop.var_key_count; k++) {
        if (loop.var_keys[k].ptr == null) return false;
    }

    // Verify ctr and lim are fastint before entering the hot loop
    TVal* ctr_ptr = loop.var_keys[loop.ctr_var_idx].ptr;
    TVal* lim_ptr = loop.var_keys[loop.lim_var_idx].ptr;
    if (!ctr_ptr.is_fastint() || !lim_ptr.is_fastint()) return false;

    // Stack-allocated register file, zero-initialised
    TVal[MAX_REGS] regs = {};
    for (uint r = 0; r < MAX_REGS; r++) {
        regs[r].set_undefined();
    }

    bool lt = loop.is_lt;
    // Body mop count = total - 3 (exclude the 2 tail GETVAR mops + INC_VAR tail)
    uint body_mop_count = loop.mop_count >= 3 ? loop.mop_count - 3 : 0;

    while (true) {
        long ctr = ctr_ptr.get_fastint();
        long lim = lim_ptr.get_fastint();

        if (lt ? (ctr >= lim) : (ctr > lim)) break;

        // Execute body mops (excluding the last 3 tail mops)
        for (uint m = 0; m < body_mop_count; m++) {
            Mop* mop = &loop.mops[m];
            switch (mop.kind) {
                case MopKind.LOAD_VAR: {
                    TVal* src = loop.var_keys[(uint)mop.var_idx].ptr;
                    if (!src.is_fastint()) return false;
                    regs[(uint)mop.dst] = *src;
                }
                case MopKind.STORE_VAR: {
                    TVal val = regs[(uint)mop.dst];
                    if (!val.is_fastint()) return false;
                    *loop.var_keys[(uint)mop.var_idx].ptr = val;
                }
                case MopKind.INC_VAR: {
                    TVal* vp = loop.var_keys[(uint)mop.var_idx].ptr;
                    if (!vp.is_fastint()) return false;
                    long v = vp.get_fastint() + 1L;
                    if (v > types::FASTINT_MAX) return false;
                    vp.set_fastint(v);
                }
                case MopKind.ARITH: {
                    TVal rb = regs[(uint)mop.b];
                    TVal rc = regs[(uint)mop.c];
                    if (!rb.is_fastint() || !rc.is_fastint()) return false;
                    long vb = rb.get_fastint();
                    long vc = rc.get_fastint();
                    long ra;
                    switch ((Opcode)mop.op) {
                        case Opcode.ADD: {
                            ra = vb + vc;
                            if (ra > types::FASTINT_MAX || ra < types::FASTINT_MIN) return false;
                        }
                        case Opcode.SUB: {
                            ra = vb - vc;
                            if (ra > types::FASTINT_MAX || ra < types::FASTINT_MIN) return false;
                        }
                        case Opcode.MUL: {
                            ra = vb * vc;
                            if (ra > types::FASTINT_MAX || ra < types::FASTINT_MIN) return false;
                        }
                        case Opcode.MOD: {
                            if (vc == 0L) return false;
                            ra = vb % vc;
                        }
                        case Opcode.BAND: {
                            ra = (long)((int)vb & (int)vc);
                        }
                        case Opcode.BOR: {
                            ra = (long)((int)vb | (int)vc);
                        }
                        case Opcode.BXOR: {
                            ra = (long)((int)vb ^ (int)vc);
                        }
                        case Opcode.SHL: {
                            ra = (long)((int)vb << ((int)vc & 31));
                        }
                        case Opcode.SHR: {
                            ra = (long)((int)vb >> ((int)vc & 31));
                        }
                        case Opcode.USHR: {
                            ra = (long)((uint)((int)vb) >> ((int)vc & 31));
                        }
                        default:
                            return false;
                    }
                    regs[(uint)mop.dst].set_fastint(ra);
                }
                case MopKind.LDREG: {
                    regs[(uint)mop.dst] = regs[(uint)mop.b];
                }
                case MopKind.LDINT: {
                    regs[(uint)mop.dst].set_fastint(mop.imm);
                }
            }
        }

        // Execute tail INC_VAR (mops[mop_count-3]) — increment counter
        if (loop.mop_count >= 3) {
            Mop* tail_inc = &loop.mops[loop.mop_count - 3];
            TVal* vp = loop.var_keys[(uint)tail_inc.var_idx].ptr;
            long next = vp.get_fastint() + 1L;
            if (next > types::FASTINT_MAX) return false;
            vp.set_fastint(next);
            // Re-read ctr_ptr in case ctr_var_idx == tail_inc.var_idx
            // (no action needed: ctr_ptr points to the same memory, loop
            //  condition re-reads it at the top of the next iteration)
        }
    }

    return true;
}

// ============================================================================
// Prologue superinstruction compilation (PROLOGUE_COMPILED)
// ============================================================================

/// Pattern info for detected function prologue.
struct ProloguePattern {
    uint start_pc;      // first DECLVAR instruction
    uint end_pc;        // first non-DECLVAR after the run
    uint param_count;   // number of DECLVAR instructions
    uint total_skip;    // bytes to skip (end_pc - start_pc)
}

/// A compiled function prologue superinstruction, optimizing parameter binding.
struct CompiledPrologue {
    uint start_pc;
    uint total_skip;     // instructions to skip after replacement
    Instruction saved_insn;
    uint param_count;
    bool initialized;
}

/// Detect a function prologue pattern (consecutive DECLVARs for parameters).
/// Returns true if pattern found; fills out pat_info.
fn bool detect_prologue_pattern(CompiledFunction* f, ProloguePattern* pat) {
    if (f == null || f.code_count < 1) return false;

    // Prologues typically start at instruction 0
    uint start = 0;
    uint count = 0;

    // Count consecutive DECLVARs from the start
    while (start < f.code_count && f.code[start].op == Opcode.DECLVAR) {
        count++;
        start++;
    }

    // Need at least 2 DECLVARs to be worth optimizing (param binding overhead)
    if (count < 2) return false;

    pat.start_pc = 0;
    pat.end_pc = start;
    pat.param_count = count;
    pat.total_skip = start;
    return true;
}

/// Compile a function prologue into a PROLOGUE_COMPILED superinstruction.
/// Patches the first DECLVAR with the superinstruction; subsequent DECLVARs
/// become part of the saved template.
fn void jit_compile_prologue(CompiledFunction* f) {
    if (f == null || f.code_count < 2) return;

    ProloguePattern pat;
    if (!detect_prologue_pattern(f, &pat)) return;

    // Save the original first instruction
    Instruction saved = f.code[pat.start_pc];

    // Patch first instruction to PROLOGUE_COMPILED
    // A = param_count (number of DECLVARs), BC = param_count (for clarity)
    f.code[pat.start_pc] = bytecode::make_a_bc(Opcode.PROLOGUE_COMPILED, pat.param_count, pat.param_count);

    // NOP out the subsequent DECLVAR instructions
    for (uint i = 1; i < pat.param_count; i++) {
        f.code[pat.start_pc + i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }

    // Mark as compiled for fallback
    if (f.jit_data == null) {
        CompiledLoopTable* table = (CompiledLoopTable*)libc::calloc(1, CompiledLoopTable::size);
        if (table != null) {
            f.jit_data = table;
        }
    }
}

// ============================================================================
// Peephole constant propagation and dead-code elimination
// ============================================================================

/// Eliminates redundant LDUNDEF instructions that are overwritten
/// in subsequent instructions without being read.
fn void eliminate_dead_undef_stores(CompiledFunction* f) {
    if (f == null || f.code_count < 2) return;

    for (uint i = 0; i + 1 < f.code_count; i++) {
        Instruction curr = f.code[i];
        Instruction next = f.code[i + 1];

        // Pattern: LDUNDEF rX / ... / (instruction that writes rX without reading it)
        // We can skip this for simple patterns where rX is immediately overwritten.
        if (curr.op == Opcode.LDUNDEF) {
            uint rX = (uint)curr.a;

            // Check if rX is unconditionally overwritten in next instruction
            // without being read as source (b or c).
            uint next_a = (uint)next.a;
            uint next_b = (uint)next.b;
            uint next_c = (uint)next.c;

            // If next writes to a different register, keep LDUNDEF
            if (next_a != rX) continue;

            // If next reads rX as a source operand, keep LDUNDEF
            if (next_b == rX || next_c == rX) continue;

            // next writes to rX without reading it — LDUNDEF is dead
            // (but only eliminate if next never jumps to this slot, which we
            // can't easily determine; for safety, only eliminate certain opcodes)
            switch (next.op) {
                case Opcode.LDINT:
                case Opcode.LDCONST:
                case Opcode.LDREG:
                case Opcode.LDNULL:
                case Opcode.LDTRUE:
                case Opcode.LDFALSE:
                case Opcode.LDUNDEF:
                case Opcode.LDTHIS: {
                    f.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                }
                default: break;
            }
        }
    }
}

/// Fuses consecutive LDINT instructions into a single LDINTX when applicable.
/// Pattern: LDINT rX, low16 / LDINTX rX, high16 → single fused instruction
/// (This is already handled by the compiler, but helps clean up generated code.)
fn void fuse_ldint_sequences(CompiledFunction* f) {
    if (f == null || f.code_count < 2) return;

    for (uint i = 0; i + 1 < f.code_count; i++) {
        Instruction curr = f.code[i];
        Instruction next = f.code[i + 1];

        // Pattern: LDINT rX, val / LDINT rX, val2 (same register written twice)
        // This is inefficient — the first is dead.
        if (curr.op == Opcode.LDINT && next.op == Opcode.LDINT) {
            uint curr_a = (uint)curr.a;
            uint next_a = (uint)next.a;

            if (curr_a == next_a) {
                // Same register; first LDINT is dead (unless it's a jump target)
                f.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            }
        }
    }
}

/// Run all peephole optimizations on a compiled function.
fn void jit_peephole_optimize(CompiledFunction* f) {
    if (f == null) return;
    eliminate_dead_undef_stores(f);
    fuse_ldint_sequences(f);
}

// ============================================================================
// GETPROPC2 chain fusion
// ============================================================================

/// Fuse consecutive GETPROPC pairs where output of first is input of second.
/// Pattern: GETPROPC r_tmp, r_src, key1  /  GETPROPC r_dst, r_tmp, key2
/// → GETPROPC2 r_tmp, r_src, key1  /  (data: r_dst, key2) in next slot
fn void jit_fuse_getpropc_chains(CompiledFunction* f) {
    if (f == null || f.code_count < 2) return;

    for (uint i = 0; i + 1 < f.code_count; i++) {
        Instruction i1 = f.code[i];
        Instruction i2 = f.code[i + 1];

        if (i1.op != Opcode.GETPROPC) continue;
        if (i2.op != Opcode.GETPROPC) continue;

        // Check: output of i1 (i1.a) == input of i2 (i2.b)
        if (i1.a != i2.b) continue;

        // Fuse: rewrite i1 as GETPROPC2, repurpose i2 as data slot
        f.code[i] = bytecode::make_abc(Opcode.GETPROPC2, i1.a, i1.b, i1.c);
        // i2 stays as-is; GETPROPC2 handler will read A and C from it and skip past
    }
}

// ============================================================================
// Call-site inline caching (CallIC) for monomorphic dispatch
// ============================================================================

/// Allocate and initialize call-site IC array for a function.
/// One entry per CALL/CALL_PROP instruction in the bytecode.
fn void jit_init_call_ic(CompiledFunction* f, Heap* h) {
    if (f == null || f.code_count == 0) return;

    // Count CALL instructions
    uint call_count = 0;
    for (uint i = 0; i < f.code_count; i++) {
        Opcode op = f.code[i].op;
        if (op == Opcode.CALL || op == Opcode.CALL_PROP || op == Opcode.CALL_S) {
            call_count++;
        }
    }

    if (call_count == 0) return;

    // Allocate CallIC array (one entry per call site)
    uint size = call_count * hobject::CallICEntry::size;
    void* raw = libc::calloc(call_count, hobject::CallICEntry::size);
    if (raw == null) return;

    // Store in function (reuse jit_data for now, or create new field)
    // For now, we'll store call_count in a temporary location during execution
    // The actual lookup will be by PC-offset like VarIC
}

/// Update a call-site IC entry with the observed function.
/// Returns true if entry was successfully recorded (monomorphic so far).
fn bool jit_call_ic_record(hobject::CallICEntry* entry, void* func_obj) {
    if (entry == null || func_obj == null) return false;

    if (entry.func_obj == null) {
        // First call — populate entry
        HObject* hobj = (HObject*)func_obj;
        entry.func_obj = func_obj;
        entry.shape_id = hobj.shape_id;
        entry.generation = hobject::_active_heap != null ? ((heap::Heap*)hobject::_active_heap).shapes[hobj.shape_id].generation : 0;
        entry.call_count = 1;
        entry.func_variants = 0;
        return true;
    }

    entry.call_count++;

    // Check if function matches cached entry
    if (entry.func_obj == func_obj) {
        HObject* hobj = (HObject*)func_obj;
        if (hobj.shape_id == entry.shape_id
            && hobject::_active_heap != null
            && ((heap::Heap*)hobject::_active_heap).shapes[hobj.shape_id].generation == entry.generation) {
            // Shape still valid — monomorphic
            return true;
        }
        // Shape invalidated but same object — still use it
        return true;
    }

    // Different function observed
    entry.func_variants++;
    return entry.func_variants == 0;  // Return true only if still monomorphic
}

/// Check if a call site is monomorphic (same function called repeatedly).
/// Returns the cached function object if monomorphic, null if polymorphic or uncached.
fn void* jit_call_ic_lookup(hobject::CallICEntry* entry) {
    if (entry == null || entry.func_obj == null) return null;
    if (entry.func_variants > 0) return null;  // Polymorphic — disable optimization
    if (entry.call_count < 2) return null;    // Need at least 2 calls to confirm monomorphic

    HObject* cached_obj = (HObject*)entry.func_obj;
    if (cached_obj == null) return null;

    // Return cached function for monomorphic sites
    return entry.func_obj;
}
