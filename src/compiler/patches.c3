module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Patch list management (for break/continue)
// ============================================================================

// Add a patch address to a chain. Returns the new head.
//
// Overflow sets a flag that finish() turns into a compile error. Callers
// still get a usable chain head so parsing can continue to a clean stop
// rather than compounding the failure here. Returning the chain unchanged
// would leave `addr` unrecorded: patch_chain never patched it, it executed
// as `JUMP 0`, and the fall-through passed without any diagnostic at all.
fn uint CompilerContext.add_patch(&self, uint chain_head, uint addr) {
    if (self.patch_count >= MAX_PATCHES) {
        self.patch_overflow = true;
        return chain_head;
    }
    uint idx = self.patch_count;
    self.patches[idx].addr = addr;
    self.patches[idx].next = chain_head;
    self.patch_count++;
    return idx;
}

// Patch all jumps in a patch chain to point to the current code position.
fn void CompilerContext.patch_chain(&self, uint chain_head) {
    uint current = chain_head;
    while (current != NO_PATCH && current < self.patch_count) {
        uint addr = self.patches[current].addr;
        self.patch_jump(addr);
        current = self.patches[current].next;
    }
}

// ============================================================================
// Loop stack management
// ============================================================================

fn void CompilerContext.push_loop(&self, uint continue_target, bool is_loop) {
    if (self.loop_depth < MAX_LOOP_DEPTH) {
        self.loop_stack[self.loop_depth].continue_target = continue_target;
        self.loop_stack[self.loop_depth].break_patch_head = NO_PATCH;
        self.loop_stack[self.loop_depth].continue_patch_head = NO_PATCH;
        self.loop_stack[self.loop_depth].is_loop = is_loop;
        // Capture the lex_env depth AT loop entry, so break/continue can
        // emit the right number of POP_LEXes to unwind back to the loop's
        // lex_env. Any nested block with a PUSH_LEX adds to cur_lex_depth;
        // the break/continue must pop those extras before jumping.
        self.loop_stack[self.loop_depth].saved_lex_depth = self.cur_lex_depth;
        self.loop_stack[self.loop_depth].iter_close_reg = -1;
        self.loop_stack[self.loop_depth].saved_try_depth = self.try_depth;
        self.loop_depth++;
    }
}

// The jump opcode a break/continue targeting `loop_idx` must use.
//
// BREAK/CONTINUE are the "may cross a finally" forms: the VM parks the jump
// target on the innermost catcher and diverts to its finally block. That is
// only correct when the jump actually leaves the try/catch/finally region it
// is written in. When the target loop was entered at the current try_depth
// the whole loop lives inside that region, and asking the VM to route the
// jump through the enclosing finally makes it pop and free the catcher,
// silently dropping the completion parked there -- so `try { throw e }
// finally { while (1) break; }` swallowed `e` instead of rethrowing it.
fn Opcode CompilerContext.loop_jump_op(&self, uint loop_idx, Opcode crossing_op) {
    if (loop_idx < self.loop_depth && self.loop_stack[loop_idx].saved_try_depth >= self.try_depth) {
        return Opcode.JUMP;
    }
    return crossing_op;
}

// Patch all pending continue jumps for a loop entry to the given target address.
// Preserves each site's opcode: loop_jump_op may have emitted a plain JUMP.
fn void CompilerContext.patch_continue_chain(&self, uint head, uint target) {
    uint current = head;
    while (current != NO_PATCH) {
        uint next = self.patches[current].next;
        uint addr = self.patches[current].addr;
        int offset = (int)target - (int)addr - 1;
        self.code[addr] = bytecode::make_sabc(self.code[addr].op, offset);
        current = next;
    }
}

fn void CompilerContext.pop_loop(&self) {
    if (self.loop_depth > 0) {
        self.loop_depth--;
        // Patch all continue jumps to their target (if any pending)
        if (self.loop_stack[self.loop_depth].continue_patch_head != NO_PATCH) {
            self.patch_continue_chain(
                self.loop_stack[self.loop_depth].continue_patch_head,
                self.loop_stack[self.loop_depth].continue_target);
        }
        // Patch all break jumps to current position
        self.patch_chain(self.loop_stack[self.loop_depth].break_patch_head);
    }
}

fn void CompilerContext.add_break_patch(&self, uint addr) {
    if (self.loop_depth > 0) {
        uint top = self.loop_depth - 1;
        self.loop_stack[top].break_patch_head =
            self.add_patch(self.loop_stack[top].break_patch_head, addr);
    }
}
