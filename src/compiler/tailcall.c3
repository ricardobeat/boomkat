// Proper tail calls (ES2015 §14.8).
//
// A call in tail position reuses the caller's frame instead of pushing a new
// one, so unbounded mutual recursion in tail position runs in constant stack.
// The test262 suite asserts non-overflow at 100,000 deep, which no
// faster-but-still-growing call path can satisfy.
//
// Tail position is syntactic (§14.8.1), but every form the spec lists — the
// last expression of a `return`, both arms of a conditional in tail position,
// the RHS of `&&`/`||`/`??`, the last expression of a comma, an arrow's
// expression body — compiles to the same two-instruction shape:
//
//     CALL* rDst, ...
//     RET   rDst
//
// so this runs as a peephole over the final code rather than threading an
// `in_tail_position` flag through every expression emitter. The flag approach
// would have to be re-taught at each new expression form; matching the emitted
// shape cannot drift from what the compiler actually produces.
//
// §14.8 applies to strict code only. Sloppy code is not required to have
// proper tail calls, and rewriting there is still sound (a TAILCALL reuses
// the frame only when the runtime finds nothing in it that must outlive the
// call), so the pass runs regardless of mode.
//
// A call in a syntactic tail position is still NOT a tail call when the frame
// holds state that must outlive it. Each disqualifier below is why:
//
//   - Inside a try/catch/finally region: the handler and any `finally` block
//     must still run, so the frame cannot be discarded. `in_try` covers this.
//   - A pending for-of iterator close: `return` emits ITER_CLOSE before RET
//     (see emit_return_iter_closes), which would be skipped. Such a return
//     does not produce an adjacent CALL/RET pair, so the shape match excludes
//     it on its own.
//   - The RET is a jump target: another path reaches this RET with a value
//     this call never produced, so rewriting it would mis-return for that
//     path.
//   - Generators and async functions: their frames suspend and resume, so
//     RET_GEN / an await-bearing return is never rewritten (only plain RET
//     is matched).
//   - A direct `eval` callee, or a frame whose locals escape into a closure:
//     both are handled in the VM, which declines frame reuse when the callee
//     is not a plain compiled function or the frame owns an environment.
//
// The rewrite is shape-only: it replaces the CALL opcode with its TAILCALL
// form and NOPs the RET. Whether a given call can actually reuse the frame is
// decided at runtime, where the callee is known; a TAILCALL whose callee turns
// out to be a builtin, a bound function, a generator or a class constructor
// falls back to an ordinary call plus return.

module boomkat::compiler;

import boomkat::bytecode;
import std::core::mem;

// The plain-call opcodes this pass rewrites, paired with their tail forms.
//
// Only the undefined-this call forms are eligible. A method call
// (CALL_PROP) evaluates a receiver whose lifetime the frame owns, and
// SUPER_CALL / NEW_OBJ bind `this` into the frame being returned from;
// neither can hand its frame to the callee. CALL_S is excluded for the same
// reason: it reads an explicit receiver from callee_reg + 1.
//
// Plain CALL reads that receiver slot too, so it qualifies only when the
// receiver is provably `undefined` — see tailcall_call_has_undef_receiver.
fn Opcode tailcall_form(Opcode op) {
    switch (op) {
        case Opcode.CALL_UNDEF_THIS: return Opcode.TAILCALL_UNDEF_THIS;
        case Opcode.CALL_VAR:        return Opcode.TAILCALL_VAR;
        case Opcode.CALL_GLOBAL:     return Opcode.TAILCALL_GLOBAL;
        case Opcode.CALL:            return Opcode.TAILCALL_CALL;
        default:                     return Opcode.NOP;
    }
}

