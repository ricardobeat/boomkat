module duktape::jit;

import duktape::bytecode;
import duktape::types;
import duktape::heap;
import duktape::hobject;
import libc;

// ============================================================================
// Data structures
// ============================================================================

const uint MAX_COMPILED_LOOPS = 32;
const uint MAX_BODY_INC_VARS  = 4;   // max INC_VAR ops in loop body we capture

/// Describes a complete compiled loop: body INC_VARs + tail INC_VAR(ctr) + JMP.
///
/// The LOOP_COMPILED instruction is patched at `header_pc` (start of body).
/// `total_skip` = number of instructions from header_pc through the JMP_*.
/// At runtime jit_run_loop runs all N iterations in a tight C3 loop.
struct CompiledLoop {
    uint   header_pc;   // pc of the first body instruction (where LOOP_COMPILED is patched)
    uint   total_skip;  // instructions covered (header through JMP inclusive)

    // Body accumulator INC_VARs (resolved TVal* pointers)
    TVal*[4] body_ptrs;
    uint   body_count;

    // Loop counter and limit
    TVal*  ctr_ptr;
    TVal*  lim_ptr;

    bool   initialized;
    bool   is_lt;       // true = JMP_LT/JMP_GT, false = JMP_LE/JMP_GE
}

struct CompiledLoopTable {
    CompiledLoop[MAX_COMPILED_LOOPS] entries;
    uint count;
}

// ============================================================================
// jit_scan — post-compile pass; detects full loops and patches LOOP_COMPILED
// ============================================================================

fn void jit_scan(CompiledFunction* f, Heap* h) {
    if (f == null || f.jit_data != null) return;

    CompiledLoopTable* table = (CompiledLoopTable*)libc::calloc(1, CompiledLoopTable::size);
    if (table == null) return;
    f.jit_data = table;

    uint n = f.code_count;

    // Scan for JMP_* with a backward offset — these are loop backedges.
    uint i = 0;
    while (i < n) {
        if (table.count >= MAX_COMPILED_LOOPS) break;

        Opcode op = f.code[i].op;
        if (!jmp_is_cmp(op)) { i++; continue; }

        int offset = (int)(ichar)f.code[i].a;
        if (offset >= 0) { i++; continue; }  // forward or no-op jump

        // i is the JMP_* instruction.  The backward target (loop header) is:
        //   header = i + 1 + offset   (curr_pc after fetch + signed offset)
        int header_signed = (int)i + 1 + offset;
        if (header_signed < 0) { i++; continue; }
        uint header = (uint)header_signed;
        if (header >= i) { i++; continue; }  // sanity

        // The tail pattern just before the JMP is: INC_VAR(ctr) GETVAR(ctr) GETVAR(lim)
        // That's 3 instructions ending at i-1, i-2, i-3 (before the JMP at i).
        if (i < 3) { i++; continue; }
        uint tail_start = i - 3;  // INC_VAR(ctr)

        if (f.code[tail_start].op   != Opcode.INC_VAR) { i++; continue; }
        if (f.code[tail_start+1].op != Opcode.GETVAR)  { i++; continue; }
        if (f.code[tail_start+2].op != Opcode.GETVAR)  { i++; continue; }

        // Validate constant indices for INC_VAR(ctr) and GETVAR(lim)
        uint ctr_bc = f.code[tail_start].get_bc();
        uint lim_bc = f.code[tail_start+2].get_bc();
        if (ctr_bc >= f.const_count || lim_bc >= f.const_count) { i++; continue; }
        if (!f.constants[ctr_bc].is_string() || !f.constants[lim_bc].is_string()) { i++; continue; }

        // Body = instructions [header .. tail_start).
        // Every instruction in the body must be INC_VAR (we only know how to run those).
        if (tail_start <= header) { i++; continue; }  // empty body or overlap
        uint body_len = tail_start - header;
        if (body_len > MAX_BODY_INC_VARS) { i++; continue; }

        bool body_ok = true;
        for (uint b = 0; b < body_len; b++) {
            if (f.code[header + b].op != Opcode.INC_VAR) { body_ok = false; break; }
            uint bk = f.code[header + b].get_bc();
            if (bk >= f.const_count || !f.constants[bk].is_string()) { body_ok = false; break; }
        }
        if (!body_ok) { i++; continue; }

        // Good loop found.  total_skip covers header..JMP inclusive.
        uint total_skip = i - header + 1;  // header + body_len + 3 tail + 1 JMP

        uint id = table.count;
        table.entries[id].header_pc   = header;
        table.entries[id].total_skip  = total_skip;
        table.entries[id].body_count  = body_len;
        table.entries[id].is_lt       = jmp_is_lt(op);
        table.entries[id].initialized = false;
        table.entries[id].ctr_ptr     = null;
        table.entries[id].lim_ptr     = null;
        for (uint b = 0; b < MAX_BODY_INC_VARS; b++) table.entries[id].body_ptrs[b] = null;

        // Patch the header instruction to LOOP_COMPILED(id, total_skip).
        f.code[header] = bytecode::make_a_bc(Opcode.LOOP_COMPILED, id, total_skip);

        table.count++;
        i++;  // continue scanning after the JMP
    }
}

