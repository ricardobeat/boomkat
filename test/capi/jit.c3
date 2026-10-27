module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::compiler;
import boomkat::heap;
import boomkat::hobject;
import boomkat::vm;
import std::io;
import libc;

const String FUNCTION_SOURCE = $embed("../sljit_function.js");
const String REGION_SOURCE   = $embed("../sljit_regions.js");
const String LOOP_SOURCE     = $embed("../sljit_loop.js");
const String NATIVE_SOURCE   = $embed("../jit_native_calls.js");
const String RECOVERY_SOURCE = $embed("../jit_inline_recovery.js");
const String ALLOCATION_SOURCE = $embed("../jit_alloc_continuations.js");
const String LINK_SOURCE = $embed("../jit_linked_calls.js");
const String CFG_SOURCE = $embed("../jit_cfg_numbers.js");
const String TEMPLATE_SOURCE = $embed("jit_render.js");
const String RUN             = "for(var i=0;i<64;i++){if(render(rows)!=='<li>1:one</li><li>2:two</li>')throw new Error('render');}";

macro void @check(#condition) {
    if (!(#condition)) {
        io::eprintfn("embedding JIT check failed: %s", $stringify(#condition));
        libc::exit(1);
    }
}

fn void eval(JsContext* ctx, String source) {
    JsValue? value = ctx.eval(source);
    if (catch err = value) {
        io::eprintfn("embedding JIT exception at %d: %s", ctx.last_error_line(), ctx.last_error());
        libc::exit(1);
        return;
    }
    ctx.release(value);
}

fn ulong native_edges(JsRuntime* rt, String name, bool returns = false) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null || (String)cf.get_name() != name || cf.sljit_function == null) continue;
            FunctionPlan* plan = cf.sljit_function;
            return returns ? plan.direct_returns : plan.direct_calls;
        }
    $endif
    return 0;
}

fn ulong inline_recoveries(JsRuntime* rt) {
    ulong count;
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && cf.sljit_function != null) count += ((FunctionPlan*)cf.sljit_function).inline_recoveries;
        }
    $endif
    return count;
}

fn CompiledFunction* named_function(JsRuntime* rt, String name) {
    for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
        CompiledFunction* cf = rt.rt.heap.compiled_funcs[i];
        if (cf != null && (String)cf.get_name() == name) return cf;
    }
    return null;
}

// Separate sites read the same shape/key: the second is answered from the
// shared cache on its first visit and must still acquire its own local entry.
fn bool local_read_warmed(JsRuntime* rt, String name) {
    for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
        CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
        if (cf == null || (String)cf.get_name() != name || cf.ic_entries == null) continue;
        for (uint pos = 0; pos < cf.code_count; pos++) {
            if (cf.code[pos].op != Opcode.GETPROPC && cf.code[pos].op != Opcode.GETPROPC_CACHED) continue;
            boomkat::hobject::ICEntry* ic = (boomkat::hobject::ICEntry*)cf.ic_entries + pos;
            return ic.key.borrow() == cf.constants[cf.code[pos].c].get_heapptr() && ic.shape_id != 0;
        }
    }
    return false;
}

fn uint plans(JsRuntime* rt) {
    uint result;
    $if $feat(SLJIT):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && cf.sljit_template != null) result++;
        }
    $endif
    return result;
}

fn ulong native_hits(JsRuntime* rt) {
    ulong result;
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null) continue;
            if (cf.sljit_template != null) result += ((TemplatePlan*)cf.sljit_template).hits;
            if (cf.sljit_function != null) result += ((FunctionPlan*)cf.sljit_function).hits;
            for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) result += plan.hits;
        }
    $endif
    return result;
}

fn ulong function_hits(JsRuntime* rt, String name) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && (String)cf.get_name() == name && cf.sljit_function != null) {
                return ((FunctionPlan*)cf.sljit_function).hits;
            }
        }
    $endif
    return 0;
}

