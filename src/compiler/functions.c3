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
    while (names.len() <= (sz)idx) names.push(NO_PARAM_NAME);
    names.set((sz)idx, name_idx);
}

// A slice covering every arg index, including trailing destructured params
// that never recorded a name.
fn uint[] param_name_view(List{uint}* names, uint arg_count) {
    while (names.len() < (sz)arg_count) names.push(NO_PARAM_NAME);
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
    // The synthetic bind whose extracted value this iterator was opened on,
    // i.e. the nested pattern that owns it. 0xFFFF for the outermost pattern,
    // whose source is the destructuring input. The iterator is closed when the
    // last bind naming this owner as its parent has been emitted.
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
    // ASSIGN_TARGET only: the identifier is env-resident (not a reused local
    // register), so the emitter must PUTVAR by name, which runs the VM's
    // const-assignment check. Set by the assignment collectors rather than
    // guessed from register numbers, since a fresh temp can collide with
    // reserved low registers like r0.
    bool   assign_needs_putvar;
    // Persistent register holding the EnvRecord* RESOLVEVAR captured for this
    // binding's Reference, 0xFFFF when the store needs no captured env. Only a
    // by-name `var` inside a `with` sets it: the declaration's binding resolves
    // through the with-env, so ResolveBinding must run its `has` trap before the
    // value is read. Allocated in the emit pre-scan below every callee window.
    ushort resolve_probe_reg;
    // Private field target (this.#field). emit_destruct_bindings defers the
    // CHK_BRAND until after the source property is read (GetV).
    bool is_private_target;
    // Member target written as `super.x` / `super[k]`. The store must be
    // PUTPROP_SUPER, whose receiver is `this`, not the recorded base (PutValue
    // on a super Reference). member_obj_reg holds the home object's prototype,
    // and a setter found there runs with `this` as its receiver.
    bool is_super_target;
    // Brand register: the CHK_BRAND operand (the brand symbol) for private
    // targets. Set by emit_deferred_target.
    ushort private_brand_reg;
    // Constant-pool index for the private name in the deferred CHK_BRAND.
    uint private_brand_name_c;
    // Array rest into a member target (`[...o.r] = it`): the array the
    // collection loop initializes. The generic leaf path allocates bind_reg at
    // the watermark, which lands inside the iterator's next() callee window and
    // is clobbered on the first step. This register is allocated in the
    // pre-scan, below every such window, like the rest synthetics' group_regs.
    // 0xFFFF otherwise.
    ushort rest_array_reg;
    // Array rest's next output index. It survives the iterator's per-item
    // next() call, so the pre-scan allocates it below that call window.
    ushort rest_index_reg;
    // The deferred CHK_BRAND's object operand is member_obj_reg, a persistent
    // pre-scan copy of `this` that survives the source GETPROP (which may run a
    // getter). The parse-time temp from emit_private_access does not: a getter
    // call writes its `this` at [result_reg + 1] and can clobber it.
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
    return self.name_text((HString*)self.constants[b.name_idx].get_heapptr());
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

    // GetIterator step 3: check callability before the call, so a non-callable
    // @@iterator reports "not iterable" rather than the bare CALL's error.
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
    // IteratorBindingInitialization: once the iterator reports done:true, later
    // elements bind undefined without calling .next(), and the trailing
    // IteratorClose is skipped. [[done]] is encoded by clearing method_reg to
    // undefined (ITER_CLOSE no-ops on non-objects), so test it first.
    ushort exh_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDUNDEF, (uint)exh_reg, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)exh_reg, (uint)state.method_reg, (uint)exh_reg);
    uint exhausted_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)exh_reg);
    self.free_reg(exh_reg);

    // Fast path, the same fused step for-of uses: for a plain array iterator
    // with the builtin next method, this is a direct array read with no .next()
    // call and no result object. Anything else is refused and falls through to
    // the generic sequence. The handler relies on this layout: refusal lands on
    // the first JUMP, done on the second, a produced value on the third.
    self.emit_abc(Opcode.ITER_NEXT_FAST, (uint)dest_reg, (uint)state.method_reg, (uint)state.next_reg);
    uint to_slow_jump = self.emit_jump(Opcode.JUMP);
    uint fast_done_jump = self.emit_jump(Opcode.JUMP);
    uint fast_cont_jump = self.emit_jump(Opcode.JUMP);
    self.patch_jump(to_slow_jump);

    // Reload callee/this each call (generators may overwrite)
    self.emit_abc(Opcode.LDREG, (uint)state.callee_reg, (uint)state.next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)state.callee_this_reg, (uint)state.method_reg, 0);

    // Latch [[done]] across the protocol calls. A throw from .next() or from
    // reading .done/.value sets [[Done]] before rethrowing, so the enclosing
    // catch must not call IteratorClose. Park the iterator in save_reg and
    // restore it only after a successful not-done step.
    self.emit_abc(Opcode.LDREG, (uint)state.save_reg, (uint)state.method_reg, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);

    // Call .next() → result
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)state.callee_reg, 0);

    // IteratorNext: the value returned by .next() must be an object. Otherwise
    // a primitive step reads .done as undefined and a rest loop never ends.
    self.emit_abc(Opcode.CHKOBJ, (uint)result_reg, 0, 0);

    // IteratorStep reads `.done` first and reads `.value` (IteratorValue) only
    // when not done. The order is observable when either is an accessor: a
    // `.value` getter must not run when the iterator reports done:true.
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

    // Exhausted: bind undefined.
    self.patch_jump(exhausted_jump);
    self.emit_abc(Opcode.LDUNDEF, (uint)dest_reg, 0, 0);
    // Just became done: IteratorStep returns false without reading .value.
    self.patch_jump(mark_jump);
    // Fast path done: bind undefined and latch method_reg, which skips the
    // trailing IteratorClose. The fast path never latches it itself.
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

    // IteratorNext: a non-object step is a TypeError.
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
// `owner` is the synthetic bind whose extracted value `src_reg` holds, i.e. the
// nested pattern this iterator belongs to; 0xFFFF means the outermost pattern.
// close_finished_iter uses it to close each pattern's iterator when it ends.
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

