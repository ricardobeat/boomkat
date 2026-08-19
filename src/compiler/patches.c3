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

// Add a patch address to a chain and return the new head.
// On overflow, sets patch_overflow so finish() produces a compile error.
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
        // Save lex_env depth at loop entry so break and continue emit the
        // necessary POP_LEX instructions to unwind back to the loop's environment.
        self.loop_stack[self.loop_depth].saved_lex_depth = self.cur_lex_depth;
        self.loop_stack[self.loop_depth].iter_close_reg = -1;
        self.loop_stack[self.loop_depth].saved_try_depth = self.try_depth;
        self.loop_depth++;
    }
}

// Choose the jump opcode for a break or continue targeting loop_idx.
// Emits plain JUMP if the loop was entered at or above the current try_depth,
// since the jump does not leave the enclosing try block. Otherwise returns
// crossing_op (BREAK/CONTINUE) to route through any active finally blocks.
fn Opcode CompilerContext.loop_jump_op(&self, uint loop_idx, Opcode crossing_op) {
    if (loop_idx < self.loop_depth && self.loop_stack[loop_idx].saved_try_depth >= self.try_depth) {
        return Opcode.JUMP;
    }
    return crossing_op;
}

// Patch all pending continue jumps for a loop entry to the given target address.
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
        // Patch pending continue jumps to the loop target.
        if (self.loop_stack[self.loop_depth].continue_patch_head != NO_PATCH) {
            self.patch_continue_chain(
                self.loop_stack[self.loop_depth].continue_patch_head,
                self.loop_stack[self.loop_depth].continue_target);
        }
        // Patch break jumps to current position.
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
