module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::features;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::esm;

// ============================================================================
// VM creation / destruction
// ============================================================================

// Opt-in for test-harness binaries: when set before vm_create() or
// vm_reset(), the test262 host globals ($262, __evalScript,
// __detachArrayBuffer) are installed. Off by default.
bool test262_host_enabled = false;

// Create and initialise a new VM.
fn Vm*? vm_create(Heap* heap) {
    void* raw = heap.alloc_func(heap.heap_udata, Vm::size);
    if (raw == null) {
        return VM_ERROR~;
    }
    mem::clear(raw, (sz)(Vm::size));

    Vm* vm = (Vm*)raw;
    vm.heap = heap;
    vm.activations = &vm.activation_storage;
    vm.activation_capacity = MAX_CALLS;

$if $feat(THREADED_DISPATCH):
    init_threaded_handlers();
$endif

    // Must be zeroed: valstack slots are only safe to tval_copy_ref/decref_tval
    // when they hold a real TVal (0 is undefined). A reused block can contain
    // stale heap pointers from a previous VM, and a later decref would hit a
    // freed object and corrupt the pool freelist.
    usz vs_bytes = (usz)INITIAL_VALSTACK * TVal::size;
    void* vs_raw = heap.alloc_func(heap.heap_udata, vs_bytes);
    if (vs_raw == null) {
        heap.free_func(heap.heap_udata, raw);
        return VM_ERROR~;
    }
    mem::clear(vs_raw, (sz)(vs_bytes));
    vm.valstack = (TVal*)vs_raw;
    vm.valstack_size = INITIAL_VALSTACK;
    vm.valstack_top = (TVal*)vs_raw;
    vm.valstack_end = (TVal*)((usz)vs_raw + (usz)INITIAL_VALSTACK * TVal::size);

    // Register valstack with heap for GC root scanning
    heap.valstack_base = vm.valstack;
    heap.valstack_top_ptr = &vm.valstack_top;
    heap.curr_thread = vm;
    heap.mark_activations_fn = &vm_mark_activations;
    heap.mark_activations_slice_fn = &vm_mark_activations_slice;
    heap.catcher_chain_fn = &vm_catcher_chain_bridge;
    defer catch detach_vm_roots(heap);

    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) {
        heap.free_func(heap.heap_udata, vs_raw);
        heap.free_func(heap.heap_udata, raw);
        return VM_ERROR~;
    }
    vm.global_env = global;
    heap.shade_root_env(global);

    // Register the global environment's bindings object as a GC root
    // so that mark-and-sweep never collects the global scope.
    heap.register_gc_root(global.bindings.as_header());

    // Global lexical (declarative) record for top-level let/const/class.
    EnvRecord*? global_lex = env::env_create_declarative(heap, global);
    if (catch err = global_lex) {
        heap.free_func(heap.heap_udata, vs_raw);
        heap.free_func(heap.heap_udata, raw);
        return VM_ERROR~;
    }
    vm.global_lex_env = global_lex;
    heap.shade_root_env(global_lex);
    heap.register_gc_root(global_lex.bindings.as_header());

    if (!builtins::register_builtins(global, heap)) {
        env::env_pool_free(heap, global);
        env::env_pool_free(heap, global_lex);
        heap.free_func(heap.heap_udata, vs_raw);
        heap.free_func(heap.heap_udata, raw);
        return VM_ERROR~;
    }
    $if features::TEST262_HOST:
    if (test262_host_enabled) {
        builtins::register_test262_host(global, heap);
    }
    $endif

    vm.activation_count = 0;
    vm.has_error = false;
    vm.throw_pending = false;
    vm.current_func = null;
    vm.curr_pc = null;

    heap.call_handler_fn = &vm_call_handler_fn_impl;
    heap.call_fn = &vm_call_fn_impl;
    heap.construct_fn = &vm_construct_fn_impl;
    heap.microtask_after_fn = &builtins::promise_microtask_after;
    heap.proxy_get_fn = &vm_proxy_get_bridge;
    heap.force_deferred_ns_fn = &esm::force_deferred_namespace_bridge;
    heap.proxy_has_fn = &vm_proxy_has_bridge;
    heap.vm_ptr = vm;

    return vm;
}

// Proxy MOP bridges, connecting the hobject chain walkers to the builtins-layer
// proxy trap implementations (see heap.proxy_get_fn / proxy_has_fn).
fn bool vm_proxy_get_bridge(void* vm, void* heap, void* proxy, void* key, TVal receiver, TVal* out) {
    return builtins::proxy_mop_get(vm, (Heap*)heap, (HObject*)proxy, (HString*)key, receiver, out);
}

