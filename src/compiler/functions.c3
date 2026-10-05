module boomkat::compiler;

import boomkat::types;
import boomkat::ast;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::collections::list;
import std::io;

// A parameter slot that records no name: destructuring patterns bind their
// own leaves, so they never contribute a string constant. Out of constant-
// pool range, so emit_param_prologue can skip these slots.
const uint NO_PARAM_NAME = 0xFFFFFFFF;

// Record `idx`'s name index, filling any skipped (destructured) slots with
// NO_PARAM_NAME so the list stays addressable by arg index.
fn void param_name_set(List{uint}* names, uint idx, uint name_idx) {
    while (names.len() <= idx) names.push(NO_PARAM_NAME);
    names.set(idx, name_idx);
}

// A slice covering every arg index, including trailing destructured params
// that never recorded a name.
fn uint[] param_name_view(List{uint}* names, uint arg_count) {
    while (names.len() < arg_count) names.push(NO_PARAM_NAME);
    return names.array_view();
}

// Iterator state for a source register used in array destructuring.
struct DestructIterState {
    ushort src_reg;       // the source register this iterator is for
    ushort method_reg;    // register holding the iterator object (result of @@iterator call)
    ushort next_reg;      // register holding the .next method
    ushort callee_reg;    // callee register for .next calls
    ushort callee_this_reg; // this register for .next calls
    ushort save_reg;      // holds the iterator while method_reg is latched
                          // undefined across .next()/.done/.value (throws there
                          // must skip IteratorClose per §7.4.6/§7.4.7)
    // The synthetic bind whose extracted value this iterator was opened on, so
    // the nested ArrayBindingPattern it belongs to. 0xFFFF for the outermost
    // pattern's iterator, whose source is the destructuring's own input.
    // §8.6.2 closes a pattern's iterator when that pattern finishes, which is
    // when the last bind naming this owner as its parent has been emitted.
    ushort owner_bind;
}

// How emit_destruct_bindings syncs each leaf binding to the environment.
// PARAM_SYNC: function parameters, already declared in the env at call entry;
//   PUTVAR + GETVAR reload (PUTVAR clears the source register). The adjacent
//   same-reg/same-name pair is elided by the register-locals pass when the
//   function needs no runtime env.
// DECLARE: statement declarations (var/let/const [pattern] = rhs), declare
//   the binding via emit_var_store (DECLVAR / PUTLEX / PUTLEX_C).
// ASSIGN_TARGET: destructuring assignment ([a, b] = rhs), register-resident
//   locals are written directly by the extraction (no env op); everything
//   else gets a bare PUTVAR (no GETVAR reload, the pair would be
//   misidentified as loop-var sync and elided, dropping genuine env stores).
enum DestructStoreMode {
    PARAM_SYNC,
    DECLARE,
    ASSIGN_TARGET,
}

// One element of a destructuring pattern: a leaf target, the synthetic
// extraction point of a nested pattern, or an elision hole.
struct DestructBind {
    bool ast_parameter_tdz;
    uint ast_target;    // deferred assignment target, evaluated at extraction time
    uint ast_default;   // default expression emitted in the enclosing activation
    uint ast_key;       // deferred computed property key
    uint name_idx;       // constant index of a leaf's name (see bind_name); unused by synthetics
    uint key_idx;        // constant index of the property key (for object patterns)
    ushort arg_idx;      // which formal parameter index this belongs to
    ushort index;        // for array patterns: the element index
    bool is_object;      // true = object pattern, false = array pattern
    bool has_default;    // has a default value expression
    bool is_synthetic;   // true = intermediate extraction point (not a user variable)
    bool is_hole;        // true = elision placeholder (iterator must advance, no binding produced)
    // true = the pattern was empty (`[]`). GetIterator still runs (and the
    // iterator is closed), so `f([])` called with a non-iterable throws and a
    // custom [Symbol.iterator] is observably invoked -- but nothing is read
    // from it, so unlike a hole the iterator must NOT be advanced.
    bool is_empty_pattern;
    uint   default_func_idx;  // index into inner_funcs for default thunk (0xFFFFFFFF if none)
    ushort parent_idx;     // index of the binding whose value is the source for this one (0xFFFF = direct from arg)
    // Assignment-pattern member-expression targets: [obj.x] = v, [...obj.rest] = v
    bool   is_member_target;  // target is a member expression, not a simple identifier
    ushort member_obj_reg;    // register holding the evaluated object (for PUTPROP)
    ushort member_prop_reg;   // register holding the evaluated property key (for PUTPROP)
    // Object-pattern computed keys: { [expr]: x }. The key expression is
    // evaluated once at collect time into a persistent register; the emitter
    // reads the value via GETPROP with that register instead of a constant key.
    bool   is_computed_key;   // true = key comes from computed_key_reg, not key_idx
    ushort computed_key_reg;  // register holding the evaluated computed key
    // ASSIGN_TARGET only: the identifier target is env-resident (did not resolve
    // to a reused local register), so the emitter must PUTVAR by name, this
    // runs the VM's const-assignment check. Set by the assignment collectors;
    // decouples the store decision from is_local_var_reg register-number guessing
    // (a fresh temp can collide with reserved low registers like r0).
    bool   assign_needs_putvar;
    // Persistent register holding the EnvRecord* RESOLVEVAR captured for this
    // binding's Reference, 0xFFFF when the store needs no captured env. Only a
    // by-name `var` inside a `with` sets it: the declaration's binding resolves
    // through the with-env, so ResolveBinding must run its `has` trap before the
    // value is read. Allocated in the emit pre-scan below every callee window.
    ushort resolve_probe_reg;
    // Private field target: the member target is a private field (this.#field).
    // Used by emit_destruct_bindings to defer the CHK_BRAND until after the
    // source property is read (GetV), per ES2022 §13.15.5.6 evaluation order.
    bool is_private_target;
    // Member target written as `super.x` / `super[k]`. The store must be
    // PUTPROP_SUPER, whose receiver is the `this` value rather than the
    // recorded base (§13.15.5.3 PutValue on a super Reference): member_obj_reg
    // holds the home object's prototype, and a setter found there has to run
    // with `this` as its receiver.
    bool is_super_target;
    // Brand register: for private targets, holds the register with the
    // CHK_BRAND operand (the brand symbol). Set by emit_deferred_target when
    // is_private_target is true and deferred_brand_check is active.
    ushort private_brand_reg;
    // Constant-pool index for the private name in the deferred CHK_BRAND.
    uint private_brand_name_c;
    // Array rest into a member target (`[...o.r] = it`): the array the
    // collection loop initializes. The generic leaf path allocates bind_reg at
    // the current watermark, which for an array rest lands inside the
    // iterator's `next()` callee window (a CALL writes callee, `this` and the
    // arguments starting at its result register), so the array is clobbered on
    // the first step. This one is allocated in the pre-scan, below every such
    // window, the same way the rest synthetics' group_regs are. 0xFFFF when
    // the bind is not an array rest with a deferred target.
    ushort rest_array_reg;
    // Array rest's next output index. It survives the iterator's per-item
    // next() call, so the pre-scan allocates it below that call window.
    ushort rest_index_reg;
    // The deferred CHK_BRAND's object operand is member_obj_reg (below), NOT
    // a separate field, member_obj_reg is the persistent, pre-scan-allocated
    // copy of `this`, safe across the source property's GETPROP (which may
    // invoke a getter). The original parse-time temp register captured by
    // emit_private_access is NOT safe to hold onto past that point: a getter
    // call writes its `this` argument at [result_reg + 1], which can land on
    // an arbitrary earlier temp.
    //
    // Registers, both 0xFFFF until assigned. group_reg holds a synthetic's
    // extracted value, the source its children read from. binding_reg is a
    // leaf's destination: the caller sets it to a declared or resolved
    // variable, or leaves it for emit_destruct_bindings to allocate.
    ushort group_reg;
    ushort binding_reg;
}

// A destructuring pattern flattened in source order. A child's parent_idx is
// its synthetic's index in the same list, so a pattern holds at most 0xFFFF
// binds (0xFFFF itself means "no parent").
alias DestructBinds = List{DestructBind};

// Append `b` to a pattern with its registers unassigned, returning its index.
// The pattern takes ownership of b's deferred snapshots, freeing them here if
// the append fails.
fn ushort? CompilerContext.add_bind(&self, DestructBinds* binds, DestructBind b) {
    if (binds.len() >= 0xFFFF) {
        return self.fail("destructuring pattern has too many elements")~;
    }
    b.group_reg = 0xFFFF;
    b.binding_reg = 0xFFFF;
    b.rest_index_reg = 0xFFFF;
    binds.push(b);
    return (ushort)(binds.len() - 1);
}

fn void free_destruct_binds(DestructBinds* binds) {
    binds.free();
}

// The name a leaf bind declares or assigns. It lives in the constant pool of
// the context that collected the pattern, interned and stable for the compile.
fn char[] CompilerContext.bind_name(&self, DestructBind* b) {
    return ((HString*)self.constants[b.name_idx].get_heapptr()).get_data();
}

fn void CompilerContext.declare_param_pattern(&self, DestructBind[] binds) {
    foreach (&b : binds) {
        if (b.is_synthetic) continue;
        b.binding_reg = self.declare_var(self.bind_name(b), VAR, true);
        self.emit_a_bc(Opcode.DECLVAR, (uint)b.binding_reg, b.name_idx);
    }
}

// Emit the full iterator protocol setup for a source register.
// Sets up: src[Symbol.iterator]() → iterator, iterator.next → next method.
// Populates the DestructIterState with the register numbers.
fn void CompilerContext.emit_destruct_iter_setup(&self, ushort src_reg, DestructIterState* state) {
    // A null/undefined source is not iterable; reject it before the
    // @@iterator read, which would otherwise fail as a property access.
    self.emit_abc(Opcode.CHKITER, (uint)src_reg, 0, 1);

    // Fused open for a plain array, refusing into the generic sequence below.
    // method_reg and next_reg are allocated up front so both paths land in the
    // same registers; the generic path reuses them via LDREG.
    ushort fast_iter_reg = self.alloc_persistent_reg();
    ushort fast_next_reg = self.alloc_persistent_reg();
    self.emit_abc(Opcode.ITER_OPEN_FAST, (uint)fast_iter_reg, (uint)src_reg,
                  (uint)fast_next_reg);
    uint open_slow_jump = self.emit_jump(Opcode.JUMP);
    uint open_done_jump = self.emit_jump(Opcode.JUMP);
    self.patch_jump(open_slow_jump);

    // Get Symbol.iterator from the global Symbol object
    ushort sym_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));

    ushort iter_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);

    ushort symbol_val_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
    self.free_reg(iter_key_reg);
    self.free_reg(sym_reg);

    // Look up @@iterator method on source
    ushort method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)src_reg, (uint)symbol_val_reg);
    self.free_reg(symbol_val_reg);

    // GetIterator step 3, before the call: a non-callable @@iterator must
    // report that the source is not iterable, not that undefined is not a
    // function (which the bare CALL below would say).
    self.emit_abc(Opcode.CHKITER, (uint)method_reg, (uint)src_reg, 0);

    // Call @@iterator() → iterator object
    ushort this_slot = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)src_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
    self.free_reg(this_slot);

    // GetIterator step 5: the iterator the method returned must be an Object,
    // checked before the `.next` read below.
    self.emit_abc(Opcode.CHKITER, (uint)method_reg, 0, 2);

    // Get .next method from iterator
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);

    ushort next_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);

    // Funnel the generic results into the fast path's registers, then join.
    self.emit_abc(Opcode.LDREG, (uint)fast_iter_reg, (uint)method_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)fast_next_reg, (uint)next_reg, 0);
    self.free_reg(next_reg);
    self.free_reg(method_reg);
    self.patch_jump(open_done_jump);
    method_reg = fast_iter_reg;
    next_reg = fast_next_reg;

    // Set up callee/this pair for .next calls
    // save_reg must live BELOW the callee window so it survives .next() calls.
    ushort save_reg = self.alloc_reg();

    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

    state.src_reg = src_reg;
    state.method_reg = method_reg;
    state.next_reg = next_reg;
    state.callee_reg = callee_reg;
    state.callee_this_reg = callee_this_reg;
    state.save_reg = save_reg;
}