// Whether a plain CALL's receiver slot (callee_reg + 1) is loaded with
// `undefined` in the straight-line run-up to the call.
//
// A tagged template compiles to a plain CALL with an explicit `undefined`
// receiver rather than to CALL_UNDEF_THIS:
//
//     LDREG r11 = r2      ; callee
//     LDUNDEF r12         ; receiver
//     LDREG r13 = r5      ; strings
//     LDREG r14 = r4      ; substitution
//     CALL r15 = r11, 2
//
// §14.8.1 puts a tagged template's call in tail position, so excluding every
// CALL would leave that form out for a receiver that carries no frame state
// at all. Scanning back to the LDUNDEF proves it is the same no-receiver
// shape CALL_UNDEF_THIS represents; anything else (a real receiver whose
// lifetime the frame owns) still declines.
fn bool tailcall_call_has_undef_receiver(Instruction* code, uint call_idx, bool* jump_targets) @local {
    Instruction call_insn = code[call_idx];
    uint recv_reg = (uint)call_insn.b + 1;
    // The argument set-up is straight-line: walk back over it to the store
    // into the receiver slot. A jump target means another path reaches the
    // call with a receiver this scan never saw.
    uint k = call_idx;
    while (k > 0) {
        k--;
        if (jump_targets[k]) { return false; }
        Instruction ins = code[k];
        if (ins.op == Opcode.LDUNDEF && (uint)ins.a == recv_reg) { return true; }
        // Only the register moves and loads that build an argument list may
        // intervene. Anything else could be the receiver's own evaluation.
        if (ins.op != Opcode.LDREG && ins.op != Opcode.LDUNDEF
            && ins.op != Opcode.LDCONST && ins.op != Opcode.LDINT) { return false; }
        if ((uint)ins.a == recv_reg) { return false; }
    }
    return false;
}

// Clear the tail-call protection flag over each try's finally body, then
// restore it for whatever an enclosing try still protects.
//
// The finally region is located the way moveelim does it: the finally offset
// lives in the NOP slot after TRY, and FINALLY..ENDFINALLY nest.
fn void tailcall_unmark_finally_bodies(Instruction* code, uint code_count, bool* map) @local {
    for (uint i = 0; i < code_count; i++) {
        if (code[i].op != Opcode.TRY) { continue; }
        if (i + 1 >= code_count) { continue; }
        uint finally_off = code[i + 1].get_bc();
        if (finally_off == 0) { continue; }

        uint fdepth = 0;
        uint fk = i + finally_off;
        while (fk < code_count) {
            Opcode fop = code[fk].op;
            if (fop == Opcode.FINALLY) { fdepth++; }
            else if (fop == Opcode.ENDFINALLY) {
                fdepth--;
                if (fdepth == 0) { break; }
            }
            map[fk] = false;
            fk++;
        }
    }

    // Re-mark: an instruction inside another try's *body* (TRY..ENDTRY) is
    // still protected, whether or not it also sits in some finally.
    for (uint i = 0; i < code_count; i++) {
        if (code[i].op != Opcode.TRY) { continue; }
        uint depth = 1;
        uint j = i + 1;
        while (j < code_count) {
            if (code[j].op == Opcode.TRY) { depth++; }
            else if (code[j].op == Opcode.ENDTRY) {
                depth--;
                if (depth == 0) { break; }
            }
            map[j] = true;
            j++;
        }
    }
}