// An ArrayBindingPattern closes its iterator as soon as the pattern is finished,
// before the enclosing pattern takes its next step.
//
// Emitting bind `di` can finish several patterns at once, when it is the last
// bind of each: `[[[a]]]` finishes the inner, middle and outer patterns at `a`.
// Walk the ancestor chain outwards from `di`, closing innermost first.
//
// The outermost pattern's iterator is left to the shared finally, since closing
// it here would run before whatever follows the destructuring.
//
// Clearing method_reg makes the finally's second close a no-op, the same
// [[done]] encoding that exhaustion uses.
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
                        constant_idx = self.add_string_constant_hstr(string_value);
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

// Emit object-rest collection into dest_reg: `dest = CopyDataProperties(src,
// excludedNames)`, where excludedNames holds every sibling explicit key of the
// rest bind (ECMA-262 CopyDataProperties). `binds` is the full pattern; `rest_di`
// is the rest bind. Siblings share its parent_idx.
fn void? CompilerContext.emit_object_rest(&self,
    ushort dest_reg, ushort src_reg,
    DestructBind[] binds, uint rest_di)
{
    ushort parent = binds[rest_di].parent_idx;

    // Build excludedNames: one property key per explicit sibling, coerced up front.
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
            // TOPROPKEY is idempotent, so this is safe even if
            // emit_deferred_computed_key already coerced the key.
            self.emit_abc(Opcode.TOPROPKEY, (uint)binds[j].computed_key_reg, 0, 0);
            elem_reg = binds[j].computed_key_reg;
        } else {
            elem_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)elem_reg, binds[j].key_idx);
        }
        ushort idx_reg = self.alloc_reg();
        self.emit_load_index((uint)idx_reg, (uint)excl_count);
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