// Advance the iterator by calling .next(), extract .value into dest_reg.
// Must be preceded by emit_destruct_iter_setup for the same iterator state.
fn void CompilerContext.emit_destruct_iter_next(&self, DestructIterState* state, ushort dest_reg) {
    // IteratorBindingInitialization §13.3.3: once the iterator has reported
    // done:true, [[done]] is latched, later elements bind undefined without
    // calling .next() again, and the trailing IteratorClose must be skipped.
    // We encode [[done]] by clearing method_reg to undefined (ITER_CLOSE
    // no-ops on non-objects), so first test it before calling .next().
    ushort exh_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDUNDEF, (uint)exh_reg, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)exh_reg, (uint)state.method_reg, (uint)exh_reg);
    uint exhausted_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)exh_reg);
    self.free_reg(exh_reg);

    // Fast path, the same fused step for-of uses: for a plain array iterator
    // with the builtin next method the step is a direct array read, no .next()
    // call and no {value,done} result object. The handler refuses (falls
    // through to the generic sequence below) for anything else, so GetIterator
    // and the protocol stay observable. Layout the handler relies on: refusal
    // lands on the first JUMP, done on the second, a produced value on the third.
    self.emit_abc(Opcode.ITER_NEXT_FAST, (uint)dest_reg, (uint)state.method_reg, (uint)state.next_reg);
    uint to_slow_jump = self.emit_jump(Opcode.JUMP);
    uint fast_done_jump = self.emit_jump(Opcode.JUMP);
    uint fast_cont_jump = self.emit_jump(Opcode.JUMP);
    self.patch_jump(to_slow_jump);

    // Reload callee/this each call (generators may overwrite)
    self.emit_abc(Opcode.LDREG, (uint)state.callee_reg, (uint)state.next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)state.callee_this_reg, (uint)state.method_reg, 0);

    // Latch [[done]] across the protocol calls: §7.4.6/§7.4.7, a throw from
    // .next() or from reading .done/.value sets [[Done]] before rethrowing,
    // so the enclosing catch must NOT call IteratorClose for it. Park the
    // iterator in save_reg and restore it only on a successful not-done step.
    self.emit_abc(Opcode.LDREG, (uint)state.save_reg, (uint)state.method_reg, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);

    // Call .next() → result
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)state.callee_reg, 0);

    // IteratorNext (§7.4.3): the value returned by .next() must be an object.
    // Without this a primitive step reads .done as undefined, so a rest loop
    // never sees done and spins forever.
    self.emit_abc(Opcode.CHKOBJ, (uint)result_reg, 0, 0);

    // IteratorStep (§7.4.7) reads `.done` first and only reads `.value`
    // (IteratorValue, §7.4.8) when not done, an observable ordering when
    // `.done`/`.value` are accessor properties (a `.value` getter must not
    // run when the iterator reports done:true).
    ushort key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)key_reg);
    uint mark_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    // Not done: extract .value.
    self.emit_abc(Opcode.LDCONST, (uint)key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)dest_reg, (uint)result_reg, (uint)key_reg);
    self.free_reg(done_reg);
    self.free_reg(key_reg);
    self.free_reg(result_reg);
    // Successful not-done step: restore the live iterator for IteratorClose.
    self.emit_abc(Opcode.LDREG, (uint)state.method_reg, (uint)state.save_reg, 0);
    uint end_jump = self.emit_jump(Opcode.JUMP);

    // Exhausted: bind undefined (mark target also clears method_reg, which is
    // already undefined on this path, harmless).
    self.patch_jump(exhausted_jump);
    self.emit_abc(Opcode.LDUNDEF, (uint)dest_reg, 0, 0);
    // Just-became-done: IteratorStep returns false without reading .value
    // (§7.4.7), so bind undefined here too, dest_reg was never populated on
    // this path since .value is now only read when not done.
    self.patch_jump(mark_jump);
    // Fast path done lands with mark_jump: the iterator just reported done,
    // so dest_reg binds undefined and method_reg latches to undefined, which
    // is what skips the trailing IteratorClose. The fast path itself never
    // latched method_reg, so this landing does it.
    self.patch_jump(fast_done_jump);
    self.emit_abc(Opcode.LDUNDEF, (uint)dest_reg, 0, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);
    self.patch_jump(end_jump);
    // Fast path value lands at the same exit as the generic not-done path.
    self.patch_jump(fast_cont_jump);
}

// Collect the remaining values from an array rest iterator. The fast step
// handles built-in iterators whose next() behavior is already guarded by
// ITER_NEXT_FAST; refusal keeps the full IteratorNext/done/value protocol.
fn void CompilerContext.emit_destruct_iter_rest(&self,
    ushort array_reg, ushort index_reg, DestructIterState* state)
{
    // An earlier element may already have observed done:true. Rest then
    // produces an empty array without calling next() again.
    ushort exhausted_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDUNDEF, (uint)exhausted_reg, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)exhausted_reg, (uint)state.method_reg,
                  (uint)exhausted_reg);
    uint already_exhausted_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)exhausted_reg);
    self.free_reg(exhausted_reg);

    ushort result_reg = self.alloc_reg();
    ushort done_key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    ushort value_key_reg = self.alloc_reg();
    ushort value_reg = self.alloc_reg();

    uint collect_start = self.code_count;
    self.emit_abc(Opcode.ITER_NEXT_FAST, (uint)value_reg,
                  (uint)state.method_reg, (uint)state.next_reg);
    uint generic_jump = self.emit_jump(Opcode.JUMP);
    uint fast_done_jump = self.emit_jump(Opcode.JUMP);
    uint fast_value_jump = self.emit_jump(Opcode.JUMP);
    self.patch_jump(generic_jump);

    // User iterators and observable array elements use the full protocol.
    // Latch [[Done]] across .next()/.done/.value so a throw there does not
    // trigger IteratorClose; restore only after a successful value read.
    self.emit_abc(Opcode.LDREG, (uint)state.callee_reg, (uint)state.next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)state.callee_this_reg, (uint)state.method_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)state.save_reg, (uint)state.method_reg, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)state.callee_reg, 0);

    // IteratorNext (§7.4.3): a non-object step is a TypeError.
    self.emit_abc(Opcode.CHKOBJ, (uint)result_reg, 0, 0);
    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
    uint generic_done_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)value_reg, (uint)result_reg, (uint)value_key_reg);
    self.emit_abc(Opcode.LDREG, (uint)state.method_reg, (uint)state.save_reg, 0);
    uint generic_value_jump = self.emit_jump(Opcode.JUMP);

    // Both step paths append through the same CreateDataProperty operation.
    self.patch_jump(fast_value_jump);
    self.patch_jump(generic_value_jump);
    self.emit_abc(Opcode.INITPROP, (uint)array_reg, (uint)index_reg, (uint)value_reg);
    self.emit_abc(Opcode.INC, (uint)index_reg, 0, 0);
    int back_offset = (int)collect_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    // Fast and generic done branches share the latch that skips IteratorClose.
    self.patch_jump(generic_done_jump);
    self.patch_jump(fast_done_jump);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);
    self.patch_jump(already_exhausted_jump);

    self.free_reg(value_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);
}

// Free registers held by an iterator state.
fn void CompilerContext.free_destruct_iter(&self, DestructIterState* state) {
    self.free_reg(state.callee_this_reg);
    self.free_reg(state.callee_reg);
    self.free_reg(state.save_reg);
    self.free_reg(state.next_reg);
    self.free_reg(state.method_reg);
}

// The iterator already open on a source register, or 0xFFFF for none.
fn ushort find_destruct_iter(ushort src_reg, DestructIterState[] states, uint* count) {
    for (uint i = 0; i < *count; i++) {
        if (states[i].src_reg == src_reg) return (ushort)i;
    }
    return 0xFFFF;
}

// The iterator for a source register, opening it (GetIterator) on first use.
//
// `owner` is the synthetic bind whose extracted value `src_reg` holds, which
// is the nested ArrayBindingPattern this iterator belongs to; 0xFFFF means the
// outermost pattern, reading the destructuring's own input. close_finished_iter
// uses it to close each pattern's iterator when that pattern ends.
fn ushort CompilerContext.open_destruct_iter(&self, ushort src_reg, ushort owner,
                                             DestructIterState[] states, uint* count) {
    ushort idx = find_destruct_iter(src_reg, states, count);
    if (idx != 0xFFFF) return idx;
    idx = (ushort)*count;
    (*count)++;
    self.emit_destruct_iter_setup(src_reg, &states[idx]);
    states[idx].owner_bind = owner;
    return idx;
}

// Is `anc` an ancestor of bind `di`, or `di` itself? Walks the parent_idx
// chain, which is a tree rooted at 0xFFFF.
fn bool destruct_bind_within(DestructBind[] binds, uint di, ushort anc) {
    uint cur = di;
    while (cur != 0xFFFF) {
        if (cur == (uint)anc) return true;
        cur = (uint)binds[cur].parent_idx;
    }
    return false;
}

// §8.6.2: an ArrayBindingPattern closes its own iterator as soon as that
// pattern is finished, before the enclosing pattern takes its next step.
//
// Emitting bind `di` finishes every pattern whose subtree `di` is the last
// bind of, which is more than one when a pattern ends with a nested pattern:
// `[[[a]]]` finishes the inner, the middle and the outer at `a`. So this walks
// the ancestor chain outwards from `di`, closing each iterator in turn --
// innermost first, which is the order the patterns end in.
//
// The outermost pattern's iterator is left to the shared finally: closing it
// here would place the close before whatever follows the destructuring, and
// the finally is what covers the abrupt completions anyway.
//
// Clearing method_reg afterwards makes the finally's second close a no-op, the
// same encoding of [[done]] that exhausting the iterator uses.
fn void CompilerContext.close_finished_iter(&self, DestructBind[] binds, uint di,
                                            DestructIterState[] states, uint* iter_count) {
    for (ushort owner = binds[di].parent_idx; owner != 0xFFFF;
         owner = binds[owner].parent_idx) {
        // A later bind still inside this pattern means it has not finished.
        bool finished = true;
        for (uint dj = di + 1; dj < binds.len; dj++) {
            if (destruct_bind_within(binds, dj, owner)) { finished = false; break; }
        }
        if (!finished) return;
        for (uint i = 0; i < *iter_count; i++) {
            if (states[i].owner_bind != owner) continue;
            self.emit_abc(Opcode.ITER_CLOSE, (uint)states[i].method_reg, 0, 0);
            self.emit_abc(Opcode.LDUNDEF, (uint)states[i].method_reg, 0, 0);
            break;
        }
    }
}

// Only a literal load followed by a return can bypass the thunk: no name
// resolution, allocation of mutable values, or evaluation side effects move
// across the caller's undefined check. Constants belong to the caller's pool.
fn void? CompilerContext.emit_pattern_default(&self, DestructBind* bind, ushort dest) {
    if (bind.ast_default == 0) {
        self.emit_destruct_default(bind.default_func_idx, dest);
        return;
    }
    NameEvalFrame frame = self.save_name_eval();
    defer self.restore_name_eval(frame);
    self.has_inferred_name = !bind.is_synthetic && !bind.is_member_target;
    self.inferred_name = self.has_inferred_name ? self.bind_name(bind) : "";
    ushort floor = self.next_reg;
    Val value = self.gen_expr(bind.ast_default, 0)!;
    self.gen_line_end(bind.ast_default);
    if (dest != value.reg) self.emit_abc(Opcode.LDREG, (uint)dest, (uint)value.reg, 0);
    self.free_regs_to(floor);
}

fn void CompilerContext.emit_destruct_default(&self, uint func_idx, ushort dest_reg) {
    CompiledFunction* func = self.inner_funcs[func_idx];
    if (!self.disable_optimize && func.code_count == 2
        && func.code[1].op == Opcode.RET
        && func.code[0].a == func.code[1].a) {
        Instruction load = func.code[0];
        switch (load.op) {
            case Opcode.LDINT:
                self.emit_a_sbx(Opcode.LDINT, (uint)dest_reg, load.get_sbc());
                return;
            case Opcode.LDCONST:
                TVal value = func.constants[load.get_bc()];
                if (!value.is_object()) {
                    uint constant_idx;
                    if (value.is_string() && value.get_heapptr() != null) {
                        // Each compiled pool owns its reference after the
                        // default thunk's literal is copied into this pool.
                        HString* string_value = (HString*)value.get_heapptr();
                        constant_idx = self.add_string_constant(string_value.get_data());
                    } else {
                        constant_idx = self.add_constant(value);
                    }
                    self.emit_a_bc(Opcode.LDCONST, (uint)dest_reg, constant_idx);
                    return;
                }
            case Opcode.LDUNDEF:
            case Opcode.LDNULL:
            case Opcode.LDTRUE:
            case Opcode.LDFALSE:
                self.emit_abc(load.op, (uint)dest_reg, 0, 0);
                return;
            default:
        }
    }

    ushort closure_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);
    ushort call_base = self.alloc_reg();
    if (self.next_reg <= call_base + 1) { self.next_reg = call_base + 2; }
    self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
    // A SuperCall default thunk is arrow-flagged and takes `this` from the
    // lexical capture (see compile_default_expr); a plain LDTHIS here would
    // read the enclosing derived constructor's uninitialized `this` and throw
    // before the default ever runs. Every other thunk takes the receiver.
    Opcode this_op = func.is_arrow() ? Opcode.LDUNDEF : Opcode.LDTHIS;
    self.emit_abc(this_op, (uint)(call_base + 1), 0, 0);
    self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
    self.emit_abc(Opcode.LDREG, (uint)dest_reg, (uint)call_base, 0);
    self.free_regs_to(call_base);
}

