module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::jit;
import boomkat::types;
import boomkat::vm;
import std::io;

const ulong HELPER_HOME_SENTINEL = 0x7654321076543210UL;

fn void check_ssa_boxed_truth() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    eval(&context, "var console={log:function(){}};");
    eval(&context, $embed("../jit_ssa_boxed_truth.js"));
    CompiledFunction* cf = named_function(&runtime, "nativeBoxedTruth");
    @check(cf != null && cf.code_count > vm::SSA_SPAN);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null);
    @check(plan.ssa_region.ssa_helpers == null);
    @check(plan.ssa_region.ssa_completed > 100);
    ulong[512] exits_before = plan.exit_pcs;
    ulong completed = plan.ssa_region.ssa_completed;
    eval(&context, "for(var q=0;q<64;q++){if(nativeBoxedTruth(truthObject,truthOutput)!==3)throw 'object native branch';}");
    @check(plan.ssa_region.ssa_completed >= completed + 32);
    // The forward branch tests the boxed argument. The backward IF_TRUE
    // may still exit for a scheduled GC/interrupt poll and is not a tag miss.
    uint conditions = 0;
    for (uint pc = 0; pc < plan.count && pc < 512; pc++) {
        if (cf.code[pc].op != Opcode.IF_FALSE) continue;
        @check(plan.exit_pcs[pc] == exits_before[pc]);
        conditions++;
    }
    @check(conditions == 1);
    Heap* h = runtime.rt.heap;
    HObject* globals = runtime.rt.vm.global_env.bindings;
    int object_slot = globals.find_prop_idx(h.str_intern("truthObject"), h);
    @check(object_slot >= 0);
    HObject* prior = h.htmldda_obj;
    defer h.htmldda_obj = prior;
    h.htmldda_obj = globals.prop_values()[object_slot].get().get_heapptr();
    eval(&context, "if(nativeBoxedTruth(truthObject,truthOutput)!==6)throw 'live HTMLDDA identity';");
    h.htmldda_obj = prior;
    eval(&context, "if(nativeBoxedTruth(truthObject,truthOutput)!==3)throw 'restored HTMLDDA identity';");
    io::printn("SSA boxed truth: PASS native cyclic object/null/boolean/integer branches");
}

fn long helper_home_probe(LoopState* state) @noinline {
    ulong* bits = state.execution.saved_bits;
    ulong boxed_saved = vm::loop_bits(types::make_fastint(29));
    ulong boxed_scratch = vm::loop_bits(types::make_fastint(31));
    ulong boxed_spill = vm::loop_bits(types::make_fastint(37));
    bool saved_fp = jit::sljit_shim_info(3) != 0;
    state.execution.output_count = bits[0] == 37 && bits[1] == HELPER_HOME_SENTINEL
        && bits[2] == bitcast(1.25, ulong)
        && bits[3] == (saved_fp ? HELPER_HOME_SENTINEL : bitcast(2.5, ulong))
        && bits[4] == HELPER_HOME_SENTINEL && bits[5] == boxed_saved
        && bits[6] == boxed_scratch && bits[7] == boxed_spill ? 1 : 0;
    // Surviving homes must remain authoritative. Poison their unused saved
    // slots so an unnecessary restore corrupts the generated result.
    bits[1] = 99;
    if (saved_fp) bits[3] = bitcast(99.0, ulong);
    bits[4] = 99;
    bits[5] = vm::loop_bits(types::make_fastint(99));
    bits[7] = vm::loop_bits(types::make_fastint(99));
    return 1;
}

alias HelperHomeEntry = fn long(LoopState* state);

