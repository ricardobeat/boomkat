module boomkat::vm;

import boomkat::types;
import boomkat::hbigint;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::esm;
import boomkat::compiler;
import boomkat::re_bindings;
import boomkat::jit;
import std::io;
import std::math;

// Relocate the saved VM stack pointers after a nested run grows the value
// stack. ensure_valstack_grow updates the suspended caller segments while
// they are published to the collector.
fn void relocate_saved_frames(Vm* vm, TVal* saved_valstack, TVal** saved_bottom,
                              TVal** saved_top) {
    long reloc = (long)((char*)vm.valstack - (char*)saved_valstack);
    if (reloc == 0) return;
    *saved_bottom = (TVal*)((char*)*saved_bottom + reloc);
    *saved_top = (TVal*)((char*)*saved_top + reloc);
}

// Set up a named-function-expression's name binding environment.
// Returns a fresh declarative env with `name_hstr` bound immutably to
// `func_obj`, chained above `parent`. Per ECMA-262 §14.1.20/§9.2.13, the
// name binding lives in an environment OUTER to the function's own body
// scope, so a body `var`, `let`, or parameter of the same name shadows it, and
// callers splice this env onto the body scope's parent chain rather than
// making it the search head directly.
fn EnvRecord*? setup_named_function_expr_env(Vm* vm, EnvRecord* parent,
                                              HString* name_hstr,
                                              HObject* func_obj) {
    EnvRecord*? name_env_raw = env::env_create_declarative(vm.heap, parent);
    if (catch err = name_env_raw) return types::ALLOC_ERROR~;
    EnvRecord* name_env = name_env_raw;
    TVal func_tv; func_tv.set_object(func_obj);
    // CreateImmutableBinding(N, false) (ECMA-262 §15.2.5 step 5): the fnexpr
    // name is immutable with strict=false regardless of the body's mode. The
    // immut_nonstrict bit tells PUTVAR_ASSIGN's -4 branch to consult the
    // ASSIGNING code's strictness: sloppy silently drops, strict throws.
    // Plain const bindings (also PROP_FLAGS_EC, no bit) always throw.
    hobject::PropFlags name_flags = hobject::PROP_FLAGS_EC;
    name_flags.immut_nonstrict = true;
    name_env.bindings.put_prop((void*)name_hstr, func_tv, name_flags, vm.heap);
    return name_env;
}

// Resolve the lexical environment for entering a compiled-function call frame.
// Closures created inside a PUSH_LEX block scope capture that declarative env
// in func.lex_env; the frame must enter with it as lex_env so the block's
// let/const bindings stay visible (GETVAR walks lex_env, then var_env).
// Named function expressions additionally get a fresh declarative env binding
// their own name (ECMA-262 §14.1.20), chained above the captured scope.
fn EnvRecord* resolve_call_lex_env(Vm* vm, HObject* func_obj,
                                   CompiledFunction* target, EnvRecord* var_env) {
    EnvRecord* base = var_env;
    EnvRecord* cap_lex = (*func_obj.extra_ptr()).func.lex_env;
    if (cap_lex != null && cap_lex != var_env && cap_lex.flags.is_declarative) {
        // The closure was created inside a PUSH_LEX block (or a class body), so
        // its lexical bindings live in `cap_lex`. When the callee owns a fresh
        // function scope of its own, since needs_env is set: it declares `arguments`,
        // closures, or captured locals), those own bindings (parameters/locals)
        // live in `var_env`, whose natural parent is the captured function
        // var_env (`own_var_env`).
        //
        // If `cap_lex`'s parent chain itself descends to `own_var_env`, the
        // fresh scope can be reparented under `cap_lex` so its own bindings
        // resolve first, then the enclosing block's, and `own_var_env` stays
        // reachable through `cap_lex`, a single lexical chain whose search head is
        // var_env). Skip this for functions with a default/rest-parameter lex
        // bridge (that path installs its own lex_env below and reparenting
        // would risk a cycle) and when `var_env` is already on `cap_lex`'s
        // chain. Only a scope freshly allocated for THIS call is safe to
        // reparent; never mutate the shared captured `func.var_env` (reused
        // directly by needs_env=false callees, which would corrupt every future
        // call).
        //
        // When `cap_lex` does NOT reach `own_var_env` (they are lexical
        // siblings sharing a common ancestor, such as the global DeclarativeRecord
        // captured alongside a sibling function/constructor scope), reparenting
        // would sever `var_env` from `own_var_env` and lose the captured
        // parameters. Instead, enter with `cap_lex` as the lexical search head
        // and leave `var_env`'s parent intact: GETVAR walks lex_env (`cap_lex`)
        // first and falls back to var_env (`var_env` → `own_var_env`), so both
        // the block/class lexicals and the captured parameters remain visible.
        EnvRecord* own_var_env = (*func_obj.extra_ptr()).func.var_env;
        bool splice = var_env.flags.is_function_scope
            && var_env != own_var_env
            && !target.needs_lex_bridge();
        bool cap_reaches_own = false;
        if (splice) {
            EnvRecord* w = cap_lex;
            uint depth = 0;
            while (w != null && depth < 256) {
                if (w == var_env) { splice = false; break; }
                if (w == own_var_env) { cap_reaches_own = true; }
                w = w.parent;
                depth++;
            }
        }
        if (splice && cap_reaches_own) {
            var_env.parent = cap_lex;
            base = var_env;
        } else {
            base = cap_lex;
        }
    }
    if (target.is_namebinding()) {
        // The name binding must be OUTER to the function's own body scope
        // (ECMA-262 §14.1.20 NamedEvaluation / §9.2.13), so a body var/let/param
        // named the same as the function shadows it. `is_namebinding` is only
        // ever set on functions with needs_env()==true (register-resident
        // callees resolve their own name to a register at compile time and
        // never observe this env at all), so `var_env` here is always a fresh
        // scope allocated for this call, so it is safe to splice into.
        char[] name_data = target.get_name();
        HString* name_hstr = intern_string(vm, name_data);
        if (name_hstr != null) {
            if (try name_env = setup_named_function_expr_env(vm, var_env.parent, name_hstr, func_obj)) {
                var_env.parent = name_env;
                if (base == var_env) return var_env;
                // `base`, meaning cap_lex, does not reach var_env directly, so GETVAR's
                // lex_env walk finds cap_lex's chain first, then falls back to
                // a separate walk starting at var_env (see the `!found &&
                // lex_env != var_env` fallback), which now reaches name_env
                // right after var_env's own bindings.
                return base;
            }
        }
    }
    return base;
}

// ECMA-262 SetMutableBinding (global object environment record), step 5: when
// the binding is not an own property, the store is
// `Set(bindings, N, V, S)`, an ordinary [[Set]] with the global object as the
// receiver. That walks the global's PROTOTYPE CHAIN, so a setter or a Proxy
// `set` trap installed there runs and sees the global as its receiver
// (staging/sm/Proxy/global-receiver.js). A direct env_put would define an own
// property and skip the chain entirely.
//
// Returns false only when a trap threw; the caller then propagates. A falsish
// trap result is a silent drop in sloppy code.
fn bool vm_global_bareword_store(Vm* vm, void* key, TVal val, bool* set_ok = null) {
    if (vm.global_env == null) return true;
    HObject* gobj = vm.global_env.bindings;
    if (gobj == null) { env::env_put(vm.global_env, key, val); return true; }
    TVal recv; recv.set_object(gobj);
    bool sres = true;
    if (!builtins::js_set_with_receiver(vm, vm.heap, gobj, (HString*)key, val, recv, &sres)) {
        return false;
    }
    if (set_ok != null) *set_ok = sres;
    return true;
}

// Write half of global_proto_lookup (vm_calls.c3): a name the env walk missed
// can still be bound through the global object's PROTOTYPE chain, because
// HasBinding on the global object record is HasProperty (§9.1.1.4.2), and its
// SetMutableBinding step 5 is Set(bindings, N, V, S) (§9.1.1.4.5), which runs
// a prototype setter or Proxy `set` trap with the global as receiver.
//
// 1 when the name resolved and the store ran, 0 when the global object does
// not have it (the reference is unresolvable), -1 when a trap threw.
fn int vm_global_proto_store(Vm* vm, void* key, TVal val) {
    if (vm.global_env == null || vm.global_env.bindings == null) return 0;
    HObject* gobj = vm.global_env.bindings;
    if (!gobj.has_prop_proto(key, vm.heap)) {
        if (vm.heap.has_error) { vm.heap.has_error = false; return -1; }
        return 0;
    }
    bool ok = true;
    if (!vm_global_bareword_store(vm, key, val, &ok)) return -1;
    return ok ? 1 : 2;
}

// PutValue (§6.2.5.6 step 5) for a bare name the environment chain did not
// bind. Sloppy code creates the implicit global (Annex B.3.2). Strict code
// still resolves through the global object's PROTOTYPE chain, because
// HasBinding on the global object record is HasProperty (§9.1.1.4.2): a
// name found there stores through [[Set]], an absent one is a ReferenceError,
// and a refused [[Set]] is a TypeError (§9.1.1.4.5 step 5).
//
// 1 when stored, 0 when a throw was initiated, -1 when it could not be raised
// and the run must stop.
fn int vm_bareword_put(Vm* vm, Dispatch* ds, void* key, TVal val) {
    bool strict = ds.act.func != null && ((CompiledFunction*)ds.act.func).is_strict();
    if (strict) {
        int gres = vm_global_proto_store(vm, key, val);
        if (gres == 1) return 1;
        if (gres < 0) {
            TVal err = vm.heap.error_value;
            vm.heap.has_error = false;
            if (!vm_throw_value(vm, err, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                (void)vm_uncaught_error(vm, &err);
                return -1;
            }
            return 0;
        }
        HString* name = (HString*)key;
        bool raised = gres == 2
            ? vm_throw_error_fmt_str(vm, vm.heap.type_err_proto,
                "Cannot assign to read only property '%s'", name,
                ds.act, &ds.curr_pc, &ds.needs_restart)
            : vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto,
                "'%s' is not defined", name, ds.act, &ds.curr_pc, &ds.needs_restart);
        return raised ? 0 : -1;
    }
    if (!vm_global_bareword_store(vm, key, val)) {
        TVal err = vm.heap.error_value;
        vm.heap.has_error = false;
        if (!vm_throw_value(vm, err, ds.act, &ds.curr_pc, &ds.needs_restart)) {
            (void)vm_uncaught_error(vm, &err);
            return -1;
        }
        return 0;
    }
    return 1;
}

// OrdinaryHasInstance(rfunc, obj) when rfunc inherits the intrinsic
// @@hasInstance and its `prototype` is an object data property, the
// conditions th_instanceof re-checks; false leaves the general path to run.
fn bool instanceof_default(Vm* vm, HObject* rfunc, HObject* obj, TVal* ra) {
    heap::Heap* h = vm.heap;
    if (!rfunc.is_callable() || rfunc.flags.is_bound || rfunc.is_proxy() || h.hasinstance_symbol == null) return false;
    hobject::PropLookupResult hi = rfunc.get_prop_or_accessor_proto((void*)h.hasinstance_symbol, true, h);
    if (hi.kind != hobject::PropLookupKind.PROP_DATA || hi.owner != h.function_proto) return false;
    hobject::PropLookupResult pr = rfunc.get_prop_or_accessor_proto((void*)h.strs[heap::BuiltinStr.PROTOTYPE], true, h);
    if (pr.kind != hobject::PropLookupKind.PROP_DATA || !pr.data_val.is_object()) return false;
    HObject* probe = (HObject*)pr.data_val.get_heapptr();
    bool found = false;
    HObject* cur = obj;
    for (uint depth = 0; depth < hobject::MAX_PROTO_DEPTH; depth++) {
        if (cur.is_proxy()) return false;
        cur = cur.prototype;
        if (cur == null) break;
        if (cur == probe) { found = true; break; }
    }
    h.set_reg_boolean(ra, found);
    return true;
}
// OrdinaryHasInstance chain walk. Prototype hops go through [[GetPrototypeOf]]
// when a Proxy is on the chain. Sets ra to true on match. Returns false when an
// uncaught error unwinds.
fn bool instanceof_walk_chain(Vm* vm, Dispatch* ds, HObject* start, HObject* probe, TVal* ra) {
    HObject* cur = start;
    uint depth = 0;
    // The walk starts at O.[[GetPrototypeOf]](), never at the left operand:
    // comparing it first would make `C.prototype instanceof C` true.
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        if (cur.is_proxy()) {
            TVal next;
            if (!builtins::proxy_mop_get_proto(vm, vm.heap, cur, &next)) {
                TVal werr = vm.heap.error_value;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, werr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    vm.heap.tval_copy_ref(&vm.return_val, &werr);
                    vm.has_error = true;
                    vm.heap.has_error = true;
                    return false;
                }
                return true;
            }
            cur = next.is_object() ? (HObject*)next.get_heapptr() : null;
        } else {
            cur = cur.prototype;
        }
        depth++;
        if (cur == probe) { vm.heap.set_reg_boolean(ra, true); return true; }
    }
    return true;
}

// True when another nested Vm.run would exceed MAX_RUN_DEPTH; raises a
// RangeError on the has_error channel when it does.
//
// Recursion that bounces through a native builtin (a Proxy trap, a sort
// comparator, a Symbol.toPrimitive) re-enters the VM here rather than pushing
// an activation, so MAX_CALLS never sees it. Every level still consumes native
// stack, for the save area and for the builtin's own frame, so without this
// the stack faults before anything throws.
//
// The throw is raised on every channel: vm.has_error / heap.has_error /
// heap.error_value, which every native caller of vm_call_fn_impl polls after
// the call returns, and vm.throw_pending, which the coercion paths
// (vm_to_number and the builtins reached through it) test instead -- a depth
// throw raised only on has_error is invisible to those, so they read the NaN
// result as a value and coerce again, continuing the recursion this guard
// exists to stop. vm_throw_value retires all three once a catcher takes the
// throw, so none of them survives the unwind into the catch body.
// Minimum size for ordinary concat accumulation. A short result can also
// reserve space when a following ADD appends to it, looking at most
// CONCAT_RESERVE_SCAN instructions ahead.
const uint CONCAT_ACCUM_MIN = 32;
const uint CONCAT_RESERVE_SCAN = 3;

// A two-owner accumulator may change only when the other owner is the
// writable data binding that the immediately following instruction replaces.
// Inspect the slot without invoking accessors or with/unscopables hooks: RHS
// coercion can replace the binding and leave an unrelated alias as owner two.
fn bool concat_binding_owns(Vm* vm, Activation* act, HString* value,
                           uint reg_idx, Instruction* store) @private {
    if (store == null || store.a != reg_idx || act.func == null) return false;
    CompiledFunction* func = (CompiledFunction*)act.func;
    EnvRecord* owner = act.lex_env;
    uint name_idx;
    bool snapshot = false;
    switch (store.op) {
        case Opcode.PUTVAR_SNAP:
            snapshot = true;
            if ((uint)store.b >= func.num_regs) return false;
            TVal reference = act.bottom[store.b];
            if (!reference.is_envref()) return false;
            owner = (EnvRecord*)reference.get_heapptr();
            name_idx = store.c;
        case Opcode.PUTGLOBAL:
        case Opcode.PUTVAR:
        case Opcode.PUTVAR_ASSIGN:
            name_idx = store.get_bc();
        default:
            return false;
    }
    if (name_idx >= func.const_count) return false;
    TVal key = func.constants[name_idx];
    if (!key.is_string()) return false;
    while (owner != null) {
        if (owner.is_with() || owner.bindings == null
            || owner.bindings.is_proxy()) return false;
        HObject* bindings = owner.bindings;
        int idx = bindings.find_prop_idx(key.get_heapptr(), vm.heap);
        if (idx >= 0) {
            hobject::PropFlags flags = bindings.get_prop_flags((uint)idx, vm.heap);
            if (!flags.writable || flags.is_accessor) return false;
            TVal bound = bindings.prop_values()[idx].get();
            return bound.is_string() && bound.get_heapptr() == (void*)value;
        }
        // A snapshot names the resolved owner. A missing slot cannot prove
        // ownership by any outer binding after RHS side effects.
        if (snapshot) return false;
        owner = owner.parent;
    }
    return false;
}

// True when a slot of `act`'s register span other than `ra` holds `s`. The
// span is the one the collector and the zero-count flush read for the frame.
fn bool concat_frame_holds_elsewhere(Vm* vm, Activation* act, TVal* ra, HString* s) @private {
    usz index = (usz)(act - vm.activations);
    if (index >= vm.activation_count) return true;
    TVal* end = activation_span_end(vm, (uint)index);
    for (TVal* tv = act.bottom; tv < end; tv++) {
        if (tv != ra && tv.is_string() && tv.get_heapptr() == (void*)s) return true;
    }
    return false;
}

// Only the destination register and its proven write-back binding may own a
// mutable accumulator. Registers hold no counts, so the proof is: no counted
// holder (count 0, or 1 when it is the binding the next instruction
// replaces); the string was born by the concat path into this register of
// this frame instance (Heap.accum_birth_matches); and no other slot of the
// frame's span holds it. A frame below cannot hold a string born here with
// no count: it would have had to come down as a return (which pops this
// instance), through a counted holder (count above 0), or through a mapped
// arguments write (which forgets the birth). A frame above cannot be live
// while this one runs. A generator that yielded it was resumed as a new
// instance, so the serial no longer matches. Interned strings, symbols,
// native temporary roots and overlapping tails retain immutable-copy
// semantics. The result stays non-interned; property-key consumers
// canonicalize it with ensure_interned.
fn bool vm_concat_accumulate(Vm* vm, Activation* act, TVal* ra, TVal* rb,
                             HString* ls, Units tail, uint reg_idx,
                             bytecode::Instruction* next_insn) {
    if (ra != rb) return false;
    if (ls.length < CONCAT_ACCUM_MIN && ls.capacity <= ls.byte_len()) return false;
    if (ls.flags.is_interned || ls.flags.is_symbol) return false;
    if (((types::HeapHeader*)ls).is_temproot()) return false;
    if (!ra.is_string() || ra.get_heapptr() != (void*)ls) return false;

    uint rc_val = ((types::HeapHeader*)ls).refcount;
    if (rc_val != 0 && (rc_val != 1
        || !concat_binding_owns(vm, act, ls, reg_idx, next_insn))) return false;
    if (!vm.heap.accum_birth_matches(ls, reg_idx, act.serial)) return false;
    if (concat_frame_holds_elsewhere(vm, act, ra, ls)) return false;
    // Appending a slice of the accumulator's own buffer would read the units
    // the append is concurrently writing, and growing would leave `tail`
    // dangling at the old allocation. `s += s` is the reachable case; the
    // check is on the buffer range so it also rejects any partial overlap.
    char* ls_data = ls.data_ptr();
    if (tail.ptr >= ls_data && tail.ptr < ls_data + ls.capacity) return false;

    if (ls.try_append_in_place(tail)) return true;

    // Geometric growth keeps the total copied prefix units linear in the
    // final string size. The new width is the wider of the two.
    bool wide = ls.is_wide() || tail.wide;
    ulong need = (ulong)ls.length + (ulong)tail.len;
    ulong want = (ulong)ls.capacity * 2 >> (ls.is_wide() ? 1 : 0);
    if (want < need) { want = need; }
    if (hstring::length_exceeds_max(want)) { want = need; }
    if (hstring::length_exceeds_max(want)) return false;

    // The empty tail only gives the allocation its width.
    Units shape = { .ptr = null, .len = 0, .wide = wide };
    HString* grown = vm.heap.alloc_concat_string_parts(ls.units(), shape, (uint)want);
    if (grown == null) return false;
    if (!grown.try_append_in_place(tail)) {
        // Cannot happen: the capacity was sized for exactly this append. Drop
        // the allocation, which no one references yet, and let the generic path
        // produce the result.
        vm.heap.large_string_unregister(grown);
        vm.heap.free_string(grown);
        return false;
    }

    // The register takes the grown buffer. An owning binding releases its
    // old buffer when the following store replaces it.
    vm.heap.set_reg_string(ra, grown);
    vm.heap.accum_birth_set(grown, reg_idx, act.serial);
    track_heap_store(act, ra, reg_idx);
    return true;
}