fn bool jmp_is_cmp(Opcode op) @inline {
    return op == Opcode.JMP_LT || op == Opcode.JMP_LE
        || op == Opcode.JMP_GT || op == Opcode.JMP_GE;
}

fn bool jmp_is_lt(Opcode op) @inline {
    return op == Opcode.JMP_LT || op == Opcode.JMP_GT;
}

// ============================================================================
// jit_init_loop — resolve TVal* from VarIC on first execution
// ============================================================================

/// Reads VarIC entries (already warmed by at least one interpreter pass through
/// the original instructions) to resolve direct TVal* pointers.
fn bool jit_init_loop(CompiledLoop* loop, CompiledFunction* f, hobject::VarICEntry* var_ic_base) {
    if (var_ic_base == null) return false;

    uint hp = loop.header_pc;

    // Body INC_VAR accumulators: VarIC[hp+0], VarIC[hp+1], ...
    for (uint b = 0; b < loop.body_count; b++) {
        hobject::VarICEntry* vic = &var_ic_base[hp + b];
        if (vic.env == null || vic.bindings == null) return false;
        loop.body_ptrs[b] = &((HObject*)vic.bindings).prop_values()[vic.prop_idx];
    }

    // Tail: INC_VAR(ctr) is at hp + body_count; VarIC entry is at that pc.
    uint tail_start = hp + loop.body_count;
    hobject::VarICEntry* vic_ctr = &var_ic_base[tail_start];
    if (vic_ctr.env == null || vic_ctr.bindings == null) return false;
    loop.ctr_ptr = &((HObject*)vic_ctr.bindings).prop_values()[vic_ctr.prop_idx];

    // Limit GETVAR is at tail_start+2 (after INC_VAR(ctr) and GETVAR(ctr_r)).
    hobject::VarICEntry* vic_lim = &var_ic_base[tail_start + 2];
    if (vic_lim.env == null || vic_lim.bindings == null) return false;
    loop.lim_ptr = &((HObject*)vic_lim.bindings).prop_values()[vic_lim.prop_idx];

    loop.initialized = true;
    return true;
}

// ============================================================================
// jit_run_loop — tight C3 fastint loop, no switch dispatch
// ============================================================================

fn bool jit_run_loop(CompiledLoop* loop) {
    if (!loop.initialized) return false;

    // All values must be fastint for this path.
    for (uint b = 0; b < loop.body_count; b++) {
        if (!loop.body_ptrs[b].is_fastint()) return false;
    }
    if (!loop.ctr_ptr.is_fastint() || !loop.lim_ptr.is_fastint()) return false;

    bool lt = loop.is_lt;
    uint bc = loop.body_count;

    while (true) {
        long ctr = loop.ctr_ptr.get_fastint();
        long lim = loop.lim_ptr.get_fastint();

        if (lt ? (ctr >= lim) : (ctr > lim)) break;

        // Run body INC_VARs.
        for (uint b = 0; b < bc; b++) {
            long v = loop.body_ptrs[b].get_fastint() + 1L;
            if (v > types::FASTINT_MAX) return false;
            loop.body_ptrs[b].set_fastint(v);
        }

        // Increment counter.
        long next = ctr + 1L;
        if (next > types::FASTINT_MAX) return false;
        loop.ctr_ptr.set_fastint(next);
    }

    return true;
}
