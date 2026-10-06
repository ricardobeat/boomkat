module boomkat::compiler;

import boomkat::bytecode;
import boomkat::hstring;

// A primitive string's length is intrinsic. Liveness proves neither the
// join result nor its optional local copy has any other observer.
fn void eliminate_join_allocation(CompilerContext* ctx, bool* targets, bool* in_try,
                                 RegSet* live_out, RegSet* live_in, RegSet* scratch) {
    if (!register_promotion_eligible(ctx) || ctx.has_captured_local) return;
    bool has_join = false;
    for (uint i = 0; i < ctx.code_count; i++) {
        if (ctx.code[i].op == Opcode.STRJOIN) { has_join = true; break; }
    }
    if (!has_join) return;
    moveelim_compute_liveness(ctx.code, ctx.code_count, live_out, live_in, true, scratch, null);
    for (uint i = 0; i < ctx.code_count; i++) {
        Instruction join = ctx.code[i];
        if (join.op != Opcode.STRJOIN || in_try[i]) continue;
        uint j = i + 1;
        while (j < ctx.code_count && ctx.code[j].op == Opcode.NOP && !targets[j]) j++;
        uint copy = j;
        uint source = join.a;
        if (j < ctx.code_count && !targets[j] && ctx.code[j].op == Opcode.LDREG
            && ctx.code[j].b == source) {
            source = ctx.code[j].a;
            j++;
            while (j < ctx.code_count && ctx.code[j].op == Opcode.NOP && !targets[j]) j++;
        }
        if (j >= ctx.code_count || targets[j] || in_try[j]) continue;
        Instruction length = ctx.code[j];
        if (length.op != Opcode.GETPROPC || length.b != source
            || length.c >= ctx.const_count || !ctx.constants[length.c].is_string()) continue;
        HString* key = (HString*)ctx.constants[length.c].get_heapptr();
        if (key.is_symbol() || !str_eq(key.get_data(), "length")) continue;
        if (live_out[j].test(join.a) || live_out[j].test(source)
            || length.a == join.a || length.a == source) continue;
        ctx.code[i] = bytecode::make_abc(Opcode.STRJOIN_LENGTH, length.a, join.b, join.c);
        if (copy != j) ctx.code[copy] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        ctx.code[j] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}