fn void check_ssa_helper_homes() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    Heap* h = runtime.rt.heap;
    LoopState* state = h.alloc_func(h.heap_udata, LoopState::size + 2 * ulong::size);
    @check(state != null);
    defer h.free_func(h.heap_udata, state);
    SsaExecution execution;
    ulong[8] bits;
    ulong[8] results;
    foreach (&value : bits) *value = HELPER_HOME_SENTINEL;
    execution.saved_bits = &bits[0];
    execution.edge = &results[0];
    state.execution = &execution;
    SsaPlanData data;
    LoopPlan plan = { .ssa_data = &data };
    int total_fp = jit::sljit_shim_info(2);
    bool saved_fp = jit::sljit_shim_info(3) != 0;
    SsaValue[8] values = {
        { .op = ARG, .rep = INT32, .home = jit::reg_r(4) },
        { .op = ARG, .rep = INT32, .home = jit::reg_s(1) },
        { .op = ARG, .rep = F64, .home = 3 },
        { .op = ARG, .rep = F64, .home = saved_fp ? total_fp : 4 },
        { .op = ARG, .rep = INT32, .spill = 0 },
        { .op = ARG, .rep = BOXED, .home = jit::reg_s(2) },
        { .op = ARG, .rep = BOXED, .home = jit::reg_r(5) },
        { .op = ARG, .rep = BOXED, .spill = 1 }
    };
    ulong[8] expected = { 37, 41, bitcast(1.25, ulong), bitcast(2.5, ulong), 43,
        vm::loop_bits(types::make_fastint(29)), vm::loop_bits(types::make_fastint(31)),
        vm::loop_bits(types::make_fastint(37)) };
    SsaGraph graph = { .values = &values[0], .value_count = 8, .recoverable = true, .plan = &plan };
    SsaEmitter emitter = { .g = &graph, .plan = &plan, .state = jit::reg_s(0) };
    void* compiler = jit::sljit_create_compiler(null);
    @check(compiler != null);
    defer jit::sljit_free_compiler(compiler);
    emitter.e.compiler = compiler;
    @check(jit::sljit_emit_enter(compiler, 0, jit::SLJIT_ARGS1WW_R, 7 | (total_fp << 8), 3, 0) == 0);
    emitter.e.mov(emitter.state, 0, jit::reg_r(0), 0);
    for (uint i = 0; i < values.len; i++) {
        emitter.e.mov(jit::reg_r(0), 0, jit::SLJIT_IMM, (long)expected[i]);
        if (values[i].rep == F64) {
            @check(jit::sljit_emit_fcopy(compiler, jit::SLJIT_COPY_TO_F64, values[i].home, jit::reg_r(0)) == 0);
        } else { emitter.store_gpr((int)i, jit::reg_r(0)); }
    }
    uint[8] live = { 0, 1, 2, 3, 4, 5, 6, 7 };
    uint[3] roots = { 5, 6, 7 };
    SsaHelperSite site = { .live_values = &live[0], .live_count = 8, .root_values = &roots[0], .root_count = 3 };
    emitter.helper_save_values(&site);
    emitter.e.mov(jit::reg_r(0), 0, emitter.state, 0);
    @check(jit::sljit_emit_icall(compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW,
        jit::SLJIT_IMM, (long)&helper_home_probe) == 0);
    // Force volatile homes to be clobbered independently of the C compiler's
    // register choices, then exercise the actual helper continuation emitter.
    emitter.e.mov(jit::reg_r(4), 0, jit::SLJIT_IMM, -99);
    emitter.e.mov(jit::reg_r(5), 0, jit::SLJIT_IMM, -99);
    emitter.e.mov(jit::reg_r(0), 0, jit::SLJIT_IMM, (long)bitcast(-99.0, ulong));
    @check(jit::sljit_emit_fcopy(compiler, jit::SLJIT_COPY_TO_F64, 3, jit::reg_r(0)) == 0);
    if (!saved_fp) @check(jit::sljit_emit_fcopy(compiler, jit::SLJIT_COPY_TO_F64, 4, jit::reg_r(0)) == 0);
    emitter.helper_restore_values(&site);
    for (uint i = 0; i < values.len; i++) {
        if (values[i].rep == F64) {
            emitter.load_fpr((int)i, 1);
            @check(jit::sljit_emit_fcopy(compiler, jit::SLJIT_COPY_FROM_F64, 1, jit::reg_r(0)) == 0);
        } else { emitter.gpr((int)i, jit::reg_r(0)); }
        emitter.e.mov(jit::reg_r(2), 0, jit::SLJIT_MEM | emitter.state, $reflect(LoopState.execution).offset);
        emitter.e.mov(jit::reg_r(2), 0, jit::SLJIT_MEM | jit::reg_r(2), $reflect(SsaExecution.edge).offset);
        emitter.e.mov(jit::SLJIT_MEM | jit::reg_r(2), (long)i * ulong::size, jit::reg_r(0), 0);
    }
    @check(jit::sljit_emit_return(compiler, jit::SLJIT_MOV, jit::SLJIT_IMM, 1) == 0);
    @check(!emitter.e.failed);
    void* code = jit::sljit_generate_code(compiler, 0, null);
    @check(code != null);
    defer jit::sljit_free_code(code, null);
    @check(((HelperHomeEntry)code)(state) == 1 && execution.output_count == 1);
    foreach (i, value : results) @check(value == expected[i]);
    io::printfn("SSA helper homes: PASS C ABI saved/volatile registers, spills and boxed roots (saved FP=%d)", saved_fp);
}