// A short intermediate can reserve space when a following ADD consumes it as
// its left operand, as in `a + b + c`. The right operand's load may sit between
// the two ADDs, so the scan steps over loads into other registers. Skip
// WIDE-prefixed instructions; missing this optimization is safe, while decoding
// a partial operand pair is not.
fn bool concat_next_add_uses_left(Instruction* next, Instruction* code_end, uint result_reg) @inline {
    for (uint i = 0; i < CONCAT_RESERVE_SCAN; i++) {
        if (next == null || next >= code_end || next.op == Opcode.WIDE) return false;
        switch (next.op) {
            case Opcode.ADD:
            case Opcode.ADDI:
                return (uint)next.b == result_reg;
            case Opcode.GETGLOBAL:
            case Opcode.GETVAR:
            case Opcode.LDCONST:
            case Opcode.LDINT:
            case Opcode.LDREG:
                if ((uint)next.a == result_reg) return false;
                next++;
            default:
                return false;
        }
    }
    return false;
}

// Concatenation values need no canonical identity until used as property keys.
// Reserve growth space only for the accumulator shape; other results hold
// exactly their content and defer hashing until a consumer needs it.
fn HString* vm_concat_birth_parts(Vm* vm, TVal* ra, TVal* rb,
                                  Units left, Units right, uint len,
                                  bool reserve_for_next_add = false,
                                  HString* left_string = null, HString* right_string = null) {
    ulong cap = (ulong)len;
    if ((ra == rb && len >= CONCAT_ACCUM_MIN) || reserve_for_next_add) {
        cap *= 2;
        if (hstring::length_exceeds_max(cap)) { cap = (ulong)len; }
    }
    return vm.heap.alloc_concat_string_parts(left, right, (uint)cap, left_string, right_string);
}

enum ConcatStatus : char { DONE, TOO_LONG, NOT_APPLICABLE }

// The string a `+` operand holds when it is a plain one: a symbol shares the
// STRING tag but must throw instead of concatenating (ECMA-262 §7.1.1).
fn HString* plain_string_of(TVal* v) @inline {
    if (!v.is_string()) return null;
    HString* s = (HString*)v.get_heapptr();
    return s != null && !s.is_symbol() ? s : null;
}

// Concatenation owes the same RangeError wherever it overflows. Returns false
// when the error could not be raised and the run must stop.
fn bool vm_concat_overflow(Vm* vm, Dispatch* ds) {
    return vm_throw_error(vm, vm.heap.range_err_proto, "Invalid string length",
                          ds.act, &ds.curr_pc, &ds.needs_restart);
}

// Last resort when the concat string cannot be allocated directly: build the
// units in a scratch buffer and intern them.
fn HString* vm_concat_interned(Vm* vm, Units left, Units right, uint total) @noinline {
    bool wide = left.wide || right.wide;
    usz bytes = (usz)total << (wide ? 1 : 0);
    char[512] stack_buf;
    char* buf = &stack_buf;
    if (bytes > stack_buf.len) {
        buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, bytes);
        if (buf == null) return null;
    }
    hstring::copy_units(buf, wide, left);
    hstring::copy_units(buf + ((usz)left.len << (wide ? 1 : 0)), wide, right);
    HString* result = vm.heap.str_intern_units({ .ptr = buf, .len = total, .wide = wide });
    if (bytes > stack_buf.len) vm.heap.free_func(vm.heap.heap_udata, buf);
    return result;
}

// ra = left + right as string concatenation. `acc` is the left operand's
// string, or null when the left operand is not one that could be an
// accumulator. The result stays non-interned and refcounted, so it needs
// register tracking: heap_reg_count must cover it for the frame teardown to
// release the reference.
fn ConcatStatus vm_concat(Vm* vm, Activation* act, TVal* ra, TVal* rb, HString* acc,
                          Units left, Units right, uint reg_idx,
                          Instruction* next, Instruction* code_end, HString* right_string = null) {
    // The cap bounds each length well below 2^32, so the sum cannot wrap, but
    // it can land past the cap, which must surface as a RangeError rather than
    // a failed allocation returning a null string.
    ulong total64 = (ulong)left.len + (ulong)right.len;
    if (hstring::length_exceeds_max(total64)) return ConcatStatus.TOO_LONG;
    uint total = (uint)total64;
    // `acc += chunk` in a loop extends the accumulator in place instead of
    // copying it whole each time, which is what makes the naive form quadratic.
    if (acc != null && vm_concat_accumulate(vm, act, ra, rb, acc, right, reg_idx, next)) {
        return ConcatStatus.DONE;
    }
    bool reserve = concat_next_add_uses_left(next, code_end, reg_idx);
    HString* result = vm_concat_birth_parts(vm, ra, rb, left, right, total, reserve, acc, right_string);
    if (result == null) result = vm_concat_interned(vm, left, right, total);
    if (result == null) {
        vm.heap.set_reg_undefined(ra);
        return ConcatStatus.DONE;
    }
    vm.heap.set_reg_string(ra, result);
    if (!result.flags.is_interned) vm.heap.accum_birth_set(result, reg_idx, act.serial);
    track_heap_store(act, ra, reg_idx);
    return ConcatStatus.DONE;
}

// The `+` operand pairs that concatenate without coercion: string + string,
// string + int and int + string. The digits are formatted straight into the
// concat buffer, so no HString exists for the integer. Only the string-first
// order can accumulate: int + string prepends, which is not an append into
// the accumulator's spare capacity. Anything else leaves the registers
// untouched and answers NOT_APPLICABLE.
fn ConcatStatus vm_concat_add(Vm* vm, Activation* act, TVal* ra, TVal* rb, TVal* rc,
                              uint reg_idx, Instruction* next, Instruction* code_end) @noinline {
    HString* ls = plain_string_of(rb);
    HString* rs = plain_string_of(rc);
    if (ls != null && rs != null) {
        HString* cached = vm.heap.cached_concat_string(ls, rs);
        if (cached != null) {
            vm.heap.set_reg_string(ra, cached);
            track_heap_store(act, ra, reg_idx);
            return ConcatStatus.DONE;
        }
        return vm_concat(vm, act, ra, rb, ls, ls.units(), rs.units(), reg_idx, next, code_end, rs);
    }
    char[32] buf;
    if (ls != null && rc.is_fastint()) {
        int n = hstring::int_to_buf(rc.get_fastint(), &buf, buf.len);
        if (n <= 0) return ConcatStatus.NOT_APPLICABLE;
        return vm_concat(vm, act, ra, rb, ls, ls.units(), hstring::narrow_units(buf[:n]), reg_idx, next, code_end);
    }
    if (rs != null && rb.is_fastint()) {
        int n = hstring::int_to_buf(rb.get_fastint(), &buf, buf.len);
        if (n <= 0) return ConcatStatus.NOT_APPLICABLE;
        return vm_concat(vm, act, ra, rb, null, hstring::narrow_units(buf[:n]), rs.units(), reg_idx, next, code_end);
    }
    return ConcatStatus.NOT_APPLICABLE;
}

// Raise `message` as an error of class `proto` on every channel a host call
// can be observed through. The coercion paths (vm_to_number and the builtins
// reached through it) test throw_pending, not has_error, so an error raised
// on only one channel is invisible to them: they read the result as a value
// and carry on.
fn void vm_host_throw(Vm* vm, HObject* proto, String message) {
    TVal err;
    err.set_undefined();
    if (try object = vm_create_error(vm, proto, message)) err.set_object(object);
    vm.has_error = true;
    vm.heap.has_error = true;
    vm.heap.tval_copy_ref(&vm.heap.error_value, &err);
    vm.heap.tval_copy_ref(&vm.return_val, &err);
    vm.throw_pending = true;
    vm.heap.tval_copy_ref(&vm.throw_value, &err);
}

fn bool vm_run_depth_exceeded(Vm* vm) @inline {
    if (vm.run_depth < MAX_RUN_DEPTH && vm.activation_count < vm.activation_capacity) return false;
    return vm_run_depth_throw(vm);
}

