// Baseline tier: one native function per CompiledFunction, running the
// interpreter's own frames.
//
// The native function, `fn long(Dispatch* ds)`, runs instructions of the
// activation the Dispatch has loaded, starting at ds.curr_pc. There is no frame
// layout of its own and no C recursion between JS frames: a call, a return, a
// throw that leaves the frame and a halt all return an OpStatus word to Vm.run,
// which reloads the top frame and enters its native code, or the interpreter
// when it has none.
//
// Each instruction stores the following instruction's address into
// ds.curr_pc, calls its opcode's thunk and tests the status. Each opcode has
// its own thunk, specialized at compile time over the Opcode enum, which calls
// the operation function vm_dispatch calls. After a NEXT the code falls through
// when ds.curr_pc still holds the stored address. Otherwise a jump, a switch op
// or a caught throw moved it, and the code dispatches through the entry table.
// The table maps every instruction word to its native address (null for words
// that do not start an instruction; a WIDE prefix and its payload are one
// instruction starting at the prefix), so the interpreter and native code can
// trade places at any instruction.
//
// Generated code holds no JS value across a thunk call; every operation
// function sees the real register window, and the interrupt and back-edge
// polls stay inside the operation functions.
//
// Not compiled: generators and async functions, script, module and eval
// top-level code, functions that open a `with` scope, and any function
// containing an opcode without a thunk.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;

// Compiles of one function before it stays interpreted.
const char BASELINE_MAX_ATTEMPTS = 2;
// Frame entries before a function compiles without --jit-stress.
const uint BASELINE_ENTRY_THRESHOLD = 2;
// Generated code and entry tables, in bytes, past which compiles are refused.
const usz BASELINE_CODE_CAP = 64 * 1024 * 1024;
// A native run's result when its target is not an instruction start: the
// interpreter continues the frame.
const long BASELINE_INTERPRET = OpStatus::values.len;

struct JitStats {
    usz code_bytes;
    usz table_bytes;
    uint compiled;
    uint excluded_suspending;
    uint excluded_top_level;
    uint excluded_with;
    uint excluded_opcode;
    uint failed;
    uint capped;
}

struct BaselineCode {
    void* exec;
    usz code_bytes;
    usz table_bytes;
    // One native address per instruction word, parallel to the code.
    void*[*] entries;
}

alias BaselineFn = fn long(Dispatch* ds);
alias Thunk = fn long(Dispatch* ds, ulong packed);

// Native code for `f`, compiling it when the policy says so, or null when the
// frame runs in the interpreter.
fn void* baseline_code(Heap* h, CompiledFunction* f) @inline {
    if (f.jit_code != null) return ((BaselineCode*)f.jit_code).exec;
    if (f.jit_refused) return null;
    if (!h.jit_stress && ++f.jit_entries < BASELINE_ENTRY_THRESHOLD) return null;
    return baseline_try_compile(h, f);
}

fn long baseline_run(void* exec, Dispatch* ds) @inline => ((BaselineFn)exec)(ds);

fn void baseline_free(Heap* h, CompiledFunction* f) {
    BaselineCode* bc = f.jit_code;
    if (bc == null) return;
    sljit_free_code(bc.exec, null);
    h.free_func(h.heap_udata, bc);
    f.jit_code = null;
}

enum Refusal : char { NONE, SUSPENDING, TOP_LEVEL, WITH, OPCODE }

fn Refusal baseline_refusal(CompiledFunction* f) {
    if (f.flags.is_generator || f.flags.is_async) return SUSPENDING;
    if (f.flags.is_global || f.flags.is_module || f.flags.is_eval) return TOP_LEVEL;
    if (f.code == null || f.code_count == 0) return OPCODE;
    for (uint i = 0; i < f.code_count; i++) {
        Instruction w = f.code[i];
        if (w.op.ordinal >= Opcode::values.len) return OPCODE;
        if (w.op == Opcode.WIDE) {
            if (i + 1 >= f.code_count) return OPCODE;
            w = f.code[++i];
            if (w.op.ordinal >= Opcode::values.len) return OPCODE;
        }
        if (w.op == Opcode.WITH_START || w.op == Opcode.WITH_END) return WITH;
        if (thunks()[w.op.ordinal] == null) return OPCODE;
    }
    return NONE;
}

