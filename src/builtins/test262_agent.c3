// The test262 `$262.agent` host: other agents for Atomics and
// SharedArrayBuffer tests to talk to. See test262/INTERPRETING.md.
//
// An agent is a thread running its own heap and VM. The main side starts
// agents from source, broadcasts a SharedArrayBuffer to them, and collects the
// strings they report. An agent registers a callback with receiveBroadcast,
// runs it for each broadcast, and says leaving() when it is done. Only the
// SharedArrayBuffer's block is shared between them; everything else is
// copied or stays in its own heap.
module boomkat::builtins;

import boomkat::agent;
import boomkat::bytecode;
import boomkat::compiler;
import boomkat::env;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::types;
import boomkat::vm;
import std::io;
import boomkat::sync;
import std::thread;
import std::time;
import libc;

// An agent needs room for the whole test: the main thread's stack is the
// platform default, but a secondary thread's can be a few hundred KB.
const usz AGENT_STACK_SIZE = 16 * 1024 * 1024;

// One report an agent made, waiting for the main side to ask for it.
struct AgentReport {
    AgentReport* next;
    char*        text;
    usz          len;
}

// The agents one main thread has started. Thread-local, so each runner
// worker has its own, and ended with the test: a report from an agent of an
// earlier test can never reach the next one.
struct AgentGroup {
    sync::Lock        lock;
    sync::Cond        changed;   // an agent started, took a broadcast, or exited
    AgentRecord*      agents;
    AgentReport*      reports;
    AgentReport*      reports_tail;
}

// Everything the main side and an agent thread both touch. Guarded by the
// group's lock, except for the fields only the agent's own thread uses.
struct AgentRecord {
    AgentRecord* next;
    AgentGroup*  group;
    sync::OsThread thread;
    Port*        port;          // the agent's mailbox, retained here
    Heap*        heap;          // valid until `exited`
    char*        source;        // the script, owned
    usz          source_len;
    bool         started;       // heap, VM and port exist; the script is about to run
    bool         exited;
    bool         leaving;       // the agent called leaving()
    char*        message;       // a broadcast waiting to be taken, a shared block
    double       message_id;
    bool         message_pending;
}

tlocal AgentGroup* t_group;

// The record of the agent whose thread this is; null on the main side.
tlocal AgentRecord* t_self;

// ============================================================================
// Main side
// ============================================================================

fn AgentGroup* agent_group() {
    if (t_group == null) {
        AgentGroup* group = (AgentGroup*)libc::calloc(1, AgentGroup::size);
        if (group == null) abort("out of memory creating an agent group");
        group.lock.init();
        group.changed.init();
        t_group = group;
    }
    return t_group;
}

// $262.agent.start(source): runs `source` as a script in a new agent, and
// returns once the agent exists.
fn void builtin_agent_start(BuiltinContext* ctx) {
    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    HString* source = builtin_to_string_vm(ctx, &arg);
    if (ctx.should_throw || source == null) return;

    AgentGroup* group = agent_group();
    AgentRecord* rec = (AgentRecord*)libc::calloc(1, AgentRecord::size);
    usz source_len = source.utf8_len(true);
    char* text = (char*)libc::malloc(source_len + 1);
    if (rec == null || text == null) abort("out of memory starting an agent");
    source.copy_utf8(text, true);
    text[source_len] = 0;
    rec.group = group;
    rec.source = text;
    rec.source_len = (uint)source_len;

    group.lock.lock();
    rec.next = group.agents;
    group.agents = rec;
    group.lock.unlock();

    agent::agent_enter();
    if (!rec.thread.start(&agent_thread_main, rec, AGENT_STACK_SIZE)) {
        agent::agent_exit();
        group.lock.lock();
        rec.started = true;
        rec.exited = true;
        group.lock.unlock();
        host_throw_error(ctx, HOST_ERR_ERROR, "$262.agent.start: could not create a thread");
        return;
    }

    group.lock.lock();
    while (!rec.started) group.changed.wait(&group.lock);
    group.lock.unlock();
    ctx.result_undefined();
}