fn bool vm_run_depth_throw(Vm* vm) @noinline {
    vm_host_throw(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded");
    return true;
}

// The compiled function behind a callee that a host call can enter through
// vm_call_lean, or null. Lean excludes class constructors, so a callee that
// passes needs none of the bound, class and builtin dispatch checks.
fn CompiledFunction* lean_callee(HObject* fobj, TVal this_val) @inline {
    if (!fobj.is_callable() || fobj.callable_kind() != hobject::CallableKind.COMPILED_FN) return null;
    hobject::HObjectFunction* fd = &(*fobj.extra_ptr()).func;
    CompiledFunction* target = fd.comp_func;
    if (target == null) return null;
    target.classify_lean_call();
    if (!target.call_flags.lean_plain && !(target.call_flags.lean_call && this_val.is_object())) return null;
    EnvRecord* cap = fd.lex_env;
    if (fd.var_env == null || (cap != null && cap.is_with())) return null;
    return target;
}

// Where a host-initiated call's registers start: above every live caller
// register. vm.valstack_top is not updated for inline JS-to-JS calls (the CALL
// fast path skips it), so the running activation's own extent counts too.
fn TVal* callback_frame_top(Vm* vm) @inline {
    TVal* top = vm.valstack_top;
    if (vm.activation_count > 0) {
        Activation* cur = &vm.activations[vm.activation_count - 1];
        CompiledFunction* cur_func = (CompiledFunction*)cur.func;
        if (cur_func != null && cur.bottom + cur_func.num_regs > top) top = cur.bottom + cur_func.num_regs;
    }
    return top;
}

// Run a host call's entry frame. A callback usually finishes inside one
// threaded burst, so the burst runs here without Vm.run's frame and loop
// setup. A burst that stops short, on an opcode the threaded handlers do not
// cover or a call that needs the switch, resumes in Vm.run from the frame it
// stopped in.
fn TVal? vm_run_entry(Vm* vm) @inline {
$if $feat(THREADED_DISPATCH):
    if (vm.heap.capi_interrupt_fn == null && vm.heap.capi_runtime == null) {
        // init and load_frame write every field the burst and the code below
        // read, and the burst sets its own IC bias, so the struct is not zeroed.
        Dispatch ds @noinit;
        ds.init(vm);
        ds.load_frame();
        ds.needs_restart = false;
        vm.run_depth++;
        ds.curr_pc = run_threaded_burst(ds.curr_pc, ds.code_end, ds.regs_base, &ds.cold);
        vm.run_depth--;
        if (ds.needs_restart && vm.activation_count == 0) return vm.return_val;
        if (!ds.needs_restart) ds.act.curr_pc = ds.curr_pc;
    }
$endif
    return Vm.run(vm);
}

// Marking is incremental, so the entry frame's function and environments are
// shaded as they are published.
fn void shade_entry_roots(Vm* vm, Activation* act) @noinline {
    vm.heap.shade_root_tval(act.tv_func);
    vm.heap.shade_root_env(act.var_env);
    vm.heap.shade_root_env(act.lex_env);
}

// The generator bookkeeping a host call restores is marked as it returns to the
// heap's roots.
fn void shade_restored_generator_roots(Vm* vm) @noinline {
    vm.heap.shade_root_generator_state(vm.heap.resume_gen);
    vm.heap.shade_root_generator_state((heap::GeneratorState*)vm.heap.gen_initial_gs);
    vm.heap.shade_root_object((hobject::HObject*)vm.heap.gen_initial_obj);
}

// Run a lean compiled function (see CompiledFunction.lean_call) for a host
// call: a plain function that is not a generator, async function, class
// constructor, or eval, and needs no scope object, arguments object, rest
// array, or `this` coercion. The caller has checked that its closure has a
// variable environment and no `with` scope, and that the receiver needs no
// coercion. Builtin callbacks (Array.prototype.map and friends) enter here.
fn TVal vm_call_lean(Vm* vm, HObject* function, CompiledFunction* target, TVal func,
                     TVal* args, uint nargs, TVal this_val, void* saved_resume_gen) {
    uint nregs = target.num_regs;
    TVal* frame = callback_frame_top(vm);
    if (frame + nregs + FRAME_SCRATCH_SLOTS > vm.valstack_end) {
        if (!ensure_valstack_grow(vm, (uint)(frame - vm.valstack) + nregs + FRAME_SCRATCH_SLOTS)) {
            TVal undef;
            undef.set_undefined();
            return undef;
        }
        frame = callback_frame_top(vm);
    }

    uint saved_count = vm.activation_count;
    TVal* saved_valstack = vm.valstack;
    TVal* saved_bottom = vm.valstack_bottom;
    TVal* saved_top = vm.valstack_top;
    CompiledFunction* saved_func = vm.current_func;
    Activation[] saved_acts = vm.activations[0:saved_count];
    ShadowActFrame shadow_frame;
    vm.save_activation_roots(&shadow_frame, saved_acts);
    void* saved_initial_gs = vm.heap.gen_initial_gs;
    void* saved_initial_obj = vm.heap.gen_initial_obj;
    void* saved_initial_rv = vm.heap.gen_initial_retval;

    vm.activations += (sz)saved_count;
    vm.activation_capacity -= saved_count;
    vm.gc_root_active_replaced();
    vm.activation_count = 1;

    HObjectFunction* fd = &(*function.extra_ptr()).func;
    EnvRecord* env = fd.var_env;
    EnvRecord* cap = fd.lex_env;
    Activation* act = &vm.activations[0];
    act.func = target;
    act.tv_func = func;
    act.parent = null;
    act.var_env = env;
    act.lex_env = (cap == null || cap == env || !cap.flags.is_declarative) ? env : cap;
    act.cat = null;
    act.forin = null;
    act.curr_pc = target.code;
    act.bottom = frame;
    act.retval = null;
    act.flags = 0;
    act.heap_reg_count = 0;
    act.new_target = null;
    act.async_promise = null;
    act.async_gen_state = null;
    act.caller_valstack_top = frame + nregs;
    if (vm.heap.gc_phase == heap::GcPhase.MARK) shade_entry_roots(vm, act);
    act.set_this_borrowed(vm.heap, this_val);

    // Only fixed parameters need their incoming values; an elided rest
    // parameter uses the argument count instead.
    // `num_formals` is the function's `length`, which stops at the first
    // default.
    uint params = target.call_flags.rest_length_only ? target.num_formals : target.num_args;
    uint copy_n = nargs < params ? nargs : params;
    if (copy_n > nregs) copy_n = nregs;
    for (uint i = 0; i < copy_n; i++) {
        vm.heap.tval_copy_ref(&frame[i], &args[i]);
        track_heap_store(act, &frame[i], i);
    }
    zero_regs_undefined(frame, copy_n, nregs);
    if (target.call_flags.rest_length_only) {
        frame[params].set_fastint((long)(nargs > params ? nargs - params : 0));
    }
    if (target.arguments_in_reg()) bind_register_arguments(vm, act, target, function, args, nargs);
    publish_frame_top(vm, frame, nregs, nargs);
    vm.valstack_bottom = frame;
    vm.current_func = target;

    TVal? result_opt = vm_run_entry(vm);
    TVal result = vm.return_val;
    if (try r = result_opt) result = r;

    relocate_saved_frames(vm, saved_valstack, &saved_bottom, &saved_top);
    vm.gc_root_active_replaced();
    vm.activation_count = saved_count;
    vm.current_func = saved_func;
    vm.activations = saved_acts.ptr;
    vm.activation_capacity += saved_count;
    vm.pop_activation_roots(&shadow_frame);
    vm.valstack_bottom = saved_bottom;
    vm.valstack_top = saved_top;
    vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;
    vm.heap.gen_initial_gs = saved_initial_gs;
    vm.heap.gen_initial_obj = saved_initial_obj;
    vm.heap.gen_initial_retval = saved_initial_rv;
    if (vm.heap.gc_phase == heap::GcPhase.MARK) shade_restored_generator_roots(vm);
    // Only the outermost host-to-VM entry drains jobs (see vm_call_fn_impl).
    if (saved_count == 0) vm.heap.drain_microtasks((void*)vm);
    return result;
}

fn TVal vm_call_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val) {
    Vm* vm = (Vm*)vm_ptr;
    heap::Realm* caller_realm = vm.heap.realm;
    if (vm.heap.realms != null) {
        if (try realm = heap::function_realm(vm.heap, func)) vm.heap.enter_realm(realm);
    }
    defer vm.heap.enter_realm(caller_realm);
    TVal undef;
    undef.set_undefined();
    if (nargs > 0xFFFFu) {
        vm_host_throw(vm, vm.heap.range_err_proto, "too many arguments");
        return undef;
    }

    // Save resume_gen before ANY dispatch below runs. Case 2 (builtin, e.g.
    // Generator.prototype.next) may itself set vm.heap.resume_gen for the
    // callee's generator before falling through to Case 3's re-dispatch, so
    // capturing this after Case 2 runs would save the callee's resume_gen
    // instead of the caller's, corrupting the caller generator's resume
    // state once restored below (e.g. yield* losing track of the delegating
    // generator's own suspend/resume bookkeeping).
    void* saved_resume_gen_outer = vm.heap.resume_gen;

    // Every host-initiated call lands here, so this is where native re-entry
    // is bounded. Cases 1 and 2 dispatch a builtin and return without ever
    // reaching Case 3's check, yet a builtin is exactly what re-enters: a
    // coercion that runs valueOf/Symbol.toPrimitive, a proxy trap handed the
    // proxy as an argument. That recursion never re-enters Vm.run, so
    // activation_count and MAX_CALLS never see it, and each bounce claims a
    // TVal[16]/TVal[18] register window plus a save area on a native stack the
    // engine cannot grow or measure. Unguarded it faults instead of throwing.
    if (vm_run_depth_exceeded(vm)) return undef;
    vm.run_depth++;
    defer vm.run_depth--;

    if (func.is_object() && func.get_heapptr() != null) {
        HObject* fobj = (HObject*)func.get_heapptr();
        CompiledFunction* lean = lean_callee(fobj, this_val);
        if (lean != null) {
            return vm_call_lean(vm, fobj, lean, func, args, nargs, this_val, saved_resume_gen_outer);
        }
    }

    // Bound function [[Call]] (ECMA-262 §9.4.1.1): unwrap [[BoundTargetFunction]],
    // [[BoundThis]] and [[BoundArguments]] here and recurse, rather than
    // dispatching BOUND_CALL through the temp_regs windows below.
    // builtin_bound_call rewrites its register window with frame-owned
    // refcounting (decref the old callee/this, incref the new), which is
    // unbalanced against the raw borrows those windows hold on this path --
    // each bound call drained one reference from the bound function -- and it
    // re-dispatches into Case 3, which requires a compiled target, so a bound
    // builtin or lightfunc target was silently never invoked. Mirrors the
    // [[Construct]] unwrap in vm_construct_fn_impl. Nested binds recurse.
    // Everything read out of the bound object stays borrowed, rooted by the
    // chain from the caller's func, which the caller keeps alive across this
    // call (the same contract Case 3 already relies on).
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* bobj = (HObject*)func.get_heapptr();
        if (bobj.is_bound()) {
            Heap* heap = vm.heap;
            TVal bound_target = (*bobj.extra_ptr()).func.bound.target;
            TVal bound_this = (*bobj.extra_ptr()).func.bound.this_arg;
            HObject* args_arr = (*bobj.extra_ptr()).func.bound.args;

            uint bound_argc = 0;
            if (args_arr != null) {
                HString* len_key = heap.str(heap::BuiltinStr.LENGTH);
                if (len_key != null) {
                    TVal? lv = args_arr.get_prop_proto(len_key, heap);
                    if (try l = lv) {
                        if (l.is_fastint()) {
                            bound_argc = (uint)l.get_fastint();
                        } else if (l.is_number()) {
                            bound_argc = (uint)l.get_number();
                        }
                    }
                }
            }

            uint total_argc = bound_argc + nargs;
            TVal* combined_args = null;
            if (total_argc > 0) {
                combined_args = (TVal*)heap.alloc_func(heap.heap_udata, TVal::size * total_argc);
                if (combined_args == null) return undef;
            }
            defer if (combined_args != null) heap.free_func(heap.heap_udata, combined_args);

            uint combined_idx = 0;
            if (args_arr != null) {
                for (uint i = 0; i < bound_argc && combined_idx < total_argc; i++) {
                    // A miss (hole / failed key intern) still consumes a
                    // slot as undefined so the call args don't shift left.
                    TVal ev;
                    ev.set_undefined();
                    char[20] buf;
                    int n = (int)(io::bprintf(&buf, "%d", i) ?? buf[:0]).len;
                    if (n > 0 && n < 20) {
                        HString* ek = builtins::builtin_intern_string(heap, buf[:n]);
                        if (ek != null) {
                            TVal? e = args_arr.get_prop_proto(ek, heap);
                            if (try got = e) ev = got;
                        }
                    }
                    combined_args[combined_idx++] = ev;
                }
            }
            for (uint i = 0; i < nargs && combined_idx < total_argc; i++) {
                combined_args[combined_idx++] = args[i];
            }

            return vm_call_fn_impl(vm_ptr, bound_target, combined_args, combined_idx, bound_this);
        }
    }

    // §9.2.1 step 1: a class constructor called without `new` is a TypeError.
    // The call opcodes check this for calls written in script; this is the
    // same check for every call the host makes, so a class handed to a builtin
    // as a callback -- a sort comparator, a map function, a Symbol.toPrimitive
    // method -- throws rather than being quietly skipped.
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* cobj = (HObject*)func.get_heapptr();
        if (cobj.is_class_ctor()) {
            vm_host_throw(vm, vm.heap.type_err_proto,
                          "Class constructor cannot be invoked without 'new'");
            return undef;
        }
    }

    // Case 1: a lightfunc dispatches directly through BuiltinContext.
    if (func.is_lightfunc()) {
        uint fn_idx = (uint)(usz)func.get_heapptr();

        // Layout: [callee, this, arg0, arg1, ...], as in Case 2. The slots
        // below base_reg let a builtin that re-targets the call rewrite the
        // callee and `this`: eval swaps in the function it just compiled and
        // asks for a re-dispatch. With base_reg = 1 and no callee slot those
        // writes landed one before the array.
        TVal[18] local_regs;
        TVal* temp_regs = &local_regs;
        if (nargs > 16) {
            temp_regs = (TVal*)vm.heap.alloc_func(vm.heap.heap_udata, ((usz)nargs + 2) * TVal::size);
            if (temp_regs == null) { vm_host_throw(vm, vm.heap.range_err_proto, "out of memory"); return undef; }
            mem::clear(temp_regs, (sz)(((usz)nargs + 2) * TVal::size));
        }
        defer if (temp_regs != &local_regs) vm.heap.free_func(vm.heap.heap_udata, temp_regs);
        defer vm.heap.decref_tval(&temp_regs[0]);
        temp_regs[0] = func;       // callee at index 0 (base_reg - 2)
        temp_regs[1] = this_val;   // this at index 1   (base_reg - 1)
        for (uint i = 0; i < nargs; i++) {
            temp_regs[2 + i] = args[i];
        }

        builtins::BuiltinContext ctx;
        ctx.callee_obj = null;
        ctx.vm = vm;
        ctx.regs = temp_regs;
        ctx.base_reg = 2;          // base_reg - 2 = 0 = callee, base_reg - 1 = 1 = this
        ctx.argc = (ushort)nargs;
        ctx.result = builtins::result_slot(&temp_regs[0]);
        ctx.heap = vm.heap;
        ctx.this_val = this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;

        builtins::dispatch_builtin(fn_idx, &ctx);
        if (ctx.should_throw) {
            // Propagate the throw on both error channels: vm.has_error /
            // heap.has_error for callers using vm_check_call_fn_error() or
            // ctx.heap.has_error, and vm.throw_pending / vm.throw_value for
            // the vm_to_string / to_primitive coercion paths.
            vm.has_error = true;
            vm.heap.has_error = true;
            vm.heap.tval_copy_ref(&vm.heap.error_value, &ctx.throw_value);
            vm.heap.tval_copy_ref(&vm.return_val, &ctx.throw_value);
            vm.throw_pending = true;
            vm.heap.tval_copy_ref(&vm.throw_value, &ctx.throw_value);
            return undef;
        }
        if (ctx.needs_re_dispatch) {
            // The builtin re-targeted the call, so run the new callee rather
            // than returning the result slot, which still holds the seeded
            // callee value.
            uint re_nargs = ctx.re_nargs;
            if (re_nargs > nargs) re_nargs = nargs;
            return vm_call_fn_impl(vm_ptr, temp_regs[0], &temp_regs[2], re_nargs,
                                   temp_regs[1]);
        }
        vm.heap.store_builtin_result(&vm.return_val, ctx.result.view());
        return vm.return_val;
    }

    // Case 2: an HObject with a builtin_fn_index also goes through BuiltinContext.
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        hobject::CallableKind fn_kind = (hobj != null && hobj.is_callable())
            ? hobj.callable_kind() : hobject::CallableKind.OTHER;
        // BOUND_FN also dispatches through its builtin (bound_call), which
        // re-targets via needs_re_dispatch below.
        if (hobj != null && hobj.is_callable()
            && (fn_kind == hobject::CallableKind.BUILTIN_FN
                || (fn_kind == hobject::CallableKind.BOUND_FN
                    && (*hobj.extra_ptr()).func.builtin_fn_index >= 0))) {
            uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;

            // Builtins may modify callee/this via base_reg-2 and base_reg-1.
            // Layout: [callee, this, arg0, arg1, ...]
            TVal[18] local_regs;
            TVal* temp_regs = &local_regs;
            if (nargs > 16) {
                temp_regs = (TVal*)vm.heap.alloc_func(vm.heap.heap_udata, ((usz)nargs + 2) * TVal::size);
                if (temp_regs == null) { vm_host_throw(vm, vm.heap.range_err_proto, "out of memory"); return undef; }
                mem::clear(temp_regs, (sz)(((usz)nargs + 2) * TVal::size));
            }
            defer if (temp_regs != &local_regs) vm.heap.free_func(vm.heap.heap_udata, temp_regs);
            defer vm.heap.decref_tval(&temp_regs[0]);
            temp_regs[0] = func;       // callee at index 0 (base_reg - 2)
            temp_regs[1] = this_val;   // this at index 1   (base_reg - 1)
            for (uint i = 0; i < nargs; i++) {
                temp_regs[2 + i] = args[i];
            }

            builtins::BuiltinContext ctx;
            ctx.callee_obj = null;
            ctx.vm = vm;
            ctx.regs = temp_regs;
            ctx.base_reg = 2;          // base_reg - 2 = 0 = callee, base_reg - 1 = 1 = this
            ctx.argc = (ushort)nargs;
            ctx.result = builtins::result_slot(&temp_regs[0]);
            ctx.heap = vm.heap;
            ctx.this_val = this_val;
            ctx.is_constructor = false;
            ctx.needs_re_dispatch = false;
            ctx.re_nargs = 0;
            ctx.global_env = vm.global_env;
            ctx.should_throw = false;
            ctx.callee_obj = hobj;

            builtins::dispatch_builtin(fn_idx, &ctx);

            if (ctx.should_throw) {
                // Propagate throw via vm.has_error so callers checking
                // vm_check_call_fn_error() or ctx.heap.has_error detect it.
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &ctx.throw_value);
                vm.heap.tval_copy_ref(&vm.return_val, &ctx.throw_value);
                return undef;
            }

            if (ctx.needs_re_dispatch) {
                // Builtin (e.g., generator .next()) modified the callee/this and
                // expects the call to be re-dispatched.
                func = temp_regs[0];
                this_val = temp_regs[1];
                // Rebuild args from temp_regs[2..] with the re-dispatched nargs
                uint new_nargs = ctx.re_nargs;
                for (uint i = 0; i < new_nargs && i < 16; i++) {
                    if (2 + i < 18) args[i] = temp_regs[2 + i];
                }
                nargs = new_nargs;
                // Fall through to Case 3
            } else {
                vm.heap.store_builtin_result(&vm.return_val, ctx.result.view());
                return vm.return_val;
            }
        }
    }

    // Case 3: compiled function on HObject
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && (*hobj.extra_ptr()).func.comp_func != null) {
            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;
            if (catch compiler::materialize_function(target, vm.heap)) return undef;
            CompiledFunction* lean = lean_callee(hobj, this_val);
            if (lean != null) {
                return vm_call_lean(vm, hobj, lean, func, args, nargs, this_val, saved_resume_gen_outer);
            }
            uint nregs = target.num_regs;

            // Grow the valstack (while activation_count is still the
            // caller's, so ensure_valstack_grow relocates all live pointers).
            // The callback frame is placed above all live caller registers.
            TVal* true_top = callback_frame_top(vm);
            if (true_top + nregs + FRAME_SCRATCH_SLOTS > vm.valstack_end) {
                if (!ensure_valstack_grow(vm, (uint)(true_top - vm.valstack) + nregs + FRAME_SCRATCH_SLOTS)) {
                    return undef;
                }
                true_top = callback_frame_top(vm);
            }

            // Save current VM state (after potential realloc)
            uint saved_act_count = vm.activation_count;
            TVal* saved_valstack_bottom = vm.valstack_bottom;
            TVal* saved_valstack_top = vm.valstack_top;
            TVal* saved_valstack = vm.valstack;
            CompiledFunction* saved_current_func = vm.current_func;
            void* saved_resume_gen = saved_resume_gen_outer;  // captured before Case 1/2 could overwrite it

            Activation[] saved_acts = vm.activations[0:saved_act_count];
            ShadowActFrame shadow_frame;
            vm.save_activation_roots(&shadow_frame, saved_acts);
            bool roots_linked = true;
            defer if (roots_linked) vm.pop_activation_roots(&shadow_frame);

            TVal* frame = true_top;

            vm.activations += (sz)saved_act_count;
            vm.activation_capacity -= saved_act_count;
            mem::clear(vm.activations, Activation::size);

            Activation* act = &vm.activations[0];
            vm.gc_root_active_replaced();
            vm.activation_count = 1;
            EnvRecord* cfn_var_env = (*hobj.extra_ptr()).func.var_env;
            // Register-only callbacks need no scope allocation, just like the
            // compiled CALL path. EnvRecords otherwise live until heap teardown.
            if (target.needs_env() && !target.is_eval_fn()) {
                if (try fv_cfn = env::env_create_function_scope(vm.heap, cfn_var_env, target.scope_capacity())) { cfn_var_env = fv_cfn; }
            }
            act.func = target;
            act.tv_func = func;
            vm.heap.shade_root_tval(act.tv_func);
            act.parent = null;
            act.var_env = cfn_var_env;
            vm.heap.shade_root_env(act.var_env);
            act.lex_env = resolve_call_lex_env(vm, hobj, target, cfn_var_env);
            vm.heap.shade_root_env(act.lex_env);
                    act.cat = null;
                    act.forin = null;
            act.curr_pc = target.code;
            act.async_promise = null;
            act.async_gen_state = null;
            act.serial = ++vm.activation_serial;
            act.native_ret = null;

            // Check for generator/async resume: if heap.resume_gen is set
            // and matches this function, restore the saved PC and registers.
            bool did_resume = false;
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_r = vm.heap.resume_gen;
                // No GEN_EXECUTING exclusion here (unlike dispatch_calls'
                // CALL path): call_fn IS the legitimate re-entry point for an
                // async generator whose body is already in flight, so
                // rejecting GEN_EXECUTING would strand .return()/.throw().
                if ((CompiledFunction*)gs_r.func == target) {
                    did_resume = true;
                    // Mark the generator as running for the duration of this
                    // re-entrant resume, mirroring dispatch_calls. Without it
                    // the generator stays GEN_SUSPENDED_* while its body
                    // executes, so a nested resume of the same generator is
                    // indistinguishable from a legitimate one and the
                    // yield* delegation chain runs an extra next() per level.
                    // GEN_AWAITING_RETURN is preserved: an async generator
                    // parked on the await inside AsyncGeneratorAwaitReturn is
                    // not executing, and overwriting it loses the pending
                    // return completion (as at the gen_suspend site).
                    if (gs_r.state != GEN_AWAITING_RETURN) gs_r.state = GEN_EXECUTING;
                    act.async_gen_state = gs_r;
                    vm.heap.shade_root_generator_state((heap::GeneratorState*)act.async_gen_state);
                    act.curr_pc = (Instruction*)gs_r.saved_pc;
                    act.var_env = (EnvRecord*)gs_r.var_env;
                    vm.heap.shade_root_env(act.var_env);
                    act.lex_env = (EnvRecord*)gs_r.lex_env;
                    vm.heap.shade_root_env(act.lex_env);
                    chains_restore_from_gen(act, gs_r);
                    // Restore saved registers instead of initializing fresh
                    $if $feat(HEAP_VERIFY):
                        vm.heap.verify_roots("before_resume_restore");
                        if (gs_r.saved_regs != null) {
                            vm.heap.verify_tval_array(gs_r.saved_regs, gs_r.num_regs, "resume_saved_regs");
                        }
                    $endif
                    restore_generator_registers(vm, gs_r, frame, nregs,
                                                target.is_sync_generator());
                    // If the yield fired inside a non-generator inner function
                    // (a default-expression thunk, e.g. `[x = yield]`), the
                    // saved PC points just after the thunk's CALL in the
                    // generator body. Place the resume value into that CALL's
                    // result register so the post-CALL code reads it. This is
                    // the async-generator counterpart of the sync-generator
                    // handling in vm_calls.c3's CALL-resume path, since async
                    // generators re-enter here via async_gen_resume_body/call_fn
                    // rather than through the re-dispatched CALL opcode.
                    if (gs_r.pending_resume_reg != 0xFFFF && gs_r.pending_resume_reg < nregs) {
                        vm.heap.tval_copy_ref(&frame[gs_r.pending_resume_reg], &gs_r.resume_value);
                        gs_r.pending_resume_reg = 0xFFFF;
                    }
                    // Put the resume value into register 0 (LOAD_RESUME will read it)
                    // The resume value is read by LOAD_RESUME from gs_r.resume_value
                    // into the A operand register, so no need to pre-populate frame[0].
                    // vm.heap.tval_copy_ref(&frame[0], &gs_r.resume_value);
                    // Propagate async context so RET can settle the async Promise
                    if (gs_r.async_promise != null) {
                        act.flags |= ACT_FLAG_ASYNC;
                        act.async_promise = (hobject::HObject*)gs_r.async_promise;
                        vm.heap.shade_root_object(act.async_promise);
                    }
                    // Note: this_binding is set below (after this block).
                    // For generator resumes via call_fn, this_val is the generator
                    // object (from .next()), but the generator's actual 'this' is
                    // in gs_r.this_binding. We restore it after cfn_is_gen_initial is
                    // determined (the restore is conditional on cfn_is_gen_initial=false
                    // and only applied for generators that use 'this' inside their body).
                    // [Restored below in the this_binding section]
                    $if $feat(HEAP_VERIFY):
                        vm.heap.verify_roots("after_resume_restore");
                    $endif
                }
            }

            act.bottom = frame;
            // Preserve any flags already set (e.g. ACT_FLAG_ASYNC for resumed async fns)
            uint preserved_flags = act.flags;
            act.flags = (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
                      | preserved_flags;
            // Initial call to a plain async function (B18): create the
            // function's promise and mark the activation async so RET settles
            // it and AWAIT can suspend onto it. The CALL opcode path does the
            // same (vm_calls.c3); without it the callback runs synchronously
            // to completion and the builtin receives the raw return value
            // instead of a promise. Async generators are excluded: their
            // promise/request machinery is owned by gen_initial/GEN_START.
            HObject* cfn_async_prom = null;
            if (!did_resume && target.is_async() && !target.is_async_gen()) {
                HObject*? prom_raw = builtins::promise_create(vm.heap);
                if (try p = prom_raw) {
                    cfn_async_prom = p;
                    act.flags |= ACT_FLAG_ASYNC;
                    act.async_promise = p;
                    vm.heap.shade_root_object(act.async_promise);
                }
            }
            act.heap_reg_count = 0;
            if (did_resume) { track_restored_regs(act, frame, nregs); }
            act.caller_valstack_top = frame + nregs;
            // Set this_binding. For generator resumes via call_fn where the initial
            // call was also via call_fn (i.e. cfn_is_gen_initial was true for the
            // creation call), the generator's saved this_binding must be restored.
            // For all other cases, use this_val (the passed-in receiver).
            // Set this_binding for the activation.
            // For generator resumes via call_fn, this_val is the generator object
            // (the receiver of .next()), but the generator's actual 'this' is saved
            // in gs_r.this_binding. Restore it directly to avoid running the generator
            // body with the wrong 'this' (e.g. Boolean.prototype[Symbol.iterator] needs
            // this=true/false, not the generator object).
            // IMPORTANT: use a raw assign (no tval_copy_ref) because act.this_binding
            // still contains stale bits from the previous occupant of vm.activations[0].
            // Using tval_copy_ref would incorrectly decref those stale bits.
            if (did_resume && vm.heap.resume_gen != null) {
                GeneratorState* gs_rb2 = vm.heap.resume_gen;
                if (!gs_rb2.this_binding.is_undefined() && !gs_rb2.this_binding.is_null()) {
                    // Restore the generator's saved 'this' (e.g. boolean true/false for
                    // Boolean.prototype[Symbol.iterator] generators).
                    // Borrowed from the generator state, which owns it for as
                    // long as the generator is alive, so no reference is taken.
                    act.set_this_borrowed(vm.heap, gs_rb2.this_binding);
                } else {
                    // The generator was created with an undefined or null `this`,
                    // so apply ECMA-262 §10.4.3 to non-arrow sloppy functions.
                    if (!target.is_arrow() && !target.is_strict()
                        && vm.global_env != null && vm.global_env.bindings != null) {
                        this_val.set_object(vm.global_env.bindings);
                    }
                    act.set_this_borrowed(vm.heap, this_val);
                }
            } else if (target.is_arrow()) {
                // Arrow functions have no receiver of their own, so `this` is
                // lexically inherited from the enclosing scope, captured once
                // at CLOSURE-creation time (§9.2.1 [[ThisMode]]=lexical), not
                // from the caller-supplied this_val (which for a call routed
                // through a builtin, e.g. Array.prototype.map's thisArg or an
                // iterator's ITER_CLOSE-driven .return(), is unrelated to the
                // arrow's defining scope). Exception: a still-TDZ captured
                // value (arrow defined before super() ran in a derived
                // constructor) must be re-resolved live from the immediate
                // caller; see super_walk_live_this().
                TVal arrow_this = (*hobj.extra_ptr()).func.captured_this;
                if (env::is_tdz_sentinel(&arrow_this) && saved_act_count > 0) {
                    arrow_this = super_walk_live_this(vm, &saved_acts[saved_act_count - 1]);
                }
                act.set_this_borrowed(vm.heap, arrow_this);
            } else {
                // Not a resume: the same sloppy-receiver rules as the inline
                // CALL path apply (ECMA-262 §10.4.3 / ECMA-262 §10.4.1.2). An
                // undefined/null `this` becomes the global object; any other
                // primitive is ToObject-boxed. Only the substitution was here,
                // so a callback invoked through heap.call_fn (Array.prototype
                // iteration, Array.fromAsync's mapfn) saw a bare primitive.
                TVal coerced_this;
                bool used_boxed = false;
                if (!target.is_arrow() && !target.is_strict()) {
                    if (this_val.is_undefined() || this_val.is_null()) {
                        if (vm.global_env != null && vm.global_env.bindings != null) {
                            coerced_this.set_object_borrowed(vm.global_env.bindings);
                            this_val = coerced_this;
                        }
                    } else if (!this_val.is_object()) {
                        HObject* boxed = builtins::to_object_wrapper(vm.heap, this_val);
                        if (boxed != null) {
                            // Transfer to_object_wrapper's reference to the
                            // activation; handle_return releases it on RET.
                            vm.heap.shade_root_object(boxed);
                            act.this_binding.set_object(boxed);
                            act.flags |= ACT_FLAG_THIS_OWNED | ACT_FLAG_THIS_VALID;
                            used_boxed = true;
                        }
                    }
                }
                if (!used_boxed) {
                    // The caller keeps this_val alive; THIS_VALID publishes
                    // the borrow to the collector without taking a string reference.
                    act.set_this_borrowed(vm.heap, this_val);
                }
            }

            // For the initial (non-resume) call to a generator function, set up
            // gen_initial_gs / gen_initial_obj so GEN_START can find them.
            // vm.heap.gen_initial_gs may already be set (from the inline CALL opcode)
            // so only allocate when it is not already there.
            void* cfn_saved_gen_initial_gs  = vm.heap.gen_initial_gs;
            void* cfn_saved_gen_initial_obj = vm.heap.gen_initial_obj;
            void* cfn_saved_gen_initial_rv  = vm.heap.gen_initial_retval;
            TVal cfn_gen_result_slot; cfn_gen_result_slot.set_undefined();
            bool cfn_is_gen_initial = false;
            // Sync generators and async generators both create their instance
            // object here and suspend at GEN_START; plain async functions run
            // their body immediately (handled elsewhere), so exclude those.
            if (!did_resume && (target.is_sync_generator() || target.is_async_gen())
                && vm.heap.gen_initial_gs == null) {
                GeneratorState* cfn_gs = vm.heap.alloc_generator_state();
                if (cfn_gs != null) {
                    cfn_gs.pending_resume_reg = 0xFFFF;
                    cfn_gs.func = target;
                    cfn_gs.func_obj = hobj;
                    vm.heap.shade_root_object(hobj);
                    cfn_gs.num_regs = target.num_regs;
                    usz cfn_regs_bytes = (usz)target.num_regs * TVal::size;
                    void* cfn_regs_raw = (cfn_regs_bytes > 0)
                        ? vm.heap.alloc_generator_registers(cfn_regs_bytes)
                        : null;
                    if (cfn_regs_bytes > 0 && cfn_regs_raw == null) {
                        vm.heap.free_generator_state(cfn_gs);
                    } else {
                        if (cfn_regs_raw != null) mem::clear(cfn_regs_raw, (sz)(cfn_regs_bytes));
                        cfn_gs.saved_regs = (TVal*)cfn_regs_raw;
                        HObject*? cfn_gen_obj_raw = vm.heap.alloc_object(hobject::ObjClass.GENERATOR);
                        if (try cfn_gen_obj = cfn_gen_obj_raw) {
                            // ECMA-262 §25.3.3 step 1: OrdinaryCreateFromConstructor(
                            // functionObject, "%GeneratorPrototype%"). Deferred to
                            // GEN_START (see vm_calls.c3's matching comment) so a
                            // default-parameter side effect on functionObject.prototype
                            // is observed; default to the shared Generator.prototype
                            // here, corrected by GEN_START if needed.
                            if (target.is_async_gen()) {
                                cfn_gs.is_async_gen = true;
                                cfn_gen_obj.prototype = (vm.heap.async_generator_proto != null)
                                    ? vm.heap.async_generator_proto : vm.heap.generator_proto;
                            } else {
                                cfn_gen_obj.prototype = vm.heap.generator_proto;
                            }
                            (*cfn_gen_obj.extra_ptr()).gen.generator_data = cfn_gs;
                            cfn_gs.gen_obj = cfn_gen_obj;
                            vm.heap.shade_root_object(cfn_gen_obj);
                            vm.heap.acquire_generator_state(cfn_gs);
                            vm.heap.gen_initial_gs  = cfn_gs;
                            vm.heap.gen_initial_obj = cfn_gen_obj;
                            vm.heap.shade_root_generator_state((heap::GeneratorState*)cfn_gs);
                            vm.heap.shade_root_object((hobject::HObject*)cfn_gen_obj);
                            // Point gen_initial_retval at our local slot so GEN_START
                            // can write the generator object. act.retval is also set to
                            // this slot so GEN_START's ds.act.retval check succeeds.
                            vm.heap.gen_initial_retval = &cfn_gen_result_slot;
                            cfn_is_gen_initial = true;
                        } else {
                            vm.heap.free_scanned(cfn_regs_raw, cfn_regs_bytes);
                            vm.heap.free_generator_state(cfn_gs);
                        }
                    }
                }
            }

            act.retval = cfn_is_gen_initial ? &cfn_gen_result_slot : null;

            if (!did_resume) {
                for (uint i = 0; i < nregs; i++) {
                    frame[i].set_undefined();
                }
                if (target.has_rest()) {
                    // Copy the fixed (pre-rest) formals first.
                    uint copy_count = (uint)target.num_formals;
                    uint copy_n = nargs < copy_count ? nargs : copy_count;
                    for (uint i = 0; i < copy_n; i++) {
                        vm.heap.tval_copy_ref(&frame[i], &args[i]);
                        track_heap_store(act, &frame[i], i);
                    }
                    // Build the rest array from remaining args.
                    uint rest_idx = copy_count;
                    uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                    frame[rest_idx] = build_rest_parameter(vm.heap, target, args + copy_count, overflow);
                    track_heap_store(act, &frame[rest_idx], rest_idx);
                } else {
                    uint copy_n = nargs < nregs ? nargs : nregs;
                    for (uint i = 0; i < copy_n; i++) {
                        vm.heap.tval_copy_ref(&frame[i], &args[i]);
                        track_heap_store(act, &frame[i], i);
                    }
                }
            }
            publish_frame_top(vm, frame, nregs, nargs);
            vm.valstack_bottom = frame;
            vm.current_func = target;

            // Create arguments object if the function references 'arguments'.
            // Skip on a generator/async resume: the call-time arguments object
            // was built at the initial call and saved into gs.var_env (restored
            // into act.var_env above). This re-entrant call_fn path is driven
            // with argc=0, so rebuilding here would install an empty arguments
            // object (length 0) that shadows the correct call-time one, and the
            // async-generator `arguments` bug (async generators resume through
            // call_fn, unlike sync generators which resume via the CALL opcode).
            if (target.uses_arguments() && !did_resume) {
                bind_arguments(vm, act, target, hobj, args, nargs, true);
            }

            // Run through Vm.run rather than Vm.execute, whose init would redo the
            // state already set up here.
            TVal? result_opt = Vm.run(vm);
            TVal result;
            if (try r = result_opt) {
                result = r;
            } else {
                result = vm.return_val;
            }

            relocate_saved_frames(vm, saved_valstack, &saved_valstack_bottom,
                                  &saved_valstack_top);

            // Restore VM state (caller registers were never touched)
            vm.gc_root_active_replaced();
            vm.activation_count = saved_act_count;
            vm.current_func = saved_current_func;
            vm.activations = saved_acts.ptr;
            vm.activation_capacity += saved_act_count;
            vm.pop_activation_roots(&shadow_frame);
            roots_linked = false;
            vm.valstack_bottom = saved_valstack_bottom;
            vm.valstack_top = saved_valstack_top;
            vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;  // restore after nested generator
            vm.heap.shade_root_generator_state(vm.heap.resume_gen);

            // Restore gen_initial state in case GEN_START didn't clear it
            // (e.g. if the body threw before reaching GEN_START).
            vm.heap.gen_initial_gs      = cfn_saved_gen_initial_gs;
            vm.heap.gen_initial_obj     = cfn_saved_gen_initial_obj;
            vm.heap.shade_root_generator_state((heap::GeneratorState*)cfn_saved_gen_initial_gs);
            vm.heap.shade_root_object((hobject::HObject*)cfn_saved_gen_initial_obj);
            vm.heap.gen_initial_retval  = cfn_saved_gen_initial_rv;

            // For generator initial calls, the generator object was written into
            // cfn_gen_result_slot by GEN_START and returned as halt_value.
            if (cfn_is_gen_initial && cfn_gen_result_slot.is_object()
                && cfn_gen_result_slot.get_heapptr() != null) {
                result = cfn_gen_result_slot;
            }

            // Initial async call: the caller must receive the function's
            // promise. If the body completed, RET already delivered the
            // promise as result; if it suspended at an AWAIT or threw,
            // Vm.run returned undefined and the pending/rejected promise is
            // the value the builtin should collect (map stores it, .then
            // adopts it via promise_resolve_with_value).
            if (cfn_async_prom != null
                && (!result.is_object() || result.get_heapptr() != (void*)cfn_async_prom)) {
                result.set_object(cfn_async_prom);
            }

            // Drain microtasks after callback execution, but only when this
            // invocation is the outermost native→VM reentry: nesting deeper
            // than one live activation means some other synchronous script
            // or async-function frame is still mid-statement above us on the
            // real call stack, and draining here would run its unrelated
            // queued jobs (e.g. an unrelated top-level `.then()` chain) out
            // of order relative to work that frame hasn't finished queuing
            // yet. That outer frame's own eventual drain point (end of
            // script, or its own return through this same path) still runs
            // the queue once its synchronous work is done.
            if (saved_act_count == 0) {
                vm.heap.drain_microtasks((void*)vm);
            }

            return result;
        }
    }

    return undef;
}

