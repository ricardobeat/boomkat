module boomkat::vm;

import boomkat::heap;
import boomkat::hobject;

// The client owns every registration, including partially constructed graphs.
// A failed optimization may leave harmless watches until the plan is freed.
fn bool sljit_watch_layout(Heap* h, FunctionPlan* plan, HObject* owner) @feat(SLJIT) {
    for (JitWriteDependency* node = plan.dependencies; node != null; node = node.next_client) {
        if (node.owner == owner && node.slot == null) return true;
    }
    JitWriteDependency* node = h.jit_watch_layout(owner, &plan.dependencies_live);
    if (node == null) return false;
    node.next_client = plan.dependencies;
    plan.dependencies = node;
    return true;
}

fn bool sljit_watch_property(Heap* h, FunctionPlan* plan, HObject* owner, uint slot) @feat(SLJIT) {
    PropValue* address = &owner.prop_values()[slot];
    bool has_layout;
    bool has_value;
    for (JitWriteDependency* node = plan.dependencies; node != null; node = node.next_client) {
        if (node.owner != owner) continue;
        if (node.slot == null) { has_layout = true; }
        else if (node.slot == address) { has_value = true; }
    }
    if (!has_layout) {
        JitWriteDependency* layout = h.jit_watch_layout(owner, &plan.dependencies_live);
        if (layout == null) return false;
        layout.next_client = plan.dependencies;
        plan.dependencies = layout;
    }
    if (!has_value) {
        JitWriteDependency* value = h.jit_watch_slot(owner, slot, &plan.dependencies_live);
        if (value == null) return false;
        value.next_client = plan.dependencies;
        plan.dependencies = value;
    }
    return true;
}

fn void sljit_dependencies_rollback(Heap* h, FunctionPlan* plan, JitWriteDependency* checkpoint) @feat(SLJIT) {
    while (plan.dependencies != checkpoint) {
        JitWriteDependency* node = plan.dependencies;
        plan.dependencies = node.next_client;
        h.jit_unwatch(node);
    }
}

fn void sljit_dependencies_free(Heap* h, FunctionPlan* plan) @feat(SLJIT) {
    sljit_dependencies_rollback(h, plan, null);
}
