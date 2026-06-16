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

/// Describes one loop whose closing INC_VAR+compare+branch has been replaced
/// by a LOOP_COMPILED superinstruction.
///
/// Pattern A (skip_count=5): INC_VAR(acc) INC_VAR(ctr) GETVAR(ctr_r) GETVAR(lim_r) JMP_*
/// Pattern B (skip_count=4): INC_VAR(ctr) GETVAR(ctr_r) GETVAR(lim_r) JMP_*
struct CompiledLoop {
    uint  patch_pc;    // index of the LOOP_COMPILED instruction
    uint  skip_count;  // 5 for pattern A, 4 for pattern B
    TVal* inc_ptr;     // accumulator TVal* in env bindings (null for pattern B)
    TVal* ctr_ptr;     // counter TVal* in env bindings
    TVal* lim_ptr;     // limit TVal* in env bindings
    bool  initialized; // true once pointers have been resolved from VarIC
    bool  is_lt;       // true = JMP_LT/JMP_GT condition, false = JMP_LE/JMP_GE
}

struct CompiledLoopTable {
    CompiledLoop[MAX_COMPILED_LOOPS] entries;
    uint count;
}

// ============================================================================
// jit_scan — one-time scan after compilation; patches LOOP_COMPILED in
// ============================================================================