// trace_print_tval and trace_instruction are now in vm_trace.c3.

// A resumed ordinary async body runs at the base of its retained segment.
// Nested callbacks publish their callers before replacing the active frames;
// each shadow segment records its own bounds for tracing and relocation.
fn TVal vm_run_async_continuation(Vm* vm, HObject* job, TVal value) {
    GeneratorState* gs = (*job.extra_ptr()).async_cont.state;
    uint saved_count = vm.activation_count;
    if (saved_count >= vm.activation_capacity) {
        return builtins::async_run_continuation(vm.heap, (void*)vm, job, value);
    }
    // The outer segment stops being current: its live slots take counts.
    vm_segment_counts(vm, true);
    ShadowActFrame shadow;
    vm.save_activation_roots(&shadow, vm.activations[0:saved_count]);
    TVal* saved_stack = vm.valstack;
    uint saved_size = vm.valstack_size;
    TVal* saved_top = vm.valstack_top;
    TVal* saved_bottom = vm.valstack_bottom;
    TVal* saved_end = vm.valstack_end;
    GeneratorState* saved_owner = vm.async_stack_state;
    vm.activations += (sz)saved_count;
    vm.activation_capacity -= saved_count;
    vm.activation_count = 0;
    vm.gc_root_active_replaced();
    vm.valstack = gs.saved_regs;
    vm.valstack_size = gs.async_regs_capacity;
    vm.valstack_bottom = gs.saved_regs;
    vm.valstack_top = gs.saved_regs;
    vm.valstack_end = gs.saved_regs + gs.async_regs_capacity;
    vm.async_stack_state = gs;
    vm.heap.valstack_base = vm.valstack;
    vm.heap.valstack_limit = vm.valstack_end;
    TVal result = builtins::async_run_continuation(vm.heap, (void*)vm, job, value);
    if (gs.state == GEN_EXECUTING) gs.state = GEN_COMPLETED;
    // A finished body leaves its last register values behind. They hold no
    // counts while this segment is current, and releasing the state would
    // otherwise treat them as counted.
    if (gs.state == GEN_COMPLETED && gs.saved_regs != null) {
        for (uint i = 0; i < gs.num_regs; i++) gs.saved_regs[i].set_undefined();
    }
    vm.valstack = saved_stack;
    vm.valstack_size = saved_size;
    vm.valstack_top = saved_top;
    vm.valstack_bottom = saved_bottom;
    vm.valstack_end = saved_end;
    vm.async_stack_state = saved_owner;
    vm.heap.valstack_base = saved_stack;
    vm.heap.valstack_limit = saved_end;
    vm.activations -= (sz)saved_count;
    vm.activation_capacity += saved_count;
    vm.activation_count = saved_count;
    vm.gc_root_active_replaced();
    vm.pop_activation_roots(&shadow);
    vm_segment_counts(vm, false);
    return result;
}

// Heap.call_handler_fn dispatches native continuations and ordinary callbacks.
fn TVal vm_call_handler_fn_impl(void* vm_ptr, TVal handler, TVal* arg) {
    TVal undef;
    undef.set_undefined();
    // Each PromiseReactionJob (ECMA-262 §27.2.2.1) is an independent microtask:
    // it takes its input as `arg` and reports a throw via its return value or
    // (for a native handler) heap.has_error, never through a pre-existing entry in
    // the VM's error-propagation channels. A prior job may have left those
    // channels set: e.g. an async function whose for-await step rejected leaves
    // heap.has_error / vm.throw_pending populated with the rejection reason.
    // Clear ALL of them before this handler runs, so a stale error cannot
    // resurface, either inside the handler, where an ADD re-fires throw_pending via
    // vm_check_to_number_throw) or after it (promise_microtask_after seeing a
    // stale heap.has_error and wrongly rejecting the handler's downstream, which
    // dropped the onRejected result of `.then(onF, onR)` on a for-await
    // rejection). This mirrors promise_clear_error_channels.
    Vm* vm = (Vm*)vm_ptr;
    if (vm != null) {
        vm.throw_pending = false;
        // throw_value holds a strong ref (see the DYN_IMPORT IfAbruptReject
        // site), so release the discarded error before clearing.
        if (vm.heap != null) vm.heap.decref_tval(&vm.throw_value);
        vm.throw_value.set_undefined();
        vm.has_error = false;
        if (vm.heap != null) vm.heap.has_error = false;
    }
    if (handler.is_object() && handler.get_heapptr() != null) {
        HObject* job = (HObject*)handler.get_heapptr();
        if (job.get_class() == hobject::ObjClass.ASYNC_CONTINUATION) {
            return vm_run_async_continuation(vm, job, *arg);
        }
    }
    return vm_call_fn_impl(vm_ptr, handler, arg, arg != null ? 1 : 0, undef);
}