fn bool CompilerContext.can_fast_flat_array(&self,
    DestructBind[] binds, bool disable_array_fast, bool has_rest)
{
    uint count = (uint)binds.len;
    if (disable_array_fast || count == 0 || count > (has_rest ? 65 : 64)
        || self.in_with() || self.eval_mode) return false;

    ushort source = binds[0].arg_idx;
    ushort first_binding = binds[0].binding_reg;
    if (first_binding == 0xFFFF) return false;
    for (uint i = 0; i < count; i++) {
        DestructBind bind = binds[i];
        bool is_rest = has_rest && i + 1 == count;
        if (bind.is_object || bind.is_synthetic || bind.is_hole
            || bind.is_empty_pattern || bind.has_default
            || bind.is_member_target || bind.is_computed_key
            || bind.ast_target != 0 || bind.ast_key != 0
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
        && self.can_fast_flat_array(binds, disable_array_fast, true)) {
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

    // The VM guards iterator identity and observability before extracting the
    // flat pattern. Parameter slices arrive in source order from the AST.
    bool flat_param_fast = store_mode == PARAM_SYNC
        && !self.has_rest && !self.ast_param_scope
        && !self.is_async && !self.is_user_generator
        && binds[0].arg_idx < self.num_args;
    if (((store_mode == DECLARE && is_lexical) || flat_param_fast)
        && self.can_fast_flat_array(binds, disable_array_fast, false)) {
        self.emit_abc(Opcode.DESTRUCT_ARRAY_FAST, (uint)binds[0].arg_idx,
                      (uint)binds[0].binding_reg, count);
        uint slow_jump = self.emit_jump(Opcode.JUMP);
        foreach (bind : binds) {
            if (store_mode == PARAM_SYNC) {
                self.emit_a_bc(Opcode.PUTVAR, (uint)bind.binding_reg, bind.name_idx);
                self.emit_a_bc(Opcode.GETVAR, (uint)bind.binding_reg, bind.name_idx);
            } else {
                self.emit_var_store(bind.binding_reg, bind.name_idx, true, is_const);
            }
        }
        uint done_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(slow_jump);
        self.emit_destruct_bindings(binds, store_mode, is_lexical, is_const, true)!;
        self.patch_jump(done_jump);
        return;
    }

    // Each array pattern opens at most one iterator, so a pattern needs no
    // more states than it has binds.
    DestructIterState[] iter_states = mem::new_array(DestructIterState, (sz)count);
    defer mem::free(iter_states);
    uint iter_count = 0;

    // Pre-scan: allocate persistent registers before any iterator setup. Rest
    // group_regs must sit below callee_reg to survive the per-iteration CALL
    // frame (see plan 042/043). Also note whether any array binds exist, which
    // decides the IteratorClose TRY guard.
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
            // Persistent slot for a possible private-field brand symbol. It is
            // unknown yet whether the target is `this.#x`, but the register must
            // be allocated now, below the source GETPROP's result register: a
            // getter run during that read writes its callee/this at
            // [result_reg, result_reg + 1] and could clobber it. Freed if the
            // target is not private.
            binds[di].private_brand_reg = self.alloc_persistent_reg();
        }
        if (binds[di].ast_key != 0) {
            // Stable register for a deferred computed key's evaluated value:
            // allocated below every callee window so it survives the GETPROP
            // reads and any nested-pattern CALLs up to point of use.
            binds[di].computed_key_reg = self.alloc_persistent_reg();
        }
        // A by-name `var` in a `with` captures its Reference's env before the
        // value is read, and the store happens after the default thunk's CALL,
        // so the probe must sit below that call's callee window. PUTVAR_SNAP
        // packs the env register into one byte. A probe that does not fit falls
        // back to DECLVAR and loses only the `has` trap ordering. Object leaves
        // only: the array branch extracts straight into bind_reg, which the
        // probe's shadowing temporary would clobber.
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
        if (!binds[di].is_object) {
            has_array_binds = true;
        }
    }

    // IteratorClose on abrupt completion: wrap array destructuring in a TRY, so
    // a throw during lref evaluation, default-value evaluation or IteratorStep
    // reaches a catch that calls iterator.return() before rethrowing.
    // iter_try_addr is the placeholder TRY, followed by its finally slot. It is
    // 0xFFFFFFFF when there are no array binds (no guard needed).
    uint iter_try_addr = 0xFFFFFFFF;
    if (has_array_binds) {
        iter_try_addr = self.emit_a_bc(Opcode.TRY, 0, 0);
        self.emit_a_bc(Opcode.NOP, 0, 0);
    }

    for (uint di = 0; di < count; di++) {
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
            // Walk earlier binds for the highest consumed index of this source
            // register (0 if none). A register-indexed table would be wasteful,
            // since registers span up to MAX_REGISTERS.
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

        // Empty pattern: GetIterator here, and IteratorClose by the close pass
        // at the end of this iteration.
        if (binds[di].is_empty_pattern) {
            self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                    iter_states, &iter_count);
        } else if (binds[di].is_hole) {
            // Elision: advance the iterator once and bind nothing. Per
            // IteratorBindingInitialization, each elision calls IteratorStep and
            // propagates abrupt completions.
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
                self.set_branch(skip_addr, Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
            }

            // REQUIRE_OBJ, TypeError if null/undefined nested target.
            // Skip for rest synthetics (always an array).
            if (binds[di].key_idx != 0xFFFF) {
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)group_reg, 0, 0);
            }
        } else {
            // Leaf binding, a real variable. Member targets (ASSIGN_TARGET) pass
            // 0xFFFF rather than a pre-allocated register. A getter's call frame
            // starts at GETPROP's result register and reuses everything above it,
            // so bind_reg must sit above every live persistent register, including
            // those the pre-scan allocated. Allocate it fresh here.
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

            // A by-name `var` in a `with` stores through the Reference that
            // ResolveBinding created. GetIdentifierReference runs the with
            // object's `has` trap before GetV reads the source property, and the
            // store re-enters that same env (ECMA-262 InitializeReferencedBinding).
            // RESOLVEVAR captures the owning EnvRecord* into a persistent register
            // below every callee window (see the pre-scan), and the store becomes
            // PUTVAR_SNAP. It is emitted per branch, after the property name is
            // evaluated, since PropertyBindingInitialization runs before
            // KeyedBindingInitialization's ResolveBinding. The value is extracted
            // into a register above the probe: GETPROP's accessor frame reuses
            // everything above its result register and would destroy the probe.
            // The register must stay high for the whole bind. Retargeting the
            // GETPROP to a low register (moveelim's producer retarget) would move
            // the getter's frame back over the probe.
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
                    // KeyedDestructuringAssignmentEvaluation evaluates the target lref, then
                    // GetV's the source property, then PutValues. So the deferred
                    // target runs before GETPROP. The deferred CHK_BRAND for a private
                    // target runs at PutValue time in the ASSIGN_TARGET switch below,
                    // not here, or it would run twice.
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
                    // IteratorClose on the open iterator (ECMA-262
                    // DestructuringAssignmentEvaluation).
                    if (binds[di].ast_target != 0) {
                        self.emit_deferred_target(&binds[di])!;
                    }

                    self.emit_destruct_iter_rest(bind_reg,
                        binds[di].rest_index_reg, &iter_states[iter_idx]);
                } else {
                    // Array pattern: use iterator protocol
                    ushort iter_idx = self.open_destruct_iter(src_reg, binds[di].parent_idx,
                                                              iter_states, &iter_count);
                    // The deferred member target is evaluated before IteratorStep.
                    // A throw here must IteratorClose the already-open iterator.
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
                self.set_branch(skip_addr, Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
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
                    // Member targets (e.g. [obj.x] = v) use PUTPROP rather than
                    // PUTVAR. The deferred target was already emitted before
                    // IteratorStep, so only the store is left. A private member's
                    // brand check was deferred and runs after the value is extracted
                    // into bind_reg (see emit_deferred_target, which sets is_private_target).
                    if (binds[di].is_member_target) {
                        if (binds[di].is_private_target) {
                            // Use member_obj_reg (the pre-scan copy of `this`), not the
                            // parse-time temp from emit_private_access. A getter run while
                            // reading the source writes its `this` at [result_reg + 1] and
                            // can clobber a temp captured before the copy was made.
                            self.emit_abc(Opcode.CHK_BRAND,
                                (uint)binds[di].member_obj_reg,
                                (uint)binds[di].private_brand_reg,
                                binds[di].private_brand_name_c);
                            self.free_reg(binds[di].private_brand_reg);
                        }
                        // A `super.x` target stores through PUTPROP_SUPER:
                        // member_obj_reg holds the home object's prototype,
                        // where the walk starts, but a setter found there runs
                        // with the current `this` as its receiver (PutValue on a
                        // super Reference), and a new data property lands there too.
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
    // IteratorClose must run on every abrupt completion, not only throw: also
    // return (a generator .return() resuming a yield inside a target lref, as in
    // `[...{}[yield]]`) and break/continue. So the guard is a try/FINALLY. The
    // finally runs ITER_CLOSE for each iterator, and ENDFINALLY re-dispatches
    // the pending completion. The normal path runs the finally too, which closes
    // a partially consumed iterator, so no separate close is needed.
    if (iter_try_addr != 0xFFFFFFFF && iter_count > 0) {
        // Normal path: end the try region, then fall through to the finally.
        // (The jump slot's finally offset also routes abrupt completions here.)
        self.emit_simple(Opcode.ENDTRY);

        // FINALLY block, entered on normal completion (fall-through) and on any
        // abrupt completion (via the catcher's finally_pc).
        uint finally_target = self.code_count;
        self.emit_simple(Opcode.FINALLY);
        for (uint i = 0; i < iter_count; i++) {
            // B=2: auto-detect the completion type. Suppress .return() errors only
            // for a pending throw (IteratorClose). A return completion, e.g. a
            // generator .return() through a yield here, must propagate them.
            self.emit_abc(Opcode.ITER_CLOSE, (uint)iter_states[i].method_reg, 2, 0);
        }
        self.emit_simple(Opcode.ENDFINALLY);

        // Patch TRY: flags = finally (bit 1). Jump slot BC = finally offset.
        self.set_try(iter_try_addr, 2, 0, finally_target - iter_try_addr);
    } else if (iter_try_addr != 0xFFFFFFFF) {
        // No iterator was opened, so the guard only needs an empty finally.
        self.emit_simple(Opcode.ENDTRY);
        uint finally_target_e = self.code_count;
        self.emit_simple(Opcode.FINALLY);
        self.emit_simple(Opcode.ENDFINALLY);
        self.set_try(iter_try_addr, 2, 0, finally_target_e - iter_try_addr);
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
// Eval code only: record the name in eval_var_coll_idxs, so var_declaration can
// tell that a re-declared `var x;` is already instantiated and skip its
// DECLVAR_HOIST. That hoist would re-create a binding the body's `delete x;`
// removed (EvalDeclarationInstantiation).
fn void CompilerContext.record_eval_var_name(&self, char[] raw_name) {
    HString* hs = ((Heap*)self.heap).str_intern(raw_name);
    uint ni = self.add_string_constant_hstr(hs);
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
    char[] var_name = self.name_text(var_hstr);
    // A var whose name is a parameter is NOT re-initialized: only names absent
    // from parameterNames get `undefined` (FunctionDeclarationInstantiation), so
    // the argument survives `function f(p){ if (false) { var p = 1; } return p; }`.
    // The parameter's binding is already the var binding, so emit neither LDUNDEF
    // nor a declaration.
    if (self.is_param_name(var_name)) {
        self.has_local_bindings = true;
        return;
    }
    // A var whose name is also a FunctionDeclaration is NOT re-initialized
    // either. GlobalDeclarationInstantiation and FunctionDeclarationInstantiation
    // leave function-declared names alone, so the hoisted function survives
    // `function f(){} var f;` in any order. LDUNDEF plus DECLVAR_HOIST would
    // clobber it, and the var's register would shadow the env binding. Function
    // declarations are hoisted before this pass, so hoisted_fn_names is populated.
    if (self.is_hoisted_fn(var_name)) {
        self.has_local_bindings = true;
        return;
    }
    // `var arguments` in an ordinary (non-arrow) function declares no binding:
    // FunctionDeclarationInstantiation binds "arguments" to the arguments object
    // created at call entry, and `var arguments = v` only assigns to it. So the
    // name makes the function need that object, as a reference would. The hoist
    // stub below is still emitted (reads resolve through the environment), and
    // the VM skips it once the object exists.
    bool uses_args_object = !is_global && !self.is_arrow && str_eq(var_name, "arguments");
    if (uses_args_object) {
        self.uses_arguments = true;
    }
    // One binding per name. If the B.3.3 scan reaches a block first, a later
    // `var f` reuses that entry (var_declaration's find_local_reg). If `var f`
    // comes first, declaring again would allocate a second register: the
    // capture-marking loop marks the first while DECLGLOBALFUNC writes the
    // second, so env reads see undefined. A formal parameter's entry doubles as
    // the var binding, so reuse it. A block-scoped entry is not the var binding,
    // so an exempt block must still declare it. Only a VAR or parameter entry
    // proves the binding exists.
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
    // block() may withdraw a B.3.3 entry init when the block is exempt (a
    // same-named `let` is visible, or a formal or arguments). It then NOPs this
    // DECLVAR_HOIST and erases the scope entry. The instruction index is recorded
    // by name for that.
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
    // The list is not cleared: function_declaration reads it to skip those
    // declarations, all of which are reached after this runs. The flag stops a
    // nested block from repeating the emission.
    self.hoisted_defer_emitted = true;
    // Emit in REVERSE order. EvalDeclarationInstantiation walks varDeclarations
    // in reverse for the CanDeclareGlobalFunction check, which throws a TypeError
    // on a non-definable name (e.g. `function NaN(){}`). Doing it at runtime in
    // this order aborts the eval before earlier declarations reach the global env.
    for (ushort di = (ushort)(self.hoisted_defer_count); di > 0; di--) {
        ushort idx = (ushort)(di - 1);
        self.emit_a_bc(Opcode.CLOSURE, (uint)self.hoisted_defer_regs[idx],
                       self.hoisted_defer_inner_idxs[idx]);
        // Use DECLGLOBALFUNC, not DECLVAR, so the binding gets function-declaration
        // attributes: inside a function body it is non-configurable (so sloppy
        // `delete f` returns false), and on the global object the descriptor
        // follows CreateGlobalFunctionBinding.
        self.emit_a_bc(Opcode.DECLGLOBALFUNC, (uint)self.hoisted_defer_regs[idx],
                       self.hoisted_defer_name_idxs[idx]);
    }
}

// The same for a scope the caller already holds.
fn void? CompilerContext.hoist_decls_in(&self, uint scope, bool is_global, bool checks_only) {
    Token saved_token = self.lexer.current;
    defer self.lexer.current = saved_token;
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
                    if (self.is_hoisted_fn(name)) {
                        return self.fail("module-level function declaration cannot share a name with a var declaration")~;
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

    bool already = !self.add_hoisted_fn(fn_name);
    if (already) {
        // A duplicate: the later declaration wins, so only the last one is compiled and instantiated.
        bool dup_known = false;
        for (uint di = 0; di < self.hoisted_defer_count; di++) {
            if (str_eq(self.hoisted_defer_names[di], fn_name)) {
                dup_known = true;
                break;
            }
        }
        if (!dup_known) {
            self.ensure_hoisted_defer_cap();
            if (self.hoisted_defer_count < self.hoisted_defer_cap) {
                HString* dup_hstr = ((Heap*)self.heap).str_intern(fn_name);
                self.hoisted_defer_names[self.hoisted_defer_count] = self.name_text(dup_hstr);
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
    for (uint di = 0; di < self.hoisted_defer_count; di++) {
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
    Token saved_token = self.lexer.current;
    defer self.lexer.current = saved_token;
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
        bool already = !self.add_hoisted_fn(fn_name);
        if (already && self.is_module) {
            return self.fail("duplicate module-level function declaration")~;
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
    // Function-level lexical scope, above the block-level PUSH_LEX from block().
    // Only needed with default parameters, so skipped otherwise.
    bool has_func_lex = self.defaults.len() > 0;
    if (has_func_lex) {
        self.emit_simple(Opcode.PUSH_LEX);

        // TDZ: each param starts as a sentinel until its default check completes
        // (defaulted) or it becomes visible (plain).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            // A destructured param binds its leaves itself, so it has no
            // name of its own to put in the TDZ.
            if (ni == NO_PARAM_NAME) continue;
            self.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // PUTLEX for pre-default params, which their arguments already initialize.
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

        uint skip_addr = self.emit_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0);
        self.free_reg(cmp_reg);

        if (d.ast_expr != 0) {
            ushort saved_reg = self.next_reg;
            Val value = self.gen_expr(d.ast_expr, 0)!;
            self.emit_abc(Opcode.LDREG, (uint)pr, (uint)value.reg, 0);
            self.free_regs_to(saved_reg);
        } else if (d.is_literal) {
            self.emit_a_bc(d.literal.op, (uint)pr, d.literal.get_bc());
        } else {
            ushort closure_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

            // Set up call: consecutive registers for callee + this
            ushort call_base = self.alloc_reg();
            if (self.next_reg <= call_base + 1) {
                self.next_reg = call_base + 2;
            }
            ushort this_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
            // A SuperCall default thunk is arrow-flagged and reads `this` from its
            // lexical capture (see compile_default_expr), so this_reg is unused.
            // Other thunks take the receiver.
            Opcode this_op = self.inner_funcs[func_idx].is_arrow()
                ? Opcode.LDUNDEF : Opcode.LDTHIS;
            self.emit_abc(this_op, (uint)(call_base + 1), 0, 0);

            self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

            // Copy default result to parameter register.
            self.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

            self.free_regs_to(call_base);
        }

        // Patch the skip jump to land before the PUTVAR, so the store runs on
        // both branches (argument passed or default used).
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.set_branch(skip_addr, Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

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
    foreach (far : self.far_offsets) {
        if (far.target == n && self.code[far.addr].op != Opcode.TRY) return true;
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
                                               self.add_string_constant_hstr(hstr));
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
        def_ctx.super_name_idx = def_ctx.add_string_constant_hstr(super_hstr);
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        HString* static_super_hstr = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
        def_ctx.static_super_name_idx = def_ctx.add_string_constant_hstr(static_super_hstr);
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        HString* home_object_hstr = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
        def_ctx.home_object_name_idx = def_ctx.add_string_constant_hstr(home_object_hstr);
    }
    def_ctx.adopt_private_names(self);
    // A parameter default belongs to the enclosing function's definition, not to
    // a nested body. ContainsAwait and ContainsArguments still apply when the
    // parameter list sits directly in a class static block (test262
    // static-init-await-reference).
    def_ctx.forbid_arguments = self.forbid_arguments;
    def_ctx.forbid_await = self.forbid_await;
    def_ctx.forbid_yield = self.forbid_yield;

    // A default sits in the enclosing FormalParameters, where a YieldExpression
    // (generators) or AwaitExpression (async functions) is an early error. yield
    // and await stay reserved words, so is_generator/is_async are propagated
    // above, but their expression forms are forbidden here.
    if (self.in_formal_params) {
        if (self.is_generator) def_ctx.forbid_yield = true;
        if (self.is_async)     def_ctx.forbid_await = true;
    }

    // NamedEvaluation: an anonymous function, arrow, class or generator default
    // takes the binding identifier as its name. The name travels in
    // inferred_name, and the expression path reads has_inferred_name (set by
    // decl_var's initializer path).
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
    // A default belongs to the enclosing function's definition, so a `super()` in
    // it binds the enclosing derived constructor's `this`. A thunk containing a
    // SuperCall is flagged as an arrow: instantiate_closure captures the creating
    // frame's `this`, and super_init_this_chain walks out to that frame. Call
    // sites pass LDUNDEF for the this slot, so the uninitialized `this` is never
    // read. Only SuperCall needs this. `super.x` reads the home object through the
    // captured scope, and `this`/`new.target` are passed or captured separately.
    // Flagging every thunk would change direct-eval `arguments` semantics.
    if (func.code != null) {
        for (uint ci = 0; ci < func.code_count; ci++) {
            Instruction ins = func.code[ci];
            if (ins.op == Opcode.SUPER_CALL || ins.op == Opcode.SUPER_CALL_S) {
                func.flags.is_arrow = true;
                break;
            }
            // A nested default thunk containing a SuperCall (e.g.
            // `[x=[a=super()]=[]]`) is already arrow-flagged. This thunk runs it,
            // so it must be an arrow too, or LDTHIS here reads the uninitialized
            // `this`. needs_lex_bridge tells such a thunk apart from an ordinary
            // arrow, which manages its own `this`.
            if (ins.op == Opcode.CLOSURE) {
                uint idx = bytecode::code_bc(func.code, ci);
                if (idx < func.inner_count && func.inner_funcs[idx] != null
                    && func.inner_funcs[idx].is_arrow()
                    && func.inner_funcs[idx].needs_lex_bridge()) {
                    func.flags.is_arrow = true;
                    break;
                }
            }
        }
    }
    // A parameter default is evaluated in the enclosing FormalParameters
    // (FunctionDeclarationInstantiation), so `new.target` there is the enclosing
    // function's. The thunk is a real closure called through CALL, with no
    // new.target of its own, so it captures the creating frame's as an arrow
    // does. eval_allows_new_target is unused on a body that is neither eval code
    // nor an arrow, and instantiate_closure reads it for this purpose.
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
                name_idx = bytecode::code_bc(func.code, i);
            default:
                continue;
        }
        if (name_idx >= func.const_count) continue;
        TVal kv = func.constants[name_idx];
        if (!kv.is_string()) continue;
        HString* hs = (HString*)kv.get_heapptr();
        if (hs == null) continue;
        self.add_captured_name(self.name_text(hs));
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
    // A static block is class code, so it is strict whatever the enclosing
    // script's mode.
    block_ctx.is_strict = true;
    block_ctx.lexer.set_strict(true);
    // The lexer is shared with the caller, so put its strictness back on every
    // exit; a class in a sloppy script must not leave the rest of that script
    // tokenized as strict.
    defer self.lexer.set_strict(self.is_strict);
    block_ctx.in_class_body = self.in_class_body;
    block_ctx.has_super_binding = self.has_super_binding;
    block_ctx.super_is_home_object = self.super_is_home_object;
    // HomeObject for `super.x` in a static block is always the class constructor
    // (MakeMethod in EvaluateClassStaticBlockBody), never the prototype, even if
    // the block sits among instance elements.
    block_ctx.super_is_static_method = true;
    if (self.super_name_idx != 0xFFFFFFFF) {
        HString* super_hstr = (HString*)self.constants[self.super_name_idx].get_heapptr();
        block_ctx.super_name_idx = block_ctx.add_string_constant_hstr(super_hstr);
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        HString* static_super_hstr = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
        block_ctx.static_super_name_idx = block_ctx.add_string_constant_hstr(static_super_hstr);
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        HString* home_object_hstr = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
        block_ctx.home_object_name_idx = block_ctx.add_string_constant_hstr(home_object_hstr);
    }
    // super() is forbidden (HasDirectSuper early error), same mechanism
    // field/static initializers use to reject it.
    block_ctx.is_constructable = false;
    // ClassStaticBlockStatementList forbids `arguments`, return, await and yield.
    // These gates are per-context and do not propagate into nested function bodies.
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
    // `name` is a slice into compile-lifetime storage, so copy it to the heap.
    if (name.len > 0) {
        char* name_heap = (char*)alloc::malloc_try(mem, (sz)((usz)name.len + 1)) ?? null;
        if (name_heap != null) {
            for (usz i = 0; i < (usz)name.len; i++) name_heap[i] = name[i];
            name_heap[name.len] = 0;
            func.name_ptr = name_heap;
            func.name_len = (uint)name.len;
            // Named function expression: the VM creates a binding for `name` at
            // call time (InstantiateOrdinaryFunctionExpression).
            if (is_named_expr) {
                func.flags.is_namebinding = true;
            }
        }
    }

    // Keep a heap copy of the source text, so Function.prototype.toString returns
    // it verbatim. src_start is the function's opening token (`function`,
    // computed `[`, arrow head, ...). inner_body_end_pos is just past the body's
    // closing `}`. The `async` keyword of `async function` precedes src_start,
    // so the literal "async " is prepended.
    if (src_start != 0xFFFFFFFF && src_start < (uint)source.len
        && inner_body_end_pos > src_start) {
        uint src_end = inner_body_end_pos;
        if (src_end > (uint)source.len) src_end = (uint)source.len;
        uint slen = src_end - src_start;
        // Method shorthand (`async m(){}`) already captures `async`. Only add the
        // prefix when the span lacks it.
        bool span_has_async = slen >= 6
            && source[src_start] == 'a'
            && source[src_start + 1] == 's'
            && source[src_start + 2] == 'y'
            && source[src_start + 3] == 'n'
            && source[src_start + 4] == 'c'
            && source[src_start + 5] == ' ';
        bool needs_async_prefix = is_async && !span_has_async;
        usz alloc_len = (usz)slen + (needs_async_prefix ? (usz)6 : (usz)0);
        if (slen > 0 && !needs_async_prefix && ast::index_state != null
            && ast::index_state.share_source(source) != null) {
            func.src_buf = ast::index_state.src_buf;
            func.src_ptr = func.src_buf.data + src_start;
            func.src_len = slen;
        } else if (slen > 0) {
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
// `is_namebinding`, so the VM binds `name` to the function object in a fresh
// lexical environment at call time. `is_method_body` says the caller is
// compiling an object-literal or class MethodDefinition. That propagates the
// class/super/HomeObject context into the body (see below), and checks the
// parameter list as UniqueFormalParameters, which forbids duplicate names
// whatever the strictness.
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

    // Generator state: the body parses as a generator if the caller is one.
    // is_user_generator is set only for a written `*`, which tells an async
    // generator from a plain async function.
    inner_ctx.is_generator = self.is_generator;
    inner_ctx.is_user_generator = self.is_user_generator;

    // Async functions set is_generator too, so AWAIT suspends and resumes like a yield.
    inner_ctx.is_async = self.is_async;
    if (inner_ctx.is_async) inner_ctx.is_generator = true;

    // Class/super/HomeObject context propagates only into a method body. A plain
    // function, even one nested in a method, starts a fresh [[ThisMode]] and
    // [[HomeObject]] boundary (an arrow shares the enclosing one via arrow_ctx).
    // Leaving these fields at their zero defaults makes `super.x`, `super()` and
    // `this.#x` a SyntaxError there. Each CompilerContext has its own constant
    // pool, so super names are re-interned into the inner pool.
    //
    // is_constructable is propagated in every case. Each call site sets it from
    // the function's shape before this call, and super() is still blocked by
    // has_super_binding.
    inner_ctx.is_constructable = self.is_constructable;
    if (object_home != 0xFFFFFFFF) {
        inner_ctx.has_super_binding = true;
        inner_ctx.super_is_home_object = true;
        inner_ctx.super_home_is_object_literal = true;
        HString* home = (HString*)self.constants[object_home].get_heapptr();
        inner_ctx.super_name_idx = inner_ctx.add_string_constant_hstr(home);
    } else if (is_method_body) {
        inner_ctx.in_class_body = self.in_class_body;
        inner_ctx.has_super_binding = self.has_super_binding;
        inner_ctx.super_is_home_object = self.super_is_home_object;
        inner_ctx.super_is_static_method = self.super_is_static_method;
        inner_ctx.super_home_is_object_literal = self.super_home_is_object_literal;
        if (self.super_name_idx != 0xFFFFFFFF) {
            HString* super_hstr = (HString*)self.constants[self.super_name_idx].get_heapptr();
            inner_ctx.super_name_idx = inner_ctx.add_string_constant_hstr(super_hstr);
        } else {
            inner_ctx.super_name_idx = 0xFFFFFFFF;
        }
        if (self.static_super_name_idx != 0xFFFFFFFF) {
            HString* static_super_hstr = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
            inner_ctx.static_super_name_idx = inner_ctx.add_string_constant_hstr(static_super_hstr);
        } else {
            inner_ctx.static_super_name_idx = 0xFFFFFFFF;
        }
        if (self.home_object_name_idx != 0xFFFFFFFF) {
            HString* home_object_hstr = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
            inner_ctx.home_object_name_idx = inner_ctx.add_string_constant_hstr(home_object_hstr);
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
    // A method body must resolve `this.#x` against the enclosing class body's
    // private names. resolve_private_name reads these fields directly, so they
    // are copied, not just in_class_body.
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
        arrow_ctx.super_name_idx = arrow_ctx.add_string_constant_hstr(name);
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        HString* name = (HString*)self.constants[self.static_super_name_idx].get_heapptr();
        arrow_ctx.static_super_name_idx = arrow_ctx.add_string_constant_hstr(name);
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        HString* name = (HString*)self.constants[self.home_object_name_idx].get_heapptr();
        arrow_ctx.home_object_name_idx = arrow_ctx.add_string_constant_hstr(name);
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