// Stable descriptors need not all join the collector chain at invocation
// entry. Exercise sparse ownership independently of incidental JS allocation.
fn void check_ssa_lazy_roots() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    Heap* h = runtime.rt.heap;
    Vm* vm = runtime.rt.vm;
    CompiledFunction function = { .num_regs = 1 };
    CompiledFunction* prior_function = vm.current_func;
    Activation prior_activation = vm.activation_storage[0];
    defer { vm.current_func = prior_function; vm.activation_storage[0] = prior_activation; }
    vm.current_func = &function;
    vm.activation_storage[0] = { .func = &function, .bottom = vm.valstack };
    ColdCtx cold = { .vm = vm, .heap = h, .act = &vm.activation_storage[0] };
    JitArtifact owner = { .state = LIVE, .generation = 1 };
    LoopPlan plan = { .code_owner = &owner };
    ValueRoot* prior_roots = h.value_roots;
    ValueRoot* prior_cursor = h.gc_root_value_cursor;
    SsaExecution execution;
    @check(vm::ssa_execution_init(&execution, &cold, &plan, 4096, 0, 0));
    @check(execution.root_count == 0 && h.value_roots == prior_roots);
    @check(owner.pins == 1);
    TVal first = types::make_string(h.alloc_text("native sparse alpha"));
    TVal second = types::make_string(h.alloc_text("native sparse beta"));
    HeapHeader* first_header = first.get_heapptr();
    HeapHeader* second_header = second.get_heapptr();
    ulong first_bits = vm::loop_bits(first);
    ulong second_bits = vm::loop_bits(second);
    uint[2] ids = { 4095, 17 };
    SsaHelperSite site = { .root_values = &ids[0], .root_count = 2 };
    execution.saved_bits[4095] = first_bits;
    execution.saved_bits[17] = second_bits;
    @check(vm::ssa_execution_roots(&execution, &site));
    h.decref_tval(&first); first.set_undefined();
    h.decref_tval(&second); second.set_undefined();
    @check(first_header.refcount == 1 && second_header.refcount == 1);
    @check(execution.root_count == 2 && execution.root_order[0] == 4095 && execution.root_order[1] == 17);
    @check(h.value_roots == &execution.roots[17] && execution.roots[17].previous == &execution.roots[4095]);
    h.gc_root_value_cursor = &execution.roots[4095];
    // Each string has only its old native root. Retain the complete new map
    // before replacing either descriptor or the first copy frees a source.
    execution.saved_bits[4095] = second_bits;
    execution.saved_bits[17] = first_bits;
    @check(vm::ssa_execution_roots(&execution, &site));
    @check(execution.root_count == 2 && h.gc_root_value_cursor == &execution.roots[4095]);
    @check(execution.roots[4095].value.get_heapptr() == second_header);
    @check(execution.roots[17].value.get_heapptr() == first_header);
    @check(first_header.refcount == 1 && second_header.refcount == 1);
    site.root_count = 0;
    @check(vm::ssa_execution_roots(&execution, &site));
    @check(execution.live_root_count == 0 && execution.root_count == 2);
    @check(execution.roots[4095].value.is_undefined() && execution.roots[17].value.is_undefined());
    @check(h.gc_root_value_cursor == &execution.roots[4095]);
    // A boxed deopt-only location also lazily registers before its retain and
    // publication passes. The chain's cursor remains on the older descriptor.
    TVal third = types::make_string(h.alloc_text("native deopt gamma"));
    SsaDeoptLocation location = { .kind = CONSTANT, .rep = BOXED, .value = 700, .bits = vm::loop_bits(third) };
    for (uint pass = 0; pass < 3; pass++) @check(vm::ssa_deopt_anchor_location(&execution, location, pass));
    h.decref_tval(&third); third.set_undefined();
    @check(execution.root_count == 3 && execution.root_order[2] == 700);
    @check(h.value_roots == &execution.roots[700] && h.gc_root_value_cursor == &execution.roots[4095]);
    @check(((HeapHeader*)execution.roots[700].value.get_heapptr()).refcount == 1);
    vm::ssa_execution_dispose(&execution);
    @check(h.value_roots == prior_roots && h.gc_root_value_cursor == prior_roots && owner.pins == 0);
    h.gc_root_value_cursor = prior_cursor;
    io::printn("SSA lazy roots: PASS empty entry, sparse swaps, clear, deopt and reverse disposal");
}