// Heap.construct_fn's implementation: `new Fn(args)` semantics.
// Allocates a fresh this, runs the constructor with ACT_FLAG_CONSTRUCT,
// and returns the resulting instance.  Used by Promise combinators for
// NewPromiseCapability(C).
fn TVal vm_construct_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal new_target) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();
    if (vm == null) return undef;
    heap::Realm* caller_realm = vm.heap.realm;
    if (vm.heap.realms != null) {
        if (try realm = heap::function_realm(vm.heap, func)) vm.heap.enter_realm(realm);
    }
    defer vm.heap.enter_realm(caller_realm);
    Heap* heap = vm.heap;

    // Save resume_gen before any dispatch below runs, since a builtin constructor
    // dispatched further down can itself set vm.heap.resume_gen for its own
    // callee before this function's own save point, corrupting the caller's
    // resume state once restored. See vm_call_fn_impl for the same fix.
    void* saved_resume_gen_outer2 = vm.heap.resume_gen;

    // Lightfuncs can't be constructors.
    if (func.is_lightfunc()) return undef;
    if (!func.is_object() || func.get_heapptr() == null) return undef;
    HObject* ctor = (HObject*)func.get_heapptr();
    if (ctor == null || !ctor.flags.callable) return undef;

    // Determine the new.target object. Reflect.construct may supply a different
    // constructor; ordinary `new` calls pass the callee itself.
    HObject* new_target_obj = ctor;
    if (new_target.is_object() && new_target.get_heapptr() != null) {
        new_target_obj = (HObject*)new_target.get_heapptr();
    }

    // Bound function [[Construct]] (ECMA-262 §9.4.1.2):
    //   5. If SameValue(F, newTarget) is true, let newTarget be target.
    //   6. Return ? Construct(target, args, newTarget).
    // Without the unwrap, a plain `new bound()` would pass the bound function
    // itself as new.target and ordinary `Reflect.construct(bound, [], X)` would
    // not retarget to the underlying target when X === bound.
    if (ctor.flags.is_bound) {
        // [[BoundTargetFunction]]/[[BoundArguments]] live directly on the
        // object (not property-table entries; see HObjectFunction.bound.target
        // in hobject.c3).
        TVal target_tv = (*ctor.extra_ptr()).func.bound.target;
        HObject* args_arr = (*ctor.extra_ptr()).func.bound.args;

        // ECMA-262 §9.4.1.2: Extract bound arguments and prepend them.
        uint bound_argc = 0;
        if (args_arr != null) {
            HString* len_key = heap.str(heap::BuiltinStr.LENGTH);
            if (len_key != null) {
                TVal? lv = args_arr.get_prop_proto(len_key, heap);
                if (try l = lv) {
                    if (l.is_fastint()) {
                        bound_argc = (uint)l.get_fastint();
                    } else if (l.is_number()) {
                        bound_argc = (uint)l.get_number();
                    }
                }
            }
        }

        uint total_argc = bound_argc + nargs;
        TVal* combined_args = null;
        if (total_argc > 0) {
            combined_args = (TVal*)heap.alloc_func(heap.heap_udata, TVal::size * total_argc);
            if (combined_args == null) return undef;
        }
        defer if (combined_args != null) heap.free_func(heap.heap_udata, combined_args);

        // Copy bound args
        uint combined_idx = 0;
        if (args_arr != null) {
            for (uint i = 0; i < bound_argc && combined_idx < total_argc; i++) {
                // A miss (hole / failed key intern) still consumes a
                // slot as undefined so the call args don't shift left.
                TVal ev;
                ev.set_undefined();
                char[20] buf;
                int n = (int)(io::bprintf(&buf, "%d", i) ?? buf[:0]).len;
                if (n > 0 && n < 20) {
                    HString* ek = builtins::builtin_intern_string(heap, buf[:n]);
                    if (ek != null) {
                        TVal? e = args_arr.get_prop_proto(ek, heap);
                        if (try got = e) ev = got;
                    }
                }
                combined_args[combined_idx++] = ev;
            }
        }

        // Append call args
        for (uint i = 0; i < nargs && combined_idx < total_argc; i++) {
            combined_args[combined_idx++] = args[i];
        }

        TVal target_as_new = new_target;
        // SameValue(F, newTarget): if the caller passed the bound fn itself
        // as newTarget, swap it for the underlying target so downstream's
        // `new.target` reflects the original target.
        TVal f_as_tv; f_as_tv.set_object(ctor);
        if (builtins::same_value(f_as_tv, new_target)) {
            target_as_new = target_tv;
        }
        return vm_construct_fn_impl(vm_ptr, target_tv, combined_args, combined_idx, target_as_new);
    }

    // HObjectProxy.target overlays HObjectFunction.comp_func (both offset 0),
    // so reading comp_func directly on a Proxy exotic object would reinterpret
    // its [[ProxyTarget]] pointer as a CompiledFunction*. Route Proxies (and
    // any other BUILTIN_FN) through the builtin-dispatch branch below instead.
    CompiledFunction* target = ctor.callable_kind() == hobject::CallableKind.BUILTIN_FN
        ? null : (*ctor.extra_ptr()).func.comp_func;
    if (target != null) { if (catch compiler::materialize_function(target, heap)) return undef; }
    // Derived class constructors (`class X extends Y`) do NOT create `this`
    // here, since super() creates it inside the base [[Construct]] (ECMA-262 §9.2.2
    // step 5). Start with an uninitialized (TDZ-sentinel) this_binding and mark
    // the activation DERIVED so SUPER_CALL initializes it; otherwise the
    // constructed instance (e.g. a Promise subclass) is lost and combinator
    // capabilities read back as uninitialized.
    bool is_derived_target = (target != null && target.is_derived_ctor());

    // GetPrototypeFromConstructor(new_target, "%Object.prototype%") is
    // OrdinaryCreateFromConstructor work for an ordinary constructor that
    // actually creates `this` (ECMA-262 §9.1.14). A built-in or bound
    // constructor allocates its own instance and a derived constructor gets
    // `this` from super(), so none of them may fire the observable
    // Get(new_target, "prototype") here: the real constructor performs it,
    // and firing it twice breaks a Proxy new.target whose get trap counts
    // calls (test262 staging/sm/Error/constructor-ordering).
    TVal this_tv;
    if (target == null
        || ctor.callable_kind() == hobject::CallableKind.BOUND_FN
        || is_derived_target) {
        this_tv.set_undefined();
    } else {
        HObject*? new_this_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err_t = new_this_raw) return undef;
        HObject* new_this = new_this_raw;
        new_this.prototype = heap.object_proto;
        HString* ctor_proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        if (ctor_proto_key != null) {
            bool have_proto = false;
            if (try proto_tv = new_target_obj.get_prop_proto(ctor_proto_key, heap)) {
                if (proto_tv.is_object() && proto_tv.get_heapptr() != null) {
                    heap.set_prototype(new_this, (HObject*)proto_tv.get_heapptr());
                    have_proto = true;
                }
            }
            if (!have_proto) {
                // GetPrototypeFromConstructor step 6: the non-object fallback
                // goes through GetFunctionRealm(new_target), which throws when
                // a Proxy in the chain has been revoked.
                if (try realm = heap::function_realm(heap, new_target)) {
                    heap.set_prototype(new_this, heap.realm_intrinsic(realm, heap.object_proto));
                } else {
                    vm_host_throw(vm, heap.type_err_proto, "Cannot get the realm of a revoked proxy");
                    return undef;
                }
            }
        }
        if (new_target_obj == ctor && target.call_flags.constructor_capacity > hobject::INLINE_PROPS) {
            new_this.reserve_props(heap, constructor_reserve_capacity(target.call_flags.constructor_capacity));
        }
        this_tv.set_object(new_this);
    }
    if (is_derived_target) {
        this_tv = env::tdz_sentinel();
    }
    // Note: target == null is the correct signal for "not a compiled
    // function" (e.g. a built-in). A compiled function with num_regs == 0
    // (empty body, no locals/params referenced) is still a real constructor
    // and must run through the compiled-function activation path below, so
    // routing it into the builtin-dispatch branch here would silently no-op
    // any user constructor with an empty or trivial body.
    if (target == null) {
        // A built-in constructor dispatches directly. Bound functions also
        // dispatch through builtin_fn_index (Builtin.BOUND_CALL.ordinal), so route
        // them through the same builtin-dispatch path as BUILTIN_FN.
        if (ctor.callable_kind() == hobject::CallableKind.BUILTIN_FN
            || ctor.callable_kind() == hobject::CallableKind.BOUND_FN) {
            int builtin_idx = (*ctor.extra_ptr()).func.builtin_fn_index;
            // For Promise, allocate as PROMISE class so builtin_promise
            // initialises the right internal slots.
            if (builtin_idx == (int)builtins::Builtin.PROMISE.ordinal) {
                HObject*? prom_this_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
                if (catch err_p = prom_this_raw) return undef;
                HObject* prom_this = prom_this_raw;
                prom_this.prototype = heap.promise_proto;
                builtins::promise_init(prom_this);
                this_tv.set_object(prom_this);
            }
            TVal[18] temp_regs;
            temp_regs[0] = func;
            temp_regs[1] = this_tv;
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[2 + i] = args[i];
            }
            builtins::BuiltinContext bctx;
            bctx.callee_obj = null;
            bctx.vm = vm;
            bctx.regs = &temp_regs;
            bctx.base_reg = 2;
            bctx.argc = (ushort)nargs;
            bctx.result = builtins::result_slot(&temp_regs[0]);
            bctx.heap = heap;
            bctx.this_val = this_tv;
            bctx.is_constructor = true;
            bctx.needs_re_dispatch = false;
            bctx.re_nargs = 0;
            bctx.global_env = vm.global_env;
            bctx.should_throw = false;
            bctx.callee_obj = ctor;
            bctx.new_target = new_target_obj;
            builtins::dispatch_builtin((uint)builtin_idx, &bctx);
            if (bctx.should_throw) {
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &bctx.throw_value);
                vm.heap.tval_copy_ref(&vm.return_val, &bctx.throw_value);
                return undef;
            }
            if (bctx.needs_re_dispatch) {
                // Bound function whose downstream target is a compiled function
                // (or another non-directly-dispatchable callable): builtin_bound_call
                // placed the resolved downstream callee/args in temp_regs and asked
                // for a re-dispatch. ECMA-262 §9.4.1.2 BoundFunctionExoticObject.[[Construct]]:
                // Construct(BoundTargetFunction, args, newTarget === F ? BoundTargetFunction : newTarget).
                TVal downstream_func = temp_regs[0];
                TVal downstream_new_target = (new_target_obj == ctor) ? downstream_func : new_target;
                uint new_nargs = bctx.re_nargs;
                TVal[16] fwd_args;
                for (uint i = 0; i < new_nargs && i < 16; i++) {
                    fwd_args[i] = temp_regs[2 + i];
                }
                return vm_construct_fn_impl(vm_ptr, downstream_func, &fwd_args, new_nargs, downstream_new_target);
            }
            TVal result = bctx.result.get();
            if (result.is_object()) return result;
            if (result.is_undefined()) return this_tv;
            return result;
        }
        return undef;
    }

    // Compiled user-defined function: set up a constructor activation.
    uint nregs = target.num_regs;
    if (vm_run_depth_exceeded(vm)) return undef;
    if (!vm.valstack_top || !vm.valstack) return undef;
    uint needed_slots = (uint)((char*)vm.valstack_top - (char*)vm.valstack) / TVal::size + nregs;
    if (needed_slots > vm.valstack_size / TVal::size) {
        if (!ensure_valstack(vm, needed_slots)) return undef;
    }

    // Save current VM state for restoration after the constructor returns.
    uint saved_act_count = vm.activation_count;
    TVal* saved_valstack_bottom = vm.valstack_bottom;
    TVal* saved_valstack_top = vm.valstack_top;
    TVal* saved_valstack = vm.valstack;
    CompiledFunction* saved_current_func = vm.current_func;
    void* saved_resume_gen = saved_resume_gen_outer2;  // captured before the builtin-constructor dispatch above could overwrite it

    Activation[] saved_acts = vm.activations[0:saved_act_count];
    ShadowActFrame shadow_frame;
    vm.save_activation_roots(&shadow_frame, saved_acts);
    bool roots_linked = true;
    defer if (roots_linked) vm.pop_activation_roots(&shadow_frame);

    TVal* frame = vm.valstack_top;
    vm.activations += (sz)saved_act_count;
    vm.activation_capacity -= saved_act_count;
    mem::clear(vm.activations, Activation::size);
    vm.gc_root_active_replaced();
    vm.activation_count = 1;
    Activation* act = &vm.activations[0];

    EnvRecord* cfn_var_env = (*ctor.extra_ptr()).func.var_env;
    if (try fv_cfn = env::env_create_function_scope(heap, (*ctor.extra_ptr()).func.var_env, (*ctor.extra_ptr()).func.comp_func.scope_capacity())) {
        cfn_var_env = fv_cfn;
    }
    act.func = target;
    act.tv_func = func;
    vm.heap.shade_root_tval(act.tv_func);
    act.parent = null;
    act.var_env = cfn_var_env;
    vm.heap.shade_root_env(act.var_env);
    act.lex_env = resolve_call_lex_env(vm, ctor, target, cfn_var_env);
    vm.heap.shade_root_env(act.lex_env);
    act.cat = null;
    act.forin = null;
    act.curr_pc = target.code;
    act.async_promise = null;
    act.async_gen_state = null;
    act.bottom = frame;
    act.retval = null;
    act.flags = ACT_FLAG_CONSTRUCT
              | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
              | (is_derived_target ? ACT_FLAG_DERIVED : 0);
    act.heap_reg_count = 0;
    act.caller_valstack_top = frame + nregs;
    act.this_binding = this_tv;
    vm.heap.shade_root_tval(act.this_binding);
    act.new_target = new_target_obj;
    vm.heap.shade_root_object(act.new_target);

    for (uint i = 0; i < nregs; i++) {
        frame[i].set_undefined();
    }
    uint copy_n = nargs < nregs ? nargs : nregs;
    for (uint i = 0; i < copy_n; i++) {
        vm.heap.tval_copy_ref(&frame[i], &args[i]);
        track_heap_store(act, &frame[i], i);
    }
    // Rest parameter: collect overflow args (indices num_formals..nargs-1) into
    // an array in the rest slot, mirroring the normal call path. Without this a
    // rest-param function invoked through construct_fn (e.g. a derived class's
    // implicit `constructor(...args){ super(...args); }`) sees the raw first arg
    // in the rest slot instead of an array, so `super(...args)` forwards nothing
    // and the base constructor's executor never runs.
    if (target.has_rest()) {
        uint formals = (uint)target.num_formals;
        uint rest_idx = formals;
        uint overflow = (nargs > formals) ? (nargs - formals) : 0;
        if (rest_idx < nregs) {
            frame[rest_idx] = build_rest_parameter(vm.heap, target, args + formals, overflow);
            track_heap_store(act, &frame[rest_idx], rest_idx);
        }
    }
    if (target.uses_arguments()) {
        bind_arguments(vm, act, target, ctor, frame, nargs, true);
    }

    publish_frame_top(vm, frame, nregs, nargs);
    vm.valstack_bottom = frame;
    vm.current_func = target;

    TVal? result_opt = Vm.run(vm);
    TVal result;
    bool ctor_faulted = false;
    TVal ctor_error; ctor_error.set_undefined();
    if (try r = result_opt) {
        result = r;
    } else {
        result = vm.return_val;
        // An uncaught throw inside the constructor (e.g. super() to a
        // TypedArray ctor raising RangeError) unwinds Vm.run to a fault.
        // vm_uncaught_error already latched heap.error_value; preserve it so
        // the caller sees a thrown error rather than a swallowed stale value.
        if (vm.heap.has_error) {
            ctor_faulted = true;
            vm.heap.tval_copy_ref(&ctor_error, &vm.heap.error_value);
        }
    }

    // ECMA-262 §12.3.5.2: if constructor returns an object, that's the new instance.
    // For a derived constructor `this_tv` started as the TDZ sentinel; the real
    // instance was bound by super() into the activation's this_binding, so read
    // it back from there (act still points at vm.activations[0], pre-restore).
    TVal final_this = this_tv;
    if (is_derived_target) {
        final_this = act.this_binding;
    }
    if (result.is_object() && result.get_heapptr() != null) {
        final_this = result;
    }

    // Relocate saved pointers if valstack moved during the constructor run.
    relocate_saved_frames(vm, saved_valstack, &saved_valstack_bottom,
                          &saved_valstack_top);

    // Restore VM state.
    vm.gc_root_active_replaced();
    vm.activation_count = saved_act_count;
    vm.current_func = saved_current_func;
    vm.activations = saved_acts.ptr;
    vm.activation_capacity += saved_act_count;
    vm.pop_activation_roots(&shadow_frame);
    roots_linked = false;
    vm.valstack_bottom = saved_valstack_bottom;
    vm.valstack_top = saved_valstack_top;
    vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;
    vm.heap.shade_root_generator_state(vm.heap.resume_gen);

    vm.heap.drain_microtasks((void*)vm);

    // Re-surface a constructor fault after state restore and the microtask
    // drain (either can clear the error channel). Callers of construct_fn
    // (e.g. TypedArray subarray/slice species paths) check heap.has_error.
    if (ctor_faulted) {
        vm.has_error = true;
        vm.heap.has_error = true;
        vm.heap.tval_copy_ref(&vm.heap.error_value, &ctor_error);
        return ctor_error;
    }
    return final_this;
}

fn TVal? Vm.execute(Vm* vm, CompiledFunction* func) {
    // Set up initial activation (matches outer executor setup)
    Activation* entry_act = &vm.activations[0];
    vm.gc_root_active_replaced();
    vm.activation_count = 1;
    // An uncaught throw ends a run with the flag set; left stale, it would make
    // the next run's native getters report a fault.
    vm.has_error = false;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = vm.global_env;
    vm.heap.shade_root_env(entry_act.var_env);
    entry_act.lex_env = vm.global_lex_env != null ? vm.global_lex_env : vm.global_env;
    vm.heap.shade_root_env(entry_act.lex_env);
    entry_act.cat = null;
    entry_act.forin = null;
    entry_act.curr_pc = func.code;  // Points into bytecode
    entry_act.retval = null;
    entry_act.flags = 0;
    // sloppy `arguments.callee` reads ds.act.tv_func; the script's outermost
    // activation never has a "callee" value (no function wraps it), so leave
    // the field undefined. vm_reset() does the same at session start.
    entry_act.tv_func.set_undefined();
    // activations[0] is reused across entries without zeroing; a prior async
    // module/function body at this index would otherwise leave both fields
    // pointing at its Promise/GeneratorState.
    entry_act.async_promise = null;
    entry_act.async_gen_state = null;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    // ECMA-262 §10.4.1: global `this` is the global object for non-strict scripts.
    TVal this_val;
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    // Allocate value stack slots for the function (nregs = total register count)
    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    // Initialize registers to undefined
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    // Set after ensure_valstack: a growing realloc may have moved vm.valstack,
    // so capturing entry_act.bottom beforehand would leave it pointing into
    // the freed buffer.
    entry_act.bottom = vm.valstack;
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    // The top-level activation has no caller, but caller_valstack_top must be
    // set to a valid value so that RET restoring back to this activation
    // (after a compiled callee returns) doesn't corrupt vm.valstack_top.
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    // A top-level uncaught error must survive the drain below: each queued
    // job runs through vm_call_handler_fn_impl, which unconditionally clears
    // heap.has_error (so a stale error from a PRIOR job can't resurface
    // inside the next one) even though nothing here queued a new error yet.
    // That clear also wipes the flag for the uncaught error `run` just set,
    // while error_value itself is untouched and stays GC-rooted (see
    // Heap.mark/error_value), so latch the flag and restore it once the
    // drain (which legitimately owns has_error while jobs run) is done.
    bool had_error = vm.heap.has_error;

    // Drain microtask queue after top-level script execution
    vm.heap.drain_microtasks((void*)vm);

    if (had_error) vm.heap.has_error = true;

    // An interrupt that aborted the drain must surface as this run's failure,
    // not be swallowed by the successful main-run result. The interrupted job
    // left has_error set, error_value rooted, and the uncatchable flag set for
    // the host boundary; deliver the same shape an uncaught throw would.
    if (vm.heap.uncatchable_throw) return VM_ERROR~;

    return result;
}

// Execute a compiled function with a specific environment (for ESM modules).
// Same as execute() but uses the provided env for var_env/lex_env instead
// of the global environment.
fn TVal? Vm.execute_in_env(Vm* vm, CompiledFunction* func, EnvRecord* env) {
    Activation* entry_act = &vm.activations[0];
    vm.gc_root_active_replaced();
    vm.activation_count = 1;
    // An uncaught throw ends a run with the flag set; left stale, it would make
    // the next run's native getters report a fault.
    vm.has_error = false;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = env;
    vm.heap.shade_root_env(entry_act.var_env);
    entry_act.lex_env = env;
    vm.heap.shade_root_env(entry_act.lex_env);
    entry_act.cat = null;
    entry_act.forin = null;
    entry_act.curr_pc = func.code;
    entry_act.retval = null;
    entry_act.flags = 0;
    // ds.act.tv_func drives sloppy arguments.callee; the script's outermost
    // activation has no callable wrapping it, so the field is undefined here.
    entry_act.tv_func.set_undefined();
    // activations[0] is reused across entries without zeroing; a prior async
    // module/function body at this index would otherwise leave both fields
    // pointing at its Promise/GeneratorState.
    entry_act.async_promise = null;
    entry_act.async_gen_state = null;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    // A Module Environment Record's HasThisBinding() is true but
    // GetThisBinding() always returns undefined (ECMA-262 §8.1.1.5.4), so this
    // entry point is module-execution only, so `this` at module top level is
    // unconditionally undefined, never globalThis.
    TVal this_val;
    this_val.set_undefined();
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    // Set after ensure_valstack: a growing realloc may have moved vm.valstack,
    // so capturing entry_act.bottom beforehand would leave it pointing into
    // the freed buffer.
    entry_act.bottom = vm.valstack;
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    // See the matching latch in Vm.execute(): the drain below runs jobs
    // through vm_call_handler_fn_impl, which unconditionally clears
    // heap.has_error, wiping the flag for the uncaught error `run` just set.
    bool had_error = vm.heap.has_error;

    vm.heap.drain_microtasks((void*)vm);

    if (had_error) vm.heap.has_error = true;

    // An interrupt that aborted the drain must surface as this run's failure,
    // not be swallowed by the successful main-run result. The interrupted job
    // left has_error set, error_value rooted, and the uncatchable flag set for
    // the host boundary; deliver the same shape an uncaught throw would.
    if (vm.heap.uncatchable_throw) return VM_ERROR~;

    return result;
}

