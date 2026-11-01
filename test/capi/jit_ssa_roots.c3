module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::vm;
import std::io;

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
