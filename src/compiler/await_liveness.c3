// Bounded saved-register liveness for ordinary async functions.
module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;

const uint AWAIT_LIVE_MAX_REGS = 64;
const uint AWAIT_LIVE_MAX_CODE = 2048;

// The liveness engine understands more bytecode than this analysis accepts.
// Keeping eligibility as a positive list makes new and multiword opcodes use
// the full async snapshot until their control flow and operands are reviewed.
fn bool await_liveness_opcode_allowed(Opcode op) {
    switch (op) {
        case Opcode.NOP:
        case Opcode.LDREG:
        case Opcode.LDCONST:
        case Opcode.SETCONST:
        case Opcode.LDINT:
        case Opcode.LDUNDEF:
        case Opcode.LDNULL:
        case Opcode.LDTRUE:
        case Opcode.LDFALSE:
        case Opcode.LDTHIS:
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.EXP:
        case Opcode.ADDI:
        case Opcode.SUBI:
        case Opcode.INC:
        case Opcode.DEC:
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.BAND:
        case Opcode.BOR:
        case Opcode.BXOR:
        case Opcode.SHL:
        case Opcode.SHR:
        case Opcode.USHR:
        case Opcode.EQ:
        case Opcode.NEQ:
        case Opcode.SEQ:
        case Opcode.SNEQ:
        case Opcode.LT:
        case Opcode.LE:
        case Opcode.GT:
        case Opcode.GE:
        case Opcode.INSTANCEOF:
        case Opcode.IN:
        case Opcode.JUMP:
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
        case Opcode.JMP_NLT:
        case Opcode.JMP_NLE:
        case Opcode.JMP_NGT:
        case Opcode.JMP_NGE:
        case Opcode.JMP_LT:
        case Opcode.JMP_LE:
        case Opcode.JMP_GT:
        case Opcode.JMP_GE:
        case Opcode.JMP_SEQ:
        case Opcode.JMP_SNEQ:
        case Opcode.GETPROP:
        case Opcode.GETPROPC:
        case Opcode.GETPROP_CACHE:
        case Opcode.GETPROPC_CACHED:
        case Opcode.PUTPROP:
        case Opcode.PUTPROP_NE:
        case Opcode.DELPROP:
        case Opcode.NEWOBJ:
        case Opcode.NEWARR:
        case Opcode.SETALEN:
        case Opcode.FREEZEOBJ:
        case Opcode.INITPROP:
        case Opcode.INITPROPN:
        case Opcode.CALL:
        case Opcode.CALL_UNDEF_THIS:
        case Opcode.CALL_VAR:
        case Opcode.CALL_GLOBAL:
        case Opcode.RET:
        case Opcode.RETUNDEF:
        case Opcode.GETVAR:
        case Opcode.RESOLVEVAR:
        case Opcode.THROW_UNRESOLVED:
        case Opcode.PUTVAR:
        case Opcode.PUTVAR_ASSIGN:
        case Opcode.PUTVAR_SNAP:
        case Opcode.DECLVAR:
        case Opcode.DECLVAR_HOIST:
        case Opcode.DECLGLOBALFUNC:
        case Opcode.DECLB33GLOBAL:
        case Opcode.GETGLOBAL:
        case Opcode.PUTGLOBAL:
        case Opcode.GETGLOBAL_PRIM:
        case Opcode.PUTGLOBAL_PRIM:
        case Opcode.TYPEOFIDENT:
        case Opcode.DELVAR:
        case Opcode.GETBOUND:
        case Opcode.TOPROPKEY:
        case Opcode.TOSTR:
        case Opcode.PUSH_LEX:
        case Opcode.POP_LEX:
        case Opcode.PUSH_VAR:
        case Opcode.POP_VAR:
        case Opcode.PUTLEX:
        case Opcode.PUTLEX_C:
        case Opcode.INITTZ:
        case Opcode.CHKGLOBALLEX:
        case Opcode.CHKGLOBALVAR:
        case Opcode.CHKGLOBALFUNC:
        case Opcode.NEWREGEXP:
        case Opcode.SETPROTO:
        case Opcode.GETPROTO:
        case Opcode.NEWTARGET:
        case Opcode.AWAIT:
        case Opcode.LOAD_RESUME:
            return true;
        default:
            return false;
    }
}

fn void build_await_liveness(CompilerContext* ctx, CompiledFunction* func, Heap* heap) {
    if (ctx.disable_optimize || !ctx.is_async || ctx.is_user_generator || ctx.has_wide
        || func.num_regs > AWAIT_LIVE_MAX_REGS || func.code_count > AWAIT_LIVE_MAX_CODE
        || ctx.has_direct_eval || ctx.has_with_stmt || ctx.outer_with
        || ctx.uses_arguments || ctx.has_captured_local || ctx.inner_func_count != 0
        || ctx.has_rest || ctx.default_count != 0 || ctx.destruct_default_count != 0
        || ctx.has_destructured_param || func.code_count == 0) return;

    uint await_count = 0;
    for (uint i = 0; i < func.code_count; i++) {
        Opcode op = func.code[i].op;
        if (!await_liveness_opcode_allowed(op)) return;
        if (op == Opcode.AWAIT) {
            if (i + 1 >= func.code_count || func.code[i + 1].op != Opcode.LOAD_RESUME) return;
            await_count++;
        }
    }
    if (await_count == 0) return;

    uint word_count = ((uint)func.num_regs + 31) / 32;
    if (word_count == 0) word_count = 1;
    usz set_count = (usz)func.code_count * 2 + 3;
    usz arena_words = set_count * (usz)word_count;
    uint* arena = (uint*)heap.alloc_func(heap.heap_udata, arena_words * uint::size);
    if (arena == null) return;
    mem::clear(arena, (sz)(arena_words * uint::size));

    RegSet* sets = (RegSet*)heap.alloc_func(heap.heap_udata, set_count * RegSet::size);
    if (sets == null) {
        heap.free_func(heap.heap_udata, arena);
        return;
    }
    for (usz i = 0; i < set_count; i++) {
        sets[i].words = arena + i * (usz)word_count;
        sets[i].word_count = word_count;
    }
    RegSet* live_out = sets;
    RegSet* live_in = sets + func.code_count;
    RegSet* scratch = sets + (usz)func.code_count * 2;
    moveelim_compute_liveness(func.code, func.code_count, live_out, live_in,
                              true, scratch, null);

    AwaitLiveEntry* entries = (AwaitLiveEntry*)heap.alloc_func(
        heap.heap_udata, (usz)await_count * AwaitLiveEntry::size);
    if (entries != null) {
        uint out_idx = 0;
        for (uint i = 0; i < func.code_count; i++) {
            if (func.code[i].op != Opcode.AWAIT) continue;
            uint resume_pc = i + 1;
            uint overwritten = (uint)func.code[resume_pc].a;
            ulong mask = 0;
            uint saved_span = 0;
            for (uint reg = 0; reg < (uint)func.num_regs; reg++) {
                if (reg != overwritten && live_out[resume_pc].test(reg)) {
                    mask |= (1UL << reg);
                    saved_span = reg + 1;
                }
            }
            entries[out_idx].pc = resume_pc;
            entries[out_idx].num_regs = saved_span;
            entries[out_idx].mask = mask;
            out_idx++;
        }
        func.await_live = entries;
        func.await_live_count = await_count;
    }

    heap.free_func(heap.heap_udata, sets);
    heap.free_func(heap.heap_udata, arena);
}