// Rewrite `CALL* rDst ; RET rDst` into a TAILCALL, in place.
//
// `jump_targets` and `in_try` are the maps
// moveelim_mark_jump_targets_and_try_regions builds; this pass runs after it
// so both are already populated for the final instruction sequence.
fn void run_tail_calls(Instruction* code, uint code_count, bool* jump_targets, bool* in_try) {
    if (code_count < 2) { return; }

    // `in_try` covers the finally body as well as the try body, because move
    // elimination must avoid both. Tail calls must not: §14.8.1 puts a
    // `return` in a `finally` body in tail position. Nothing is owed once the
    // finally runs — it IS the pending work — and the RET inside it returns
    // from the function outright rather than falling through to ENDFINALLY.
    // A `return` in the *try* body is the opposite: the finally has yet to
    // run, so that frame cannot be handed away.
    //
    // So refine the map: un-mark the finally bodies of each try, then re-mark
    // whatever an *enclosing* try still protects. A finally nested inside an
    // outer try body is still protected by that outer try.
    bool[] tail_in_try = mem::new_array(bool, code_count);
    defer mem::free(tail_in_try);
    for (uint i = 0; i < code_count; i++) { tail_in_try[i] = in_try[i]; }
    tailcall_unmark_finally_bodies(code, code_count, tail_in_try);

    for (uint i = 0; i + 1 < code_count; i++) {
        Instruction call_insn = code[i];
        Opcode tail_op = tailcall_form(call_insn.op);
        if (tail_op == Opcode.NOP) { continue; }
        if (call_insn.op == Opcode.CALL
            && !tailcall_call_has_undef_receiver(code, i, jump_targets)) { continue; }

        // The RET must follow the call, either immediately or through a single
        // register copy. The copy is what a conditional in tail position emits:
        //
        //     return c ? a : f(x);   ->   CALL_VAR r4 ; LDREG r3 = r4 ; RET r3
        //
        // because both arms must leave their value in one register. §14.8.1
        // puts both arms of a conditional in tail position, so seeing through
        // exactly one LDREG that moves the call's own result is required, not
        // an optimization. Nothing else may intervene: a NOP is not skipped
        // (NOP compaction has not run yet) and any other instruction could
        // observe or overwrite the result.
        uint ret_idx = i + 1;
        uint result_reg = call_insn.a;
        Instruction next_insn = code[ret_idx];
        bool via_copy = false;
        if (next_insn.op == Opcode.LDREG && next_insn.b == result_reg) {
            // The copy's destination becomes the register RET must name.
            result_reg = next_insn.a;
            ret_idx = i + 2;
            if (ret_idx >= code_count) { continue; }
            // Control must not enter between the call and its copy: that would
            // reach the copy with a value this call never produced.
            if (jump_targets[i + 1]) { continue; }
            via_copy = true;
        }

        // The copy may be followed by an unconditional JUMP to the shared RET
        // rather than the RET itself. That is what a conditional whose call is
        // in the FIRST arm emits: the arm jumps over the other arm to the
        // common return. Following exactly one such jump is still the same
        // tail position — nothing executes between the call and the return.
        if (ret_idx < code_count && code[ret_idx].op == Opcode.JUMP) {
            int off = code[ret_idx].get_sabc();
            int tgt = (int)ret_idx + 1 + off;
            if (tgt < 0 || (uint)tgt >= code_count) { continue; }
            ret_idx = (uint)tgt;
        }

        Instruction ret_insn = code[ret_idx];
        if (ret_insn.op != Opcode.RET) { continue; }

        // The RET must return exactly the value this call produced.
        if (ret_insn.a != result_reg) { continue; }

        // Control must not be able to arrive at the call itself from
        // elsewhere: a jump into it would reach a frame this pass has already
        // decided is disposable.
        if (jump_targets[i]) { continue; }

        // The RET may be a jump target when the call reaches it through its own
        // copy: that is the merge point of a conditional, where the other arm
        // jumps in to return its own value through the same register. This path
        // still returns exactly this call's result, and the rewrite only affects
        // this path — the other arm reaches the RET, which is still there.
        // Without an intervening copy there is no such merge: a jump straight to
        // the RET would return whatever the register happened to hold.
        if (!via_copy && jump_targets[ret_idx]) { continue; }

        // A try/catch/finally region still owns the frame.
        if (tail_in_try[i] || tail_in_try[ret_idx]) { continue; }

        // Only the call opcode changes. The RET stays: a TAILCALL whose
        // callee turns out to be ineligible (a builtin, bound function,
        // generator or class constructor, or a caller frame that still owns
        // state) runs as an ordinary call and falls through to it, and a
        // successful tail call never reaches it — the reused frame returns
        // directly to the caller's caller. Keeping it also means this pass
        // cannot change behaviour if the VM declines every tail call.
        code[i] = bytecode::make_abc(tail_op, call_insn.a, call_insn.b, call_insn.c);
    }
}