// Native work done on behalf of a named function, by whichever tier compiled
// it: a whole function region, or the hot loop inside it. A loop that the loop
// tier can take is faster than compiling the enclosing function, so the tier
// that owns the work is not part of the contract this checks.
fn ulong region_work(JsRuntime* rt, String name, bool calls = false) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null || (String)cf.get_name() != name) continue;
            if (calls) {
                if (cf.sljit_function == null) continue;
                return ((FunctionPlan*)cf.sljit_function).inline_calls;
            }
            ulong work = 0;
            if (cf.sljit_function != null) work += ((FunctionPlan*)cf.sljit_function).charged_edges;
            for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) work += plan.hits;
            return work;
        }
    $endif
    return 0;
}

fn int stop_after_polls(void* runtime, void* opaque) {
    uint* polls = (uint*)opaque;
    (*polls)++;
    return *polls >= 3 ? 1 : 0;
}

fn void check_numeric_pipeline() @feat(SLJIT) {
    // Earlier fixtures deliberately poison indexed prototypes. Use a fresh
    // runtime so this check requires successful compiled push continuations.
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    eval(&context, "var console={log:function(){}};");
    eval(&context, CFG_SOURCE);
    CompiledFunction* numeric = named_function(&runtime, "jitCfgNumbers");
    @check(numeric != null && numeric.sljit_function != null);
    @check(((FunctionPlan*)numeric.sljit_function).numeric_homes != 0);
    CompiledFunction* calls = named_function(&runtime, "jitCfgCalls");
    @check(calls != null && calls.sljit_function != null);
    FunctionPlan* plan = calls.sljit_function;
    @check(plan.numeric_homes != 0);
    @check(plan.direct_calls != 0);
    @check(plan.direct_returns != 0);
    @check(plan.resumed_allocations != 0 && runtime.rt.heap.jit_resumed_pushes != 0);
}

fn void check_ic_gc_roots() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context,
        "function gcRead(o){return o.value;}"
        "var gcP0={value:11},gcP1={value:22},gcP2={value:33};"
        "var gcR0=Object.create(gcP0),gcR1=Object.create(gcP1),gcR2=Object.create(gcP2);"
        "gcR0.a=1;gcR1.a=1;gcR1.b=2;gcR2.a=1;gcR2.b=2;gcR2.c=3;"
        "for(var g=0;g<10;g++){if(gcRead(gcR0)!==11||gcRead(gcR1)!==22||gcRead(gcR2)!==33)throw 'cache';}");
    CompiledFunction* cf = named_function(&runtime, "gcRead");
    @check(cf != null && cf.ic_entries != null);
    hobject::ICEntry* entries = cf.ic_entries;
    hobject::ICEntry* cache;
    uint slot;
    for (uint i = 0; i < cf.ic_count; i++) if (entries[i].chain_len == hobject::IC_CHAIN_PROTO) {
        cache = &entries[i]; slot = i; break;
    }
    @check(cache != null && cache.chain.proto.count == 2);
    Heap* h = runtime.rt.heap;
    h.mark_and_sweep(true, true);
    h.gc_begin_cycle(true);
    uint cursor = cf.const_count + slot;
    @check(!h.gc_scan_compiled_slot(cf, &cursor));
    @check(((HeapHeader*)cache.chain.proto.primary.owner).is_reachable());
    for (uint i = 0; i < cache.chain.proto.count; i++) {
        @check(((HeapHeader*)cache.chain.proto.arms[i].owner).is_reachable());
    }
    h.mark_and_sweep(true, true);

    // Point the entry at a real private receiver shape, then retire that shape.
    // Invalidation must clear the owner discriminator before a root scan can
    // interpret a zero chain length as a snapshot index of UINT_MAX.
    hobject::HObject* receiver = h.alloc_plain_object()!!;
    receiver.make_shape_private(h);
    cache.shape_id = receiver.shape_id;
    receiver.make_shape_private(h);
    h.purge_retired_shapes();
    @check(cache.shape_id == heap::SHAPE_NONE && cache.chain_len == 0 && !cache.has_proto);
    @check(hobject::ic_cached_proto(cache) == null);
    cursor = cf.const_count + slot;
    @check(!h.gc_scan_compiled_slot(cf, &cursor));
    h.mark_and_sweep(true, true);
}

