module boomkat::vm;

import boomkat::bytecode;
import std::io;

// Addresses are process-local and pair with that process's sampling log.
// Choose the deepest matching frame for overlaps: a caller's CALL range
// contains its expanded callee bodies. Prologue, exits and callee entry are
// separate ranges so frame overhead cannot be mistaken for bytecode work.
fn void sljit_address_map(FunctionPlan* plan, CompiledFunction* cf, uint id) @feat(SLJIT_MAP) {
    io::printfn("SLJIT map id=%d kind=entry start=%p end=%p", id, plan.native, plan.map_pcs[0]);
    void* end = (char*)(void*)plan.native + (sz)(plan.code_bytes - plan.resume_bytes);
    io::printfn("SLJIT map id=%d kind=exit start=%p end=%p", id, plan.map_pcs[plan.count],
        plan.map_calls != null ? plan.map_calls : end);
    if (plan.map_calls != null) io::printfn("SLJIT map id=%d kind=call_entry start=%p end=%p", id, plan.map_calls, end);
    if (plan.resume_fragment != null) io::printfn("SLJIT map id=%d kind=helper_fragment start=%p end=%p", id,
        plan.resume_fragment, (char*)plan.resume_fragment + (sz)plan.resume_bytes);
    for (uint pc = 0; pc < plan.count; pc++) {
        io::printfn("SLJIT map id=%d kind=body depth=0 frame=0 pc=%d opcode=%s start=%p end=%p", id,
            plan.begin + pc, (ZString)bytecode::get_opcode_name(cf.code[plan.begin + pc].op),
            plan.map_pcs[pc], plan.map_pcs[pc + 1]);
    }
    for (FunctionInlineFrame* frame = plan.inline_frames; frame != null; frame = frame.next) {
        for (uint pc = 0; pc < frame.target.code_count; pc++) {
            io::printfn("SLJIT map id=%d kind=body depth=%d frame=%d target_line=%d pc=%d opcode=%s start=%p end=%p",
                id, frame.depth, frame.id, frame.target.get_line(0), pc,
                (ZString)bytecode::get_opcode_name(frame.target.code[pc].op), frame.map_pcs[pc], frame.map_pcs[pc + 1]);
        }
    }
}