fn void* baseline_try_compile(Heap* h, CompiledFunction* f) @noinline {
    JitStats* st = &h.jit_stats;
    switch (baseline_refusal(f)) {
        case SUSPENDING: st.excluded_suspending++; f.jit_refused = true; return null;
        case TOP_LEVEL:  st.excluded_top_level++;  f.jit_refused = true; return null;
        case WITH:       st.excluded_with++;       f.jit_refused = true; return null;
        case OPCODE:     st.excluded_opcode++;     f.jit_refused = true; return null;
        case NONE: break;
    }
    if (st.code_bytes + st.table_bytes >= BASELINE_CODE_CAP) {
        st.capped++;
        f.jit_refused = true;
        return null;
    }
    BaselineCode* bc = baseline_compile(h, f);
    if (bc == null) {
        st.failed++;
        if (++f.jit_attempts >= BASELINE_MAX_ATTEMPTS) f.jit_refused = true;
        return null;
    }
    if (st.code_bytes + st.table_bytes + bc.code_bytes + bc.table_bytes > BASELINE_CODE_CAP) {
        sljit_free_code(bc.exec, null);
        h.free_func(h.heap_udata, bc);
        st.capped++;
        f.jit_refused = true;
        return null;
    }
    st.code_bytes += bc.code_bytes;
    st.table_bytes += bc.table_bytes;
    st.compiled++;
    f.jit_code = bc;
    return bc.exec;
}

const int R0 = 1;
const int R1 = 2;
const int R2 = 3;

fn BaselineCode* baseline_compile(Heap* h, CompiledFunction* f) {
    uint count = f.code_count;
    usz table_bytes = BaselineCode::size + (usz)count * void*::size;
    BaselineCode* bc = h.alloc_func(h.heap_udata, table_bytes);
    if (bc == null) return null;
    mem::clear(bc, (sz)table_bytes);
    bc.table_bytes = table_bytes;

    void* c = sljit_create_compiler(null);
    if (c == null) { h.free_func(h.heap_udata, bc); return null; }
    defer sljit_free_compiler(c);
    void*[] labels = mem::new_array(void*, count);
    defer mem::free(labels);

    int ds_reg = reg_s(0);
    int code_reg = reg_s(1);
    int table_reg = reg_s(2);
    Dispatch* layout = (Dispatch*)(usz)4096;
    long pc_off = (char*)&layout.curr_pc - (char*)layout;
    long code_off = (char*)&layout.code_base - (char*)layout;
    int pc_mem = SLJIT_MEM | ds_reg;

    sljit_emit_enter(c, 0, SLJIT_ARGS1WW, 3, 3, 0);
    sljit_emit_op1(c, SLJIT_MOV, code_reg, 0, pc_mem, code_off);
    sljit_emit_op1(c, SLJIT_MOV, table_reg, 0, SLJIT_IMM, (long)(usz)&bc.entries[0]);

    // Dispatch on ds.curr_pc through the entry table.
    void* dispatch = sljit_emit_label(c);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, pc_mem, pc_off);
    sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, code_reg, 0);
    sljit_emit_op2(c, SLJIT_LSHR, R1, 0, R1, 0, SLJIT_IMM, 2);
    void* out_of_range = sljit_emit_cmp(c, SLJIT_GREATER_EQUAL, R1, 0, SLJIT_IMM, count);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, mem_index(table_reg, R1), 3);
    void* no_entry = sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0);
    sljit_emit_ijump(c, SLJIT_JUMP, R0, 0);
    void* interpret = sljit_emit_label(c);
    sljit_set_label(out_of_range, interpret);
    sljit_set_label(no_entry, interpret);
    sljit_emit_return(c, SLJIT_MOV, SLJIT_IMM, BASELINE_INTERPRET);
    void* leave = sljit_emit_label(c);
    sljit_emit_return(c, SLJIT_MOV, R0, 0);

    Thunk[] table = thunks();
    for (uint i = 0; i < count;) {
        Instruction w = f.code[i];
        uint next = i + 1;
        ulong packed;
        if (w.op == Opcode.WIDE) {
            Instruction p = f.code[next++];
            packed = (ulong)p.op.ordinal
                | (ulong)((w.a << 8) | p.a) << 16
                | (ulong)((w.b << 8) | p.b) << 32
                | (ulong)((w.c << 8) | p.c) << 48;
            w = p;
        } else {
            packed = (ulong)w.op.ordinal | (ulong)w.a << 16 | (ulong)w.b << 32 | (ulong)w.c << 48;
        }
        labels[i] = sljit_emit_label(c);
        long next_off = (long)next * Instruction::size;
        sljit_emit_op2(c, SLJIT_ADD, R0, 0, code_reg, 0, SLJIT_IMM, next_off);
        sljit_emit_op1(c, SLJIT_MOV, pc_mem, pc_off, R0, 0);
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, ds_reg, 0);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)packed);
        sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)table[w.op.ordinal]);
        sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R0, 0, SLJIT_IMM, 0), leave);
        sljit_emit_op1(c, SLJIT_MOV, R1, 0, pc_mem, pc_off);
        sljit_emit_op2(c, SLJIT_ADD, R2, 0, code_reg, 0, SLJIT_IMM, next_off);
        sljit_set_label(sljit_emit_cmp(c, SLJIT_NOT_EQUAL, R1, 0, R2, 0), dispatch);
        i = next;
    }
    sljit_set_label(sljit_emit_jump(c, SLJIT_JUMP), dispatch);

    bc.exec = sljit_generate_code(c, 0, null);
    if (bc.exec == null) { h.free_func(h.heap_udata, bc); return null; }
    bc.code_bytes = sljit_shim_code_size(c);
    for (uint i = 0; i < count; i++) {
        if (labels[i] != null) bc.entries[i] = (void*)sljit_shim_label_addr(labels[i]);
    }
    return bc;
}