// MAY-write effects must include destructive inputs and implicit call windows,
// while branch offsets and property receivers are not register destinations.
fn void check_register_effects() {
    uint[8] words;
    compiler::RegSet writes = { .words = &words[0], .word_count = 8 };
    compiler::register_may_writes(bytecode::make_abc(Opcode.PUTCAP, 7, 0, 0), &writes);
    @check(writes.test(7) && !writes.test(0));
    writes.clear();
    compiler::register_may_writes(bytecode::make_abc(Opcode.INC_LT, 4, 0, 0), &writes);
    @check(writes.test(4));
    writes.clear();
    compiler::register_may_writes(bytecode::make_abc(Opcode.CALL_UNDEF_THIS, 2, 10, 3), &writes);
    @check(writes.test(2) && writes.test(11) && writes.test(14) && !writes.test(9));
    writes.clear();
    compiler::register_may_writes(bytecode::make_abc(Opcode.JMP_NLT, 20, 2, 3), &writes);
    compiler::register_may_writes(bytecode::make_abc(Opcode.PUTPROPC, 5, 6, 7), &writes);
    for (uint i = 0; i < 256; i++) @check(!writes.test(i));
    compiler::register_may_writes(bytecode::make_abc(Opcode.WIDE, 0, 0, 0), &writes);
    @check(writes.test(0) && writes.test(255));
}