// $262.agent.broadcast(sab, id): hands the buffer to every running agent and
// returns once each of them has taken it.
fn void builtin_agent_broadcast(BuiltinContext* ctx) {
    TVal buf_arg;
    buf_arg.set_undefined();
    if (ctx.argc >= 1) buf_arg = ctx.regs[ctx.base_reg];
    HObject* buf = buf_arg.is_object() ? (HObject*)buf_arg.get_heapptr() : null;
    if (buf == null || buf.get_class() != hobject::ObjClass.ARRAYBUFFER || !(*buf.extra_ptr()).ab.is_shared) {
        host_throw_error(ctx, HOST_ERR_TYPE, "$262.agent.broadcast requires a SharedArrayBuffer");
        return;
    }
    double id = 0.0;
    if (ctx.argc >= 2) {
        TVal id_arg = ctx.regs[ctx.base_reg + 1];
        id = builtin_to_number_vm(ctx, &id_arg);
        if (ctx.should_throw) return;
    }

    AgentGroup* group = agent_group();
    char* block = (*buf.extra_ptr()).ab.data;
    group.lock.lock();
    defer group.lock.unlock();
    for (AgentRecord* rec = group.agents; rec != null; rec = rec.next) {
        if (rec.exited) continue;
        rec.message = block;
        rec.message_id = id;
        rec.message_pending = true;
        agent::port_post_event(rec.port);
    }
    // The block stays alive through the caller's reference until every agent
    // has adopted it, which is when its message stops pending.
    while (broadcast_pending(group)) group.changed.wait(&group.lock);
    ctx.result_undefined();
}

// True while a running agent has not yet taken its message. Caller holds the lock.
fn bool broadcast_pending(AgentGroup* group) @private {
    for (AgentRecord* rec = group.agents; rec != null; rec = rec.next) {
        if (!rec.exited && rec.message_pending) return true;
    }
    return false;
}

// $262.agent.getReport(): the oldest report not yet read, or null.
fn void builtin_agent_get_report(BuiltinContext* ctx) {
    AgentGroup* group = agent_group();
    group.lock.lock();
    AgentReport* report = group.reports;
    if (report != null) {
        group.reports = report.next;
        if (group.reports == null) group.reports_tail = null;
    }
    group.lock.unlock();
    if (report == null) {
        ctx.result_null();
        return;
    }
    ctx.result_string(builtin_intern_string(ctx.heap, report.text[:report.len]));
    libc::free(report.text);
    libc::free(report);
}

// Ends every agent the calling thread started and waits for them. The runner
// and CLI call it when a test or program is over: agents that never said
// leaving() would otherwise outlive it.
fn void agent_host_shutdown() {
    AgentGroup* group = t_group;
    if (group == null) return;
    t_group = null;

    group.lock.lock();
    for (AgentRecord* rec = group.agents; rec != null; rec = rec.next) {
        if (rec.exited) continue;
        mem::@atomic_store(rec.heap.interrupt_requested, 1u);
        agent::port_post_event(rec.port, true);
    }
    group.lock.unlock();

    AgentRecord* rec = group.agents;
    while (rec != null) {
        AgentRecord* next = rec.next;
        rec.thread.join();
        agent::port_release(rec.port);
        libc::free(rec.source);
        libc::free(rec);
        rec = next;
    }
    for (AgentReport* report = group.reports; report != null;) {
        AgentReport* next = report.next;
        libc::free(report.text);
        libc::free(report);
        report = next;
    }
    group.changed.destroy();
    group.lock.destroy();
    libc::free(group);
}

// ============================================================================
// Both sides
// ============================================================================

// $262.agent.sleep(ms)
fn void builtin_agent_sleep(BuiltinContext* ctx) {
    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    double ms = builtin_to_number_vm(ctx, &arg);
    if (ctx.should_throw) return;
    if (ms > 0.0) {
        if (catch err = thread::sleep_ns((NanoDuration)(ms * 1.0e6))) {}
    }
    ctx.result_undefined();
}

// $262.agent.monotonicNow(): milliseconds on a clock that never goes back.
fn void builtin_agent_monotonic_now(BuiltinContext* ctx) {
    ctx.result_number((double)clock::now() / 1.0e6);
}

// ============================================================================
// Agent side
// ============================================================================

// $262.agent.receiveBroadcast(callback): the function the agent runs for each
// broadcast. It lives on the agent's global so the collector keeps it.
fn void builtin_agent_receive_broadcast(BuiltinContext* ctx) {
    TVal callback;
    callback.set_undefined();
    if (ctx.argc >= 1) callback = ctx.regs[ctx.base_reg];
    if (!callback.is_object() || !((HObject*)callback.get_heapptr()).is_callable()) {
        host_throw_error(ctx, HOST_ERR_TYPE, "$262.agent.receiveBroadcast requires a function");
        return;
    }
    env::env_declare_nonenum(ctx.global_env, builtin_intern_string(ctx.heap, "__agent_callback"), callback);
    ctx.result_undefined();
}

