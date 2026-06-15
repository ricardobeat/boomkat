module tinyduck::compiler;

import tinyduck::types;
import tinyduck::lexer;
import tinyduck::bytecode;
import tinyduck::hstring;
import tinyduck::hobject;
import tinyduck::heap;
import libc;
import std::io;

// ============================================================================
// Patch list management (for break/continue)
// ============================================================================

/// Add a patch address to a chain. Returns the new head.
fn uint CompilerContext.add_patch(&self, uint chain_head, uint addr) {
    if (self.patch_count >= 256) {
        return chain_head;
    }
    uint idx = self.patch_count;
    self.patches[idx].addr = addr;
    self.patches[idx].next = chain_head;
    self.patch_count++;
    return idx;
}

/// Patch all jumps in a patch chain to point to the current code position.
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
        self.loop_depth++;
    }
}

/// Patch all pending continue jumps for a loop entry to the given target address.
fn void CompilerContext.patch_continue_chain(&self, uint head, uint target) {
    uint current = head;
    while (current != NO_PATCH) {
        uint next = self.patches[current].next;
        int offset = (int)target - (int)self.patches[current].addr - 1;
        self.code[self.patches[current].addr] = bytecode::make_sabc(Opcode.JUMP, offset);
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