// Shared emission helper for function-parameter destructuring bindings.
// Emit object-rest collection into dest_reg: `dest = CopyDataProperties(src,
// excludedNames)` where excludedNames names every sibling explicit key (own
// key list minus the rest target), per ES2018 §13.3.3 RestBindingInitialization
// / DestructuringAssignment §7.3.24 CopyDataProperties. `binds` is the full
// pattern; `rest_di` is the rest bind whose siblings (same parent_idx) name
// the properties to exclude.
fn void? CompilerContext.emit_object_rest(&self,
    ushort dest_reg, ushort src_reg,
    DestructBind[] binds, uint rest_di)
{
    ushort parent = binds[rest_di].parent_idx;

    // Build the excludedNames array: one element per explicit sibling key,
    // evaluated/coerced to a property key (string or symbol) up front.
    // CopyDataProperties compares against these values, not raw expressions.
    ushort excl_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)excl_reg, 0, 0);
    uint excl_count = 0;
    for (uint j = 0; j < binds.len; j++) {
        if (j == rest_di) continue;
        if (binds[j].parent_idx != parent) continue;
        if (binds[j].is_object == false) continue;   // array siblings can't share an object parent
        if (binds[j].key_idx == 0xFFFF) continue;     // another rest (shouldn't happen)

        ushort elem_reg;
        if (binds[j].is_computed_key) {
            if (binds[j].ast_key != 0) {
                self.emit_deferred_computed_key(&binds[j])!;
            }
            // TOPROPKEY is idempotent on an already-coerced register (see its
            // doc comment), so this is safe whether or not the assignment-
            // pattern path already coerced it via emit_deferred_computed_key.
            self.emit_abc(Opcode.TOPROPKEY, (uint)binds[j].computed_key_reg, 0, 0);
            elem_reg = binds[j].computed_key_reg;
        } else {
            elem_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)elem_reg, binds[j].key_idx);
        }
        ushort idx_reg = self.alloc_reg();
        self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)excl_count);
        self.emit_abc(Opcode.PUTPROP, (uint)excl_reg, (uint)idx_reg, (uint)elem_reg);
        self.free_reg(idx_reg);
        if (!binds[j].is_computed_key) self.free_reg(elem_reg);
        excl_count++;
    }
    self.emit_a_bc(Opcode.SETALEN, (uint)excl_reg, excl_count);

    self.emit_abc(Opcode.NEWOBJ, (uint)dest_reg, 0, 0);
    self.emit_abc(Opcode.OBJREST, (uint)dest_reg, (uint)excl_reg, (uint)src_reg);
    self.free_reg(excl_reg);
}

// The ES6 parameter benchmark uses a flat object parameter followed by a flat
// two-element array parameter. Keep the object property reads in the normal
// source-order lowering, then let the final array pair try the guarded fast
// path. The fallback compiles that complete array pattern through its own
// IteratorClose guard.
fn bool CompilerContext.can_fast_mixed_param_array_pair(&self,
    DestructBind[] binds, bool disable_array_fast)
{
    uint count = (uint)binds.len;
    if (disable_array_fast || count < 3
        || self.defaults.len() != 0 || self.has_rest
        || self.is_async || self.is_user_generator
        || self.in_with() || self.eval_mode) return false;

    uint pair_start = count - 2;
    DestructBind first = binds[pair_start];
    DestructBind second = binds[pair_start + 1];
    if (first.is_object || second.is_object
        || first.is_synthetic || second.is_synthetic
        || first.is_hole || second.is_hole
        || first.is_empty_pattern || second.is_empty_pattern
        || first.has_default || second.has_default
        || first.is_member_target || second.is_member_target
        || first.is_computed_key || second.is_computed_key
        || first.key_idx == 0xFFFF || second.key_idx == 0xFFFF

        || first.parent_idx != 0xFFFF || second.parent_idx != 0xFFFF
        || first.index != 0 || second.index != 1
        || first.arg_idx != second.arg_idx || first.arg_idx >= self.num_args
        || first.binding_reg == 0xFFFF || first.binding_reg < self.num_args
        || second.binding_reg == 0xFFFF
        || second.binding_reg != (ushort)(first.binding_reg + 1)
        || first.name_idx >= self.const_count || second.name_idx >= self.const_count) {
        return false;
    }

    // The preceding binds must be plain leaves from one root object pattern.
    // This keeps every observable object read ahead of the array fast-path
    // check and ensures no earlier bind has already consumed the array source.
    ushort object_arg = binds[0].arg_idx;
    if (object_arg >= self.num_args || object_arg == first.arg_idx) return false;
    for (uint i = 0; i < pair_start; i++) {
        if (!binds[i].is_object || binds[i].is_synthetic || binds[i].is_hole
            || binds[i].is_empty_pattern || binds[i].has_default
            || binds[i].is_member_target || binds[i].is_computed_key
            || binds[i].key_idx == 0xFFFF

            || binds[i].parent_idx != 0xFFFF
            || binds[i].arg_idx != object_arg
            || binds[i].binding_reg == 0xFFFF
            || binds[i].binding_reg < self.num_args
            || binds[i].name_idx >= self.const_count) {
            return false;
        }
    }
    return true;
}

fn bool CompilerContext.can_fast_lexical_array_rest(&self,
    DestructBind[] binds, bool disable_array_fast)
{
    uint count = (uint)binds.len;
    if (disable_array_fast || count == 0 || count > 65
        || self.in_with() || self.eval_mode) return false;

    ushort source = binds[0].arg_idx;
    ushort first_binding = binds[0].binding_reg;
    if (first_binding == 0xFFFF) return false;
    for (uint i = 0; i < count; i++) {
        DestructBind bind = binds[i];
        bool is_rest = i + 1 == count;
        if (bind.is_object || bind.is_synthetic || bind.is_hole
            || bind.is_empty_pattern || bind.has_default
            || bind.is_member_target || bind.is_computed_key

            || bind.parent_idx != 0xFFFF
            || bind.arg_idx != source
            || bind.index != i
            || (is_rest ? bind.key_idx != 0xFFFF : bind.key_idx == 0xFFFF)
            || bind.binding_reg != (ushort)(first_binding + i)
            || bind.binding_reg < self.num_args
            || bind.name_idx >= self.const_count) {
            return false;
        }
    }
    return true;
}