fn void check_ssa_sparse_imports() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    Heap* h = runtime.rt.heap;
    Vm* vm = runtime.rt.vm;
    CompiledFunction function = { .num_regs = 900 };
    CompiledFunction* prior_function = vm.current_func;
    Activation prior_activation = vm.activation_storage[0];
    uint prior_count = vm.activation_count;
    defer { vm.current_func = prior_function; vm.activation_storage[0] = prior_activation; vm.activation_count = prior_count; }
    vm.current_func = &function;
    vm.activation_storage[0] = { .func = &function, .bottom = vm.valstack };
    vm.activation_count = 1;
    vm.valstack[0].set_fastint(3);
    vm.valstack[899].set_fastint(11);
    ColdCtx cold = { .vm = vm, .heap = h, .act = &vm.activation_storage[0] };
    JitArtifact owner = { .state = LIVE, .generation = 1 };
    LoopPlan plan = { .code_owner = &owner };
    SsaExecution execution;
    @check(vm::ssa_execution_init(&execution, &cold, &plan, 1, 0, 0));
    defer vm::ssa_execution_dispose(&execution);
    // Validation/rebinding and sparse publication must not silently copy a
    // 900-register frame. Only the actual before-frame output is imported.
    vm.valstack[899].set_fastint(22);
    @check(vm::ssa_execution_rebind(&execution));
    @check(execution.input_values[899].get_fastint() == 11);
    execution.outputs[0].reg = 1;
    execution.outputs[0].value.set_fastint(9);
    execution.output_count = 1;
    @check(vm::ssa_execution_publish(&execution));
    @check(execution.input_values[1].get_fastint() == 9 && vm.valstack[1].get_fastint() == 9);
    @check(execution.input_values[899].get_fastint() == 11);
    SsaFrameEntry[1] after = { { .reg = 0, .value = 0 } };
    SsaHelperSite site = { .after_entries = &after[0], .after_count = 1, .result_reg = 899 };
    vm.valstack[0].set_fastint(44);
    vm.valstack[899].set_fastint(55);
    @check(vm::ssa_execution_import_after(&execution, &site));
    @check(execution.input_values[0].get_fastint() == 44 && execution.input_values[899].get_fastint() == 55);
    @check(execution.input_values[1].get_fastint() == 9);
    io::printn("SSA sparse imports: PASS rebind, sparse before/after maps and high result");
}