// The thunk of each opcode, null for those without one.
Thunk[Opcode::values.len] thunk_table @private;
bool thunks_ready @private;

fn Thunk[] thunks() @inline {
    if (!thunks_ready) init_thunks();
    return &thunk_table;
}

fn void init_thunks() @noinline @private {
    $foreach $op : Opcode::values:
        $if !@excluded($op):
            thunk_table[$op.ordinal] = fn long(Dispatch* ds, ulong packed) {
                DecodedInsn insn = {
                    .op = $op,
                    .a = (uint)((packed >> 16) & 0xFFFF),
                    .b = (uint)((packed >> 32) & 0xFFFF),
                    .c = (uint)(packed >> 48),
                };
                // The interpreter switches a constant-key read between its
                // cached and uncached forms by rewriting the opcode in place.
                $if $op == Opcode.GETPROPC || $op == Opcode.GETPROPC_CACHED:
                    insn.op = ds.curr_pc[-1].op;
                $endif
                Activation* act = ds.act;
                CompiledFunction* func = ds.vm.current_func;
                OpStatus s = @run_op($op, ds, insn);
                if (s == NEXT && ds.needs_restart) return (long)OpStatus.RESTART.ordinal;
                // Native code runs one frame: a frame switched to in place is
                // entered through Vm.run.
                return (long)vm::jit_restart_switched(ds, act, func, s).ordinal;
            };
        $endif
    $endforeach
    thunks_ready = true;
}

// Opcodes without a thunk: the WIDE prefix, which is never dispatched alone,
// the generator and async suspension ops, and `with` scope entry and exit.
macro bool @excluded(Opcode $op) @const {
    $switch $op:
        $case Opcode.WIDE:
        $case Opcode.LAST_OP:
        $case Opcode.LOAD_RESUME:
        $case Opcode.AWAIT:
        $case Opcode.YIELD:
        $case Opcode.YIELD_STAR:
        $case Opcode.YIELD_STAR_ASYNC:
        $case Opcode.GEN_START:
        $case Opcode.RET_GEN:
        $case Opcode.RETUNDEF_GEN:
        $case Opcode.WITH_START:
        $case Opcode.WITH_END:
            return true;
        $default:
            return false;
    $endswitch
}