// Walks binds in declaration order, resolving source registers from arg slots
// or parent group temps, and emits GETPROP (object patterns) or iterator
// protocol (array patterns) to extract values into each bind's group_reg /
// binding_reg.
fn void? CompilerContext.emit_destruct_bindings(&self,
    DestructBind[] binds,
    DestructStoreMode store_mode = PARAM_SYNC,
    bool is_lexical = false, bool is_const = false,
    bool disable_array_fast = false)
{
    if (binds.len == 0) return;
    uint count = (uint)binds.len;

    if (store_mode == DECLARE && is_lexical
        && self.can_fast_lexical_array_rest(binds, disable_array_fast)) {
        uint prefix_count = count - 1;
        self.emit_abc(Opcode.DESTRUCT_ARRAY_REST_FAST,
                      (uint)binds[0].arg_idx,
                      (uint)binds[0].binding_reg,
                      prefix_count);
        uint slow_jump = self.emit_jump(Opcode.JUMP);
        for (uint i = 0; i < count; i++) {
            self.emit_var_store(binds[i].binding_reg, binds[i].name_idx, true, is_const);
        }
        uint done_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(slow_jump);
        self.emit_destruct_bindings(binds, store_mode, is_lexical, is_const, true)!;
        self.patch_jump(done_jump);
        return;
    }

    // A flat pair of local lexical names or a single simple array parameter
    // can skip iterator setup when the VM proves that doing so is unobservable.
    // The generic lowering remains the refusal path for every other pattern.
    bool flat_param_fast = store_mode == PARAM_SYNC && count == 2
        && self.num_args == 1 && !self.has_rest && self.defaults.len() == 0
        && !self.is_async && !self.is_user_generator
        && binds[0].arg_idx == 0 && binds[1].arg_idx == 0;
    if (!disable_array_fast
        && ((store_mode == DECLARE && is_lexical) || flat_param_fast)
        && !self.in_with() && !self.eval_mode && count == 2
        && !binds[0].is_object && !binds[1].is_object
        && !binds[0].is_synthetic && !binds[1].is_synthetic
        && !binds[0].is_hole && !binds[1].is_hole
        && !binds[0].is_empty_pattern && !binds[1].is_empty_pattern
        && !binds[0].has_default && !binds[1].has_default
        && !binds[0].is_member_target && !binds[1].is_member_target
        && !binds[0].is_computed_key && !binds[1].is_computed_key
        && binds[0].key_idx != 0xFFFF && binds[1].key_idx != 0xFFFF

        && binds[0].ast_target == 0 && binds[1].ast_target == 0

        && binds[0].ast_key == 0 && binds[1].ast_key == 0
        && binds[0].parent_idx == 0xFFFF && binds[1].parent_idx == 0xFFFF
        && binds[0].index == 0 && binds[1].index == 1
        && binds[0].binding_reg != 0xFFFF
        && binds[1].binding_reg == (ushort)(binds[0].binding_reg + 1)
        && binds[0].arg_idx == binds[1].arg_idx
        && binds[0].name_idx < self.const_count && binds[1].name_idx < self.const_count) {
        self.emit_abc(Opcode.DESTRUCT_ARRAY_FAST, (uint)binds[0].arg_idx,
                      (uint)binds[0].binding_reg, 2);
        uint slow_jump = self.emit_jump(Opcode.JUMP);
        if (store_mode == PARAM_SYNC) {
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[0].binding_reg, binds[0].name_idx);
            self.emit_a_bc(Opcode.GETVAR, (uint)binds[0].binding_reg, binds[0].name_idx);
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[1].binding_reg, binds[1].name_idx);
            self.emit_a_bc(Opcode.GETVAR, (uint)binds[1].binding_reg, binds[1].name_idx);
        } else {
            self.emit_var_store(binds[0].binding_reg, binds[0].name_idx, true, is_const);
            self.emit_var_store(binds[1].binding_reg, binds[1].name_idx, true, is_const);
        }
        uint done_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(slow_jump);
        self.emit_destruct_bindings(binds, store_mode, is_lexical, is_const, true)!;
        self.patch_jump(done_jump);
        return;
    }

    bool mixed_param_fast = store_mode == PARAM_SYNC
        && self.can_fast_mixed_param_array_pair(binds, disable_array_fast);
    uint mixed_pair_start = mixed_param_fast ? count - 2 : 0xFFFFFFFF;

    // Each array pattern opens at most one iterator, so a pattern needs no
    // more states than it has binds.
    DestructIterState[] iter_states = mem::new_array(DestructIterState, count);
    defer mem::free(iter_states);
    uint iter_count = 0;

    // The expected iterator index for each bind's source register is computed
    // on demand by scanning earlier binds (line ~910) — the source register
    // can be anywhere in the up-to-65535 register space, so a flat
    // register-indexed table is wasteful and easy to OOB.

    // Pre-scan: allocate group_reg for rest synthetics before any iterator
    // setup, so they land below callee_reg and survive the per-iteration CALL
    // frame overlay (see plan 042/043). alloc_persistent_reg documents that
    // these registers must outlive the collection-loop calls.
    // Also detect whether any array (iterator-based) binds are present so we
    // can decide whether to emit a TRY guard for IteratorClose on abrupt completion.
    bool has_array_binds = false;
    for (uint di = 0; di < count; di++) {
        binds[di].resolve_probe_reg = 0xFFFF;
        binds[di].rest_array_reg    = 0xFFFF;
        binds[di].rest_index_reg    = 0xFFFF;
        if (binds[di].is_synthetic && !binds[di].is_object && binds[di].key_idx == 0xFFFF) {
            binds[di].group_reg = self.alloc_persistent_reg();
        }
        if (!binds[di].is_object && binds[di].key_idx == 0xFFFF) {
            binds[di].rest_index_reg = self.alloc_persistent_reg();
        }
        if ((binds[di].ast_target != 0) && !binds[di].is_object
            && binds[di].key_idx == 0xFFFF && !binds[di].is_synthetic) {
            // The rest array itself, for the reason on rest_array_reg.
            binds[di].rest_array_reg = self.alloc_persistent_reg();
        }
        if (binds[di].ast_target != 0) {
            // Stable pair for a deferred member target's evaluated object/key:
            // allocated below every iterator/push callee window so the values
            // survive the protocol CALLs up to the final PUTPROP.
            binds[di].member_obj_reg  = self.alloc_persistent_reg();
            binds[di].member_prop_reg = self.alloc_persistent_reg();
            // Reserve a persistent slot for a possible private-field brand
            // symbol too, we don't know yet whether the target is
            // `this.#x` until emit_deferred_target re-parses it, but the
            // register must be allocated NOW (below the source property's
            // upcoming GETPROP result register) so a getter invoked while
            // reading the source (invoke_getter writes callee/this at
            // [result_reg, result_reg + 1] before the call) cannot land on
            // it and clobber the brand symbol. Freed immediately if the
            // target turns out not to be private.
            binds[di].private_brand_reg = self.alloc_persistent_reg();
        }
        if (binds[di].ast_key != 0) {
            // Stable register for a deferred computed key's evaluated value:
            // allocated below every callee window so it survives the GETPROP
            // reads and any nested-pattern CALLs up to point of use.
            binds[di].computed_key_reg = self.alloc_persistent_reg();
        }
        // A by-name `var` bound inside a `with` needs its Reference's env
        // captured before the value is read, and the store happens after the
        // default thunk's CALL, so the probe must sit below that call's callee
        // window. PUTVAR_SNAP packs the env register into a single byte, so a
        // probe that does not fit falls back to the plain DECLVAR store and
        // loses only the `has` trap ordering, never the store itself. Object
        // leaves only: the array branch extracts straight into bind_reg, which
        // the probe's shadowing temporary would then clobber.
        if (store_mode == DECLARE && !is_lexical && self.in_with()
            && binds[di].is_object && !binds[di].is_synthetic
            && binds[di].name_idx <= bytecode::MAX_C) {
            ushort probe = self.alloc_persistent_reg();
            if (probe <= bytecode::MAX_B) {
                binds[di].resolve_probe_reg = probe;
            } else {
                self.free_reg(probe);
            }
        }
        if (!binds[di].is_object
            && !(mixed_param_fast && di >= mixed_pair_start)) {
            // The candidate pair's refusal path emits its own IteratorClose
            // guard, so the fast path needs no empty outer TRY/finally.
            has_array_binds = true;
        }
    }

    // IteratorClose on abrupt completion (ES2022 §13.3.3.8):
    // Wrap array-destructuring body in TRY so that any throw during lref
    // evaluation, default-value evaluation, or IteratorStep propagates
    // through a catch block that calls iterator.return() before re-throwing.
    // try_addr / jump_slot_addr track the placeholder instructions; both are
    // set to 0xFFFFFFFF if there are no array binds (no guard needed).
    uint iter_try_addr      = 0xFFFFFFFF;
    uint iter_jump_slot     = 0xFFFFFFFF;
    if (has_array_binds) {
        iter_try_addr   = self.emit_a_bc(Opcode.TRY, 0, 0);
        iter_jump_slot  = self.emit_a_bc(Opcode.NOP, 0, 0);
    }

    for (uint di = 0; di < count; di++) {
        if (mixed_param_fast && di == mixed_pair_start) {
            // The preceding object leaves have already run in source order.
            // Try the same guarded extraction used by a standalone flat pair;
            // refusal owns a fresh iterator and its IteratorClose handling.
            self.emit_abc(Opcode.DESTRUCT_ARRAY_FAST,
                          (uint)binds[di].arg_idx,
                          (uint)binds[di].binding_reg, 2);
            uint slow_jump = self.emit_jump(Opcode.JUMP);
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[di].binding_reg,
                           binds[di].name_idx);
            self.emit_a_bc(Opcode.GETVAR, (uint)binds[di].binding_reg,
                           binds[di].name_idx);
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[di + 1].binding_reg,
                           binds[di + 1].name_idx);
            self.emit_a_bc(Opcode.GETVAR, (uint)binds[di + 1].binding_reg,
                           binds[di + 1].name_idx);
            uint done_jump = self.emit_jump(Opcode.JUMP);

            self.patch_jump(slow_jump);
            DestructBind[2] fallback_binds = { binds[di], binds[di + 1] };
            self.emit_destruct_bindings(fallback_binds[0:2], store_mode,
                                        is_lexical, is_const, true)!;
            self.patch_jump(done_jump);
            break;
        }

        // Resolve source register, either the argument slot or a parent group temp
        ushort src_reg;
        if (binds[di].parent_idx == 0xFFFF) {
            src_reg = binds[di].arg_idx;
        } else {
            src_reg = binds[binds[di].parent_idx].group_reg;
        }

        // ---- Hole / elision: advance iterator past gaps ----
        // For any array bind (not object), ensure iterator is at the target index.
        // This covers: element binds, synthetic binds, and rest binds.
        if (!binds[di].is_object) {
            // Walk earlier binds to find the highest consumed iterator index
            // for this source register (sentinel "no prior bind" → 0). The
            // source register can be any value up to MAX_REGISTERS, so a flat
            // register-indexed table would be wasteful and easy to OOB.
            ushort ei = 0;
            for (uint dj = 0; dj < di; dj++) {
                if (binds[dj].is_object) continue;
                if (binds[dj].key_idx == 0xFFFF) continue;
                ushort dj_src;
                if (binds[dj].parent_idx == 0xFFFF) {
                    dj_src = binds[dj].arg_idx;
                } else {
                    dj_src = binds[binds[dj].parent_idx].group_reg;
                }
                if (dj_src != src_reg) continue;
                ushort after = (ushort)(binds[dj].index + 1);
                if (after > ei) ei = after;
            }
            ushort target = binds[di].index;
            while (ei < target) {
                ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                          iter_states, &iter_count);
                ushort hole_reg = self.alloc_reg();
                self.emit_destruct_iter_next(&iter_states[iter_idx], hole_reg);
                self.free_reg(hole_reg);
                ei++;
            }
        }

        // Empty pattern: open the iterator and nothing more. The close pass
        // at the end of this iteration emits the ITER_CLOSE, so this is
        // GetIterator + IteratorClose, exactly what an empty
        // ArrayBindingPattern performs.
        if (binds[di].is_empty_pattern) {
            self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                    iter_states, &iter_count);
        } else if (binds[di].is_hole) {
            // Elision: advance the iterator once and bind nothing. Per
            // IteratorBindingInitialization §13.3.3 each elision calls
            // IteratorStep and propagates abrupt completions.
            ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                      iter_states, &iter_count);
            ushort hole_reg = self.alloc_reg();
            self.emit_destruct_iter_next(&iter_states[iter_idx], hole_reg);
            self.free_reg(hole_reg);
        } else if (binds[di].is_synthetic) {
            // Use pre-allocated group_reg for rest synthetics, allocate now for others.
            ushort group_reg;
            if (binds[di].key_idx == 0xFFFF) {
                group_reg = binds[di].group_reg;
            } else {
                group_reg = self.alloc_reg();
                binds[di].group_reg = group_reg;
            }

            if (binds[di].is_object) {
                // Object pattern: GETPROP via a constant or computed key.
                if (binds[di].is_computed_key) {
                    if (binds[di].ast_key != 0) {
                        self.emit_deferred_computed_key(&binds[di])!;
                    }
                    self.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)binds[di].computed_key_reg);
                } else {
                    ushort key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, binds[di].key_idx);
                    self.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                }
            } else if (binds[di].key_idx == 0xFFFF) {
                // Synthetic rest: collect remaining iterator values into an array.
                self.emit_abc(Opcode.NEWARR, (uint)group_reg, 0, 0);
                self.emit_a_sbx(Opcode.LDINT, (uint)binds[di].rest_index_reg, 0);

                ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                          iter_states, &iter_count);
                DestructIterState* state = &iter_states[iter_idx];
                self.emit_destruct_iter_rest(group_reg, binds[di].rest_index_reg, state);
            } else {
                // Array pattern element: single iterator advance.
                ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                          iter_states, &iter_count);
                self.emit_destruct_iter_next(&iter_states[iter_idx], group_reg);
            }

            // Default value check for nested patterns: if group_reg is
            // undefined, evaluate the default thunk before REQUIRE_OBJ.
            if (binds[di].has_default && binds[di].key_idx != 0xFFFF) {
                ushort undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                ushort cmp_reg = self.alloc_reg();
                self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)group_reg, (uint)undef_reg);
                self.free_reg(undef_reg);

                // The skip branch is patched below; a WIDE prefix for a wide
                // cmp_reg lands BEFORE the instruction, so record the branch's
                // own index from the emit, not the pre-emit count.
                uint skip_addr = self.emit_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0);
                self.free_reg(cmp_reg);

                self.emit_pattern_default(&binds[di], group_reg)!;

                int skip_off = (int)self.code_count - (int)skip_addr - 1;
                self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
            }

            // REQUIRE_OBJ, TypeError if null/undefined nested target.
            // Skip for rest synthetics (always an array).
            if (binds[di].key_idx != 0xFFFF) {
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)group_reg, 0, 0);
            }
        } else {
            // Leaf binding, a real variable.
            // Member-expression assignment targets (ASSIGN_TARGET) pass 0xFFFF
            // here rather than a pre-allocated register: the caller cannot know
            // where the persistent member_obj_reg/member_prop_reg/computed_key_reg
            // will land (allocated in the pre-scan above), and GETPROP's accessor
            // getter call frame is placed AT the result register (reusing it and
            // everything above), so bind_reg must be allocated *after*, i.e. at
            // a higher register number than, any live persistent register or
            // the getter call would clobber it. Allocate it fresh here instead.
            ushort bind_reg = binds[di].binding_reg;
            if (bind_reg == 0xFFFF) {
                // An array rest into a member target uses the pre-scan
                // register instead, which sits below the iterator's callee
                // window; see rest_array_reg.
                bind_reg = binds[di].rest_array_reg != 0xFFFF
                         ? binds[di].rest_array_reg
                         : self.alloc_reg();
                binds[di].binding_reg = bind_reg;
            }
            uint ni = binds[di].name_idx;

            // A by-name `var` bound inside a `with` stores through the
            // Reference ResolveBinding created: GetIdentifierReference runs the
            // with object's `has` trap before GetV reads the source property,
            // and the store below re-enters that same env
            // (ES2024 §14.3.3.3 steps 2-3, then InitializeReferencedBinding).
            // RESOLVEVAR captures the owning EnvRecord* into a persistent
            // register allocated below every callee window (see the pre-scan);
            // the store becomes PUTVAR_SNAP. It is emitted per-branch, after
            // the property name has been evaluated (PropertyBindingInitialization
            // step 1 runs before KeyedBindingInitialization's ResolveBinding).
            // The value is then extracted into a register ABOVE the probe:
            // GETPROP's accessor frame sits at its result register and reuses
            // everything above it, so the bind's binding_reg (declared before
            // any of this, hence below the probe) would let the getter destroy
            // the probe before the store reads it. The register must stay high for
            // the whole bind: retargeting the GETPROP down to a low register
            // (moveelim's producer retarget) would move the getter's frame back
            // over the probe.
            bool needs_probe = (binds[di].resolve_probe_reg != 0xFFFF);

            // Extract value from source into bind_reg
            if (binds[di].is_object) {
                if (binds[di].key_idx == 0xFFFF) {
                    // Object rest: `{...rest}` → CopyDataProperties(src, siblings).
                    if (binds[di].ast_target != 0) self.emit_deferred_target(&binds[di])!;
                    if (needs_probe) {
                        self.emit_a_bc(Opcode.RESOLVEVAR, (uint)binds[di].resolve_probe_reg, ni);
                        bind_reg = self.alloc_reg();
                    }
                    self.emit_object_rest(bind_reg, src_reg, binds, di)!;
                } else if (binds[di].is_computed_key) {
                    if (binds[di].ast_key != 0) {
                        self.emit_deferred_computed_key(&binds[di])!;
                    }
                    // Per ES2022 §13.15.5.6 KeyedDestructuringAssignmentEvaluation:
                    // 1. Evaluate target (lref), get object + key reference.
                    // 2. GetV(value, propertyName), read source property.
                    // 3. PutValue, assign (including brand check for private fields).
                    // So emit_deferred_target runs first, then GETPROP; the deferred
                    // CHK_BRAND for private targets runs later, at PutValue time,
                    // the ASSIGN_TARGET switch below (right before PUTPROP), NOT
                    // here. Emitting it here too would run CHK_BRAND twice (once
                    // before PutValue, wrongly early, and once at the correct
                    // PutValue point) for every private-member destructuring target.
                    if (binds[di].ast_target != 0) {
                        self.emit_deferred_target(&binds[di])!;
                    }
                    if (needs_probe) {
                        self.emit_a_bc(Opcode.RESOLVEVAR, (uint)binds[di].resolve_probe_reg, ni);
                        bind_reg = self.alloc_reg();
                    }
                    self.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)binds[di].computed_key_reg);
                } else {
                    if (binds[di].ast_target != 0) {
                        self.emit_deferred_target(&binds[di])!;
                    }
                    ushort key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, binds[di].key_idx);
                    if (needs_probe) {
                        self.emit_a_bc(Opcode.RESOLVEVAR, (uint)binds[di].resolve_probe_reg, ni);
                        bind_reg = self.alloc_reg();
                    }
                    self.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                    // See the computed-key branch above: the CHK_BRAND for a
                    // private-member target runs later, at PutValue time (the
                    // ASSIGN_TARGET switch below), not here.
                }
            } else {
                if (binds[di].key_idx == 0xFFFF) {
                    // Rest element: collect remaining iterator values into a new array.
                    // Use bind_reg (pre-allocated low register from declare_var)
                    // directly for the array to avoid the CALL callee-frame overlay
                    // (CALL places callee frame at callee_reg+2, which would
                    // clobber a freshly allocated register).
                    self.emit_abc(Opcode.NEWARR, (uint)bind_reg, 0, 0);
                    self.emit_a_sbx(Opcode.LDINT, (uint)binds[di].rest_index_reg, 0);

                    ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                              iter_states, &iter_count);
                    DestructIterState* state = &iter_states[iter_idx];

                    // Emit the deferred rest member-target evaluation now, AFTER
                    // the iterator is opened but BEFORE collection, so a throw from
                    // a side-effecting target (e.g. `...{}[thrower()]`) triggers
                    // IteratorClose on the open iterator (ES2022 §13.15.5.3).
                    if (binds[di].ast_target != 0) {
                        self.emit_deferred_target(&binds[di])!;
                    }

                    self.emit_destruct_iter_rest(bind_reg,
                        binds[di].rest_index_reg, &iter_states[iter_idx]);
                } else {
                    // Array pattern: use iterator protocol
                    ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                              iter_states, &iter_count);
                    // Emit the deferred member-target evaluation BEFORE
                    // IteratorStep, per ES2022 §13.15.5.6: the target lref is
                    // evaluated before IteratorStep, so any throw here triggers
                    // IteratorClose on the already-opened inner iterator.
                    if (binds[di].ast_target != 0) {
                        self.emit_deferred_target(&binds[di])!;
                    }
                    self.emit_destruct_iter_next(&iter_states[iter_idx], bind_reg);
                }
            }

            // Default value check: if bind_reg is undefined, use the default thunk
            if (binds[di].has_default) {
                ushort undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                ushort cmp_reg = self.alloc_reg();
                self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)bind_reg, (uint)undef_reg);
                self.free_reg(undef_reg);

                uint skip_addr = self.emit_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0);
                self.free_reg(cmp_reg);

                self.emit_pattern_default(&binds[di], bind_reg)!;

                int skip_off = (int)self.code_count - (int)skip_addr - 1;
                self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
            }

            // Sync binding to environment per store mode (see DestructStoreMode).
            switch (store_mode) {
                case PARAM_SYNC:
                    if (binds[di].ast_parameter_tdz) self.emit_var_store(bind_reg, ni, true, false);
                    self.emit_a_bc(Opcode.PUTVAR, (uint)bind_reg, ni);
                    self.emit_a_bc(Opcode.GETVAR, (uint)bind_reg, ni);
                case DECLARE:
                    if (binds[di].resolve_probe_reg != 0xFFFF) {
                        // Store through the captured Reference (see the
                        // RESOLVEVAR note at the leaf's extraction).
                        self.emit_abc(Opcode.PUTVAR_SNAP, (uint)bind_reg,
                                      (uint)binds[di].resolve_probe_reg, ni);
                    } else {
                        self.emit_var_store(bind_reg, ni, is_lexical, is_const);
                    }
                case ASSIGN_TARGET:
                    // Member-expression targets (e.g. [obj.x] = v) use PUTPROP
                    // rather than PUTVAR. The deferred target evaluation code was
                    // already re-emitted before IteratorStep (ES2022 §13.15.5.6),
                    // so here we just do the assignment. For private member
                    // targets, the brand check was deferred and must run AFTER
                    // the value has been extracted into bind_reg, matching the
                    // object-pattern code path's structure (see emit_deferred_target
                    //, it set is_private_target during the earlier emit).
                    if (binds[di].is_member_target) {
                        if (binds[di].is_private_target) {
                            // Use member_obj_reg (the persistent, pre-scan-
                            // allocated copy of `this`), NOT private_brand_obj_reg
                            // (the original parse-time temp register): a getter
                            // invoked while reading the source property writes
                            // its `this` argument at [result_reg + 1] (see
                            // invoke_getter), which can land exactly on a
                            // temp register captured before the persistent
                            // copy was made, corrupting it before this read.
                            self.emit_abc(Opcode.CHK_BRAND,
                                (uint)binds[di].member_obj_reg,
                                (uint)binds[di].private_brand_reg,
                                binds[di].private_brand_name_c);
                            self.free_reg(binds[di].private_brand_reg);
                        }
                        // A `super.x` target stores through PUTPROP_SUPER:
                        // member_obj_reg holds the home object's prototype,
                        // where the walk starts, but a setter found there runs
                        // with the current `this` as its receiver (§13.15.2
                        // SetSuperProperty), and a new data property lands
                        // there too.
                        self.emit_abc(binds[di].is_super_target
                                          ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP,
                            (uint)binds[di].member_obj_reg,
                            (uint)binds[di].member_prop_reg,
                            (uint)bind_reg);
                        self.free_reg(binds[di].member_prop_reg);
                        self.free_reg(binds[di].member_obj_reg);
                    } else if (binds[di].assign_needs_putvar || !self.is_local_var_reg(bind_reg)) {
                        // Destructuring assignment target, throws on TDZ let/const.
                        self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)bind_reg, ni);
                    }
            }
        }

        self.close_finished_iter(binds, di, iter_states, &iter_count);
    }

    // Close the TRY guard and emit the IteratorClose finally block.
    //
    // IteratorClose must run on EVERY abrupt completion of the destructuring,
    // not just throw, but also a `return` completion (e.g. a generator `.return()`
    // resuming a `yield` inside a target lref such as `[...{}[yield]]`) and
    // break/continue. A catch-only handler fires on throw alone, so the guard is
    // lowered as a try/FINALLY: the finally runs ITER_CLOSE for each iterator and
    // ENDFINALLY then re-dispatches the pending completion (throw/return/break/
    // continue/normal). On the normal path the finally still runs, which also
    // covers §13.15.5.3 "if [[done]] is false, IteratorClose" for a
    // partially-consumed iterator, so no separate normal-path close is needed.
    if (iter_try_addr != 0xFFFFFFFF && iter_count > 0) {
        // Normal path: end the try region, then fall through to the finally.
        // (The jump slot's finally offset also routes abrupt completions here.)
        self.emit_simple(Opcode.ENDTRY);

        // FINALLY block, entered on normal completion (fall-through) and on any
        // abrupt completion (via the catcher's finally_pc).
        uint finally_target = self.code_count;
        self.emit_simple(Opcode.FINALLY);
        for (uint i = 0; i < iter_count; i++) {
            // B=2: auto-detect completion type, suppress .return() errors only
            // when the pending completion is a throw (§7.4.6 steps 6/8); a return
            // completion (e.g. generator .return() through a yield here) must
            // propagate a throwing/non-object .return().
            self.emit_abc(Opcode.ITER_CLOSE, (uint)iter_states[i].method_reg, 2, 0);
        }
        self.emit_simple(Opcode.ENDFINALLY);

        // Patch TRY: flags = finally (bit1). Jump slot BC = finally offset.
        self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 2, 0);
        uint finally_off = finally_target - iter_try_addr;
        self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off);
    } else if (iter_try_addr != 0xFFFFFFFF) {
        // TRY was emitted but no iterators were set up (unusual: pure object binds
        // after the pre-scan flag, should not happen, but be safe).
        self.emit_simple(Opcode.ENDTRY);
        uint finally_target_e = self.code_count;
        self.emit_simple(Opcode.FINALLY);
        self.emit_simple(Opcode.ENDFINALLY);
        self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 2, 0);
        uint finally_off_e = finally_target_e - iter_try_addr;
        self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off_e);
    }

    // Free iterator registers. IteratorClose already ran in the finally above.
    for (uint i = 0; i < iter_count; i++) {
        self.free_destruct_iter(&iter_states[i]);
    }
}