// Execute a module body that may contain top-level await, as an async
// activation. Allocates the module's evaluation Promise, marks the entry
// activation ACT_FLAG_ASYNC, runs the body (which suspends on top-level
// `await` via the same machinery as async functions), then drives the
// microtask queue until the promise settles.
//
// Returns true if the module evaluated to completion (promise fulfilled or
// still pending with an empty queue, which counts as success). Returns false if
// the module's evaluation promise REJECTED; in that case the rejection reason
// is left in heap.error_value so the caller surfaces it as the module's
// uncaught error. Returns a fault only on hard setup failure.
fn bool? Vm.execute_module_async(Vm* vm, CompiledFunction* func, EnvRecord* env, HObject** out_pending) {
    // Allocate the module evaluation Promise up front so top-level await can
    // suspend into it and RET can settle it.
    HObject*? prom_raw = vm.heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return err~;
    HObject* mod_promise = prom_raw;
    mod_promise.prototype = vm.heap.promise_proto;
    builtins::promise_init(mod_promise);
    // Internal to this evaluation: its rejection is handed back through
    // heap.error_value (or adopted by the module's eval_promise when the body
    // suspends), never left for user code to observe. Marking it handled up
    // front keeps a module whose body throws from also reporting a bogus
    // unhandled rejection alongside the real one on the import() promise.
    (*mod_promise.extra_ptr()).promise.is_handled = true;
    // Pin it across the evaluation + microtask drain so GC can't sweep it
    // transiently, and released before returning.
    mod_promise.as_header().incref();

    Activation* entry_act = &vm.activations[0];
    vm.gc_root_active_replaced();
    vm.activation_count = 1;
    // An uncaught throw ends a run with the flag set; left stale, it would make
    // the next run's native getters report a fault.
    vm.has_error = false;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = env;
    vm.heap.shade_root_env(entry_act.var_env);
    entry_act.lex_env = env;
    vm.heap.shade_root_env(entry_act.lex_env);
    entry_act.cat = null;
    entry_act.forin = null;
    entry_act.curr_pc = func.code;
    entry_act.retval = null;
    entry_act.flags = ACT_FLAG_ASYNC;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }
    entry_act.async_promise = mod_promise;
    vm.heap.shade_root_object(entry_act.async_promise);
    entry_act.async_gen_state = null;
    entry_act.tv_func.set_undefined();

    // A Module Environment Record's HasThisBinding() is true but
    // GetThisBinding() always returns undefined (ECMA-262 §8.1.1.5.4), so this
    // entry point is module-execution only, so `this` at module top level is
    // unconditionally undefined, never globalThis.
    TVal this_val;
    this_val.set_undefined();
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        vm.heap.decref(mod_promise.as_header());
        return VM_ERROR~;
    }
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    // Set after ensure_valstack: a growing realloc may have moved vm.valstack,
    // so capturing entry_act.bottom beforehand would leave it pointing into
    // the freed buffer.
    entry_act.bottom = vm.valstack;
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    // Run the body. If it completes synchronously, RET settles mod_promise
    // (fulfilled) or a throw rejects it. If it suspends on top-level await,
    // Vm.run returns and the reactions run during a later drain, eventually
    // settling mod_promise.
    (void)Vm.run(vm);
    // Clear a synchronous throw: for an async body a thrown value must reject
    // the promise (which RET/the unwind already did), not remain a live VM
    // fault, so the caller sees a settled promise instead.
    vm.has_error = false;
    vm.heap.has_error = false;

    // Never pump the microtask queue here to wait for settlement. Per
    // ECMA-262 §16.2.1.5.2/§16.2.1.5.5, an async/TLA module's evaluation
    // does not block: the caller (a sibling static import in the same DFS,
    // or a dynamic import job) must move on and let mod_promise settle later
    // via its own reactions. Polling to completion was both wrong per spec
    // (it made a static import of an async sibling module block, when
    // §16.2.1.5.5's "Execute dependencies first" step must not wait; see
    // top-level-await/async-module-does-not-block-sibling-modules.js) and
    // actively unsafe when reached from inside a drain (a dynamic import job
    // is itself a queued microtask; drain_microtasks' reentrancy guard would
    // silently no-op, making a poll loop spin until its guard budget
    // exhausted). Every entry point that needs to observe eventual
    // completion (run_module_file's top-level drain loop, a dynamic import
    // job chaining onto eval_promise) does so by draining after this
    // function returns, not by blocking inside it.
    uint final_state = builtins::promise_get_state(mod_promise, builtins::PROMISE_PENDING);
    if (final_state == builtins::PROMISE_PENDING) {
        // Still pending: hand the pinned promise to the caller so it can
        // chain mod.eval_promise onto it (promise_adopt_native) instead of
        // polling. The caller now owns the pinning reference.
        *out_pending = mod_promise;
        return true;
    }

    bool rejected = final_state == builtins::PROMISE_REJECTED;
    if (rejected) {
        TVal reason = builtins::promise_get_result(mod_promise);
        vm.heap.tval_copy_ref(&vm.heap.error_value, &reason);
        vm.heap.has_error = true;
    }

    vm.heap.decref(mod_promise.as_header());
    return !rejected;
}

// Execute a module body while the VM is already mid-dispatch (dynamic
// import from a running module or script). Unlike execute_in_env /
// execute_module_async, which take over activations[0] and valstack[0] and so
// destroy the caller's live frame. The nested module uses the free activation
// segment and registers above its caller, mirroring vm_call_fn_impl.
//
// Returns true when the module body evaluated to completion; false when it
// threw, for a sync body, or its evaluation promise rejected, for an async or
// TLA body.
// in that case the thrown value / rejection reason is left in
// heap.error_value. Faults only on hard setup failure. For an async/TLA
// body that is still pending once this call returns (top-level await
// suspended and cannot be polled to completion here, since this is reached from
// inside a microtask drain such as a dynamic import job),
// `*out_pending` is set to the pinned per-evaluation promise so the caller
// can chain onto it instead; `true` is returned in that case too (not yet
// known to have failed).
// `out_completion`, when non-null, receives the body's completion value: the
// Script completion $262.evalScript must return (ECMA-262 §18.2.1
// ScriptEvaluation). Module callers pass null, since a module body evaluates
// to undefined and has no completion to observe.
fn bool? Vm.execute_module_nested(Vm* vm, CompiledFunction* func, EnvRecord* env, HObject** out_pending, TVal* out_completion = null) {
    uint nregs = func.num_regs;

    // A module body nests another Vm.run with its own activation save area, so
    // it counts against the same native stack budget as a native re-entry.
    if (vm_run_depth_exceeded(vm)) return false;

    // Compute the true top of the current (topmost live) activation's
    // register file. vm.valstack_top is NOT updated for inline JS-to-JS
    // calls, so it may point below the caller's full register space; the
    // nested module frame must be placed above that to avoid overlap.
    TVal* true_top = vm.valstack_top;
    if (vm.activation_count > 0) {
        Activation* cur_act = &vm.activations[vm.activation_count - 1];
        CompiledFunction* cur_func = (CompiledFunction*)cur_act.func;
        if (cur_func != null) {
            TVal* act_top = cur_act.bottom + cur_func.num_regs;
            if (act_top > true_top) true_top = act_top;
        }
    }

    // Grow the valstack first (while activation_count is still the
    // caller's, so ensure_valstack_grow relocates all live pointers). The
    // module frame is placed above all live caller registers.
    uint true_used = (uint)(true_top - vm.valstack);
    if (true_top + nregs + FRAME_SCRATCH_SLOTS > vm.valstack_end) {
        if (!ensure_valstack_grow(vm, true_used + nregs + FRAME_SCRATCH_SLOTS)) {
            return VM_ERROR~;
        }
        // Recompute true_top after potential realloc
        if (vm.activation_count > 0) {
            Activation* cur_act2 = &vm.activations[vm.activation_count - 1];
            CompiledFunction* cur_func2 = (CompiledFunction*)cur_act2.func;
            if (cur_func2 != null) {
                TVal* act_top2 = cur_act2.bottom + cur_func2.num_regs;
                true_top = (act_top2 > vm.valstack_top) ? act_top2 : vm.valstack_top;
            } else {
                true_top = vm.valstack_top;
            }
        } else {
            true_top = vm.valstack_top;
        }
    }

    // Save current VM state (after potential realloc).
    uint saved_act_count = vm.activation_count;
    TVal* saved_valstack_bottom = vm.valstack_bottom;
    TVal* saved_valstack_top = vm.valstack_top;
    TVal* saved_valstack = vm.valstack;
    CompiledFunction* saved_current_func = vm.current_func;
    void* saved_resume_gen = vm.heap.resume_gen;

    Activation[] saved_acts = vm.activations[0:saved_act_count];
    ShadowActFrame shadow_frame;
    vm.save_activation_roots(&shadow_frame, saved_acts);
    bool roots_linked = true;
    defer if (roots_linked) vm.pop_activation_roots(&shadow_frame);

    bool is_async_body = func.is_async();
    HObject* mod_promise = null;
    if (is_async_body) {
        // Allocate the module evaluation Promise up front, before touching
        // activation state, so top-level await can suspend into it and RET
        // can settle it. On failure no VM state has been modified yet.
        HObject*? prom_raw = vm.heap.alloc_object(hobject::ObjClass.PROMISE);
        if (catch err = prom_raw) return err~;
        mod_promise = prom_raw;
        mod_promise.prototype = vm.heap.promise_proto;
        builtins::promise_init(mod_promise);
        // Internal to this evaluation, as in execute_module_async above: the
        // rejection reaches the caller through heap.error_value, so it must
        // not also surface as an unhandled rejection.
        (*mod_promise.extra_ptr()).promise.is_handled = true;
        // Pin it across the evaluation + microtask drain so GC can't sweep
        // it transiently, releasing it before returning.
        mod_promise.as_header().incref();
    }

    TVal* frame = true_top;

    vm.activations += (sz)saved_act_count;
    vm.activation_capacity -= saved_act_count;
    mem::clear(vm.activations, Activation::size);
    Activation* act = &vm.activations[0];
    vm.gc_root_active_replaced();
    vm.activation_count = 1;
    act.func = func;
    act.parent = null;
    act.var_env = env;
    vm.heap.shade_root_env(act.var_env);
    // A global Script ($262.evalScript / indirect eval at global scope) runs
    // with var_env = the global object record but lex_env = the persistent
    // global DeclarativeRecord, so top-level let/const/class land there rather
    // than on the global object. ESM modules pass their own combined env.
    act.lex_env = (env == vm.global_env && vm.global_lex_env != null) ? vm.global_lex_env : env;
    vm.heap.shade_root_env(act.lex_env);
    act.cat = null;
    act.forin = null;
    act.curr_pc = func.code;
    act.async_gen_state = null;
    act.tv_func.set_undefined();
    act.bottom = frame;
    act.retval = null;
    act.heap_reg_count = 0;
    act.caller_valstack_top = frame + nregs;
    act.flags = (func.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
    if (is_async_body) {
        act.flags |= ACT_FLAG_ASYNC;
        act.async_promise = mod_promise;
        vm.heap.shade_root_object(act.async_promise);
    } else {
        act.async_promise = null;
    }

    // A global Script's `this` is the global object (ECMA-262 §9.4.4.4). A
    // Module Environment Record's GetThisBinding() returns undefined
    // (§9.1.1.5.4), so `this` at module top level is undefined. The binding
    // is not owned (no ACT_FLAG_THIS_OWNED): the global object outlives it.
    TVal this_val;
    if (env == vm.global_env && env.bindings != null) {
        this_val.set_object(env.bindings);
    } else {
        this_val.set_undefined();
    }
    // The environment roots this borrowed script receiver.
    act.this_binding = this_val;
    vm.heap.shade_root_tval(act.this_binding);

    for (uint i = 0; i < nregs; i++) {
        frame[i].set_undefined();
    }
    publish_frame_top(vm, frame, nregs, 0);
    vm.valstack_bottom = frame;
    vm.current_func = func;
    // The nested body must not accidentally match the caller's pending
    // resume state.
    vm.heap.resume_gen = null;

    TVal? run_res = Vm.run(vm);
    bool run_faulted = false;
    if (catch err = run_res) {
        run_faulted = true;
    } else if (out_completion != null) {
        // Take a reference while the value is still anchored by the inner
        // frame: the register file is torn down below, and a raw struct copy
        // would leave the caller holding a heap pointer it does not own.
        vm.heap.tval_copy_ref(out_completion, &run_res);
    }

    if (is_async_body) {
        // Clear a synchronous throw: for an async body a thrown value must
        // reject the promise (which RET/the unwind already did), not
        // remain a live VM fault.
        vm.has_error = false;
        vm.heap.has_error = false;
        // Never pump the queue here; see the matching comment in
        // execute_module_async. mod_promise settles later via its own
        // reactions; the caller chains onto it (or leaves it pending, for
        // execute_module_nested's non-module eval-script caller) instead of
        // blocking.
    }

    relocate_saved_frames(vm, saved_valstack, &saved_valstack_bottom,
                          &saved_valstack_top);

    // Restore VM state (caller registers were never touched).
    vm.gc_root_active_replaced();
    vm.activation_count = saved_act_count;
    vm.current_func = saved_current_func;
    vm.activations = saved_acts.ptr;
    vm.activation_capacity += saved_act_count;
    vm.pop_activation_roots(&shadow_frame);
    roots_linked = false;
    vm.valstack_bottom = saved_valstack_bottom;
    vm.valstack_top = saved_valstack_top;
    vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;
    vm.heap.shade_root_generator_state(vm.heap.resume_gen);

    if (is_async_body) {
        uint final_state = builtins::promise_get_state(mod_promise, builtins::PROMISE_PENDING);
        if (final_state == builtins::PROMISE_PENDING) {
            // Still pending: hand the pinned promise to the caller so it can
            // chain mod.eval_promise onto it instead of polling. The caller
            // now owns the pinning reference.
            *out_pending = mod_promise;
            return true;
        }
        // Inspect the settled promise while it is still pinned.
        bool rejected = final_state == builtins::PROMISE_REJECTED;
        if (rejected) {
            TVal reason = builtins::promise_get_result(mod_promise);
            vm.heap.tval_copy_ref(&vm.heap.error_value, &reason);
            vm.heap.has_error = true;
        }
        vm.heap.decref(mod_promise.as_header());
        return !rejected;
    }

    // Sync body: if the run faulted, the uncaught-error unwind already
    // copied the thrown value into vm.heap.error_value.
    return !run_faulted;
}

// Charge one interrupt poll point. Called from the switch sites and from the
// threaded burst, which share the budget, so decrements overlap harmlessly:
// at zero the budget resets to INIT and interrupt_due latches, and resetting
// in the same step keeps the budget from ever sitting at zero where a second
// decrement would underflow.
fn void vm_charge_interrupt(Heap* h) @inline {
    if ((h.capi_interrupt_fn != null || h.capi_runtime != null) && --h.interrupt_budget == 0) {
        h.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
        h.interrupt_due = true;
    }
}

// Poll the C-API interrupt handler at a VM safepoint (a backward branch or
// the restart-loop top). Fire only when a charge latched interrupt_due; with
// no handler installed or no charge pending, this is a null compare. Returns
// true when the dispatch loop must stop: the handler aborted, and either a
// finally catcher consumed the "interrupted" error (needs_restart set, outer
// loop resumes) or no catcher existed anywhere (the uncaught error is
// recorded; caller returns VM_ERROR~).
fn bool vm_poll_interrupt(Vm* vm, Activation* act, Instruction** curr_pc, bool* needs_restart) {
    Heap* h = vm.heap;
    if (h.capi_interrupt_fn == null && h.capi_runtime == null) return false;
    if (!h.interrupt_due) return false;
    h.interrupt_due = false;
    if (!h.poll_interrupt()) return false;
    // Abort. The error is a genuine Error marked uncatchable: catch catchers
    // skip it (vm_throw_value) but finally blocks still run, and the flag is
    // cleared only when the host receives the BK_ERR_INTERRUPT status.
    h.uncatchable_throw = true;
    vm_throw_error(vm, h.err_proto, "interrupted", act, curr_pc, needs_restart);
    return true;
}

// Move ds.curr_pc by a branch's `offset`. A backward branch is a safepoint:
// it charges the GC budget and polls the interrupt handler. Returns false when
// the handler aborted and nothing caught it. When a finally caught the abort,
// ds.curr_pc points at it and ds.needs_restart is set instead of the branch
// being taken.
fn bool vm_branch(Dispatch* ds, int offset) @inline {
    if (offset < 0) {
        Heap* h = ds.vm.heap;
        bool hot = false;
        if (--h.bwd_gc_budget == 0) {
            if (h.gc_pending) h.safepoint_gc(heap::GC_LOOP_WORK);
            h.bwd_gc_budget = heap::BWD_GC_INTERVAL;
            // An interpreted loop that got hot continues in native code:
            // Vm.run restarts and enters the frame at the branch target.
            $if $feat(SLJIT):
                hot = h.jit_enabled && !ds.jit_native && jit::baseline_loop_hot(h, ds.vm.current_func);
            $endif
        }
        if (h.capi_interrupt_fn != null || h.capi_runtime != null) {
            vm_charge_interrupt(h);
            if (vm_poll_interrupt(ds.vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return ds.needs_restart;
        }
        if (hot) {
            ds.curr_pc += offset;
            ds.act.curr_pc = ds.curr_pc;
            ds.needs_restart = true;
            return true;
        }
    }
    ds.curr_pc += offset;
    return true;
}

// The order of two operands under the relational comparison (ECMA-262
// §7.2.13), one of ORDER_LT, ORDER_EQ, ORDER_GT, or ORDER_UN when the
// comparison is undefined (a NaN). ToPrimitive on an object operand can run
// user code, so the caller checks for a throw before using the result.
fn uint vm_relational_order(Vm* vm, TVal* b, TVal* c) {
    bool undef;
    int cmp = vm_relational_compare(vm, b, c, &undef);
    if (undef) return ORDER_UN;
    return cmp < 0 ? ORDER_LT : (cmp == 0 ? ORDER_EQ : ORDER_GT);
}

// Shorthand for the vm_check_to_number_throw(vm, ds.act, &ds.curr_pc,
// &ds.needs_restart) idiom repeated throughout the dispatch switch below.
// Only wraps the boolean check itself: `return`/`break` cannot escape a
// macro body to the caller's function/loop in C3, so callers still write
// out `if (!@tonum_ok(vm, &ds)) return vm_uncaught_error(...);` (and whatever
// follows, e.g. `if (ds.needs_restart) break;`) themselves.
// NOTE: takes `ds` BY POINTER — a regular macro param is passed by value, and
// Dispatch is a plain struct, so passing `ds` itself would copy it and the
// callee's writes to curr_pc/needs_restart would land on the copy, silently
// losing thrown-error state at every call site.
macro bool @tonum_ok(vm, Dispatch* ds) {
    return vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart);
}

// Applies the bitwise/shift operator selected by the compile-time $op to two
// already-ToInt32'd (or, for USHR's left operand, ToUint32'd) ints. Resolved
// entirely at compile time via $switch, so this costs nothing at runtime —
// each call site only ever emits the one case matching its own $op.
macro int @bitop_apply($op, int b, int c) {
    $switch $op:
        $case Opcode.BAND: return b & c;
        $case Opcode.BOR:  return b | c;
        $case Opcode.BXOR: return b ^ c;
        $case Opcode.SHL:  return b << (c & 0x1F);
        $case Opcode.SHR:  return b >> (c & 0x1F);
        $default: unreachable("unsupported @bitop_apply opcode");
    $endswitch
}

// Shared skeleton for BAND/BOR/BXOR/SHL/SHR (ECMA-262 §12.12.3 / §12.9.3):
// a fastint fast path, otherwise ToNumeric both operands, dispatch on BigInt,
// then apply the operator via the general ToInt32 path. Right-operand masking
// (`& 0x1F`) for the shift ops is baked into @bitop_apply's SHL/SHR cases
// above, so it isn't repeated here.
//
// USHR is deliberately NOT expressible here: its left operand is ToUint32
// (unsigned), not ToInt32, and it has no fastint fast path at all — folding
// it in would either add a fast path is doesn't have or flip its signedness,
// both behavior changes. It stays written out longhand below.
//
// The `@body()` here holds the repeated ToNumber-throw-check idiom
// (`if (!@tonum_ok(...)) return ...; if (ds.needs_restart) break;`), which
// contains `return`/`break` that must reach the CALLER's function/switch —
// see @tonum_ok above. A regular macro statement can't do that (return/break
// don't escape a macro's own body to the caller), but a trailing @body()
// block is inlined at the call site's own control-flow scope, so return and
// break inside it resolve against the call site's switch/function exactly as
// if it had been written out longhand there. Verified empirically (not just
// inferred from docs) that this differs from control flow written directly
// in a macro's own statements.
macro @bitop(TVal* ra, TVal* rb, TVal* rc, $op, vm, Dispatch* ds; @body()) {
    if (types::both_fastint(rb, rc)) {
        vm.heap.set_reg_fastint(ra, (long)@bitop_apply($op, (int)rb.get_fastint(), (int)rc.get_fastint()));
        return;
    }
    NumericOperands ops;
    if (!vm_numeric_operands(vm, rb, rc, &ops)) {
        @body();
    }
    defer ops.release(vm);
    if (ops.b.is_bigint() || ops.c.is_bigint()) {
        if (vm_bigint_binop(vm, $op, ra, ops.b, ops.c) == BigIntOpResult.THREW) {
            @body();
        }
        return;
    }
    int b = types::toint32(vm_to_number(vm, ops.b));
    @body();
    int c = types::toint32(vm_to_number(vm, ops.c));
    @body();
    vm.heap.set_reg_fastint(ra, (long)@bitop_apply($op, b, c));
}

// How vm_read_binding resolved a name.
enum BindingRead : char {
    FOUND,
    UNRESOLVABLE,
    // The read raised an exception through the VM: ds points at its catcher,
    // or the error is recorded as uncaught.
    THREW,
}

// SetMutableBinding on the object captured by a with Reference.
fn bool? vm_write_with_binding(Dispatch* ds, HObject* base, HString* key, TVal value) {
    Vm* vm = ds.vm;
    bool threw = false;
    bool is_strict_act = ds.act.func != null
        && ((CompiledFunction*)ds.act.func).is_strict();
    TVal recv; recv.set_object(base);
    // §9.1.1.2.5 SetMutableBinding step 2: re-check HasProperty
    // on the bindings object. For a Proxy with-env this fires
    // the `has` trap again so test262 set-mutable-binding-...-
    // with-proxy-env sees the expected sequence.
    bool has_still = false;
    if (!builtins::js_has_property(vm, vm.heap, base, (HString*)key, &has_still)) {
        if (vm.heap.has_error && !vm_throw_pending(vm, ds)) return VM_ERROR~;
        threw = true;
    } else if (!has_still && is_strict_act) {
        // §9.1.1.2.5 SetMutableBinding steps 3-4: the reference was
        // created against this bindings object, but the read side
        // deleted the binding. A strict reference throws a
        // ReferenceError and writes nothing. A sloppy one falls
        // through to [[Set]], which re-creates the property with the
        // new value (ECMA-262 §10.2.1.2.4's create-when-absent step).
        HString* name_hstr = (HString*)key;
        if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto,
                "%s is not defined", name_hstr,
                ds.act, &ds.curr_pc, &ds.needs_restart)) {
            return VM_ERROR~;
        }
        threw = true;
    } else {
        bool sres;
        if (!builtins::js_set_with_receiver(vm, vm.heap, base, (HString*)key, value, recv, &sres)) {
            vm.heap.has_error = false;
            TVal err_val = vm.heap.error_value;
            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                return VM_ERROR~;
            }
            threw = true;
        } else if (!sres && is_strict_act) {
            if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot assign to read only property", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return VM_ERROR~;
            }
            threw = true;
        }
    }
    return threw;
}

