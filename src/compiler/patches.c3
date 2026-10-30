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
fn uint CompilerContext.add_patch(&self, uint chain_head, uint addr) {
    uint idx = (uint)self.patches.len();
    self.patches.push({ addr, chain_head });
    return idx;
}

// Patch all jumps in a patch chain to point to the current code position.
fn void CompilerContext.patch_chain(&self, uint chain_head) {
    uint current = chain_head;
    while (current != NO_PATCH) {
        uint addr = self.patches[(sz)current].addr;
        self.patch_jump(addr);
        current = self.patches[(sz)current].next;
    }
}

// ============================================================================
// Loop stack management
// ============================================================================

fn uint CompilerContext.loop_depth(&self) => (uint)self.loop_stack.len();

fn LoopInfo* CompilerContext.innermost_loop(&self) => &self.loop_stack[^1];

fn void CompilerContext.push_loop(&self, uint continue_target, bool is_loop) {
    // break/continue pop POP_LEXes back to saved_lex_depth.
    self.loop_stack.push({
        .continue_target = continue_target,
        .break_patch_head = NO_PATCH,
        .continue_patch_head = NO_PATCH,
        .is_loop = is_loop,
        .saved_lex_depth = self.cur_lex_depth,
        .saved_with_depth = self.cur_with_depth,
        .iter_close_reg = -1,
        .deferred_close = false,
        .close_reg = REG_NONE,
        .saved_try_depth = self.try_depth,
    });
}

// The jump opcode a break/continue targeting `loop_idx` must use.
//
// BREAK/CONTINUE may cross a finally: the VM parks the jump target on the
// innermost catcher and diverts to its finally block. That is only valid when
// the jump leaves the try region it is written in. If the target loop was
// entered at the current try_depth, the jump stays inside that region, and
// routing it through the finally would pop the catcher and drop the parked
// completion: `try { throw e } finally { while (1) break; }` would swallow `e`.
fn Opcode CompilerContext.loop_jump_op(&self, uint loop_idx, Opcode crossing_op) {
    if (loop_idx < self.loop_depth() && self.loop_stack[(sz)loop_idx].saved_try_depth >= self.try_depth) {
        return Opcode.JUMP;
    }
    return crossing_op;
}

// Patch pending continue jumps to `target`. Each site keeps its opcode, since
// loop_jump_op may have emitted a plain JUMP.
fn void CompilerContext.patch_continue_chain(&self, uint head, uint target) {
    uint current = head;
    while (current != NO_PATCH) {
        uint next = self.patches[(sz)current].next;
        uint addr = self.patches[(sz)current].addr;
        int offset = (int)target - (int)addr - 1;
        self.code[addr] = bytecode::make_sabc(self.code[addr].op, offset);
        current = next;
    }
}

fn void CompilerContext.pop_loop(&self) {
    if (try loop = self.loop_stack.pop()) {
        if (loop.continue_patch_head != NO_PATCH) {
            self.patch_continue_chain(loop.continue_patch_head, loop.continue_target);
        }
        self.patch_chain(loop.break_patch_head);
    }
}

fn void CompilerContext.add_break_patch(&self, uint addr) {
    if (self.loop_depth() > 0) {
        uint top = self.loop_depth() - 1;
        self.loop_stack[(sz)top].break_patch_head =
            self.add_patch(self.loop_stack[(sz)top].break_patch_head, addr);
    }
}