// Create the hoisted binding for one `var` name found by the pre-scan:
// a register slot, an `undefined` initial value, and the env declaration.
// Shared by the plain-identifier declarator path and the binding-pattern
// walker, which must produce byte-identical bindings for their leaf names.
//
// Eval code only: record the var name in eval_var_coll_idxs so the body-side
// var_declaration can recognise a re-declared `var x;` as already-instantiated
// and skip the redundant DECLVAR_HOIST (which would otherwise re-create a
// binding the body's `delete x;` just removed, see §18.2.1.2 step 16).
fn void CompilerContext.record_eval_var_name(&self, char[] raw_name) {
    HString* hs = ((Heap*)self.heap).str_intern(raw_name);
    uint ni = self.add_string_constant(hs.get_data());
    for (uint k = 0; k < self.eval_var_coll_count; k++) {
        if (self.eval_var_coll_idxs[k] == ni) return;
    }
    if (self.eval_var_coll_count >= self.eval_var_coll_cap) {
        uint new_cap = self.eval_var_coll_cap == 0 ? 16 : self.eval_var_coll_cap * 2;
        void* pn = ((Heap*)self.heap).realloc_func(((Heap*)self.heap).heap_udata,
            self.eval_var_coll_idxs, (usz)(new_cap * 4));
        if (pn == null) return;
        self.eval_var_coll_idxs = (uint*)pn;
        self.eval_var_coll_cap = new_cap;
    }
    self.eval_var_coll_idxs[self.eval_var_coll_count++] = ni;
}

fn void CompilerContext.hoist_one_var_name(&self, char[] raw_name, bool is_global, bool b33_record = false) {
    if (self.eval_mode) { self.record_eval_var_name(raw_name); }
    // Intern the name so every later use shares one canonical copy.
    HString* var_hstr = ((Heap*)self.heap).str_intern(raw_name);
    char[] var_name = var_hstr.get_data();
    // A var whose name is already a parameter is NOT re-initialized: per
    // ES2015 §9.2.10 step 27, only var names absent from parameterNames get
    // the `undefined` initialization, so the argument value must survive
    // `function f(p){ if (false) { var p = 1; } return p; }`. The parameter's
    // own binding already is the var binding, so emit neither LDUNDEF nor a
    // declaration and leave every read pointing at it.
    if (self.is_param_name(var_name)) {
        self.has_local_bindings = true;
        return;
    }
    // A var whose name is also a FunctionDeclaration is likewise NOT
    // re-initialized: GlobalDeclarationInstantiation (§16.1.7) and
    // FunctionDeclarationInstantiation (§10.2.11) create the var binding but
    // only initialize names that are not already function-declared, so the
    // hoisted function value must survive `function f(){} var f;` (and any
    // order). Emitting LDUNDEF + DECLVAR_HOIST here would clobber the function
    // binding with undefined (the function binding is env-resident, but the
    // var's register would also shadow it). Function decls are hoisted before
    // this pass, so hoisted_fn_names is already populated.
    for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
        if (str_eq(self.hoisted_fn_names[hi], var_name)) {
            self.has_local_bindings = true;
            return;
        }
    }
    // `var arguments` in an ordinary (non-arrow) function declares no binding
    // of its own: §10.2.11 binds "arguments" to the arguments object created
    // at call entry, and `var arguments = v` is only an assignment to it. The
    // name must therefore make the function need that object, exactly as a
    // reference to `arguments` would. The hoist stub below is still emitted
    // (reads resolve through the environment, not through its register), and
    // the VM skips the stub for this name once the object exists.
    bool uses_args_object = !is_global && !self.is_arrow && str_eq(var_name, "arguments");
    if (uses_args_object) {
        self.uses_arguments = true;
    }
    // One binding per name: when the B.3.3 scan reaches a block FIRST a later
    // `var f` reuses the entry made here (var_declaration's find_local_reg),
    // but when `var f` comes first its entry is already in place. Declaring
    // afresh then allocates a SECOND register for the same binding: the
    // capture-marking loop marks the first entry while the block's
    // DECLGLOBALFUNC writes the second, so env-resident reads see undefined.
    // A formal parameter's own entry likewise doubles as the var binding
    // (§9.2.10 step 27 leaves it alone), so reuse it instead of allocating.
    // A BLOCK-scoped entry (the scan's own declaration, or a `let` in an
    // enclosing/earlier block) is NOT the var binding — an exempt block must
    // still create it; keep declaring. Only a VAR entry (or a formal/catch
    // parameter entry) proves the var binding already exists.
    if (try _existing_b33 = self.find_var_or_param_reg(var_name)) {
        self.has_local_bindings = true;
        return;
    }
    ushort var_reg = self.declare_var(var_name, VAR);
    self.has_local_bindings = true;
    // `arguments` is bound by the VM at call entry (see the uses_arguments
    // note above), so the register must not become the live home slot: force
    // every read through the environment, as the catch parameter does.
    if (uses_args_object) {
        self.mark_scope_captured(self.scope_depth - 1);
    }
    self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
    uint var_name_idx = self.add_string_constant(var_name);
    uint hoist_pc = self.emit_a_bc(Opcode.DECLVAR_HOIST, (uint)var_reg, var_name_idx);
    // A B.3.3 entry init may be withdrawn by block(): when the block proves
    // exempt (same-named `let` visible, formal, arguments) it NOPs this
    // DECLVAR_HOIST and erases the scope entry, leaving no var binding at
    // all. Stash the instruction index keyed by name for that withdrawal.
    if (b33_record) {
        self.record_b33_hoist(var_name, (uint)var_reg, hoist_pc);
    }
    // At global scope, var bindings are normally env-resident (accessed via
    // GETGLOBAL/PUTGLOBAL); the register is only a temporary DECLVAR source.
    // Free it immediately so 500+ var declarations don't exhaust the register
    // file.  The exception: a REGISTER-RESIDENT global keeps its register as
    // the live home slot for the whole top-level body, synced at end of script.
    if (is_global && !self.is_slot_global_name(var_name)) { self.free_reg(var_reg); }
}

// Emit deferred body-scope functions after entering the body's lexical
// scope. Keep the list so generation can skip their declaration nodes.
fn void CompilerContext.emit_hoisted_fn_decls(&self) {
    if (self.hoisted_defer_count == 0 || self.hoisted_defer_emitted) return;
    // The list is NOT cleared: function_declaration reads it to recognise the
    // declarations it must skip, and every one of those is reached after this
    // runs. A flag marks the emission instead, so a nested block cannot repeat
    // it.
    self.hoisted_defer_emitted = true;
    // Emit in REVERSE order. ES2024 §19.2.1.2 EvalDeclarationInstantiation
    // step 8 walks varDeclarations in reverse list order for the
    // CanDeclareGlobalFunction check that throws TypeError on a
    // non-definable name (e.g. `function NaN(){}` when NaN is the
    // non-configurable built-in). Doing it at runtime means a failing
    // check aborts the eval before any earlier declarations leak into
    // the global env; forward order would create them and then throw.
    for (ushort di = (ushort)(self.hoisted_defer_count); di > 0; di--) {
        ushort idx = (ushort)(di - 1);
        self.emit_a_bc(Opcode.CLOSURE, (uint)self.hoisted_defer_regs[idx],
                       self.hoisted_defer_inner_idxs[idx]);
        // Use DECLGLOBALFUNC (not DECLVAR) so the binding carries the
        // function-declaration attributes: inside a function body the
        // binding is non-configurable (Annex B.3.3 / §10.2.1.1.6, so
        // sloppy `delete f` returns false), and on the global object the
        // descriptor reflects CreateGlobalFunctionBinding's non-enumerable
        // rule for global-script declarations.
        self.emit_a_bc(Opcode.DECLGLOBALFUNC, (uint)self.hoisted_defer_regs[idx],
                       self.hoisted_defer_name_idxs[idx]);
    }
}

