module boomkat::heap;

import boomkat::vm;
import boomkat::types;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::esm;

// Null is the primary realm, keeping existing functions and single-realm heaps allocation-free.
fn Realm* Heap.enter_realm(&self, Realm* target) @inline {
    Realm* previous = self.realm;
    if (previous != target) self.switch_realm(target);
    return previous;
}

fn void Heap.switch_realm(&self, Realm* target) @noinline {
    Realm* previous = self.realm;
    vm::Vm* v = (vm::Vm*)self.vm_ptr;
    Realm* saved = previous != null ? previous : self.realms;
    saved.state = self.realm_state;
    saved.global_env = v.global_env;
    saved.global_lex_env = v.global_lex_env;
    Realm* next = target != null ? target : self.realms;
    self.realm_state = next.state;
    self.realm = target;
    v.global_env = (env::EnvRecord*)next.global_env;
    v.global_lex_env = (env::EnvRecord*)next.global_lex_env;
    if (self.gc_phase == GcPhase.MARK) {
        self.mark_realm(saved);
        self.mark_realm(next);
    }
}

fn Realm*? Heap.create_realm(&self) {
    vm::Vm* v = (vm::Vm*)self.vm_ptr;
    if (self.realms == null) {
        void* root = self.alloc_func(self.heap_udata, Realm::size);
        if (root == null) return types::ALLOC_ERROR~;
        self.realms = (Realm*)root;
        *self.realms = { .state = self.realm_state, .global_env = v.global_env,
                        .global_lex_env = v.global_lex_env };
    }
    void* raw = self.alloc_func(self.heap_udata, Realm::size);
    if (raw == null) return types::ALLOC_ERROR~;
    Realm* realm = (Realm*)raw;
    *realm = { .next = self.realms.next };
    self.realms.next = realm;
    Realm* previous = self.enter_realm(realm);
    defer self.enter_realm(previous);
    env::EnvRecord* global = env::env_create(self, null)!;
    v.global_env = global;
    v.global_lex_env = env::env_create_declarative(self, global)!;
    self.register_gc_root(global.bindings.as_header());
    self.register_gc_root(v.global_lex_env.bindings.as_header());
    if (!builtins::register_builtins(global, self)) return types::ALLOC_ERROR~;
    if (vm::test262_host_enabled && !builtins::register_test262_host(global, self)) return types::ALLOC_ERROR~;
    return realm;
}

fn void Heap.mark_intrinsics(&self, RealmState* state) {
    $foreach $field : RealmState::members:
        $if $field.type == HObject*:
            self.mark_hobject(state.$field);
        $endif
    $endforeach
}

fn void Heap.mark_realm_module(&self, Realm* realm, uint index) {
    esm::ModuleDef* mod = ((esm::ModuleDef**)realm.state.module_cache)[index];
    if (mod == null) return;
    self.mark_env_chain(mod.env);
    if (mod.has_eval_error) self.mark_tval(&mod.eval_error);
    if (mod.is_synthetic) self.mark_tval(&mod.synth_value);
    self.mark_hobject(mod.import_meta_obj);
    self.mark_hobject(mod.namespace_obj);
    self.mark_hobject(mod.deferred_namespace_obj);
    self.mark_hobject(mod.module_source_obj);
    self.mark_hobject(mod.defer_pending_promise);
    self.mark_hobject(mod.eval_promise);
}

fn void Heap.mark_realm(&self, Realm* r) {
    self.mark_intrinsics(&r.state);
    self.mark_env_chain(r.global_env);
    self.mark_env_chain(r.global_lex_env);
    for (uint i = 0; i < r.state.promoted_builtin_capacity; i++) self.mark_hobject(r.state.promoted_builtins[i]);
    for (uint i = 0; i < r.state.checkpoint_count; i++) self.mark_tval(&r.state.checkpoint_entries[i].value);
    for (uint i = 0; i < r.state.module_cache_count; i++) self.mark_realm_module(r, i);
}

fn void Heap.mark_realm_roots(&self) {
    for (Realm* r = self.realms; r != null; r = r.next) {
        if (r != self.realm && !(r == self.realms && self.realm == null)) self.mark_realm(r);
    }
}

fn void Heap.free_realms(&self) {
    if (self.realms == null) return;
    // The active state's side allocations remain owned by Heap's ordinary teardown.
    for (Realm* r = self.realms; r != null; ) {
        Realm* next = r.next;
        if (r != self.realm && !(r == self.realms && self.realm == null)) {
            if (r.state.promoted_builtins != null) self.free_func(self.heap_udata, r.state.promoted_builtins);
            if (r.state.checkpoint_entries != null) self.free_func(self.heap_udata, r.state.checkpoint_entries);
            RealmState active = self.realm_state;
            self.realm_state = r.state;
            self.free_module_cache();
            self.realm_state = active;
        }
        self.free_func(self.heap_udata, r);
        r = next;
    }
    self.realm = null;
    self.realms = null;
}

// GetFunctionRealm follows bound targets and proxies; revoked proxies throw in the caller's realm.
fn Realm*? function_realm(Heap* h, TVal value) {
    while (value.is_object()) {
        hobject::HObject* object = (hobject::HObject*)value.get_heapptr();
        if (object == null || !object.flags.callable) return types::TYPE_ERROR~;
        if (object.is_proxy()) {
            if (builtins::proxy_handler(object) == null) return types::TYPE_ERROR~;
            value.set_object_borrowed(builtins::proxy_target(object));
        } else if (object.callable_kind() == hobject::CallableKind.BOUND_FN) {
            value = (*object.extra_ptr()).func.bound.target;
        } else {
            return (*object.extra_ptr()).func.realm;
        }
    }
    return null;
}

fn HObject* Heap.realm_intrinsic(&self, Realm* realm, HObject* prototype) {
    if (realm == self.realm) return prototype;
    RealmState* state = realm != null ? &realm.state : &self.realms.state;
    $foreach $field : RealmState::members:
        $if $field.type == HObject*:
            if (self.realm_state.$field == prototype) return state.$field;
        $endif
    $endforeach
    return prototype;
}

fn HObject* Heap.named_intrinsic(&self, char[] name, HObject* value = null) {
    $foreach $field : RealmState::members:
        $if $field.has_tag("constructor"):
            if (builtins::mem_eq_bytes(name, $field.get_tag("constructor"))) {
                if (value != null) self.realm_state.$field = value;
                return self.realm_state.$field;
            }
        $endif
    $endforeach
    return null;
}

fn void Heap.invalidate_array_indices(&self, HObject* object) @inline {
    if (object == self.array_proto || object == self.object_proto) self.index_clean_proto = null;
    if (@unlikely(self.realms != null)) self.invalidate_inactive_array_indices(object);
}

fn void Heap.invalidate_inactive_array_indices(&self, HObject* object) @noinline {
    for (Realm* realm = self.realms; realm != null; realm = realm.next) {
        if (object == realm.state.array_proto || object == realm.state.object_proto) {
            realm.state.index_clean_proto = null;
        }
    }
}
