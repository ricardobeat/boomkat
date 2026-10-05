module boomkat::compiler;

import boomkat::bytecode;

// Targets and keys run at their pattern step, after the iterator is opened.
fn void? CompilerContext.emit_deferred_target(&self, DestructBind* bind)
{

        ushort floor = self.next_reg;
        self.defer_brand_check = true;
        self.deferred_brand_reg = REG_NONE;
        self.deferred_brand_reg_hint = bind.private_brand_reg;
        defer {
            self.defer_brand_check = false;
            self.deferred_brand_reg_hint = REG_NONE;
        }
        MemberTarget target = self.gen_member_target(bind.ast_target)!;
        self.gen_remove_member_read(target.super);
        bind.is_super_target = target.super;
        bind.is_private_target = target.private;
        if (target.private) { bind.private_brand_name_c = self.deferred_brand_name_c; }
        else { self.free_reg(bind.private_brand_reg); }
        self.emit_abc(Opcode.LDREG, (uint)bind.member_obj_reg, (uint)target.base.reg, 0);
        self.emit_abc(Opcode.LDREG, (uint)bind.member_prop_reg, (uint)target.key, 0);
        self.free_regs_to(floor);
        bind.ast_target = 0;
    }

fn void? CompilerContext.emit_deferred_computed_key(&self, DestructBind* bind)
{

        ushort floor = self.next_reg;
        Val value = self.gen_expr(bind.ast_key, 0)!;
        self.emit_abc(Opcode.LDREG, (uint)bind.computed_key_reg, (uint)value.reg, 0);
        self.emit_abc(Opcode.TOPROPKEY, (uint)bind.computed_key_reg, 0, 0);
        self.free_regs_to(floor);
        bind.ast_key = 0;
    }

fn void CompilerContext.resolve_assign_targets(&self, DestructBind[] binds) {
    foreach (&b : binds) {
        if (b.is_synthetic || b.is_member_target) continue;
        if (!self.is_global) {
            if (try existing = self.resolve_var(self.bind_name(b))
                && self.find_const_name_idx(existing) == uint::max) {
                b.binding_reg = existing;
                continue;
            }
        }
        b.binding_reg = self.alloc_reg();
        b.assign_needs_putvar = true;
    }
}

fn void? CompilerContext.emit_destructure(&self, DestructBind[] binds, bool is_object, ushort src_reg,
                                         DestructStoreMode store_mode, bool is_lexical = false,
                                         bool is_const = false) {
    if (is_object) self.emit_abc(Opcode.REQUIRE_OBJ, (uint)src_reg, 0, 0);
    foreach (&b : binds) {
        if (b.parent_idx == 0xFFFF) b.arg_idx = src_reg;
    }
    self.emit_destruct_bindings(binds, store_mode, is_lexical, is_const)!;
}