// The same for a scope the caller already holds.
fn void? CompilerContext.hoist_decls_in(&self, uint scope, bool is_global, bool checks_only) {
    uint saved_line = self.lexer.current.line;
    defer self.lexer.current.line = saved_line;
    ast::AstIndex* idx = ast::index_state;
    ast::Resolver* res = &idx.res;
    ast::Scope* sc = &res.scopes.data[scope];
    // The enclosing function's flag must survive this pass; during it the flag describes the
    // declaration being hoisted.
    bool enclosing_is_async = self.is_async;
    self.is_async = false;
    defer self.is_async = enclosing_is_async;
    for (uint i = sc.site_start; i < sc.site_end; i++) {
        ast::Site* s = &res.sites.data[i];
        if (res.scopes.data[s.scope].func != scope) continue;
        char[] name = idx.tree.atoms.get(idx.tree.lhs.data[s.node]);
        switch (s.kind) {
            case VAR:
                if (self.is_module) {
                    for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                        if (str_eq(self.hoisted_fn_names[hi], name)) {
                            return self.fail("module-level function declaration cannot share a name with a var declaration")~;
                        }
                    }
                }
                if (checks_only) {
                    if (is_global && !self.is_module) {
                        uint chk_idx = self.add_string_constant(name);
                        self.emit_a_bc(Opcode.CHKGLOBALVAR, 0, chk_idx);
                        self.record_declared_global(chk_idx);
                    }
                } else {
                    self.hoist_one_var_name(name, is_global);
                }
            case ANNEXB_VAR:
                if (!checks_only && name != "arguments") self.hoist_one_var_name(name, is_global);
            case FUNC_BLOCK:
                continue;
            case FUNC:
                if (is_global || s.exported) continue;
                self.hoist_function_indexed(s)!;
            default:
        }
    }

}

// Compile the function declaration of `s` at function level and queue it for the block prologue.
fn void? CompilerContext.hoist_function_indexed(&self, ast::Site* s) {
    ast::AstIndex* idx = ast::index_state;
    uint rec = idx.tree.rhs.data[s.decl];
    uint fnf = idx.tree.field(rec, ast::FN_FLAGS);
    bool hoist_is_async = (fnf & ast::FNF_ASYNC) != 0;
    char[] fn_name = idx.tree.atoms.get(idx.tree.lhs.data[s.node]);

    // `await`, `yield` and the reserved literals are left to the name parse in enter_hoisted_function.
    if (is_restricted_name(fn_name, false, false, self.is_strict)) {
        return self.fail("reserved word cannot be used as a binding identifier")~;
    }

    bool already = false;
    for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
        if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
            already = true;
            break;
        }
    }
    if (!already) {
        self.ensure_hoisted_fn_cap();
        if (self.hoisted_fn_count < self.hoisted_fn_cap) {
            self.hoisted_fn_names[self.hoisted_fn_count] = fn_name;
            self.hoisted_fn_count++;
        }
    } else {
        // A duplicate: the later declaration wins, so only the last one is compiled and instantiated.
        bool dup_known = false;
        for (ushort di = 0; di < self.hoisted_defer_count; di++) {
            if (str_eq(self.hoisted_defer_names[di], fn_name)) {
                dup_known = true;
                break;
            }
        }
        if (!dup_known) {
            self.ensure_hoisted_defer_cap();
            if (self.hoisted_defer_count < self.hoisted_defer_cap) {
                HString* dup_hstr = ((Heap*)self.heap).str_intern(fn_name);
                self.hoisted_defer_names[self.hoisted_defer_count] = dup_hstr.get_data();
                self.hoisted_defer_count++;
            }
        }
    }

    bool saved_gen = self.is_generator;
    bool saved_user_gen = self.is_user_generator;
    bool gen_here;
    char[] fn_name2;

        fn_name2 = self.gen_name(idx.tree.lhs.data[s.node]);
        gen_here = (fnf & ast::FNF_GENERATOR) != 0;

    self.is_generator = gen_here;
    self.is_user_generator = gen_here;

    ushort func_reg;
    ushort? hoist_existing_reg = self.find_same_scope_reg(fn_name2);
    if (try her = hoist_existing_reg) {
        func_reg = her;
    } else {
        func_reg = self.declare_var(fn_name2, VAR);
    }
    self.has_local_bindings = true;

    bool saved_is_constructable = self.is_constructable;
    self.is_constructable = !self.is_generator && !hoist_is_async;

    self.is_async = hoist_is_async;
    uint ast_scope = idx.function_scope(s.decl);
    CompiledFunction* inner = self.compile_inner_function(fn_name2, false, idx.tree.field(rec, ast::FN_SRC_START), ast_scope: ast_scope)!;
    self.gen_line(idx.tree.field(rec, ast::FN_SRC_END) - 1);
    self.is_async = false;

    self.is_generator = saved_gen;
    self.is_user_generator = saved_user_gen;
    self.is_constructable = saved_is_constructable;

    uint inner_idx = self.add_inner_func(inner);
    uint name_idx = self.add_string_constant(fn_name2);

    bool recorded = false;
    for (ushort di = 0; di < self.hoisted_defer_count; di++) {
        if (str_eq(self.hoisted_defer_names[di], fn_name2)) {
            self.hoisted_defer_regs[di] = func_reg;
            self.hoisted_defer_inner_idxs[di] = inner_idx;
            self.hoisted_defer_name_idxs[di] = name_idx;
            recorded = true;
            break;
        }
    }
    if (!recorded) {
        self.ensure_hoisted_defer_cap();
        if (self.hoisted_defer_count < self.hoisted_defer_cap) {
            self.hoisted_defer_names[self.hoisted_defer_count] = fn_name2;
            self.hoisted_defer_regs[self.hoisted_defer_count] = func_reg;
            self.hoisted_defer_inner_idxs[self.hoisted_defer_count] = inner_idx;
            self.hoisted_defer_name_idxs[self.hoisted_defer_count] = name_idx;
            self.hoisted_defer_count++;
        }
    }
}

// Script and module function declarations: checked, then instantiated.
fn bool? CompilerContext.hoist_global_fn_decls_indexed(&self, bool checks_only) {
    uint saved_line = self.lexer.current.line;
    defer self.lexer.current.line = saved_line;
    ast::AstIndex* idx = ast::index_state;
    if (idx == null || !idx.use) return false;
    ast::Resolver* res = &idx.res;
    ast::Scope* sc = &res.scopes.data[1];
    bool enclosing_is_async = self.is_async;
    self.is_async = false;
    defer self.is_async = enclosing_is_async;
    for (uint i = sc.site_start; i < sc.site_end; i++) {
        ast::Site* s = &res.sites.data[i];
        if (s.scope != 1 || s.kind != ast::DeclKind.FUNC || (s.exported && !self.is_module)) continue;
        uint rec = idx.tree.rhs.data[s.decl];
        uint fnf = idx.tree.field(rec, ast::FN_FLAGS);
        bool hoist_is_async = (fnf & ast::FNF_ASYNC) != 0;
        char[] fn_name = idx.tree.atoms.get(idx.tree.lhs.data[s.node]);

        if (is_restricted_name(fn_name, false, false, self.is_strict)) {
            return self.fail("reserved word cannot be used as a binding identifier")~;
        }
        bool already = false;
        for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
            if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
                already = true;
                break;
            }
        }
        if (already && self.is_module) {
            return self.fail("duplicate module-level function declaration")~;
        }
        if (!already) {
            self.ensure_hoisted_fn_cap();
            if (self.hoisted_fn_count < self.hoisted_fn_cap) {
                self.hoisted_fn_names[self.hoisted_fn_count] = fn_name;
                self.hoisted_fn_count++;
            }
        }
        if (checks_only) {
            if (!already && self.is_global && !self.is_module) {
                uint chk_idx = self.add_string_constant(fn_name);
                self.emit_a_bc(Opcode.CHKGLOBALFUNC, 0, chk_idx);
                self.record_declared_global(chk_idx);
            }
            continue;
        }
        bool saved_gen = self.is_generator;
        bool saved_user_gen = self.is_user_generator;
        bool gen_here;
        char[] fn_name2 = self.gen_name(idx.tree.lhs.data[s.node]);
        gen_here = (fnf & ast::FNF_GENERATOR) != 0;
        self.is_generator = gen_here;
        self.is_user_generator = gen_here;

        ushort func_reg = self.declare_var(fn_name2, VAR);
        self.has_local_bindings = true;

        bool saved_is_constructable = self.is_constructable;
        self.is_constructable = !self.is_generator && !hoist_is_async;

        self.is_async = hoist_is_async;
        CompiledFunction* inner = self.compile_inner_function(fn_name2, false, idx.tree.field(rec, ast::FN_SRC_START), ast_scope: idx.function_scope(s.decl))!;
        self.gen_line_end(s.decl);
        self.is_async = false;

        self.is_generator = saved_gen;
        self.is_user_generator = saved_user_gen;
        self.is_constructable = saved_is_constructable;

        uint inner_idx = self.add_inner_func(inner);
        if (self.is_module && self.current_module != null) {
            mod_register_func_decl(self.get_module_def(), fn_name2, inner_idx);
            self.free_reg(func_reg);
            continue;
        }

        if (self.is_module && self.current_module != null) {
            mod_register_func_decl(self.get_module_def(), fn_name2, inner_idx);
            self.free_reg(func_reg);
            continue;
        }

        self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
        uint name_idx = self.add_string_constant(fn_name2);
        self.emit_a_bc(Opcode.DECLGLOBALFUNC, (uint)func_reg, name_idx);
        self.free_reg(func_reg);
    }

    return true;
}

// Emit the parameter prologue: the function-level lexical scope, the TDZ
// sentinels, the default-value checks, and the PUTLEXes that make each param
// visible. Runs after the parameter list is parsed and every param has a
// register, and before the body, including before `emit_destruct_bindings`,
// since destructuring patterns may reference earlier params.
//
// `param_name_indices` holds each param's string-constant index in
// declaration order; `first_default_idx` is the 0-based arg index of the
// first defaulted param, or 0xFFFF when none has a default.
fn void? CompilerContext.emit_param_prologue(&self, ushort arg_count,
                                             ushort first_default_idx,
                                             uint[] param_name_indices) {
    // Push a function-level lexical scope for let/const at function top level.
    // This sits above the block-level PUSH_LEX emitted by block() so that
    // function-level let/const go into a scope that outlives inner blocks.
    // Skip when there are no default parameters (the only case that needs
    // a function-level scope distinct from the block scope).
    bool has_func_lex = self.defaults.len() > 0;
    if (has_func_lex) {
        self.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            // A destructured param binds its leaves itself, so it has no
            // name of its own to put in the TDZ.
            if (ni == NO_PARAM_NAME) continue;
            self.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ, they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            // Source register is the param's own slot (params occupy r0..rN in
            // declaration order); using r0 unconditionally would copy the first
            // param's value into every lex binding.
            if (ni != NO_PARAM_NAME) self.emit_a_bc(Opcode.PUTLEX, (uint)ai, ni);
            ai++;
        }
    }

    ushort published = first_default_idx;
    // Emit default parameter checks (must run before body, after PUSH_LEX)
    foreach (d : self.defaults) {
        ushort pr = d.param_reg;
        uint name_idx = d.param_name_idx;
        uint func_idx = d.default_func_idx;

        if (has_func_lex) {
            while (published < pr) {
                uint name = param_name_indices[published];
                if (name != NO_PARAM_NAME) self.emit_a_bc(Opcode.PUTLEX, (uint)published, name);
                published++;
            }
        }
        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        self.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = self.emit_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0);
        self.free_reg(cmp_reg);

        if (d.is_literal) {
            self.emit_a_bc(d.literal.op, (uint)pr, d.literal.get_bc());
        } else {
            // CLOSURE for default function
            ushort closure_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

            // Set up call: consecutive registers for callee + this
            ushort call_base = self.alloc_reg();
            if (self.next_reg <= call_base + 1) {
                self.next_reg = call_base + 2;
            }
            ushort this_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
            // A SuperCall default thunk is arrow-flagged and takes `this` from the
            // lexical capture, so the this slot is unused (see
            // compile_default_expr); every other thunk takes the receiver.
            Opcode this_op = self.inner_funcs[func_idx].is_arrow()
                ? Opcode.LDUNDEF : Opcode.LDTHIS;
            self.emit_abc(this_op, (uint)(call_base + 1), 0, 0);

            self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

            // Copy default result to parameter register.
            self.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

            self.free_regs_to(call_base);
        }

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        // This ensures PUTVAR runs for BOTH branches (argument passed or default used).
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to lex scope first (clears TDZ sentinel), then var_env.
        // GETVAR reloads from env in case PUTVAR cleared it.
        self.emit_a_bc(Opcode.PUTLEX, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
        published = pr + 1;
    }

    if (has_func_lex) {
        while (published < arg_count) {
            uint name = param_name_indices[published];
            if (name != NO_PARAM_NAME) self.emit_a_bc(Opcode.PUTLEX, (uint)published, name);
            published++;
        }
    }
}

// Whether any branch instruction in the freshly compiled body targets the
// fall-off-end position (code_count). Such a branch would advance curr_pc to
// code_end, which the VM does not guard against per-instruction, so the
// caller must append a terminating RETUNDEF to catch that path. Offset
// decoding mirrors moveelim's jump-target scan (the authoritative branch set).
fn bool CompilerContext.branch_targets_fall_off_end(&self) {
    uint n = self.code_count;
    for (uint i = 0; i < n; i++) {
        Instruction ins = self.code[i];
        int tgt = -1;
        switch (ins.op) {
            case Opcode.JUMP:
            case Opcode.BREAK:
            case Opcode.CONTINUE:
                tgt = (int)i + 1 + ins.get_sabc();
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE:
                tgt = (int)i + 1 + ins.get_sbc();
            case Opcode.JMP_NLT..Opcode.JMP_SNEQI:
                tgt = (int)i + 1 + (int)(ichar)ins.a;
            default:
                tgt = -1;
        }
        if (tgt == (int)n) return true;
    }
    return false;
}