// $262.agent.report(value): queues String(value) for the main side's getReport.
fn void builtin_agent_report(BuiltinContext* ctx) {
    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    HString* text = builtin_to_string_vm(ctx, &arg);
    if (ctx.should_throw || text == null) return;
    if (t_self == null) {
        host_throw_error(ctx, HOST_ERR_TYPE, "$262.agent.report is only available inside an agent");
        return;
    }

    AgentReport* report = (AgentReport*)libc::calloc(1, AgentReport::size);
    usz text_len = text.utf8_len(true);
    char* copy = (char*)libc::malloc(text_len + 1);
    if (report == null || copy == null) abort("out of memory queuing an agent report");
    text.copy_utf8(copy, true);
    copy[text_len] = 0;
    report.text = copy;
    report.len = (uint)text_len;

    AgentGroup* group = t_self.group;
    group.lock.lock();
    if (group.reports_tail != null) {
        group.reports_tail.next = report;
    } else {
        group.reports = report;
    }
    group.reports_tail = report;
    group.lock.unlock();
    ctx.result_undefined();
}

// $262.agent.leaving(): the agent is done; its loop ends after the current job.
fn void builtin_agent_leaving(BuiltinContext* ctx) {
    if (t_self != null) {
        t_self.group.lock.lock();
        t_self.leaving = true;
        t_self.group.lock.unlock();
    }
    ctx.result_undefined();
}

// The agent's interrupt handler never interrupts by itself. Installing one is
// what makes the VM poll the interrupt flag, which is how the host stops an
// agent that is spinning.
fn int agent_never_interrupts(void* runtime, void* opaque) => 0;

// Replaces the `$262.agent` that register_test262_host gave this agent's
// global with the agent-side one.
fn bool register_agent_side(EnvRecord* global_env, Heap* heap) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return false;
    HObject* agent_obj = raw;
    heap.set_prototype(agent_obj, heap.object_proto);

    TVal agent_tv;
    agent_tv.set_object(agent_obj);
    env::env_declare_nonenum(global_env, builtin_intern_string(heap, "__agent"), agent_tv);

    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_RECEIVE_BROADCAST, "receiveBroadcast", 1)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_REPORT, "report", 1)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_LEAVING, "leaving", 0)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_SLEEP, "sleep", 1)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_MONOTONIC_NOW, "monotonicNow", 0)) return false;

    TVal h262_tv = env::env_get(global_env, builtin_intern_string(heap, "$262"))!!;
    HObject* h262 = (HObject*)h262_tv.get_heapptr();
    h262.put_prop(builtin_intern_string(heap, "agent"), agent_tv, hobject::PROP_FLAGS_WC, heap);
    return true;
}

fn bool put_agent_fn(Heap* heap, HObject* target, Builtin which, char[] name, int length) @private {
    HString* key = builtin_intern_string(heap, name);
    HObject* fn_obj = alloc_builtin_fn(heap, which.ordinal, name, length);
    if (fn_obj == null || key == null) return false;
    TVal fn_tv;
    fn_tv.set_object(fn_obj);
    target.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);
    return true;
}

// The main side's `$262.agent`, installed with the rest of the test262 host.
fn bool register_agent_main_side(Heap* heap, HObject* h262) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return false;
    HObject* agent_obj = raw;
    heap.set_prototype(agent_obj, heap.object_proto);
    TVal agent_tv;
    agent_tv.set_object(agent_obj);
    h262.put_prop(builtin_intern_string(heap, "agent"), agent_tv, hobject::PROP_FLAGS_WC, heap);

    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_START, "start", 1)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_BROADCAST, "broadcast", 2)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_GET_REPORT, "getReport", 0)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_SLEEP, "sleep", 1)) return false;
    if (!put_agent_fn(heap, agent_obj, Builtin.AGENT_MONOTONIC_NOW, "monotonicNow", 0)) return false;
    return true;
}

// ============================================================================
// The agent thread
// ============================================================================

fn int agent_thread_main(void* arg) {
    // A secondary thread has no temp allocator until it is given one.
    @pool_init(mem, 256 * 1024) {
        agent_thread_run((AgentRecord*)arg);
    };
    return 0;
}

