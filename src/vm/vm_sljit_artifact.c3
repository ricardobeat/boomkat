module boomkat::vm;

import boomkat::heap;
import boomkat::bytecode;
import boomkat::jit;

// One owner includes every executable fragment and the metadata those
// fragments address. Dispatch detachment precedes retirement; reclamation
// waits for both generated execution and its C publication work to unwind.
enum JitArtifactKind : char { FUNCTION_CODE, LOOP_CODE, TEMPLATE_CODE }
enum JitArtifactState : char { DRAFT, LIVE, RETIRED, RELEASED }
alias JitArtifactRelease = fn void(Heap* h, JitArtifact* artifact);

struct JitArtifact @feat(SLJIT) {
    JitArtifact* previous;
    JitArtifact* next;
    JitArtifact* retired_next;
    CompiledFunction* function;
    void* payload;
    JitArtifactRelease release;
    usz code_bytes;
    usz metadata_bytes;
    ulong generation;
    ulong last_use;
    ulong progress;
    uint pins;
    JitArtifactKind kind;
    JitArtifactState state;
}

fn void sljit_artifact_publish(Heap* h, JitArtifact* artifact,
    CompiledFunction* cf, void* payload, JitArtifactKind kind,
    usz code_bytes, usz metadata_bytes, JitArtifactRelease release) @feat(SLJIT) {
    assert(artifact.state == DRAFT);
    artifact.function = cf;
    artifact.payload = payload;
    artifact.kind = kind;
    artifact.code_bytes = code_bytes;
    artifact.metadata_bytes = metadata_bytes;
    artifact.release = release;
    artifact.generation = ++h.jit_artifact_generation;
    if (artifact.generation == 0) artifact.generation = ++h.jit_artifact_generation;
    artifact.state = LIVE;
    artifact.next = h.jit_artifacts;
    if (artifact.next != null) artifact.next.previous = artifact;
    h.jit_artifacts = artifact;
    h.jit_code_bytes += code_bytes;
    h.jit_metadata_bytes += metadata_bytes;
}

fn bool sljit_artifact_is_live(JitArtifact* artifact, ulong generation) @feat(SLJIT) @inline {
    return artifact != null && artifact.state == LIVE && artifact.generation == generation;
}

// A zero result declines a new entry. Existing pins may finish recovery from
// retired code, but cannot start another optimized invocation through it.
fn ulong sljit_artifact_enter(Heap* h, JitArtifact* artifact) @feat(SLJIT) {
    if (artifact == null || artifact.state != LIVE) return 0;
    artifact.pins++;
    h.jit_native_active++;
    artifact.last_use = ++h.jit_clock;
    return artifact.generation;
}

fn void sljit_artifact_drain(Heap* h) @feat(SLJIT) {
    if (h.jit_native_active != 0) return;
    bool released;
    while (h.jit_retired_artifacts != null) {
        JitArtifact* artifact = h.jit_retired_artifacts;
        assert(artifact.pins == 0 && artifact.state == RETIRED);
        h.jit_retired_artifacts = artifact.retired_next;
        h.jit_retired_code_bytes -= artifact.code_bytes;
        h.jit_code_bytes -= artifact.code_bytes;
        h.jit_metadata_bytes -= artifact.metadata_bytes;
        artifact.state = RELEASED;
        JitArtifactRelease release = artifact.release;
        release(h, artifact);
        released = true;
    }
    // Temporary admission failures may retry after real capacity is released,
    // never merely because an attempt or a speculative entry took place.
    if (released) h.jit_capacity_generation++;
}

fn void sljit_artifact_leave(Heap* h, JitArtifact* artifact) @feat(SLJIT) {
    assert(artifact != null && artifact.pins != 0 && h.jit_native_active != 0);
    artifact.pins--;
    h.jit_native_active--;
    sljit_artifact_drain(h);
}

// Caller has already detached entry points and incoming links. Queued owners
// remain charged and retain all dependencies until the last native frame and
// its C post-publication scope have finished.
fn void sljit_artifact_retire(Heap* h, JitArtifact* artifact) @feat(SLJIT) {
    if (artifact.state != LIVE) return;
    if (artifact.previous != null) { artifact.previous.next = artifact.next; }
    else { h.jit_artifacts = artifact.next; }
    if (artifact.next != null) artifact.next.previous = artifact.previous;
    artifact.previous = null;
    artifact.next = null;
    artifact.state = RETIRED;
    artifact.retired_next = h.jit_retired_artifacts;
    h.jit_retired_artifacts = artifact;
    h.jit_retired_code_bytes += artifact.code_bytes;
    sljit_artifact_drain(h);
}

// A legacy loop may replace its kernel after returning to C. Keep that old
// fragment charged and alive until the enclosing native/publication scope ends.
struct JitCodeFragment @feat(SLJIT) {
    JitArtifact artifact;
    void* code;
}
fn void sljit_fragment_release(Heap* h, JitArtifact* artifact) @feat(SLJIT) {
    JitCodeFragment* fragment = artifact.payload;
    boomkat::jit::sljit_free_code(fragment.code, null);
    h.free_func(h.heap_udata, fragment);
}
fn bool sljit_artifact_retire_fragment(Heap* h, JitArtifact* owner, void* code, usz bytes) @feat(SLJIT) {
    JitCodeFragment* fragment = (JitCodeFragment*)h.alloc_func(h.heap_udata, JitCodeFragment::size);
    if (fragment == null) return false;
    *fragment = {};
    fragment.code = code;
    assert(owner.code_bytes >= bytes);
    owner.code_bytes -= bytes;
    h.jit_code_bytes -= bytes;
    sljit_artifact_publish(h, &fragment.artifact, owner.function, fragment,
        owner.kind, bytes, JitCodeFragment::size, &sljit_fragment_release);
    sljit_artifact_retire(h, &fragment.artifact);
    return true;
}

// Persistent metadata follows executable ownership. Compiler arenas and
// invocation scratch have separate, shorter lifetimes and are not included.
fn usz sljit_loop_metadata_bytes(LoopPlan* plan) @feat(SLJIT) {
    return LoopPlan::size + ssa_helper_metadata_bytes(plan);
}
fn usz sljit_function_metadata_bytes(FunctionPlan* plan, usz allocation) @feat(SLJIT) {
    usz bytes = allocation;
    if (plan.ssa_region != null) bytes += sljit_loop_metadata_bytes(plan.ssa_region);
    for (LoopPlan* leaf = plan.ssa_leaves; leaf != null; leaf = leaf.next) bytes += sljit_loop_metadata_bytes(leaf);
    for (FunctionCallLink* link = plan.calls; link != null; link = link.next) bytes += FunctionCallLink::size;
    for (FunctionInlineFrame* frame = plan.inline_frames; frame != null; frame = frame.next) bytes += FunctionInlineFrame::size;
    for (JitWriteDependency* watch = plan.dependencies; watch != null; watch = watch.next_client) bytes += JitWriteDependency::size;
    return bytes;
}