// The operation function vm_dispatch runs for `$op`.
macro OpStatus @run_op(Opcode $op, Dispatch* ds, DecodedInsn insn) {
    $if ($op.ordinal >= Opcode.JMP_NLT.ordinal && $op.ordinal <= Opcode.JMP_SNEQ.ordinal)
            || ($op.ordinal >= Opcode.JMP_NLTI.ordinal && $op.ordinal <= Opcode.JMP_SNEQI.ordinal):
        return vm::op_jmp_cmp(ds, insn);
    $else
    $switch $op:
        $case Opcode.LDREG:    return vm::op_ldreg(ds, insn);
        $case Opcode.LDCONST:  return vm::op_ldconst(ds, insn);
        $case Opcode.SETCONST: return vm::op_setconst(ds, insn);
        $case Opcode.LDINT:    return vm::op_ldint(ds, insn);
        $case Opcode.LDINTX:   return vm::op_ldintx(ds, insn);
        $case Opcode.LDUNDEF:  return vm::op_ldundef(ds, insn);
        $case Opcode.LDNULL:   return vm::op_ldnull(ds, insn);
        $case Opcode.LDTRUE:   return vm::op_ldtrue(ds, insn);
        $case Opcode.LDFALSE:  return vm::op_ldfalse(ds, insn);
        $case Opcode.LDTHIS:
        $case Opcode.GETTHISC:
        $case Opcode.PUTTHISC: return vm::op_ldthis(ds, insn);

        $case Opcode.ADD_FUSED:
        $case Opcode.ADD:      return vm::op_add(ds, insn);
        $case Opcode.SUB:      return vm::op_sub(ds, insn);
        $case Opcode.ADDI:     return vm::op_addi(ds, insn);
        $case Opcode.STRJOIN:
        $case Opcode.STRJOIN_LENGTH: return vm::op_strjoin(ds, insn);
        $case Opcode.SUBI:     return vm::op_subi(ds, insn);
        $case Opcode.MUL:
        $case Opcode.MULI:     return vm::op_mul(ds, insn);
        $case Opcode.DIV:      return vm::op_div(ds, insn);
        $case Opcode.MOD:      return vm::op_mod(ds, insn);
        $case Opcode.EXP:      return vm::op_exp(ds, insn);

        $case Opcode.UNP:
        $case Opcode.UNM:
        $case Opcode.BNOT:
        $case Opcode.LNOT:
        $case Opcode.TYPEOF:
        $case Opcode.VOID:
        $case Opcode.TONUMERIC:
        $case Opcode.INC:
        $case Opcode.INC_LT:
        $case Opcode.DEC:
        $case Opcode.PUTARG:
        $case Opcode.INC_VAR:
        $case Opcode.DEC_VAR:
        $case Opcode.INC_GLOBAL:
        $case Opcode.DEC_GLOBAL: return vm::op_unary(ds, insn);

        $case Opcode.BAND:
        $case Opcode.BANDI:    return vm::op_band(ds, insn);
        $case Opcode.BOR:
        $case Opcode.BORI:     return vm::op_bor(ds, insn);
        $case Opcode.BXOR:
        $case Opcode.BXORI:    return vm::op_bxor(ds, insn);
        $case Opcode.SHL:
        $case Opcode.SHLI:     return vm::op_shl(ds, insn);
        $case Opcode.SHR:
        $case Opcode.SHRI:     return vm::op_shr(ds, insn);
        $case Opcode.USHR:
        $case Opcode.USHRI:    return vm::op_ushr(ds, insn);

        $case Opcode.EQ:       return vm::op_eq(ds, insn);
        $case Opcode.NEQ:      return vm::op_neq(ds, insn);
        $case Opcode.SEQ:      return vm::op_seq(ds, insn);
        $case Opcode.SNEQ:     return vm::op_sneq(ds, insn);
        $case Opcode.LT:
        $case Opcode.LE:
        $case Opcode.GT:
        $case Opcode.GE:       return vm::op_lt(ds, insn);
        $case Opcode.JMP_EQ:
        $case Opcode.JMP_NEQ:  return vm::op_jmp_eq(ds, insn);
        $case Opcode.JMP_NULL:
        $case Opcode.JMP_NNULL: return vm::op_jmp_null(ds, insn);
        $case Opcode.INSTANCEOF: return vm::op_instanceof(ds, insn);
        $case Opcode.IN:       return vm::op_in(ds, insn);

        $case Opcode.JUMP:     return vm::op_jump(ds, insn);
        $case Opcode.IF_TRUE:
        $case Opcode.IF_FALSE: return vm::op_if(ds, insn);

        $case Opcode.GETPROPC_CACHED:
        $case Opcode.GETPROP:
        $case Opcode.GETPROP_CACHE:
        $case Opcode.GETPROPC:
        $case Opcode.PUTPROP:
        $case Opcode.PUTPROP_NE:
        $case Opcode.PUTPROP_SUPER:
        $case Opcode.GETPROP_SUPER:
        $case Opcode.DELPROP:  return vm::op_property(ds, insn);
        $case Opcode.PUTPROPC: return vm::op_putpropc(ds, insn);
        $case Opcode.TOPROPKEY: return vm::op_topropkey(ds, insn);
        $case Opcode.TOSTR:    return vm::op_tostr(ds, insn);
        $case Opcode.RETEST:   return vm::op_retest(ds, insn);
        $case Opcode.HOF_GUARD: return vm::op_hof_guard(ds, insn);
        $case Opcode.HOF_ELEM: return vm::op_hof_elem(ds, insn);
        $case Opcode.HOF_GET:  return vm::op_hof_get(ds, insn);
        $case Opcode.HOF_NEWARR: return vm::op_hof_newarr(ds, insn);
        $case Opcode.HOF_PUT:  return vm::op_hof_put(ds, insn);

        $case Opcode.SPREAD_PROJECTION:
        $case Opcode.NEWOBJ_SHAPE:
        $case Opcode.INIT_SLOT:
        $case Opcode.NEWOBJ:
        $case Opcode.NEWARR:
        $case Opcode.NEWARR_CONST:
        $case Opcode.NEWREGEXP:
        $case Opcode.SETALEN:
        $case Opcode.FREEZEOBJ:
        $case Opcode.ARRSPRD:
        $case Opcode.OBJSPRD:
        $case Opcode.OBJREST:
        $case Opcode.SPREAD_ARG:
        $case Opcode.FWD_ARGS:
        $case Opcode.APPLY_ARGS: return vm::op_objects(ds, insn);

        $case Opcode.CALL:
        $case Opcode.CALL_S:
        $case Opcode.CALL_UNDEF_THIS:
        $case Opcode.CALL_VAR:
        $case Opcode.CALL_GLOBAL:
        $case Opcode.TAILCALL_UNDEF_THIS:
        $case Opcode.TAILCALL_VAR:
        $case Opcode.TAILCALL_GLOBAL:
        $case Opcode.TAILCALL_CALL:
        $case Opcode.TAILCALL_CALL_S: return vm::op_call(ds, insn);

        $case Opcode.CALL_PROP:
        $case Opcode.SETPROTO:
        $case Opcode.GETPROTO:
        $case Opcode.SUPER_CALL:
        $case Opcode.SUPER_CALL_S:
        $case Opcode.NEWTARGET:
        $case Opcode.CLASS_SCALAR_GUARD:
        $case Opcode.NEW_OBJ:
        $case Opcode.NEW_OBJ_S:
        $case Opcode.TAILCALL: return vm::op_calls(ds, insn);

        $case Opcode.DYN_IMPORT:
        $case Opcode.DYN_IMPORT_DEFER:
        $case Opcode.DYN_IMPORT_SOURCE: return vm::op_dyn_import(ds, insn);
        $case Opcode.IMPORT_META: return vm::op_import_meta(ds, insn);

        $case Opcode.RET:
        $case Opcode.RETUNDEF: return vm::op_ret(ds, insn);

        $case Opcode.RESOLVEVAR: return vm::op_resolvevar(ds, insn);
        $case Opcode.THROW_UNRESOLVED: return vm::op_throw_unresolved(ds, insn);

        $case Opcode.GETCAP:
        $case Opcode.GETVAR:
        $case Opcode.GETGLOBAL:
        $case Opcode.TYPEOFIDENT: return vm::op_getvar(ds, insn);
        $case Opcode.PUTGLOBAL: return vm::op_putglobal(ds, insn);
        $case Opcode.PUTVAR:   return vm::op_putvar(ds, insn);
        $case Opcode.PUTCAP:
        $case Opcode.PUTVAR_ASSIGN: return vm::op_putvar_assign(ds, insn);
        $case Opcode.PUTCAP_SNAP:
        $case Opcode.PUTVAR_SNAP: return vm::op_putvar_snap(ds, insn);
        $case Opcode.DECLGLOBALFUNC: return vm::op_declglobalfunc(ds, insn);
        $case Opcode.DECLB33GLOBAL: return vm::op_declb33global(ds, insn);
        $case Opcode.DECLVAR_HOIST: return vm::op_declvar_hoist(ds, insn);
        $case Opcode.DECLVAR:  return vm::op_declvar(ds, insn);
        $case Opcode.PUTLEX:   return vm::op_putlex(ds, insn);
        $case Opcode.PUTLEX_C: return vm::op_putlex_c(ds, insn);
        $case Opcode.INITTZ:   return vm::op_inittz(ds, insn);
        $case Opcode.CHKGLOBALLEX:
        $case Opcode.CHKGLOBALVAR:
        $case Opcode.CHKGLOBALFUNC: return vm::op_chkglobal(ds, insn);
        $case Opcode.DELVAR:   return vm::op_delvar(ds, insn);

        $case Opcode.WITHGET:  return vm::op_withget(ds, insn);
        $case Opcode.WITHBASE: return vm::op_withbase(ds, insn);
        $case Opcode.WTWR:     return vm::op_wtwr(ds, insn);

        $case Opcode.NEWCELLS:
        $case Opcode.GETCELL:
        $case Opcode.SETCELL:
        $case Opcode.MOVECELL: return vm::op_cells(ds, insn);
        $case Opcode.CLOSURE:
        $case Opcode.GETBOUND: return vm::op_closure(ds, insn);

        $case Opcode.INITFOR:
        $case Opcode.NEXTFOR:
        $case Opcode.ITER_NEXT_FAST:
        $case Opcode.ITER_ENTRY_FAST:
        $case Opcode.ARRAY_PATTERN_GUARD:
        $case Opcode.ITER_OPEN_FAST:
        $case Opcode.DESTRUCT_ARRAY_FAST:
        $case Opcode.DESTRUCT_ARRAY_REST_FAST: return vm::op_iterator(ds, insn);

        $case Opcode.TRY:
        $case Opcode.ENDTRY:
        $case Opcode.THROW:
        $case Opcode.THROW_REF:
        $case Opcode.THROW_SYNTAX:
        $case Opcode.CATCH:
        $case Opcode.FINALLY:
        $case Opcode.ENDFINALLY: return vm::op_exceptions(ds, insn);

        $case Opcode.NOP:
        $case Opcode.DEBUGGER:
        $case Opcode.BREAK:
        $case Opcode.CONTINUE:
        $case Opcode.INITGET:
        $case Opcode.INITSET:
        $case Opcode.INITSETI:
        $case Opcode.INITPROP:
        $case Opcode.INITELEM:
        $case Opcode.INITPROPN:
        $case Opcode.CLASS_INITGET:
        $case Opcode.CLASS_INITSET:
        $case Opcode.CLASS_INITPROP:
        $case Opcode.CSVARI:
        $case Opcode.PUSH_LEX:
        $case Opcode.POP_LEX:
        $case Opcode.PUSH_VAR:
        $case Opcode.POP_VAR:
        $case Opcode.REQUIRE_OBJ:
        $case Opcode.CHKOBJ:
        $case Opcode.CHKITER:
        $case Opcode.ITER_CLOSE:
        $case Opcode.ITER_CLOSE_ESCAPE:
        $case Opcode.GET_ITER_ASYNC:
        $case Opcode.ITER_CLOSE_ASYNC:
        $case Opcode.CHKCTOR:
        $case Opcode.CHK_PROT:
        $case Opcode.NEW_PRIV_SYM:
        $case Opcode.ADD_BRAND:
        $case Opcode.CHK_BRAND:
        $case Opcode.HAS_BRAND:
        $case Opcode.INITPROP_PRIV:
        $case Opcode.GETPROP_PRIVATE: return vm::op_misc(ds, insn);

        $default:
            $error "Opcode has no baseline thunk; add it to @run_op or @excluded.";
    $endswitch
    $endif
}