// Record the default of parameter `param_reg`. A thunk that only loads a
// literal and returns it is replaced by that load, so the prologue neither
// creates a closure nor calls one. Any other thunk joins the inner functions.
fn void CompilerContext.push_param_default(&self, ushort param_reg, uint name_idx,
                                           CompiledFunction* thunk) {
    if (thunk.code_count == 2 && thunk.inner_count == 0
        && thunk.code[1].op == Opcode.RET && thunk.code[1].a == thunk.code[0].a
        && thunk.code[0].a == 0) {
        Instruction load = thunk.code[0];
        bool literal = false;
        switch (load.op) {
            case Opcode.LDINT:
            case Opcode.LDNULL:
            case Opcode.LDTRUE:
            case Opcode.LDFALSE:
            case Opcode.NEWOBJ:
            case Opcode.NEWARR:
                literal = true;
            case Opcode.LDCONST:
                TVal tv = thunk.constants[load.get_bc()];
                if (tv.is_string()) {
                    HString* hstr = (HString*)tv.get_heapptr();
                    load = bytecode::make_a_bc(Opcode.LDCONST, 0,
                                               self.add_string_constant(hstr.get_data()));
                    literal = true;
                } else if (tv.get_tag() == TValTag.NUMBER || tv.get_tag() == TValTag.FASTINT) {
                    load = bytecode::make_a_bc(Opcode.LDCONST, 0, self.add_constant(tv));
                    literal = true;
                }
            default:
                break;
        }
        if (literal) {
            self.defaults.push({
                .param_reg = param_reg,
                .param_name_idx = name_idx,
                .is_literal = true,
                .literal = load,
            });
            return;
        }
    }
    self.defaults.push({
        .param_reg = param_reg,
        .param_name_idx = name_idx,
        .default_func_idx = self.add_inner_func(thunk),
    });
}

// Compile a default parameter expression as a zero-argument inner function.
// Free variables in the expression are resolved at runtime via GETVAR
// against the outer scope's environment chain.
fn CompiledFunction*? CompilerContext.compile_default_expr(&self, char[] inferred_name = {}, uint ast_expr = 0) {
    // Create a new CompilerContext for the default expression
    CompilerContext def_ctx;
    def_ctx.init(self.lexer, self.heap);
    defer def_ctx.cleanup();
    // A with-env from the enclosing body is captured by this closure's scope
    // chain, so its name resolution stays dynamic (see in_with).
    def_ctx.outer_with = self.in_with();
    def_ctx.module_goal = self.module_goal;

    // Direct eval in a parameter default inherits the enclosing strictness.
    def_ctx.is_strict = self.is_strict;
    def_ctx.lexer.set_strict(self.is_strict);

    // Nested arrows and eval inherit the enclosing coroutine context.
    def_ctx.is_generator = self.is_generator;
    def_ctx.is_user_generator = self.is_user_generator;

    def_ctx.is_module = self.is_module;
    if (self.is_module) def_ctx.is_async = self.is_async;

    // Propagate class context (for super expressions)
    def_ctx.in_class_body = self.in_class_body;
    def_ctx.is_constructable = self.is_constructable;
    def_ctx.has_super_binding = self.has_super_binding;
    def_ctx.super_is_home_object = self.super_is_home_object;
    def_ctx.super_is_static_method = self.super_is_static_method;
    def_ctx.super_home_is_object_literal = self.super_home_is_object_literal;
    if (self.super_name_idx != 0xFFFFFFFF) {
        HString* super_hstr = (HString*)self.constants[self.super_name_idx].get_heapptr();
        def_ctx.super_name_idx = def_ctx.add_string_constant(super_hstr.get_data());
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        HString* static_super_hstr = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
        def_ctx.static_super_name_idx = def_ctx.add_string_constant(static_super_hstr.get_data());
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        HString* home_object_hstr = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
        def_ctx.home_object_name_idx = def_ctx.add_string_constant(home_object_hstr.get_data());
    }
    def_ctx.adopt_private_names(self);
    // A parameter default value is part of the enclosing function/arrow's
    // own definition site, not a nested function body it "crosses into".
    // ContainsAwait/ContainsArguments still apply here when the parameter
    // list itself sits directly inside a class static block (test262
    // static-init-await-reference, arrow-function variant: `((x = await)
    // => 0)` inside `static { }` is a SyntaxError).
    def_ctx.forbid_arguments = self.forbid_arguments;
    def_ctx.forbid_await = self.forbid_await;
    def_ctx.forbid_yield = self.forbid_yield;

    // A parameter default value sits in the enclosing function's
    // FormalParameters, and it is an early Syntax Error for FormalParameters to
    // Contain a YieldExpression (in a generator, ES2015 §14.1.2) or an
    // AwaitExpression (in an async function, ES2017 §14.7; also
    // CreateDynamicFunction steps for the Generator/AsyncGenerator/AsyncFunction
    // constructors). `yield`/`await` must still be reserved words here, which
    // is why is_generator/is_async are propagated above, but the yield/await
    // *expression* productions are unavailable, so forbid them.
    if (self.in_formal_params) {
        if (self.is_generator) def_ctx.forbid_yield = true;
        if (self.is_async)     def_ctx.forbid_await = true;
    }

    // Per ES2015 §13.3.3.7 step 3 (NamedEvaluation), if the default is an
    // anonymous function/arrow/class/generator expression, the resulting
    // function object gets the binding identifier as its name. We
    // propagate this via the inferred_name slot, `function_expr` /
    // arrow / class / generator consults `has_inferred_name` (set by
    // the var initializer path in `decl_var`) and tags the function.
    if (inferred_name.len > 0) {
        def_ctx.has_inferred_name = true;
        def_ctx.inferred_name = self.keep_name(inferred_name);
    }

    // Function-level lexical scope (empty, no parameters)
    def_ctx.emit_simple(Opcode.PUSH_LEX);

    // Compile expression with implicit return
    ushort expr_reg = def_ctx.gen_expr(ast_expr, 0)!.reg;
    def_ctx.gen_line_end(ast_expr);
    def_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);

    // Pop the function-level lexical scope
    def_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = def_ctx.finish()!;
    // A default expression is part of the enclosing function's definition
    // site, so a `super()` inside it must bind the enclosing derived
    // constructor's `this`, not construct a fresh one. When the thunk contains
    // a SuperCall, flag it as an arrow so instantiate_closure captures the
    // creating frame's `this` (registering a pending arrow while the
    // constructor has not run super() yet) and super_init_this_chain walks out
    // to that frame; the call sites then pass LDUNDEF for the this slot so the
    // uninitialized `this` is never read. Only SuperCall needs this: `super.x`
    // reads the home object through the captured scope, and `this` /
    // `new.target` are passed or captured independently. Flagging every
    // default thunk as an arrow instead changes direct-eval `arguments`
    // semantics, which key off the arrow's lexical-arguments rules.
    if (func.code != null) {
        for (uint ci = 0; ci < func.code_count; ci++) {
            Instruction ins = func.code[ci];
            if (ins.op == Opcode.SUPER_CALL || ins.op == Opcode.SUPER_CALL_S) {
                func.flags.is_arrow = true;
                break;
            }
            // A nested default thunk that itself contains a SuperCall (e.g.
            // `[x=[a=super()]=[]]`) is arrow-flagged already; this thunk runs
            // it, so it must be arrow too, or the LDTHIS at its call site would
            // read the constructor's uninitialized `this` before the nested
            // default could bind it. needs_lex_bridge distinguishes a nested
            // default thunk from an ordinary arrow expression, which manages
            // its own lexical `this` and does not require this thunk to.
            if (ins.op == Opcode.CLOSURE) {
                uint idx = ins.get_bc();
                if (idx < func.inner_count && func.inner_funcs[idx] != null
                    && func.inner_funcs[idx].is_arrow()
                    && func.inner_funcs[idx].needs_lex_bridge()) {
                    func.flags.is_arrow = true;
                    break;
                }
            }
        }
    }
    // A parameter default value is evaluated in the enclosing function's own
    // FormalParameters (ES2015 §9.2.12 FunctionDeclarationInstantiation step
    // 24), so `new.target` there is the enclosing function's. The thunk is a
    // real closure invoked by CALL, whose activation has no new.target of its
    // own, so it has to capture the creating frame's the way an arrow does.
    // eval_allows_new_target is unused on a body that is neither eval code nor
    // an arrow, and instantiate_closure reads it for exactly that purpose.
    func.flags.eval_allows_new_target = true;

    // Parameter defaults run synchronously through CALL.
    func.flags.is_generator = false;

    // If the default expression references 'arguments', clear the thunk's
    // flag (prevent VM from creating a thunk-specific arguments object that
    // shadows the parent's) and propagate to the enclosing function so the
    // VM creates the parent's arguments object.
    if (def_ctx.uses_arguments) {
        func.flags.uses_arguments = false;
        func.flags.mapped_arguments = false;
        self.uses_arguments = true;
    }

    // Default thunks need their parent's lex scope bridged into the
    // activation so TDZ sentinels for params are visible via GETVAR.
    func.flags.needs_lex_bridge = true;

    // Thunks access the enclosing bindings through their environment. Mark
    // these accesses as captures before deciding whether that environment
    // can be elided; a conservative mark only costs an environment slot.
    self.mark_default_expr_captures(func);

    return func;
}

// Mark each name a compiled default-expression thunk accesses by name as
// captured in the enclosing scope, so the binding is environment-backed and
// the thunk's reads and writes reach it.
fn void CompilerContext.mark_default_expr_captures(&self, CompiledFunction* func) {
    if (self.is_global || func == null || func.code == null) return;
    for (uint i = 0; i < func.code_count; i++) {
        Instruction ins = func.code[i];
        uint name_idx;
        switch (ins.op) {
            case Opcode.GETVAR:
            case Opcode.PUTVAR:
            case Opcode.PUTVAR_ASSIGN:
            case Opcode.RESOLVEVAR:
            case Opcode.TYPEOFIDENT:
                name_idx = ins.get_bc();
            default:
                continue;
        }
        if (name_idx >= func.const_count) continue;
        TVal kv = func.constants[name_idx];
        if (!kv.is_string()) continue;
        HString* hs = (HString*)kv.get_heapptr();
        if (hs == null) continue;
        self.add_captured_name(hs.get_data());
    }
    // Enclosing bindings are already declared, so publish their capture marks.
    for (uint i = 0; i < self.scope_depth; i++) {
        if (self.scope_stack[i].kind == SCOPEMARK) continue;
        if (!self.scope_stack[i].is_captured
            && self.is_captured_name(self.scope_stack[i].name)) {
            self.mark_scope_captured(i);
        }
    }
}

// Each static block needs its own var/lex scope and break/continue targets;
// sibling blocks and field initializers cannot see its declarations.
fn CompiledFunction*? CompilerContext.compile_static_block(&self, uint ast_node = 0) {
    CompilerContext block_ctx;
    block_ctx.init(self.lexer, self.heap);
    defer block_ctx.cleanup();
    // A with-env from the enclosing body is captured by this closure's scope
    // chain, so its name resolution stays dynamic (see in_with).
    block_ctx.outer_with = self.in_with();
    block_ctx.module_goal = self.module_goal;
    // A static block is class code, which is strict throughout (ES2024
    // §11.2.2) whatever the enclosing script's mode.
    block_ctx.is_strict = true;
    block_ctx.lexer.set_strict(true);
    // The lexer is shared with the caller, so put its strictness back on every
    // exit; a class in a sloppy script must not leave the rest of that script
    // tokenized as strict.
    defer self.lexer.set_strict(self.is_strict);
    block_ctx.in_class_body = self.in_class_body;
    block_ctx.has_super_binding = self.has_super_binding;
    block_ctx.super_is_home_object = self.super_is_home_object;
    // HomeObject for `super.x` inside a static block is always the class
    // constructor (ES2022 §15.7.11 EvaluateClassStaticBlockBody step 4
    // MakeMethod(body, F)), never the prototype, regardless of whether the
    // block sits among static or instance elements textually.
    block_ctx.super_is_static_method = true;
    if (self.super_name_idx != 0xFFFFFFFF) {
        HString* super_hstr = (HString*)self.constants[self.super_name_idx].get_heapptr();
        block_ctx.super_name_idx = block_ctx.add_string_constant(super_hstr.get_data());
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        HString* static_super_hstr = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
        block_ctx.static_super_name_idx = block_ctx.add_string_constant(static_super_hstr.get_data());
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        HString* home_object_hstr = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
        block_ctx.home_object_name_idx = block_ctx.add_string_constant(home_object_hstr.get_data());
    }
    // super() is forbidden (HasDirectSuper early error), same mechanism
    // field/static initializers use to reject it.
    block_ctx.is_constructable = false;
    // ClassStaticBlockStatementList is [~Yield, +Await, ~Return] and bans
    // `arguments` (ContainsArguments early error), all four gates are
    // fresh CompilerContext-local flags that do not propagate into nested
    // function/arrow bodies compiled from within the block.
    block_ctx.forbid_arguments = true;
    block_ctx.forbid_return = true;
    block_ctx.forbid_await = true;
    block_ctx.forbid_yield = true;
    block_ctx.adopt_private_names(self);

    // No parameter list to parse, go straight to the body, same shape as
    // compile_inner_function's zero-param tail.
    ast::AstIndex* idx = ast::index_state;
    uint scope = idx.res.scope_at(idx.tree.rhs.data[ast_node] + 1);
    block_ctx.index_captures_of(scope);
    block_ctx.apply_capture_set();
    block_ctx.hoist_decls_in(scope, false, false)!;
    block_ctx.reserved_regs = block_ctx.next_reg;
    block_ctx.gen_block(ast_node, true)!;

    bool has_return = false;
    if (block_ctx.code_count > 0) {
        Opcode last_op = block_ctx.code[block_ctx.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF) {
            has_return = true;
        }
    }
    if (has_return && block_ctx.branch_targets_fall_off_end()) {
        has_return = false;
    }
    if (!has_return) {
        block_ctx.emit_simple(Opcode.RETUNDEF);
    }

    CompiledFunction* func = block_ctx.finish()!;
    return func;
}

