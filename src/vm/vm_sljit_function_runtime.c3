module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::jit;
import std::io;
import std::core::mem;

// Compiled function lifetime, admission, execution and diagnostics.

fn void sljit_function_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) return;
    sljit_relink_calls(h, cf, true);
    $if $feat(SLJIT_STATS):
        io::eprintfn(
            "SLJIT function %s hits=%d returns=%d charged_edges=%d budget_exits=%d code_bytes=%d",
            (String)cf.get_name(),
            plan.hits,
            plan.completed,
            plan.charged_edges,
            plan.budget_exits,
            plan.code_bytes
        );
    $endif
    jit::sljit_free_code((void*)plan.native, null);
    if (plan.resume_fragment != null) jit::sljit_free_code(plan.resume_fragment, null);
    sljit_inline_frames_free(h, plan);
    sljit_call_links_free(h, plan);
    h.jit_code_bytes -= plan.code_bytes;
    h.free_func(h.heap_udata, plan);
    cf.sljit_function = null;
}
macro bool sljit_function_resumes(Instruction* pc, CompiledFunction* cf) @feat(SLJIT) {
    FunctionPlan* plan = cf.sljit_function;
    uint offset        = (uint)(pc - cf.code);
    return plan != null && offset >= plan.begin && offset - plan.begin < plan.count
        && plan.entries[offset - plan.begin] != null;
}
fn FunctionPlan* sljit_function_compile(CompiledFunction* cf, ColdCtx* cold, uint begin = 0) @feat(SLJIT) @noinline {
    Heap* h = cold.heap;
    $if $feat(SLJIT_STATS):
        if (begin != 0) io::eprintfn(
            "SLJIT region attempt ops=%d regs=%d begin=%d budget_used=%d",
            cf.code_count,
            cf.num_regs,
            begin,
            h.jit_code_bytes
        );
    $endif
    if (begin >= cf.code_count || !sljit_code_room(h, 0)) {
        cf.sljit_budget_wait = begin < cf.code_count;
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "code budget or region bounds"; $endif
        return null;
    }
    // The view borrows the original bytecode, constants and site caches. Only
    // the region's instruction window consumes compiler tables/code budget.
    CompiledFunction region = *cf;
    region.code += begin;
    uint limit = cf.code_count > FUNCTION_OPS || cf.num_regs > LOOP_REGS ? FUNCTION_REGION_OPS : FUNCTION_OPS;
    // At a hot header select its whole loop, including nested loops and
    // forward exits inside the body. A loop exceeding the bounded compiler
    // tables retains the existing forward-region fallback.
    uint loop_end;
    bool oversized;
    if (begin != 0 || cf.code_count > FUNCTION_OPS) {
        for (uint i = begin; i < cf.code_count; i++) {
            if (loop_target(cf.code[i], i) != (int)begin) continue;
            if (i - begin >= FUNCTION_OPS) {
                oversized = true;
                break;
            }
            loop_end = i - begin + 1;
        }
    }
    if (!oversized && loop_end > limit) limit = loop_end;
    region.code_count = cf.code_count - begin < limit ? cf.code_count - begin : limit;
    region.ic_entries = (ICEntry*)cf.ic_entries + begin;
    region.var_ic_entries = (VarICEntry*)cf.var_ic_entries + begin;
    usz bytes          = FunctionPlan::size + region.code_count * (void*::size + 1);
    FunctionPlan* plan = (FunctionPlan*)h.alloc_func(h.heap_udata, bytes);
    if (plan == null) {
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "plan allocation"; $endif
        return null;
    }
    mem::clear(plan, (sz)bytes);
    plan.begin = begin;
    plan.count = region.code_count;
    plan.min_span = cf.code_count > FUNCTION_OPS || cf.num_regs > LOOP_REGS ? FUNCTION_MIN_SPAN : 6;
    plan.entries = (void**)((char*)plan + FunctionPlan::size);
    plan.short_runs = (char*)(plan.entries + plan.count);
    bool analyzed = function_analyze(&region, plan, h);
    bool emitted  = analyzed && function_emit(plan, &region, h, cold.act);
    $if $feat(SLJIT_STATS):
        cf.sljit_rejection = emitted ? null : region.sljit_rejection;
    $endif
    $if $feat(SLJIT_STATS):
        if (begin != 0) io::eprintfn(
            "SLJIT region result %s ops=%d analyzed=%d emitted=%d code_bytes=%d budget_used=%d limit=%d",
            (String)cf.get_name(),
            cf.code_count,
            analyzed,
            emitted,
            plan.code_bytes,
            h.jit_code_bytes,
            sljit_code_limit(h)
        );
    $endif
    if (!emitted || !sljit_code_room(h, plan.code_bytes)) {
        cf.sljit_budget_wait = emitted;
        $if $feat(SLJIT_STATS): if (emitted) cf.sljit_rejection = "code budget"; $endif
        if (plan.native != null) jit::sljit_free_code((void*)plan.native, null);
        if (plan.resume_fragment != null) jit::sljit_free_code(plan.resume_fragment, null);
        sljit_inline_frames_free(h, plan);
        sljit_call_links_free(h, plan);
        h.free_func(h.heap_udata, plan);
        return null;
    }
    cf.sljit_function = plan;
    for (FunctionCallLink* link = plan.calls; link != null; link = link.next) sljit_link_target(link);
    sljit_relink_calls(h, cf);
    h.jit_code_bytes += plan.code_bytes;
    plan.shape_clock = h.shape_gen_clock;
    plan.shape_epoch = h.shape_recycle_epoch;
    if (begin == 0 && plan.entries[0] != null) cf.sljit_function_calls = uint::max - 1;
    $if $feat(SLJIT_STATS):
        io::eprintfn(
            "SLJIT function compiled %s pc=%d..%d function_ops=%d regs=%d code_bytes=%d plan_bytes=%d",
            (String)cf.get_name(),
            begin,
            begin + plan.count,
            cf.code_count,
            cf.num_regs,
            plan.code_bytes,
            bytes
        );
    $endif
    return plan;
}
// Calls a function must see before the tier compiles it. The differential
// test setting compiles on the first call instead.
fn uint sljit_warmup(Heap* h) @feat(SLJIT) @inline => h.jit_stress ? 1 : 64;
fn Instruction* sljit_function_entry(
    Instruction* pc,
    TVal* regs,
    ColdCtx* cold,
    bool region = false
) @feat(SLJIT) @noinline {
    Heap* h              = cold.heap;
    $if $feat(SLJIT_ADAPTIVE): h.jit_clock++; $endif
    CompiledFunction* cf = cold.vm.current_func;
    $if $feat(SLJIT_STATS): cf.sljit_entry_attempts++; $endif
    if (!h.jit_enabled || !types::USE_NANBOX || usz::size != 8 || h.gc_phase != heap::GcPhase.IDLE
        || h.uncatchable_throw
        || std::core::mem::@atomic_load(
        h.interrupt_requested
    ) != 0) return pc;
    uint offset        = (uint)(pc - cf.code);
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) {
        if (cf.sljit_function_calls == uint::max) return pc;
        // Every function size warms on taken backedges as well as calls. A
        // region may start at a hot header, not only at bytecode zero.
        if (offset == 0) {
            if (++cf.sljit_function_calls < sljit_warmup(h)) return pc;
        } else if (!region || cf.sljit_function_calls < sljit_warmup(h)) return pc;
        cf.sljit_function_calls = uint::max;
        // A hot backedge in an ordinary function must also produce its call
        // entry. Otherwise callers can never enter that callee natively.
        plan = sljit_function_compile(cf, cold, cf.code_count <= FUNCTION_OPS ? 0 : offset);
        if (plan == null) return pc;
    }
    if (!sljit_function_resumes(pc, cf)) return pc;
    uint local = offset - plan.begin;
    if (plan.shape_clock != h.shape_gen_clock || plan.shape_epoch != h.shape_recycle_epoch) {
        for (uint i = 0; i < plan.shape_count; i++) {
            Shape* shape = h.get_shape(plan.shapes[i]);
            if (shape == null || shape.generation != plan.generations[i]) {
                sljit_function_free(h, cf);
                cf.sljit_function_calls = 0;
                return pc;
            }
        }
        plan.shape_clock = h.shape_gen_clock;
        plan.shape_epoch = h.shape_recycle_epoch;
    }
    if (cold.act.heap_reg_count < plan.heap_regs) cold.act.heap_reg_count = plan.heap_regs;
    // Native calls consume the run's progress budget too. A call-only graph
    // can exhaust it without ever taking an interpreter backward branch to
    // replenish it. With no pending collection, that poll is a no-op.
    if (h.bwd_gc_budget <= 1 && !h.gc_pending) h.bwd_gc_budget = heap::BWD_GC_INTERVAL;
    long budget     = h.bwd_gc_budget;
    bool interrupts = h.capi_runtime != null || h.capi_interrupt_fn != null;
    if (interrupts && (long)h.interrupt_budget < budget) budget = h.interrupt_budget;
    if (h.interrupt_due || budget <= 1) return pc;
    // Bound publication even when the host configures a very large poll budget.
    if (budget > 1024) budget = 1024;
    // Inline scratch is written before each read; avoid clearing 256 bytes
    // on every native entry. Only metadata-cache keys require initialization.
    FunctionRun run @noinit;
    run.entry = plan.entries[local];
    run.root = cold.act;
    $if $feat(SLJIT_ADAPTIVE):
        run.clock = h.jit_clock;
        plan.last_use = h.jit_clock;
    $endif
    run.depth = 0;
    run.start = pc;
    run.recover_frame = null;
    run.budget = budget;
    run.typed[0].receiver = null;
    run.typed[1].receiver = null;
    Instruction* resume = plan.native(regs, cold, &run);
    if (run.recover_frame != null) {
        $if $feat(SLJIT_STATS): plan.inline_recoveries++; $endif
        resume = sljit_inline_recover(cold, &run);
    }
    uint consumed = (uint)(budget - run.budget);
    uint progress = consumed;
    if (cold.act == run.root && resume - pc >= 6) progress += 16;
    sljit_budget_progress(h, progress);
    h.bwd_gc_budget -= consumed;
    if (interrupts) h.interrupt_budget -= consumed;
    $if $feat(SLJIT_STATS):
    plan.charged_edges += consumed;
    if (run.budget <= 1 && consumed != 0) plan.budget_exits++;
    $endif
    if (cold.act != run.root) {
        $if $feat(SLJIT_STATS):
        // Charge the exit to the function containing its resume PC, including
        // callees entered entirely from generated code.
        CompiledFunction* active = cold.vm.current_func;
        FunctionPlan* active_plan = active.sljit_function;
        uint exited = (uint)(resume - active.code);
        if (active_plan != null && exited < active.code_count && exited < 512) active_plan.exit_pcs[exited]++;
        plan.hits++;
        $endif
        return resume;
    }
    uint next = (uint)(resume - cf.code);
    // A run that stops at the same unexpandable call without completing a
    // backedge repeats the same prefix on every entry loop iteration. Let the
    // interpreter own the function once that is clearly never going to pay.
    bool at_call = next < cf.code_count && function_call_op(cf.code[next].op);
    bool returned = next < cf.code_count
        && (cf.code[next].op == Opcode.RET || cf.code[next].op == Opcode.RETUNDEF);
    bool stuck = consumed == 0 && next >= offset && !returned
        && (next - offset < 6 || at_call);
    if (stuck) {
        if (!h.jit_stress && ++plan.short_runs[local] >= 8) {
            plan.entries[local] = null;
            if (offset == 0) cf.sljit_function_calls = uint::max;
        }
    } else {
        plan.short_runs[local] = 0;
    }
    $if $feat(SLJIT_STATS):
    plan.hits++;
    if (next < cf.code_count && next < 512) plan.exit_pcs[next]++;
    if (next == offset) plan.stalled++;
    if (next < cf.code_count
        && (cf.code[next].op == Opcode.RET || cf.code[next].op == Opcode.RETUNDEF)) plan.completed++;
    $endif
    return cf.code + next;
}
// Large functions warm a bounded region at a taken loop header. Native
// backedges return before the shared GC/interrupt budget reaches its poll.
fn bool sljit_function_backedge(Instruction* pc, CompiledFunction* cf, Heap* h) @feat(SLJIT) @inline {
    int target = loop_target(*pc, (uint)(pc - cf.code));
    if (target < 0) return false;
    if (cf.sljit_function != null) return sljit_function_resumes(cf.code + target, cf);
    return cf.sljit_function_calls != uint::max && ++cf.sljit_function_calls >= sljit_warmup(h);
}
fn Instruction* sljit_function_region(Instruction* pc, TVal* regs, ColdCtx* cold) @feat(SLJIT) @inline {
    CompiledFunction* cf = cold.vm.current_func;
    if (cf.sljit_function_calls < sljit_warmup(cold.heap)) cf.sljit_function_calls++;
    return sljit_function_entry(pc, regs, cold, true);
}
fn Instruction* sljit_function_dispatch(
    Instruction* pc,
    HandlerTable* handlers,
    TVal* regs,
    ColdCtx* cold
) @feat(SLJIT) @noinline {
    pc = sljit_function_entry(pc, regs, cold);
    return th_next(pc, handlers, cold.act.bottom, cold);
}
// Report the counters the native tiers keep: what compiled, how often it ran,
// where each run ended, and the totals. Driven by the CLI's --stats.
fn void sljit_stats_dump(Heap* h) {
    $if $feat(SLJIT):
        uint functions;
        uint loops;
        uint templates;
        ulong hits;
        for (uint i = 0; i < h.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[i];
            if (cf == null) continue;
            FunctionPlan* plan = cf.sljit_function;
            $if $feat(SLJIT_STATS):
                if (cf.sljit_threaded_entries != 0 || cf.sljit_switch_ops != 0 || cf.sljit_entry_attempts != 0) {
                    uint retired;
                    uint active;
                    if (plan != null) for (uint j = 0; j < plan.count; j++) {
                        if (plan.short_runs[j] >= 8) retired++;
                        if (plan.entries[j] != null) active++;
                    }
                    io::printfn(
                        "SLJIT coverage id=%d line=%d ops=%d regs=%d captures=%d name=%s threaded=%d switch=%d attempts=%d warmup=%d retired=%d active=%d rejection=%s",
                        i,
                        cf.get_line(0),
                        cf.code_count,
                        cf.num_regs,
                        cf.capture_count,
                        (String)cf.get_name(),
                        cf.sljit_threaded_entries,
                        cf.sljit_switch_ops,
                        cf.sljit_entry_attempts,
                        cf.sljit_function_calls,
                        retired,
                        active,
                        (ZString)(plan != null ? "compiled"
                            : cf.sljit_rejection != null ? cf.sljit_rejection
                            : "not attempted")
                    );
                }
            $endif
            if (plan != null) {
                functions++;
                $if $feat(SLJIT_STATS):
                hits += plan.hits;
                io::printfn("SLJIT native id=%d calls=%d returns=%d", i, plan.direct_calls, plan.direct_returns);
                uint links;
                for (FunctionCallLink* link = plan.calls; link != null; link = link.next) links++;
                io::printfn("SLJIT pipeline id=%d inlined=%d recoveries=%d allocations=%d pushes=%d links=%d",
                    i, plan.general_inlines, plan.inline_recoveries, plan.resumed_allocations, plan.resumed_pushes, links);
                io::printfn("SLJIT numeric id=%d homes=%d", i, plan.numeric_homes);
                io::printfn("SLJIT code id=%d start=%p bytes=%d fragment=%p fragment_bytes=%d",
                    i, plan.native, plan.code_bytes - plan.resume_bytes, plan.resume_fragment, plan.resume_bytes);
                $if $feat(SLJIT_MAP): sljit_address_map(plan, cf, i); $endif
                for (FunctionInlineFrame* frame = plan.inline_frames; frame != null; frame = frame.next) {
                    for (uint pc = 0; pc < frame.target.code_count; pc++) {
                        if (frame.exits[pc] == 0) continue;
                        io::printfn("SLJIT inline_exit id=%d frame=%d depth=%d target_line=%d pc=%d opcode=%s count=%d",
                            i, frame.id, frame.depth, frame.target.get_line(0), pc,
                            (ZString)bytecode::get_opcode_name(frame.target.code[pc].op), frame.exits[pc]);
                    }
                }
                io::printfn(
                    "SLJIT function %s begin=%d ops=%d bytes=%d hits=%d returns=%d stalled=%d charged_edges=%d budget_exits=%d id=%d line=%d",
                    (String)cf.get_name(),
                    plan.begin,
                    plan.count,
                    plan.code_bytes,
                    plan.hits,
                    plan.completed,
                    plan.stalled,
                    plan.charged_edges,
                    plan.budget_exits,
                    i,
                    cf.get_line(0)
                );
                for (uint pc = 0; pc < 512; pc++) {
                    if (plan.exit_pcs[pc] == 0) continue;
                    io::printfn(
                        "SLJIT exit %s begin=%d pc=%d op=%d count=%d id=%d line=%d opcode=%s",
                        (String)cf.get_name(),
                        plan.begin,
                        pc,
                        pc < cf.code_count ? (int)cf.code[pc].op : -1,
                        plan.exit_pcs[pc],
                        i,
                        cf.get_line(pc),
                        (ZString)(pc < cf.code_count ? bytecode::get_opcode_name(cf.code[pc].op) : "end")
                    );
                }
                $else
                io::printfn("SLJIT function %s begin=%d ops=%d bytes=%d id=%d line=%d",
                    (String)cf.get_name(), plan.begin, plan.count, plan.code_bytes, i, cf.get_line(0));
                $endif
            }
            for (LoopPlan* lp = cf.sljit_loops; lp != null; lp = lp.next) {
                loops++;
                $if $feat(SLJIT_MAP):
                    io::printfn("SLJIT map id=%d kind=loop pc=%d start=%p end=%p", i, lp.begin,
                        lp.native, (char*)(void*)lp.native + (sz)lp.code_bytes);
                $endif
                io::printfn(
                    "SLJIT loop %s begin=%d end=%d hits=%d iterations=%d",
                    (String)cf.get_name(),
                    lp.begin,
                    lp.end,
                    lp.hits,
                    lp.iterations
                );
                $if $feat(SLJIT_STATS):
                io::printfn("SLJIT ssa name=%s begin=%d end=%d hits=%d iterations=%d",
                    (String)cf.get_name(), lp.begin, lp.end, lp.ssa_hits, lp.ssa_iterations);
                $endif
            }
            if (cf.sljit_template != null) {
                TemplatePlan* tp = (TemplatePlan*)cf.sljit_template;
                templates++;
                io::printfn("SLJIT template %s hits=%d misses=%d", (String)cf.get_name(), tp.hits, tp.misses);
            }
        }
        $if $feat(SLJIT_STATS):
        io::printfn(
            "SLJIT totals functions=%d loops=%d templates=%d hits=%d code_bytes=%d",
            functions,
            loops,
            templates,
            hits,
            h.jit_code_bytes
        );
        $else
        io::printfn("SLJIT totals functions=%d loops=%d templates=%d code_bytes=%d",
            functions, loops, templates, h.jit_code_bytes);
        $endif
        io::printfn("SLJIT budget bytes=%d limit=%d native_work=%d evictions=%d", h.jit_code_bytes,
            sljit_code_limit(h), h.jit_native_work, h.jit_evictions);
        $if $feat(SLJIT_STATS) && $feat(OP_PROFILE): opprof_dump(); $endif
    $endif
}

// Every polymorphic arm reloads the same receiver source as the initial guard.