fn void main() {
    check_register_effects();
    check_native_convention();
    check_ic_gc_roots();
    JsRuntime first, second;
    @check(!first.set_jit());
    first.create()!!;
    defer first.destroy();
    second.create()!!;
    defer second.destroy();
    JsContext a, b, isolated;
    a.create(&first)!!;
    defer a.destroy();
    b.create(&first)!!;
    defer b.destroy();
    isolated.create(&second)!!;
    defer isolated.destroy();
    eval(
        &a,
        "function warmField(o){return o.warm;}function freshField(o){return o.warm;}var warmRecord={warm:17};if(warmField(warmRecord)!==17||freshField(warmRecord)!==17)throw 'warm';"
    );
    @check(local_read_warmed(&first, "freshField"));
    JsContext*[3] contexts = { &a, &b, &isolated };
    foreach (ctx : contexts) {
        eval(ctx, TEMPLATE_SOURCE);
        eval(ctx, RUN);
    }
    @check(plans(&first) == 0 && plans(&second) == 0);
    @check(first.set_jit(false));
    $if $feat(SLJIT):
        @check(first.set_jit());
        eval(&a, RUN);
        eval(&b, RUN);
        @check(plans(&first) == 2);
        @check(plans(&second) == 0);
        ulong before = native_hits(&first);
        @check(first.set_jit(false));
        @check(!first.rt.heap.jit_enabled && !second.rt.heap.jit_enabled);
        eval(&a, "rows[0].id=7;if(render(rows)!=='<li>7:one</li><li>2:two</li>')throw 'disabled';rows[0].id=1;");
        @check(plans(&first) == 2 && native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, RUN);
        @check(native_hits(&first) > before);
        eval(&isolated, RUN);
        @check(plans(&second) == 0);
        eval(&isolated, "var console={log:function(){}};");
        eval(&isolated, LOOP_SOURCE);
        @check(second.rt.heap.jit_code_bytes == 0);
        eval(&a, "var console={log:function(){}};");
        eval(&a, LOOP_SOURCE);
        @check(first.rt.heap.jit_code_bytes > 0);
        before = native_hits(&first);
        @check(first.set_jit(false));
        eval(&a, "for(var j=0;j<64;j++)if(hash(bytes)!==expectedHash)throw 'disabled loop';");
        @check(native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, "for(var j=0;j<64;j++)if(hash(bytes)!==expectedHash)throw 'cached loop';");
        @check(native_hits(&first) > before);
        eval(&a, NATIVE_SOURCE);
        @check(native_edges(&first, "jitNativeDrive") > 0);
        @check(native_edges(&first, "jitNativeStep", true) > 0);
        ulong recovered = inline_recoveries(&first);
        eval(&a, RECOVERY_SOURCE);
        @check(inline_recoveries(&first) > recovered);
        uint inline_polls;
        recovered = inline_recoveries(&first);
        first.set_interrupt(&stop_after_polls, &inline_polls);
        bool inline_interrupted;
        if (catch err = a.eval("recoveryLoopDrive(recoveryLoopHolder,1000000000);")) inline_interrupted = true;
        @check(inline_interrupted && inline_polls == 3 && inline_recoveries(&first) > recovered);
        first.set_interrupt(null);
        JsValue inline_exception = a.get_exception()!!;
        a.release(inline_exception);
        // A fresh realm has an untouched indexed prototype chain. The fixture
        // later invalidates it deliberately, retiring its compiled append plan.
        JsContext allocation_context;
        allocation_context.create(&first)!!;
        defer allocation_context.destroy();
        eval(&allocation_context, "var console={log:function(){}};");
        ulong pushes = first.rt.heap.jit_resumed_pushes;
        eval(&allocation_context, ALLOCATION_SOURCE);
        CompiledFunction* allocator = named_function(&first, "resumeAllocate");
        @check(allocator != null && allocator.sljit_function != null);
        @check(((FunctionPlan*)allocator.sljit_function).resumed_allocations > 0);
        @check(first.rt.heap.jit_resumed_pushes > pushes);
        // Request collection during native allocation. Completion must resume
        // after that operation, with the new object rooted in its VM slot.
        first.rt.heap.gc_trigger_counter = 1;
        eval(&allocation_context, "resumeAssert(resumeAllocate(2000),4006000);");
        first.rt.heap.mark_and_sweep(true, true);
        eval(&allocation_context, "resumeAssert(resumeAllocate(200),40600);");
        eval(&a, LINK_SOURCE);
        CompiledFunction* driver = named_function(&first, "jitLinkDrive");
        CompiledFunction* linked = named_function(&first, "jitLinkTarget");
        @check(driver != null && linked != null && driver.sljit_function != null);
        @check(((FunctionPlan*)driver.sljit_function).calls != null);
        // Exercise incoming unlinking while the caller remains compiled.
        vm::sljit_function_free(first.rt.heap, linked);
        linked.sljit_function_calls = 0;
        eval(&a, "for(var linkWarm=0;linkWarm<80;linkWarm++)if(jitLinkDrive(jitLinkObject,100)!==5250)throw 'relink';");
        @check(linked.sljit_function != null);
        $if $feat(SLJIT_ADAPTIVE):
        // Exercise the real cache reclaimer with a live linked caller. Make
        // every plan recent except this target, then force one eviction.
        FunctionPlan* target_plan = linked.sljit_function;
        target_plan.last_use = 0;
        eval(&a, "if(jitLinkDrive(jitLinkObject,100)!==5250)throw 'native use';");
        @check(target_plan.last_use != 0);
        first.rt.heap.jit_clock += 65537;
        for (uint index = 0; index < first.rt.heap.compiled_func_count; index++) {
            CompiledFunction* candidate = first.rt.heap.compiled_funcs[index];
            if (candidate != null && candidate.sljit_function != null) {
                ((FunctionPlan*)candidate.sljit_function).last_use = first.rt.heap.jit_clock;
            }
        }
        target_plan.last_use = 1;
        usz saved_limit = vm::sljit_code_limit(first.rt.heap);
        first.rt.heap.jit_code_limit = first.rt.heap.jit_code_bytes + 1;
        @check(vm::sljit_code_room(first.rt.heap, 2));
        first.rt.heap.jit_code_limit = saved_limit;
        @check(linked.sljit_function == null && driver.sljit_function != null);
        eval(&a, "for(var linkAgain=0;linkAgain<80;linkAgain++)if(jitLinkDrive(jitLinkObject,100)!==5250)throw 'cache relink';");
        @check(linked.sljit_function != null);
        $endif
        check_numeric_pipeline();
        eval(&a, FUNCTION_SOURCE);
        first.rt.heap.mark_and_sweep(true, true);
        for (uint i = 0; i < 128; i++) eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==18)throw 'function';");
        @check(function_hits(&first, "functionFields") > 0);
        for (uint i = 0; i < 128; i++) eval(
            &a,
            "if(jitFunctionPump(jitFunctionSource,jitFunctionSink)!==4)throw 'continuation';"
        );
        @check(function_hits(&first, "serverPump") > 0);
        first.rt.heap.mark_and_sweep(true, true);
        for (uint i = 0; i < 128; i++) eval(
            &a,
            "if(jitFunctionWork(jitFunctionRecord)!==18)throw 'function after GC';"
        );
        @check(function_hits(&first, "functionFields") > 0);
        // Call-only native runs must not strand an exhausted backward-edge
        // budget: with no pending GC, subsequent callbacks can run natively.
        first.rt.heap.bwd_gc_budget = 1;
        before = native_hits(&first);
        @check(first.set_jit(false));
        eval(&a, "jitFunctionRecord.left=6;if(jitFunctionWork(jitFunctionRecord)!==22)throw 'disabled function';");
        @check(native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==22)throw 'cached function';");
        @check(native_hits(&first) > before);
        eval(&a, REGION_SOURCE);
        @check(region_work(&first, "jitRegionFields") > 0);
        @check(region_work(&first, "jitRegionCalls", true) > 0);
        first.rt.heap.mark_and_sweep(true, true);
        eval(&a, "if(jitRegionFields(jitRegionRecord,20000)!==35000.25)throw 'region after GC';");
        // The getter fallback deliberately disables the old field entry after
        // repeated misses. Warm a fresh native loop for the interrupt check.
        eval(
            &a,
            "function jitRegionPoll(o,n){var sum=0.25;for(var i=0;i<n;i++){sum=sum+o.x;sum=sum+o.y;}return sum;}for(var w=0;w<100;w++)jitRegionPoll(jitRegionRecord,32);"
        );
        uint region_polls;
        ulong region_before = region_work(&first, "jitRegionPoll");
        @check(region_before > 0);
        first.set_interrupt(&stop_after_polls, &region_polls);
        bool region_interrupted;
        if (catch err = a.eval("jitRegionPoll(jitRegionRecord,1000000000);")) region_interrupted = true;
        @check(region_interrupted && region_polls == 3 && region_work(&first, "jitRegionPoll") > region_before);
        first.set_interrupt(null);
        JsValue region_exception = a.get_exception()!!;
        a.release(region_exception);
        eval(&a, "1");
        uint polls;
        before = native_hits(&first);
        first.set_interrupt(&stop_after_polls, &polls);
        bool interrupted;
        if (catch err = a.eval(
            "function spin(a){var x=0;for(var i=0;i<1000000;i++)x+=a[i&511];return x;}spin(bytes);"
        )) {
            interrupted = true;
        }
        @check(interrupted && polls == 3 && native_hits(&first) > before);
        first.set_interrupt(null);
        JsValue exception = a.get_exception()!!;
        a.release(exception);
        eval(&a, "1");
    $else
        @check(!first.set_jit());
    $endif
    io::printn("embedding JIT: PASS");
}