// Name the compiled function and retain its source text.
fn void attach_function_info(CompiledFunction* func, char[] name, bool is_named_expr, uint src_start,
                             uint inner_body_end_pos, bool is_async, char[] source) {
    // Set function name. The name parameter is a slice into compile-lifetime
    // storage; copy the bytes into a heap allocation that outlives the
    // compile, so each CompiledFunction holds its own stable copy of its name.
    if (name.len > 0) {
        char* name_heap = (char*)alloc::malloc_try(mem, (sz)((usz)name.len + 1)) ?? null;
        if (name_heap != null) {
            for (usz i = 0; i < (usz)name.len; i++) name_heap[i] = name[i];
            name_heap[name.len] = 0;
            func.name_ptr = name_heap;
            func.name_len = (uint)name.len;
            // Named function expression: tag so the VM creates a lexical
            // environment binding for `name` at call time (ES2015 §14.1.20).
            if (is_named_expr) {
                func.flags.is_namebinding = true;
            }
        }
    }

    // Retain a heap-owned copy of the function's source text so that
    // Function.prototype.toString can return the original source verbatim
    // (ES2019 §19.2.3.5). The caller passes the byte offset of the function's
    // opening token (`function` keyword, computed property `[`, arrow head,
    // etc.); `inner_body_end_pos` captures the position right after the
    // body's closing `}`, so the slice is exactly the function declaration.
    //
    // For `async function ...` the consumed `async` keyword is *before* the
    // byte offset we captured (we captured `function`), so we prepend the
    // literal "async " string to the retained source to match ES2019's source
    // text representation.
    if (src_start != 0xFFFFFFFF && src_start < (uint)source.len
        && inner_body_end_pos > src_start) {
        uint src_end = inner_body_end_pos;
        if (src_end > (uint)source.len) src_end = (uint)source.len;
        uint slen = src_end - src_start;
        // Only synthesize the "async " prefix when the captured span does not
        // already include it. Method shorthand (`async m(){}`) captures from the
        // `async` token, whereas `async function ...` captures from `function`
        // and needs the prefix prepended.
        bool span_has_async = slen >= 6
            && source[src_start] == 'a'
            && source[src_start + 1] == 's'
            && source[src_start + 2] == 'y'
            && source[src_start + 3] == 'n'
            && source[src_start + 4] == 'c'
            && source[src_start + 5] == ' ';
        bool needs_async_prefix = is_async && !span_has_async;
        usz alloc_len = (usz)slen + (needs_async_prefix ? (usz)6 : (usz)0);
        if (slen > 0) {
            char* src_heap = (char*)alloc::malloc_try(mem, (sz)((usz)alloc_len + 1)) ?? null;
            if (src_heap != null) {
                usz off = 0;
                if (needs_async_prefix) {
                    src_heap[off++] = 'a';
                    src_heap[off++] = 's';
                    src_heap[off++] = 'y';
                    src_heap[off++] = 'n';
                    src_heap[off++] = 'c';
                    src_heap[off++] = ' ';
                }
                for (usz i = 0; i < (usz)slen; i++) src_heap[off + i] = source[src_start + i];
                src_heap[off + (usz)slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = (uint)alloc_len;
            }
        }
    }
}

// Compile an inner function (parameters + body) into a sub-CompiledFunction.
// If `is_named_expr` is true and `name` is non-empty, tag the result with
// `is_namebinding`, so the VM binds `name` to the function object in a
// fresh lexical environment at call time (ES2015 §14.1.20 NamedEvaluation).
// `is_method_body` says the caller is compiling an object-literal or class
// MethodDefinition. That has two effects: the class/super/HomeObject context
// propagates into the body (see below), and the parameter list is checked as
// UniqueFormalParameters (ES2024 §14.3 / §15.4.5), which forbids duplicate
// names whatever the surrounding strictness.
fn CompiledFunction*? CompilerContext.compile_inner_function(&self, char[] name, bool is_named_expr = false, uint src_start = 0xFFFFFFFF, bool is_expr = false, bool is_method_body = false, uint ast_scope = 0, uint object_home = 0xFFFFFFFF) {
    // Create a new CompilerContext for the inner function
    CompilerContext inner_ctx;
    inner_ctx.init(self.lexer, self.heap);
    defer inner_ctx.cleanup();
    // A with-env from the enclosing body is captured by this closure's scope
    // chain, so its name resolution stays dynamic (see in_with).
    inner_ctx.outer_with = self.in_with();
    inner_ctx.module_goal = self.module_goal;

    inner_ctx.is_strict = self.is_strict;
    inner_ctx.lexer.set_strict(self.is_strict);
    // The lexer is shared with the caller, and a "use strict" prologue in this
    // body raises its strictness partway through. Put it back on every exit,
    // errors included, or the rest of an enclosing sloppy script is tokenized
    // as strict: `function f(){ "use strict"; } eval = 1;` would reject the
    // assignment.
    defer self.lexer.set_strict(self.is_strict);

    // Named function expression: the compiled function will be tagged
    // is_namebinding, so it must not take the needs_env=false fast path
    // (see is_named_func_expr doc in context.c3).
    inner_ctx.is_named_func_expr = is_named_expr && name.len > 0;
    if (inner_ctx.is_named_func_expr) inner_ctx.named_func_expr_name = name;

    // subst_global_this is gone (plans/083 phase 2); is_strict now carries
    // the dynamic-Function-or-not distinction implicitly through the same
    // directive mechanism as ordinary sloppy code.

    // Propagate generator flag: if the caller is compiling a generator,
    // the inner context (which parses the body) needs to know it's in a generator.
    inner_ctx.is_generator = self.is_generator;
    // Whether this function was written with a syntactic `*`. Distinguishes an
    // async generator (is_user_generator && is_async) from a plain async fn.
    inner_ctx.is_user_generator = self.is_user_generator;

    // Propagate async flag: if the caller is compiling an async function,
    // the inner context (which parses the body) needs to know it's in an async function.
    // Async functions (incl. async generators) also set is_generator so they can
    // use YIELD/LOAD_RESUME for suspend/resume via the AWAIT opcode.
    inner_ctx.is_async = self.is_async;
    if (inner_ctx.is_async) inner_ctx.is_generator = true;

    // Propagate class/super/HomeObject context ONLY into a method body
    // (is_method_body): a plain function expression/declaration -- even one
    // written lexically inside a class method or constructor -- creates a
    // fresh [[ThisMode]]/[[HomeObject]] boundary per spec (unlike an arrow
    // function, which shares the enclosing one via arrow_ctx, a separate
    // path). `super.x`/`super()`/`this.#x` inside such a nested plain
    // function must be a SyntaxError; leaving these fields at their
    // zero-init default (false / 0xFFFFFFFF) makes expressions.c3's
    // has_super_binding/in_class_body/super_is_home_object check reject it.
    // Each CompilerContext has its own constant pool, so a super_name_idx
    // from the outer context is not valid in the inner context.  Re-intern
    // the name string into the inner context's pool to get the correct index.
    //
    // is_constructable is NOT part of this gate: it is the general "is this
    // function usable with `new`" flag (also driving ordinary `new F()`),
    // set independently by each call site based on the function's own shape
    // (not generator, not async, etc.) BEFORE calling compile_inner_function
    // -- always propagate it as-is, method body or not. super() itself is
    // still correctly blocked by has_super_binding alone (both checks must
    // pass, see expressions.c3's super-call parse).
    inner_ctx.is_constructable = self.is_constructable;
    if (object_home != 0xFFFFFFFF) {
        inner_ctx.has_super_binding = true;
        inner_ctx.super_is_home_object = true;
        inner_ctx.super_home_is_object_literal = true;
        HString* home = (HString*)self.constants[object_home].get_heapptr();
        inner_ctx.super_name_idx = inner_ctx.add_string_constant(home.get_data());
    } else if (is_method_body) {
        inner_ctx.in_class_body = self.in_class_body;
        inner_ctx.has_super_binding = self.has_super_binding;
        inner_ctx.super_is_home_object = self.super_is_home_object;
        inner_ctx.super_is_static_method = self.super_is_static_method;
        inner_ctx.super_home_is_object_literal = self.super_home_is_object_literal;
        if (self.super_name_idx != 0xFFFFFFFF) {
            HString* super_hstr = (HString*)self.constants[self.super_name_idx].get_heapptr();
            inner_ctx.super_name_idx = inner_ctx.add_string_constant(super_hstr.get_data());
        } else {
            inner_ctx.super_name_idx = 0xFFFFFFFF;
        }
        if (self.static_super_name_idx != 0xFFFFFFFF) {
            HString* static_super_hstr = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
            inner_ctx.static_super_name_idx = inner_ctx.add_string_constant(static_super_hstr.get_data());
        } else {
            inner_ctx.static_super_name_idx = 0xFFFFFFFF;
        }
        if (self.home_object_name_idx != 0xFFFFFFFF) {
            HString* home_object_hstr = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
            inner_ctx.home_object_name_idx = inner_ctx.add_string_constant(home_object_hstr.get_data());
        } else {
            inner_ctx.home_object_name_idx = 0xFFFFFFFF;
        }
    } else {
        inner_ctx.in_class_body = false;
        inner_ctx.has_super_binding = false;
        inner_ctx.super_is_home_object = false;
        inner_ctx.super_is_static_method = false;
        inner_ctx.super_home_is_object_literal = false;
        inner_ctx.super_name_idx = 0xFFFFFFFF;
        inner_ctx.static_super_name_idx = 0xFFFFFFFF;
        inner_ctx.home_object_name_idx = 0xFFFFFFFF;
    }
    // Propagate private-name declarations (ES2022): a method/getter/setter
    // body compiled here must resolve `this.#x` against the enclosing class
    // body's declared names, resolve_private_name reads these fields
    // directly, so they must be copied (not just in_class_body).
    inner_ctx.adopt_private_names(self);

    ast::AstIndex* idx = ast::index_state;
    uint node = idx.res.scopes.data[ast_scope].node;
    uint end = idx.tree.field(idx.tree.rhs.data[node], ast::FN_SRC_END);
    inner_ctx.gen_function(ast_scope)!;
    CompiledFunction* func = inner_ctx.finish()!;
    attach_function_info(func, name, is_named_expr, src_start, end, inner_ctx.is_async, inner_ctx.lexer.source);
    return func;
}

// Arrows retain the enclosing this/super binding and eval restrictions. Constant-pool indices
// belong to one context, so their names are interned into the arrow's own pool.
fn void CompilerContext.init_arrow_context(&self, CompilerContext* arrow_ctx, bool is_async_arrow) {
    arrow_ctx.init(self.lexer, self.heap);
    arrow_ctx.outer_with = self.in_with();
    arrow_ctx.module_goal = self.module_goal;
    arrow_ctx.is_strict = self.is_strict;
    arrow_ctx.lexer.set_strict(self.is_strict);
    arrow_ctx.is_arrow = true;
    arrow_ctx.is_async = is_async_arrow;
    arrow_ctx.is_generator = is_async_arrow;
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;
    arrow_ctx.super_is_home_object = self.super_is_home_object;
    arrow_ctx.super_is_static_method = self.super_is_static_method;
    arrow_ctx.super_home_is_object_literal = self.super_home_is_object_literal;
    if (self.super_name_idx != 0xFFFFFFFF) {
        HString* name = (HString*)self.constants[self.super_name_idx].get_heapptr();
        arrow_ctx.super_name_idx = arrow_ctx.add_string_constant(name.get_data());
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        HString* name = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
        arrow_ctx.static_super_name_idx = arrow_ctx.add_string_constant(name.get_data());
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        HString* name = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
        arrow_ctx.home_object_name_idx = arrow_ctx.add_string_constant(name.get_data());
    }
    arrow_ctx.is_constructable = self.is_constructable;
    arrow_ctx.adopt_private_names(self);
    arrow_ctx.forbid_arguments = self.forbid_arguments;
    arrow_ctx.in_eval_code = self.in_eval_code;
    arrow_ctx.eval_direct_in_function = self.eval_direct_in_function;
    arrow_ctx.no_new_target = self.is_global || self.no_new_target;
}

// LOAD_RESUME replaces its operand with the fulfilled value; local homes must survive it.
fn ushort CompilerContext.emit_await(&self, ushort operand) {
    if (self.is_local_var_reg(operand)) {
        ushort result = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)result, (uint)operand, 0);
        operand = result;
    }
    self.emit_abc(Opcode.AWAIT, (uint)operand, 0, 0);
    self.emit_abc(Opcode.LOAD_RESUME, (uint)operand, 0, 0);
    return operand;
}