// Read an accessor binding through its getter, or as undefined when it has
// none. A throwing getter raises through vm_throw_value, so a JS catch sees
// it and an async body's uncaught throw rejects that body's promise.
fn BindingRead? vm_read_accessor(Dispatch* ds, TVal accessor, HObject* this_obj, TVal* out) {
    Vm* vm = ds.vm;
    TVal getter = hobject::hobject_access_getter(accessor);
    if (getter.is_undefined() || getter.is_null() || vm.heap.call_fn == null) {
        out.set_undefined();
        return BindingRead.FOUND;
    }
    TVal this_tv;
    this_tv.set_object(this_obj);
    *out = vm.heap.call_fn(vm, getter, null, 0, this_tv);
    if (!vm.heap.has_error) return BindingRead.FOUND;
    vm.heap.has_error = false;
    TVal err_val = vm.heap.error_value;
    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
        vm.has_error = true;
        vm.heap.has_error = true;
        return VM_ERROR~;
    }
    return BindingRead.THREW;
}

// Read `key` from a with-scope's object environment (ECMA-262 §9.1.1.2.1
// HasBinding, §9.1.1.2.6 GetBindingValue). UNRESOLVABLE means the scope does
// not bind the name and the walk continues past it.
fn BindingRead? vm_read_with_binding(Dispatch* ds, EnvRecord* env, void* key, TVal* out) {
    Vm* vm = ds.vm;
    // HasProperty runs before @@unscopables is read, so the unscopables getter
    // is not observable for a missing binding. js_has_property, rather than a
    // prototype walk, fires a Proxy binding object's `has` trap.
    bool has_hit = false;
    if (!builtins::js_has_property(vm, vm.heap, env.bindings, (HString*)key, &has_hit)) {
        if (!vm_throw_pending(vm, ds)) return VM_ERROR~;
        return BindingRead.THREW;
    }
    if (!has_hit) {
        // A `has` trap that threw reports a miss and leaves the error pending.
        if (vm.heap.has_error) {
            if (!vm_throw_pending(vm, ds)) return VM_ERROR~;
            return BindingRead.THREW;
        }
        return BindingRead.UNRESOLVABLE;
    }
    if (vm_with_unscopables_blocks_dispatch(ds, env, key)) return BindingRead.UNRESOLVABLE;
    if (ds.needs_restart) return BindingRead.THREW;
    // The unscopables getter may have deleted the binding. The reference
    // already resolved to this scope, so the read does not move on to the
    // parent: it is undefined in sloppy code and a ReferenceError in strict
    // (§9.1.1.2.6 step 3). The second HasProperty fires a `has` trap again.
    if (!builtins::js_has_property(vm, vm.heap, env.bindings, (HString*)key, &has_hit) || !has_hit) {
        if (((CompiledFunction*)ds.act.func).is_strict()) {
            HString* name_hstr = (HString*)key;
            if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr,
                    ds.act, &ds.curr_pc, &ds.needs_restart)) {
                return VM_ERROR~;
            }
            return BindingRead.THREW;
        }
        out.set_undefined();
        return BindingRead.FOUND;
    }
    hobject::PropProtoResult proto = env.bindings.get_prop_proto_full(key, vm.heap);
    if (!proto.found) return BindingRead.UNRESOLVABLE;
    if (proto.is_accessor) {
        return vm_read_accessor(ds, proto.value, proto.owner != null ? proto.owner : env.bindings, out);
    }
    *out = proto.value;
    return BindingRead.FOUND;
}

// Resolve `key` from the current scope and read it (ECMA-262 §9.4.2
// ResolveBinding, §6.2.5.5 GetValue): the lexical chain, then the variable
// chain when a with scope separates them, then the global object's
// prototype chain, whose properties the global record also binds. On FOUND
// *out holds the value without a reference of its own. A TDZ binding or a
// throwing getter or trap raises through the VM. A data binding found on the
// lexical chain is cached in the instruction's VarIC.
// A shared, non-dictionary shape is immutable, so its id alone proves which
// keys a record holds.
fn bool rearm_shape_ok(Heap* h, HObject* b) @inline {
    hobject::Shape* sh = b.get_shape(h);
    return sh != null && !sh.dict && (b.shape_id == 0 || sh.parent != hobject::PRIVATE_SHAPE_PARENT);
}

// Run a `var` declaration into the activation's var_env. One that appends to
// a function scope is recorded in the site's cache for th_declvar, since each
// call's scope starts on the same shape.
fn void declare_scope_var(Dispatch* ds, void* key, TVal value, bool is_bare) {
    Vm* vm = ds.vm;
    EnvRecord* env = ds.act.var_env;
    bool eval_code = ((CompiledFunction*)ds.act.func).is_eval_fn();
    HObject* b = env.bindings;
    uint from_shape = b.shape_id;
    uint count = b.prop_count;
    env::env_declare_var(env, key, value, env == vm.global_env, eval_code, is_bare);
    if (ds.ic_base == null || eval_code || !env.flags.is_function_scope || env.flags.is_with
        || b.prop_count != count + 1) return;
    hobject::ICEntry* ic = ds.ic_base + (ds.curr_pc - 1 - ds.code_base);
    hobject::ic_fill_declare(ic, b, key, from_shape, b.shape_id, vm.heap);
}

// Record what a later activation needs to re-arm `vic`: the shapes of the
// declarative records between the chain head and the owner, or the owner's
// own shape when the binding lives in the head.
fn void var_ic_note_rearm(hobject::VarICEntry* vic, EnvRecord* head, EnvRecord* owner, Heap* h) {
    if (vic.slot_ptr == null || vic.prop_flags.is_accessor) return;
    char depth = 0;
    for (EnvRecord* e = head; e != owner; e = e.parent) {
        if (e == null || depth >= hobject::VAR_IC_REARM_MAX || e.flags.is_with) return;
        vic.passed_envs[depth] = (void*)e;
        vic.passed_shapes[depth] = rearm_shape_ok(h, e.bindings) ? e.bindings.shape_id : heap::SHAPE_NONE;
        depth++;
    }
    if (depth == 0 && (owner.flags.is_with || !rearm_shape_ok(h, owner.bindings))) return;
    vic.rearm_depth = depth;
}

// Point `vic` at the chain starting at `head` when that chain has the shape
// the entry was filled for. Returns false on any doubt.
fn bool var_ic_rearm(hobject::VarICEntry* vic, EnvRecord* head, Heap* h) {
    char depth = vic.rearm_depth;
    if (depth == hobject::VAR_IC_NO_REARM || head == null || vic.slot_ptr == null
        || vic.recycle_epoch != h.shape_recycle_epoch) return false;
    if (depth == 0) {
        HObject* b = head.bindings;
        if (head.flags.is_with || b == null || b.shape_id != vic.shape_id) return false;
        vic.env = (void*)head;
        vic.bindings = (void*)b;
        b.gc.ic_bound = true;
        vic.slot_ptr = vic.slot();
    } else {
        EnvRecord* e = head;
        for (char i = 0; i < depth; i++) {
            if (e == null || e.flags.is_with || e.bindings == null) return false;
            if ((void*)e != vic.passed_envs[i]
                && (vic.passed_shapes[i] == heap::SHAPE_NONE || e.bindings.shape_id != vic.passed_shapes[i])) return false;
            e = e.parent;
        }
        // A different owner is the same scope of another activation when it
        // has the shape the entry was filled for; a shared shape fixes where
        // the key's slot sits.
        if ((void*)e != vic.env) {
            if (e == null || e.flags.is_with || e.bindings == null
                || e.bindings.shape_id != vic.shape_id || !rearm_shape_ok(h, e.bindings)) return false;
            vic.env = (void*)e;
            vic.bindings = (void*)e.bindings;
            e.bindings.gc.ic_bound = true;
            vic.slot_ptr = vic.slot();
        }
        // Weak-cache pruning keeps search_head's chain alive, but an older
        // chain's records can be swept and reused for unrelated scopes.
        e = head;
        for (char i = 0; i < depth; i++) {
            vic.passed_envs[i] = (void*)e;
            e = e.parent;
        }
    }
    vic.search_head = (void*)head;
    return true;
}

fn BindingRead? vm_read_binding(Dispatch* ds, void* key, TVal* out) {
    Vm* vm = ds.vm;
    Activation* act = ds.act;
    EnvRecord*[2] chains = { act.lex_env, act.var_env != act.lex_env ? act.var_env : null };
    foreach (chain, head : chains) {
        for (EnvRecord* env = head; env != null; env = env.parent) {
            if (env.is_with()) {
                BindingRead read = vm_read_with_binding(ds, env, key, out)!;
                if (read != BindingRead.UNRESOLVABLE) return read;
                continue;
            }
            int idx = env.bindings.find_prop_idx(key, vm.heap);
            if (idx < 0) continue;
            TVal v = env.bindings.prop_values()[idx].get();
            if (env::is_tdz_sentinel(&v)) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt_str(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization",
                        name_hstr, act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return BindingRead.THREW;
            }
            if (env.bindings.get_prop_flags((uint)idx, vm.heap).is_accessor) {
                // A live module import caches the exporter's slot; any other
                // accessor stays uncached.
                if (chain == 0 && ds.var_ic_base != null) {
                    hobject::VarICEntry* vic = ds.var_ic_base + (ds.curr_pc - 1 - ds.code_base);
                    hobject::var_ic_fill(vic, (void*)env, (void*)env.bindings, env.bindings.shape_id,
                        (uint)idx, (void*)act.lex_env, false, vm.heap);
                    if (vic.slot_ptr == null || vic.prop_flags.is_accessor) hobject::var_ic_clear(vic);
                }
                return vm_read_accessor(ds, v, env.bindings, out);
            }
            if (chain == 0 && ds.var_ic_base != null) {
                hobject::VarICEntry* vic = ds.var_ic_base + (ds.curr_pc - 1 - ds.code_base);
                hobject::var_ic_fill(vic, (void*)env, (void*)env.bindings, env.bindings.shape_id, (uint)idx,
                    (void*)act.lex_env, false, vm.heap);
                var_ic_note_rearm(vic, act.lex_env, env, vm.heap);
            }
            *out = v;
            return BindingRead.FOUND;
        }
    }
    return global_proto_lookup(vm, key, out) ? BindingRead.FOUND : BindingRead.UNRESOLVABLE;
}