fn bool vm_proxy_has_bridge(void* vm, void* heap, void* proxy, void* key, bool* out) {
    return builtins::proxy_mop_has(vm, (Heap*)heap, (HObject*)proxy, (HString*)key, out);
}

// Suspended generators can release catchers after the VM is gone.
fn void detach_vm_roots(Heap* h) {
    h.curr_thread = null;
    h.vm_ptr = null;
    h.valstack_base = null;
    h.valstack_top_ptr = null;
    h.mark_activations_fn = null;
    h.mark_activations_slice_fn = null;
}

// Destroy a VM and release all owned resources.
fn void vm_destroy(Vm* vm) {
    if (vm == null) return;
    // env_destroy is not called: heap.destroy() frees all HObjects, and calling it
    // here would double-free them.
    if (vm.valstack != null) {
        vm.heap.free_func(vm.heap.heap_udata, vm.valstack);
    }
    detach_vm_roots(vm.heap);
    vm.heap.free_func(vm.heap.heap_udata, vm);
}

// Reuse a VM after heap.reset(). The valstack buffer is kept and its top rewound.
// Returns false on failure.
fn bool vm_reset(Vm* vm, Heap* heap) {
    if (vm == null || heap == null) { return false; }

    // heap.reset() may clear the chain hook; reinstall it before the walk below.
    vm.heap.catcher_chain_fn = &vm_catcher_chain_bridge;

    // All HObject*/HString* were freed by heap.reset(), so stale TVal refs must be cleared.
    for (uint i = 0; i < vm.valstack_size; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top    = vm.valstack;
    vm.valstack_bottom = vm.valstack;

    // Walk the whole pool, not just [0, activation_count): malloc'd Catcher and
    // ForInState chains hang off the activations, and vm_reset is their last owner.
    for (uint i = 0; i < MAX_CALLS; i++) {
        vm.activations[i].this_binding.set_undefined();
        vm.activations[i].tv_func.set_undefined();
        vm.activations[i].func = null;
        vm.activations[i].parent = null;
        vm.activations[i].var_env = null;
        vm.activations[i].lex_env = null;
        // Free the catcher and for-in nodes only. The heap objects they reference
        // are already freed, so they must not be released through them.
        if (vm.activations[i].cat != null && vm.heap.catcher_chain_fn != null) {
            vm.heap.catcher_chain_fn(vm.heap, vm.activations[i].cat,
                                     heap::CATCHER_CHAIN_FREE_NODES_ONLY);
        }
        vm.activations[i].cat = null;
        ForInState* fi = (ForInState*)vm.activations[i].forin;
        while (fi != null) {
            ForInState* fi_parent = fi.parent;
            if (fi.keys != null) { vm.heap.free_func(vm.heap.heap_udata, fi.keys); }
            vm.heap.free_func(vm.heap.heap_udata, fi);
            fi = fi_parent;
        }
        vm.activations[i].forin = null;
        vm.activations[i].new_target = null;
    }
    vm.activation_count = 0;
    vm.has_error        = false;
    vm.throw_pending    = false;
    vm.throw_value.set_undefined();
    vm.current_func     = null;
    vm.curr_pc          = null;
    vm.return_val.set_undefined();

    vm.heap.valstack_base = vm.valstack;
    vm.heap.valstack_top_ptr = &vm.valstack_top;
    vm.heap.curr_thread = vm;
    vm.heap.mark_activations_fn = &vm_mark_activations;
    vm.heap.mark_activations_slice_fn = &vm_mark_activations_slice;
    vm.heap.catcher_chain_fn = &vm_catcher_chain_bridge;

    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) { return false; }
    vm.global_env = global;
    vm.heap.shade_root_env(global);

    heap.register_gc_root(global.bindings.as_header());

    EnvRecord*? global_lex = env::env_create_declarative(heap, global);
    if (catch err = global_lex) { return false; }
    vm.global_lex_env = global_lex;
    vm.heap.shade_root_env(global_lex);
    heap.register_gc_root(global_lex.bindings.as_header());

    if (!builtins::register_builtins(global, heap)) { return false; }
    $if features::TEST262_HOST:
    if (test262_host_enabled) {
        builtins::register_test262_host(global, heap);
    }
    $endif

    return true;
}

// ============================================================================
// Main execution loop
// ============================================================================

// Execute a compiled function from the start.
// Matches duk_js_execute_bytecode() outer/inner pattern.