fn void jit_scan(CompiledFunction* f, Heap* h) {
    if (f == null || f.jit_data != null) return;

    CompiledLoopTable* table = (CompiledLoopTable*)libc::calloc(1, CompiledLoopTable::size);
    if (table == null) return;
    f.jit_data = table;

    uint i = 0;
    while (i < f.code_count) {
        if (table.count >= MAX_COMPILED_LOOPS) break;

        Opcode op0 = f.code[i].op;
        if (op0 != Opcode.INC_VAR) { i++; continue; }

        // --- Try Pattern A: INC_VAR INC_VAR GETVAR GETVAR JMP_* ---
        if (i + 5 <= f.code_count
            && f.code[i+1].op == Opcode.INC_VAR
            && f.code[i+2].op == Opcode.GETVAR
            && f.code[i+3].op == Opcode.GETVAR
            && jmp_is_cmp(f.code[i+4].op)
            && (ichar)f.code[i+4].a < 0)
        {
            uint inc_bc = f.code[i].get_bc();
            uint ctr_bc = f.code[i+1].get_bc();
            uint lim_bc = f.code[i+3].get_bc();
            if (inc_bc < f.const_count && ctr_bc < f.const_count && lim_bc < f.const_count
                && f.constants[inc_bc].is_string()
                && f.constants[ctr_bc].is_string()
                && f.constants[lim_bc].is_string())
            {
                uint id = table.count;
                table.entries[id].patch_pc   = i;
                table.entries[id].skip_count = 5;
                table.entries[id].is_lt      = jmp_is_lt(f.code[i+4].op);
                f.code[i] = bytecode::make_a_bc(Opcode.LOOP_COMPILED, id, 5);
                table.count++;
            }
            i += 5;
            continue;
        }

        // --- Try Pattern B: INC_VAR GETVAR GETVAR JMP_* ---
        if (i + 4 <= f.code_count
            && f.code[i+1].op == Opcode.GETVAR
            && f.code[i+2].op == Opcode.GETVAR
            && jmp_is_cmp(f.code[i+3].op)
            && (ichar)f.code[i+3].a < 0)
        {
            uint ctr_bc = f.code[i].get_bc();
            uint lim_bc = f.code[i+2].get_bc();
            if (ctr_bc < f.const_count && lim_bc < f.const_count
                && f.constants[ctr_bc].is_string()
                && f.constants[lim_bc].is_string())
            {
                uint id = table.count;
                table.entries[id].patch_pc   = i;
                table.entries[id].skip_count = 4;
                table.entries[id].is_lt      = jmp_is_lt(f.code[i+3].op);
                f.code[i] = bytecode::make_a_bc(Opcode.LOOP_COMPILED, id, 4);
                table.count++;
            }
            i += 4;
            continue;
        }

        i++;
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
// jit_init_loop — resolve TVal* pointers from VarIC on first execution
// ============================================================================

/// Called from the LOOP_COMPILED VM handler the first time this loop executes.
/// Reads VarIC entries (populated by previous INC_VAR/GETVAR runs) to get
/// direct TVal* pointers into the env's prop_values array.
/// Returns false if VarIC is cold (not yet warmed up) — interpreter falls back.
fn bool jit_init_loop(CompiledLoop* loop, CompiledFunction* f, hobject::VarICEntry* var_ic_base) {
    if (var_ic_base == null) return false;

    uint pp = loop.patch_pc;
    bool pa = (loop.skip_count == 5);

    if (pa) {
        // Pattern A: VarIC[pp] = first INC_VAR (acc), VarIC[pp+1] = second INC_VAR (ctr)
        //            VarIC[pp+3] = GETVAR for limit
        hobject::VarICEntry* vic_inc = &var_ic_base[pp];
        if (vic_inc.env == null || vic_inc.bindings == null) return false;
        loop.inc_ptr = &((HObject*)vic_inc.bindings).prop_values()[vic_inc.prop_idx];

        hobject::VarICEntry* vic_ctr = &var_ic_base[pp + 1];
        if (vic_ctr.env == null || vic_ctr.bindings == null) return false;
        loop.ctr_ptr = &((HObject*)vic_ctr.bindings).prop_values()[vic_ctr.prop_idx];

        hobject::VarICEntry* vic_lim = &var_ic_base[pp + 3];
        if (vic_lim.env == null || vic_lim.bindings == null) return false;
        loop.lim_ptr = &((HObject*)vic_lim.bindings).prop_values()[vic_lim.prop_idx];
    } else {
        // Pattern B: VarIC[pp] = INC_VAR (ctr), VarIC[pp+2] = GETVAR (lim)
        hobject::VarICEntry* vic_ctr = &var_ic_base[pp];
        if (vic_ctr.env == null || vic_ctr.bindings == null) return false;
        loop.ctr_ptr = &((HObject*)vic_ctr.bindings).prop_values()[vic_ctr.prop_idx];

        hobject::VarICEntry* vic_lim = &var_ic_base[pp + 2];
        if (vic_lim.env == null || vic_lim.bindings == null) return false;
        loop.lim_ptr = &((HObject*)vic_lim.bindings).prop_values()[vic_lim.prop_idx];
    }

    loop.initialized = true;
    return true;
}

// ============================================================================
// jit_run_loop — tight C3 fastint loop, no switch dispatch
// ============================================================================

/// Runs the loop body: increment accumulator and counter until ctr >= lim.
/// Returns true on normal completion, false if any value is non-fastint
/// (caller must de-optimize back to the interpreter for those iterations).
fn bool jit_run_loop(CompiledLoop* loop) {
    if (!loop.initialized) return false;

    if (loop.inc_ptr != null && !loop.inc_ptr.is_fastint()) return false;
    if (!loop.ctr_ptr.is_fastint() || !loop.lim_ptr.is_fastint()) return false;

    bool has_inc = (loop.inc_ptr != null);
    bool lt      = loop.is_lt;

    while (true) {
        long ctr = loop.ctr_ptr.get_fastint();
        long lim = loop.lim_ptr.get_fastint();

        if (lt ? (ctr >= lim) : (ctr > lim)) break;

        if (has_inc) {
            long v = loop.inc_ptr.get_fastint() + 1L;
            if (v > types::FASTINT_MAX) return false;
            loop.inc_ptr.set_fastint(v);
        }

        long next = ctr + 1L;
        if (next > types::FASTINT_MAX) return false;
        loop.ctr_ptr.set_fastint(next);
    }

    return true;
}