fn void agent_thread_run(AgentRecord* rec) @private {
    AgentGroup* group = rec.group;
    t_self = rec;

    Heap*? heap_opt = heap::create(null, null, null, null, null);
    if (catch err = heap_opt) {
        agent_thread_fail(rec);
        return;
    }
    Heap* hp = heap_opt;
    Vm*? vm_opt = vm::vm_create(hp);
    if (catch err = vm_opt) {
        hp.destroy();
        agent_thread_fail(rec);
        return;
    }
    Vm* v = vm_opt;

    Port* port = agent::port_for(hp);
    agent::port_retain(port);
    hp.capi_interrupt_fn = (void*)&agent_never_interrupts;
    hp.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
    bool installed = register_agent_side(v.global_env, hp);

    group.lock.lock();
    rec.port = port;
    rec.heap = hp;
    rec.started = true;
    group.changed.broadcast();
    group.lock.unlock();

    if (installed) agent_run(rec, hp, v);

    // Mark the exit before the heap goes, so the host never touches a dead heap.
    group.lock.lock();
    rec.exited = true;
    rec.message_pending = false;
    group.changed.broadcast();
    group.lock.unlock();

    vm::vm_destroy(v);
    hp.destroy();
    agent::agent_exit();
}

// A thread that never got as far as a port still has to satisfy start().
fn void agent_thread_fail(AgentRecord* rec) @private {
    rec.group.lock.lock();
    rec.port = agent::port_create();
    rec.started = true;
    rec.exited = true;
    rec.group.changed.broadcast();
    rec.group.lock.unlock();
    agent::agent_exit();
}

// Runs the agent's script, then serves broadcasts and promise jobs until the
// agent leaves, is stopped, or has nothing left that could happen.
fn void agent_run(AgentRecord* rec, Heap* hp, Vm* v) @private {
    if (!agent_eval(hp, v, rec.source[:rec.source_len])) return;

    while (true) {
        agent::run_ready(hp, (void*)v);
        if (agent_done(rec, hp)) return;
        if (agent_deliver(rec, hp, v)) continue;
        if (!agent_waiting(hp, v)) return;
        agent::wait_events(hp, 0.0);
    }
}

fn bool agent_done(AgentRecord* rec, Heap* hp) @private {
    rec.group.lock.lock();
    defer rec.group.lock.unlock();
    return rec.leaving || rec.port.stop || mem::@atomic_load(hp.interrupt_requested) != 0;
}

// True while the agent could still be sent work: it has a callback to run a
// broadcast through, or promises waiting on other agents.
fn bool agent_waiting(Heap* hp, Vm* v) @private {
    if (agent::async_pending(hp) != 0) return true;
    return agent_callback(hp, v).is_object();
}

// The function receiveBroadcast registered, or undefined.
fn TVal agent_callback(Heap* hp, Vm* v) @private {
    TVal callback;
    callback.set_undefined();
    if (try found = env::env_get(v.global_env, builtin_intern_string(hp, "__agent_callback"))) callback = found;
    return callback;
}

// Runs the broadcast callback if a message is waiting. Returns true if it did.
fn bool agent_deliver(AgentRecord* rec, Heap* hp, Vm* v) @private {
    AgentGroup* group = rec.group;
    group.lock.lock();
    bool pending = rec.message_pending;
    char* block = rec.message;
    double id = rec.message_id;
    group.lock.unlock();
    if (!pending) return false;

    // Adopt before the message stops pending: the sender holds the block
    // alive only until then.
    HObject* sab = sab_adopt(hp, block);
    group.lock.lock();
    rec.message_pending = false;
    group.changed.broadcast();
    group.lock.unlock();
    if (sab == null) return true;

    TVal callback = agent_callback(hp, v);
    if (!callback.is_object()) return true;

    TVal[2] args;
    args[0].set_object(sab);
    args[1].set_number(id);
    TVal undefined;
    undefined.set_undefined();
    hp.has_error = false;
    hp.call_fn((void*)v, callback, &args[0], 2, undefined);
    if (hp.has_error && !hp.uncatchable_throw) {
        io::eprintfn("agent: uncaught exception in receiveBroadcast callback");
        hp.has_error = false;
    }
    return true;
}

fn bool agent_eval(Heap* hp, Vm* v, char[] source) @private {
    Lexer lx = lexer::lexer_init(source, hp);
    defer lx.free_arena();
    lx.skip_hashbang();
    CompiledFunction*? f = compiler::compile(&lx, hp);
    if (catch err = f) {
        io::eprintfn("agent: SyntaxError in agent source");
        return false;
    }
    if (catch err = v.execute(f)) {
        if (!hp.uncatchable_throw) io::eprintfn("agent: uncaught exception in agent source");
        hp.has_error = false;
        return false;
    }
    return true;
}