// Run the bytecode dispatch loop over an activation stack and registers the
// caller has already set up.
fn TVal? Vm.run(Vm* vm) {
    heap::Realm* caller_realm = vm.heap.realm;
    defer vm.heap.enter_realm(caller_realm);
    vm.run_depth++;
    defer vm.run_depth--;

    Dispatch ds;
    ds.init(vm);

    // The outer loop reloads all frame state, which a JS-to-JS call invalidates.
    for (;;) {
        if (!ds.needs_restart) {
            break;
        }
        ds.needs_restart = false;

        // A restart with no remaining activation means the top-level frame
        // just unwound (e.g. an uncaught throw in a top-level async/module
        // body: vm_throw_value settles the promise, pops to count 0, and
        // requests a restart to resume the caller, but there is no caller).
        // Halt cleanly instead of indexing activations[-1].
        if (vm.activation_count == 0) {
            return vm.return_val;
        }

        ds.load_frame();

        // Interrupt poll at the restart loop top. A backward-branch poll would
        // never fire for recursion such as `function f(){ f() }`, which spends
        // its time in call/restart rather than back-edges; the restart is the
        // safepoint that catches it. needs_restart is false here (the loop
        // condition guarantees it), so the poll's own restart, set when a
        // finally consumes the abort, is the discriminator below.
        if (vm.heap.capi_interrupt_fn != null || vm.heap.capi_runtime != null) {
            vm_charge_interrupt(vm.heap);
            if (vm_poll_interrupt(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                if (!ds.needs_restart) return VM_ERROR~;
            }
        }

    $if $feat(SLJIT):
        if (vm.heap.jit_enabled && vm.threaded_handoff == ThreadedHandoff.NONE) {
            void* native = jit::baseline_code(vm.heap, vm.current_func);
            $if $feat(OP_PROFILE): opprof_runentry[native != null ? 1 : 0]++; if (native == null) opprof_relay_site(vm.current_func, ds.curr_pc); $endif
            if (native != null) {
                switch (jit::baseline_run(native, &ds)) {
                    case OpStatus.RESTART.ordinal: continue;
                    case OpStatus.HALT.ordinal: return ds.halt_value;
                    case OpStatus.FAULT.ordinal: return ds.failure~;
                    default: break; // BASELINE_INTERPRET: the interpreter takes the frame.
                }
            }
        }
    $endif

        TVal? result = vm_dispatch(&ds);
        if (!ds.needs_restart) return result;
    }
    return vm.return_val;
}

// Calls and returns switch frames in place, without a restart. With the JIT
// on, the switch made by the body's operation becomes a restart instead, so
// Vm.run enters the new frame and runs its native code when it has some.
macro OpStatus @jit_frame_switch(Dispatch* ds, #op) {
    $if $feat(SLJIT):
        if (@likely(!ds.vm.heap.jit_enabled)) return #op;
        Activation* act = ds.act;
        CompiledFunction* func = ds.vm.current_func;
        return jit_restart_switched(ds, act, func, #op);
    $else
        return #op;
    $endif
}

// Turn a NEXT that left a different frame or function current into a
// restart when the JIT is on, saving the new frame's resume point.
fn OpStatus jit_restart_switched(Dispatch* ds, Activation* act, CompiledFunction* func, OpStatus status) @inline {
    $if $feat(SLJIT):
        if (status == NEXT && (ds.act != act || ds.vm.current_func != func)) {
            ds.act.curr_pc = ds.curr_pc;
            ds.needs_restart = true;
            return RESTART;
        }
    $endif
    return status;
}

// Run instructions in the current frame until one of them needs Vm.run to
// reload the frame (ds.needs_restart) or ends the run, which returns its
// result or fault.
fn TVal? vm_dispatch(Dispatch* ds) {
    Vm* vm = ds.vm;
    // The loop tests neither of two conditions per instruction, which relies
    // on invariants worth stating:
    //
    // There is no fall-off-the-end check. The compiler ends every function
    // and script with an explicit RET or RETUNDEF, so curr_pc cannot reach
    // code_end during normal dispatch.
    //
    // ds.halt is not polled either. Only the return and generator opcodes
    // set it, meaning RET, RETUNDEF, RET_GEN, RETUNDEF_GEN, and the
    // sub-dispatch helpers in vm_control.c3 and vm_generators.c3, so it is
    // checked right after those call sites instead.
    for (; !ds.needs_restart; ) {
    $if $feat(THREADED_DISPATCH):
        if (@unlikely(vm.threaded_handoff != ThreadedHandoff.NONE)) {
            ThreadedHandoff handoff = vm.threaded_handoff;
            vm.threaded_handoff = ThreadedHandoff.NONE;
            if (handoff == ThreadedHandoff.THROW) {
                if (!vm_throw_value(vm, vm.threaded_throw, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.threaded_throw);
                }
                continue;
            }
            DecodedInsn call = vm.threaded_call;
            if (catch err = dispatch_calls(ds, call.op, ds.regs_base + call.a, ds.regs_base + call.b,
                                           ds.regs_base + call.c, call)) { return err~; }
            if (ds.halt) { return ds.halt_value; }
            if (!ds.needs_restart) { ds.regs_base = ds.act.bottom; }
            continue;
        }
        ds.curr_pc = run_threaded_burst(ds.curr_pc, ds.code_end, ds.regs_base, &ds.cold);
        // The burst's return of the outermost frame ends the run.
        if (ds.needs_restart) break;
        ds.sync_code();
        if (@unlikely(vm.threaded_handoff != ThreadedHandoff.NONE)) continue;
    $endif

        Instruction word = *ds.curr_pc;
        ds.curr_pc++;

        // WIDE prefix: the word's A/B/C fields carry the high bytes of
        // the following instruction's operands. Handlers only ever see
        // the widened DecodedInsn, never the prefix word.
        DecodedInsn insn;
        if (@unlikely(word.op == Opcode.WIDE)) {
            Instruction payload = *ds.curr_pc;
            ds.curr_pc++;
            insn.op = payload.op;
            insn.a  = ((uint)word.a << 8) | payload.a;
            insn.b  = ((uint)word.b << 8) | payload.b;
            insn.c  = ((uint)word.c << 8) | payload.c;
        } else {
            insn.op = word.op;
            insn.a  = word.a;
            insn.b  = word.b;
            insn.c  = word.c;
        }

        Opcode op = insn.op;

        TVal* ra = ds.regs_base + insn.a;
        TVal* rb = ds.regs_base + insn.b;
        TVal* rc = ds.regs_base + insn.c;

    $if $feat(TRACE_VM):
    if (@unlikely(vm.trace)) {
        trace_instruction(vm, ds.curr_pc - 1, (uint)((ds.curr_pc - 1) - ds.code_base), &insn,
                          ra, rb, rc, ds.regs_base, ds.act);
    }
    $endif

    $if $feat(OP_PROFILE):
        opprof_record(op);
    $endif

    $if $feat(SLJIT):
        if (has_feedback(op)) note_feedback(ds, insn);
    $endif

    OpStatus status;
    switch (op) @jump {

    // === LOAD / STORE ===
    case Opcode.LDREG:    status = op_ldreg(ds, insn);
    case Opcode.LDCONST:  status = op_ldconst(ds, insn);
    case Opcode.SETCONST: status = op_setconst(ds, insn);
    case Opcode.LDINT:    status = op_ldint(ds, insn);
    case Opcode.LDINTX:   status = op_ldintx(ds, insn);
    case Opcode.LDUNDEF:  status = op_ldundef(ds, insn);
    case Opcode.LDNULL:   status = op_ldnull(ds, insn);
    case Opcode.LDTRUE:   status = op_ldtrue(ds, insn);
    case Opcode.LDFALSE:  status = op_ldfalse(ds, insn);
    case Opcode.LDTHIS:
    case Opcode.GETTHISC:
    case Opcode.PUTTHISC: status = op_ldthis(ds, insn);

    // === ARITHMETIC ===
    case Opcode.ADD_FUSED:
    case Opcode.ADD:     status = op_add(ds, insn);
    case Opcode.SUB:     status = op_sub(ds, insn);
    case Opcode.ADDI:    status = op_addi(ds, insn);
    case Opcode.STRJOIN:
    case Opcode.STRJOIN_LENGTH: status = op_strjoin(ds, insn);
    case Opcode.SUBI:    status = op_subi(ds, insn);
    case Opcode.MUL:
    case Opcode.MULI:    status = op_mul(ds, insn);
    case Opcode.DIV:     status = op_div(ds, insn);
    case Opcode.MOD:     status = op_mod(ds, insn);
    case Opcode.EXP:     status = op_exp(ds, insn);

    // === UNARY ===
    case Opcode.UNP:
    case Opcode.UNM:
    case Opcode.BNOT:
    case Opcode.LNOT:
    case Opcode.TYPEOF:
    case Opcode.VOID:
    case Opcode.TONUMERIC:
    case Opcode.INC:
    case Opcode.INC_LT:
    case Opcode.DEC:
    case Opcode.PUTARG:
    case Opcode.INC_VAR:
    case Opcode.DEC_VAR:
    case Opcode.INC_GLOBAL:
    case Opcode.DEC_GLOBAL: status = op_unary(ds, insn);

    // === BITWISE ===
    case Opcode.BAND:
    case Opcode.BANDI:   status = op_band(ds, insn);
    case Opcode.BOR:
    case Opcode.BORI:    status = op_bor(ds, insn);
    case Opcode.BXOR:
    case Opcode.BXORI:   status = op_bxor(ds, insn);
    case Opcode.SHL:
    case Opcode.SHLI:    status = op_shl(ds, insn);
    case Opcode.SHR:
    case Opcode.SHRI:    status = op_shr(ds, insn);
    case Opcode.USHR:
    case Opcode.USHRI:   status = op_ushr(ds, insn);

    // === COMPARISON ===
    case Opcode.EQ:      status = op_eq(ds, insn);
    case Opcode.NEQ:     status = op_neq(ds, insn);
    case Opcode.SEQ:     status = op_seq(ds, insn);
    case Opcode.SNEQ:    status = op_sneq(ds, insn);
    case Opcode.LT:
    case Opcode.LE:
    case Opcode.GT:
    case Opcode.GE:      status = op_lt(ds, insn);
    case Opcode.JMP_NLT..Opcode.JMP_SNEQ:
    case Opcode.JMP_NLTI..Opcode.JMP_SNEQI: status = op_jmp_cmp(ds, insn);
    case Opcode.JMP_EQ:
    case Opcode.JMP_NEQ: status = op_jmp_eq(ds, insn);
    case Opcode.JMP_NULL:
    case Opcode.JMP_NNULL: status = op_jmp_null(ds, insn);
    case Opcode.INSTANCEOF: status = op_instanceof(ds, insn);
    case Opcode.IN:      status = op_in(ds, insn);

    // === CONTROL FLOW ===
    case Opcode.JUMP:    status = op_jump(ds, insn);
    case Opcode.IF_TRUE:
    case Opcode.IF_FALSE: status = op_if(ds, insn);

    // === PROPERTY ACCESS ===
    case Opcode.GETPROPC_CACHED:
    case Opcode.GETPROP:
    case Opcode.GETPROP_CACHE:
    case Opcode.GETPROPC:
    case Opcode.PUTPROP:
    case Opcode.PUTPROP_NE:
    case Opcode.PUTPROP_SUPER:
    case Opcode.GETPROP_SUPER:
    case Opcode.DELPROP:     status = op_property(ds, insn);
    case Opcode.PUTPROPC:    status = op_putpropc(ds, insn);
    case Opcode.TOPROPKEY:   status = op_topropkey(ds, insn);
    case Opcode.TOSTR:       status = op_tostr(ds, insn);
    case Opcode.RETEST:      status = op_retest(ds, insn);
    case Opcode.HOF_GUARD:   status = op_hof_guard(ds, insn);
    case Opcode.HOF_ELEM:    status = op_hof_elem(ds, insn);
    case Opcode.HOF_GET:     status = op_hof_get(ds, insn);
    case Opcode.HOF_NEWARR:  status = op_hof_newarr(ds, insn);
    case Opcode.HOF_PUT:     status = op_hof_put(ds, insn);

    // === OBJECT / ARRAY CREATION ===
    case Opcode.SPREAD_PROJECTION:
    case Opcode.NEWOBJ_SHAPE:
    case Opcode.INIT_SLOT:
    case Opcode.NEWOBJ:
    case Opcode.NEWARR:
    case Opcode.NEWARR_CONST:
    case Opcode.NEWREGEXP:
    case Opcode.SETALEN:
    case Opcode.FREEZEOBJ:
    case Opcode.ARRSPRD:
    case Opcode.OBJSPRD:
    case Opcode.OBJREST:
    case Opcode.SPREAD_ARG:
    case Opcode.FWD_ARGS:
    case Opcode.APPLY_ARGS:  status = op_objects(ds, insn);

    // === FUNCTION CALLS ===
    case Opcode.CALL:
    case Opcode.CALL_S:
    case Opcode.CALL_UNDEF_THIS:
    case Opcode.CALL_VAR:
    case Opcode.CALL_GLOBAL:
    case Opcode.TAILCALL_UNDEF_THIS:
    case Opcode.TAILCALL_VAR:
    case Opcode.TAILCALL_GLOBAL:
    case Opcode.TAILCALL_CALL:
    case Opcode.TAILCALL_CALL_S: status = @jit_frame_switch(ds, op_call(ds, insn));

    case Opcode.CALL_PROP:
    case Opcode.SETPROTO:
    case Opcode.GETPROTO:
    case Opcode.SUPER_CALL:
    case Opcode.SUPER_CALL_S:
    case Opcode.NEWTARGET:
    case Opcode.CLASS_SCALAR_GUARD:
    case Opcode.NEW_OBJ:
    case Opcode.NEW_OBJ_S:
    case Opcode.TAILCALL: status = @jit_frame_switch(ds, op_calls(ds, insn));

    // === GENERATORS ===
    case Opcode.LOAD_RESUME:
    case Opcode.AWAIT:
    case Opcode.YIELD:
    case Opcode.YIELD_STAR:
    case Opcode.YIELD_STAR_ASYNC:
    case Opcode.GEN_START: status = op_generators(ds, insn);

    // === DYNAMIC IMPORT ===
    case Opcode.DYN_IMPORT:
    case Opcode.DYN_IMPORT_DEFER:
    case Opcode.DYN_IMPORT_SOURCE: status = op_dyn_import(ds, insn);
    case Opcode.IMPORT_META: status = op_import_meta(ds, insn);

    // === RETURNS ===
    case Opcode.RET:
    case Opcode.RETUNDEF: status = @jit_frame_switch(ds, op_ret(ds, insn));
    case Opcode.RET_GEN:
    case Opcode.RETUNDEF_GEN: status = op_ret_gen(ds, insn);

    case Opcode.RESOLVEVAR: status = op_resolvevar(ds, insn);
    case Opcode.THROW_UNRESOLVED: status = op_throw_unresolved(ds, insn);

    // === VARIABLE ACCESS ===
    case Opcode.GETCAP:
    case Opcode.GETVAR:
    case Opcode.GETGLOBAL:
    case Opcode.TYPEOFIDENT: status = op_getvar(ds, insn);
    case Opcode.PUTGLOBAL: status = op_putglobal(ds, insn);
    case Opcode.PUTVAR: status = op_putvar(ds, insn);
    case Opcode.PUTCAP:
    case Opcode.PUTVAR_ASSIGN: status = op_putvar_assign(ds, insn);
    case Opcode.PUTCAP_SNAP:
    case Opcode.PUTVAR_SNAP: status = op_putvar_snap(ds, insn);
    case Opcode.DECLGLOBALFUNC: status = op_declglobalfunc(ds, insn);
    case Opcode.DECLB33GLOBAL: status = op_declb33global(ds, insn);
    case Opcode.DECLVAR_HOIST: status = op_declvar_hoist(ds, insn);
    case Opcode.DECLVAR: status = op_declvar(ds, insn);
    case Opcode.PUTLEX: status = op_putlex(ds, insn);
    case Opcode.PUTLEX_C: status = op_putlex_c(ds, insn);
    case Opcode.INITTZ: status = op_inittz(ds, insn);
    case Opcode.CHKGLOBALLEX:
    case Opcode.CHKGLOBALVAR:
    case Opcode.CHKGLOBALFUNC: status = op_chkglobal(ds, insn);
    case Opcode.DELVAR: status = op_delvar(ds, insn);

    // === WITH STATEMENT ===
    case Opcode.WITH_START: status = op_with_start(ds, insn);
    case Opcode.WITH_END: status = op_with_end(ds, insn);
    case Opcode.WITHGET: status = op_withget(ds, insn);
    case Opcode.WITHBASE: status = op_withbase(ds, insn);
    case Opcode.WTWR: status = op_wtwr(ds, insn);

    // === CLOSURES ===
    case Opcode.NEWCELLS:
    case Opcode.GETCELL:
    case Opcode.SETCELL:
    case Opcode.MOVECELL: status = op_cells(ds, insn);

    case Opcode.CLOSURE:
    case Opcode.GETBOUND: status = op_closure(ds, insn);

    // === ITERATOR ===
    case Opcode.INITFOR:
    case Opcode.NEXTFOR:
    case Opcode.ITER_NEXT_FAST:
    case Opcode.ITER_ENTRY_FAST:
    case Opcode.ARRAY_PATTERN_GUARD:
    case Opcode.ITER_OPEN_FAST:
    case Opcode.DESTRUCT_ARRAY_FAST:
    case Opcode.DESTRUCT_ARRAY_REST_FAST: status = op_iterator(ds, insn);

    // === EXCEPTION HANDLING ===
    case Opcode.TRY:
    case Opcode.ENDTRY:
    case Opcode.THROW:
    case Opcode.THROW_REF:
    case Opcode.THROW_SYNTAX:
    case Opcode.CATCH:
    case Opcode.FINALLY:
    case Opcode.ENDFINALLY: status = @jit_frame_switch(ds, op_exceptions(ds, insn));

    // === MISC ===
    case Opcode.NOP:
    case Opcode.DEBUGGER:
    case Opcode.BREAK:
    case Opcode.CONTINUE:
    case Opcode.INITGET:
    case Opcode.INITSET:
    case Opcode.INITSETI:
    case Opcode.INITPROP:
    case Opcode.INITELEM:
    case Opcode.INITPROPN:
    case Opcode.CLASS_INITGET:
    case Opcode.CLASS_INITSET:
    case Opcode.CLASS_INITPROP:
    case Opcode.CSVARI:
    case Opcode.PUSH_LEX:
    case Opcode.POP_LEX:
    case Opcode.PUSH_VAR:
    case Opcode.POP_VAR:
    case Opcode.REQUIRE_OBJ:
    case Opcode.CHKOBJ:
    case Opcode.CHKITER:
    case Opcode.ITER_CLOSE:
    case Opcode.ITER_CLOSE_ESCAPE:
    case Opcode.GET_ITER_ASYNC:
    case Opcode.ITER_CLOSE_ASYNC:
    case Opcode.CHKCTOR:
    case Opcode.CHK_PROT:
    case Opcode.NEW_PRIV_SYM:
    case Opcode.ADD_BRAND:
    case Opcode.CHK_BRAND:
    case Opcode.HAS_BRAND:
    case Opcode.INITPROP_PRIV:
    case Opcode.GETPROP_PRIVATE: status = op_misc(ds, insn);

    default:
        return VM_ERROR~;
    }
    switch (status) {
        case NEXT:
        case RESTART: continue;
        case HALT:    return ds.halt_value;
        case FAULT:   return ds.failure~;
    }
    }
    return (TVal){};
}

// ECMA-262 §9.1.1.2.1 HasBinding step 6-9: a `with` binding is hidden by an
// @@unscopables entry whose value is true. Returns true when `name` is
// blocked; on a getter throw, heap.has_error is left pending so the caller
// can surface it. Used by the with-env branches of RESOLVEVAR, GETVAR,
// GETGLOBAL, DELVAR, and the INC_VAR/DEC_VAR var_env fall-through.
fn bool vm_with_unscopables_blocks(Vm* vm, EnvRecord* with_env, void* name) {
    Heap* h = vm.heap;
    // Lazy-initialise the @@unscopables symbol. It's only built when needed
    // (a with-block hits an object whose prototype carries @@unscopables),
    // so the heap-creator doesn't have to know which well-known symbols to
    // pre-create.
    if (h.unscopables_symbol == null) {
        HString* sym = builtins::ensure_unscopables_symbol(h);
        if (sym == null) return false;
        h.unscopables_symbol = sym;
    }
    HObject* b = with_env.bindings;
    if (b == null) return false;
    TVal receiver; receiver.set_object(b);
    TVal usv;
    if (!builtins::js_get(vm, h, b, (HString*)h.unscopables_symbol, &usv)) return false;
    if (h.has_error) return false;
    if (!usv.is_object() || usv.get_heapptr() == null) return false;
    HObject* us_obj = (HObject*)usv.get_heapptr();
    TVal blocked_v;
    if (!builtins::js_get(vm, h, us_obj, (HString*)name, &blocked_v)) return false;
    if (h.has_error) return false;
    return env::env_tval_to_boolean(blocked_v);
}

// Variant that surfaces a throw from the unscopables getter (test262
// unscopables-*-get-err.js). The plain `vm_with_unscopables_blocks` returns
// false on the throw, which silently dropped the binding lookup; this
// variant routes any pending throw through the dispatcher's restart path.
fn bool vm_with_unscopables_blocks_dispatch(Dispatch* ds, EnvRecord* with_env, void* name) {
    Vm* vm = ds.vm;
    if (vm_with_unscopables_blocks(vm, with_env, name)) return true;
    if (vm.heap.has_error) {
        if (!vm_throw_pending(vm, ds)) return false;
    }
    return false;
}

// Surfaces a pending heap error through the VM throw machinery. Returns
// false on VM failure (caller should `return VM_ERROR~`).
fn bool vm_throw_pending(Vm* vm, Dispatch* ds) {
    if (!vm.heap.has_error) return true;
    vm.heap.has_error = false;
    TVal err_val = vm.heap.error_value;
    return vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart);
}
