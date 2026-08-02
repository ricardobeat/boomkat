module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;

// ============================================================================
// VM creation / destruction
// ============================================================================

// Opt-in flag for test-harness binaries: when set before vm_create() /
// vm_reset_globals(), the test262 host globals ($262, __evalScript,
// __detachArrayBuffer) are installed alongside the standard built-ins.
// The default engine globals never include them.
bool test262_host_enabled = false;

/// Create and initialise a new VM.
fn Vm*? vm_create(Heap* heap) {
    void* raw = heap.alloc_func(heap.heap_udata, Vm::size);
    if (raw == null) {
        return VM_ERROR~;
    }
    mem::clear(raw, (sz)(Vm::size));

    Vm* vm = (Vm*)raw;
    vm.heap = heap;

$if $feature(THREADED_DISPATCH):
    init_threaded_handlers();
$endif

    // Allocate value stack. Must be zeroed: register/valstack slots are only
    // ever safe to tval_copy_ref/decref_tval when they hold a genuine TVal
    // (0 means undefined). malloc reuse of a just-freed valstack, such as the
    // previous VM's, torn down by vm_destroy) can otherwise hand back memory
    // still containing stale heap pointers, causing a later decref to hit an
    // already-freed object and corrupt the pool freelist.
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
    heap.catcher_chain_fn = &vm_catcher_chain_bridge;

    // Create global environment
    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) {
        heap.free_func(heap.heap_udata, vs_raw);
        heap.free_func(heap.heap_udata, raw);
        return VM_ERROR~;
    }
    vm.global_env = global;

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
    heap.register_gc_root(global_lex.bindings.as_header());

    // Register built-ins
    if (!builtins::register_builtins(global, heap)) {
        env::env_destroy(heap, global);
        heap.free_func(heap.heap_udata, vs_raw);
        heap.free_func(heap.heap_udata, raw);
        return VM_ERROR~;
    }
    if (test262_host_enabled) {
        builtins::register_test262_host(global, heap);
    }

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
    heap.proxy_has_fn = &vm_proxy_has_bridge;
    heap.vm_ptr = vm;

    return vm;
}

/// Proxy MOP bridges, connecting the hobject chain walkers to the builtins-layer
/// proxy trap implementations (see heap.proxy_get_fn / proxy_has_fn).
fn bool vm_proxy_get_bridge(void* vm, void* heap, void* proxy, void* key, TVal receiver, TVal* out) {
    return builtins::proxy_mop_get(vm, (Heap*)heap, (HObject*)proxy, (HString*)key, receiver, out);
}

fn bool vm_proxy_has_bridge(void* vm, void* heap, void* proxy, void* key, bool* out) {
    return builtins::proxy_mop_has(vm, (Heap*)heap, (HObject*)proxy, (HString*)key, out);
}

/// Destroy a VM and release all owned resources.
fn void vm_destroy(Vm* vm) {
    if (vm == null) return;
    // env_destroy is NOT called here because all HObjects are tracked
    // in the heap_allocated linked list and freed by heap.destroy().
    // Calling env_destroy would double-free those tracked objects.
    if (vm.valstack != null) {
        vm.heap.free_func(vm.heap.heap_udata, vm.valstack);
    }
    // Clear heap's valstack GC root pointers
    vm.heap.valstack_base = null;
    vm.heap.valstack_top_ptr = null;
    vm.heap.free_func(vm.heap.heap_udata, vm);
}

/// Reset a VM for reuse with a freshly-reset heap.
/// Call heap.reset() first, then vm_reset() to reinitialise global env and
/// builtins. The valstack backing buffer is reused; only its top is rewound.
/// Returns false on failure (treat like vm_create failing).
fn bool vm_reset(Vm* vm, Heap* heap) {
    if (vm == null || heap == null) { return false; }

    // Re-arm the chain hook before the activation walk below uses it: heap.reset()
    // runs first and the bridge must be installed whether or not it survived.
    vm.heap.catcher_chain_fn = &vm_catcher_chain_bridge;

    // Rewind the value stack and clear stale TVal refs. After heap.reset(),
    // all HObject*/HString* are freed, so any lingering TVal heap pointer
    // would cause use-after-free when overwritten.
    for (uint i = 0; i < vm.valstack_size; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top    = vm.valstack;
    vm.valstack_bottom = vm.valstack;

    // Clear stale refs in the activations: every heap object from the
    // previous run are freed, so this_binding, tv_func, etc. are dangling.
    //
    // The whole pool is walked, not just [0, activation_count). Frames above
    // the count are normally drained on the way down, so in practice they are
    // already null, but "normally" is the wrong standard for a leak: the
    // malloc'd Catcher and ForInState chains hang off the activation array,
    // which vm_reset is the last owner of, and a single pop path that ever
    // decrements the count without draining would strand them with nothing left
    // to notice. MAX_CALLS is a fixed, small array, so the extra iterations cost
    // nothing measurable and remove the dependence on that invariant entirely.
    for (uint i = 0; i < MAX_CALLS; i++) {
        vm.activations[i].this_binding.set_undefined();
        vm.activations[i].tv_func.set_undefined();
        vm.activations[i].func = null;
        vm.activations[i].parent = null;
        vm.activations[i].var_env = null;
        vm.activations[i].lex_env = null;
        // Free any catcher and for-in states the interrupted run left behind.
        // The heap objects they point at are already gone (heap.reset() ran
        // before this), so neither the for-in pin nor Catcher.thrown_val may be
        // released through them; only the malloc'd memory the heap reset does
        // not own is freed. Clearing `cat` without this leaked every Catcher a
        // run interrupted inside a try had allocated.
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

    // Update heap's valstack GC root pointers
    vm.heap.valstack_base = vm.valstack;
    vm.heap.valstack_top_ptr = &vm.valstack_top;
    vm.heap.curr_thread = vm;
    vm.heap.mark_activations_fn = &vm_mark_activations;
    vm.heap.catcher_chain_fn = &vm_catcher_chain_bridge;

    // Fresh global environment on the reset heap
    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) { return false; }
    vm.global_env = global;

    heap.register_gc_root(global.bindings.as_header());

    EnvRecord*? global_lex = env::env_create_declarative(heap, global);
    if (catch err = global_lex) { return false; }
    vm.global_lex_env = global_lex;
    heap.register_gc_root(global_lex.bindings.as_header());

    if (!builtins::register_builtins(global, heap)) { return false; }
    if (test262_host_enabled) {
        builtins::register_test262_host(global, heap);
    }

    return true;
}

// ============================================================================
// Main execution loop
// ============================================================================

/// Execute a compiled function from the start.
/// Matches duk_js_execute_bytecode() outer/inner pattern.
