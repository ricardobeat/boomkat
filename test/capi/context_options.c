/* Context options: no eval, cannot block, and host-class global objects. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int finalized;
static void fin(void *payload, void *opaque) { (void)opaque; assert(payload == &finalized); finalized++; }

/* The payload of a global whose class comes after its realm: a window holding
 * one JS value, reported by the class's trace hook. */
typedef struct { bk_slot held; int finalized; int traced; } window_state;
static void window_fin(void *payload, void *opaque) { (void)opaque; ((window_state *)payload)->finalized++; }
static void window_trace(void *payload, bk_tracer *tracer, void *opaque) {
    (void)opaque;
    window_state *state = payload;
    state->traced++;
    bk_trace_slot(tracer, &state->held);
}

static bk_value eval(bk_ctx ctx, const char *src) {
    return bk_eval_ex(ctx, src, strlen(src), "ctx.js", BK_EVAL_GLOBAL);
}

static int str_is(bk_ctx ctx, bk_value v, const char *want) {
    char buf[96];
    if (!v || bk_read_string(ctx, v, buf, sizeof buf, NULL) != BK_OK) return 0;
    if (strcmp(buf, want) != 0) { fprintf(stderr, "got %s, want %s\n", buf, want); return 0; }
    return 1;
}

int main(void) {
    bk_runtime rt = bk_new_runtime(NULL);
    bk_ctx plain = bk_new_context(rt, NULL);

    /* No eval: string eval and dynamic functions throw EvalError. */
    bk_context_options no_eval = { BK_CONTEXT_NO_EVAL, 0, NULL };
    bk_ctx locked = bk_new_context(rt, &no_eval);
    assert(locked && locked != plain);
    const char *probe =
        "[(() => { try { eval('1'); return 'ran' } catch (e) { return e.name } })(),"
        " (() => { try { (0, eval)('1'); return 'ran' } catch (e) { return e.name } })(),"
        " (() => { try { new Function('return 1'); return 'ran' } catch (e) { return e.name } })(),"
        " (() => { try { (function* () {}).constructor('yield 1'); return 'ran' } catch (e) { return e.name } })(),"
        " eval(7)].join()";
    assert(str_is(locked, eval(locked, probe), "EvalError,EvalError,EvalError,EvalError,7"));
    assert(str_is(plain, eval(plain, probe), "ran,ran,ran,ran,7"));
    /* The host still evaluates, and compiled scripts run. */
    assert(bk_to_number(locked, eval(locked, "20 + 22")) == 42);
    bk_value script = bk_compile(locked, "6 * 7", 5, "s.js", BK_EVAL_GLOBAL);
    assert(script && bk_to_number(locked, bk_run_script(locked, script)) == 42);

    /* Cannot block: Atomics.wait throws a TypeError. */
    bk_context_options no_block = { BK_CONTEXT_CANNOT_BLOCK, 0, NULL };
    bk_ctx main_thread = bk_new_context(rt, &no_block);
    const char *wait =
        "(() => { if (typeof SharedArrayBuffer === 'undefined') return 'n/a';"
        " try { return Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 0) }"
        " catch (e) { return e.name } })()";
    bk_value w = eval(main_thread, wait);
    char buf[16];
    assert(bk_read_string(main_thread, w, buf, sizeof buf, NULL) == BK_OK);
    if (strcmp(buf, "n/a") != 0) {
        assert(!strcmp(buf, "TypeError"));
        assert(str_is(plain, eval(plain, wait), "timed-out"));
    }

    /* A host-class global object. */
    bk_class_def def = { "Window", 0, fin, NULL, NULL, 0, 0, NULL, NULL };
    bk_value ctor, proto;
    bk_class window = bk_define_class(plain, &def, &ctor, &proto);
    assert(window);
    bk_set_property(plain, proto, "kind", 4, bk_new_string(plain, "window", 6));
    bk_context_options with_global = { 0, window, &finalized };
    bk_ctx page = bk_new_context(rt, &with_global);
    assert(page);
    bk_value global = bk_get_global_object(page);
    assert(bk_get_instance_payload(page, global, window) == &finalized);
    assert(bk_get_instance_class(page, global) == window);
    assert(str_is(page, eval(page, "var answer = 42; globalThis.answer + ':' + kind + ':' + typeof Array"), "42:window:function"));
    assert(str_is(page, eval(page, "typeof answer"), "number"));
    bk_free_value(page, global);

    /* A host global whose class, and its parent, are defined in its own realm. */
    bk_context_options host_global = { BK_CONTEXT_HOST_GLOBAL, 0, NULL };
    bk_ctx frame = bk_new_context(rt, &host_global);
    assert(frame);
    global = bk_get_global_object(frame);
    assert(bk_get_instance_class(frame, global) == 0);
    assert(str_is(frame, eval(frame, "String(Object.getPrototypeOf(globalThis) === Object.prototype)"), "true"));
    bk_class_def target_def = { "EventTarget", 0, NULL, NULL, NULL, 0, 0, NULL, NULL };
    bk_value target_ctor, target_proto;
    bk_class event_target = bk_define_class(frame, &target_def, &target_ctor, &target_proto);
    bk_class_def window_def = { "Window", event_target, window_fin, window_trace, NULL, 0, 0, NULL, NULL };
    bk_value window_ctor, window_proto;
    bk_class frame_window = bk_define_class(frame, &window_def, &window_ctor, &window_proto);
    assert(event_target && frame_window);
    bk_set_property(frame, global, "EventTarget", 11, target_ctor);
    bk_set_property(frame, global, "Window", 6, window_ctor);
    bk_set_property(frame, target_proto, "addEventListener", 16, bk_new_string(frame, "inherited", 9));
    window_state state = { 0 };
    bk_slot_init(&state.held);
    assert(bk_set_global_class(frame, frame_window, &state) == BK_OK);
    assert(bk_get_instance_class(frame, global) == frame_window);
    assert(bk_get_instance_payload(frame, global, frame_window) == &state);
    assert(bk_get_instance_payload(frame, global, event_target) == &state);
    assert(str_is(frame, eval(frame,
        "[Object.getPrototypeOf(globalThis) === Window.prototype, globalThis instanceof EventTarget,"
        " Object.getPrototypeOf(EventTarget.prototype) === Object.prototype, addEventListener].join()"),
        "true,true,true,inherited"));
    /* Once only, and the payload is traced. */
    assert(bk_set_global_class(frame, frame_window, &state) == BK_ERR_INVALID);
    assert(bk_set_global_class(plain, frame_window, &state) == BK_ERR_INVALID);
    bk_value held = eval(frame, "({ tag: 'held' })");
    assert(bk_slot_set(frame, &state.held, held) == BK_OK);
    bk_free_value(frame, held);
    bk_gc(rt, BK_GC_FULL);
    assert(state.traced > 0);
    held = bk_slot_get(frame, &state.held);
    assert(str_is(frame, bk_get_property(frame, held, "tag", 3), "held"));
    bk_free_value(frame, held);
    bk_free_value(frame, global);

    /* A class with exotic hooks cannot be a global's, and the flag excludes global_class. */
    bk_context_options exotic_global = { BK_CONTEXT_HOST_GLOBAL, 0, NULL };
    bk_ctx other = bk_new_context(rt, &exotic_global);
    bk_exotic_hooks hooks = { 0 };
    bk_class_def exotic_def = { "Exotic", 0, NULL, NULL, NULL, 0, 0, NULL, &hooks };
    bk_class exotic = bk_define_class(other, &exotic_def, NULL, NULL);
    assert(exotic && bk_set_global_class(other, exotic, NULL) == BK_ERR_INVALID);
    bk_context_options both = { BK_CONTEXT_HOST_GLOBAL, window, &finalized };
    assert(bk_new_context(rt, &both) == NULL);

    /* Unknown flags and classes are refused. */
    bk_context_options bad = { 0x80, 0, NULL };
    assert(bk_new_context(rt, &bad) == NULL);
    bk_context_options bad_class = { 0, 999, NULL };
    assert(bk_new_context(rt, &bad_class) == NULL);

    bk_slot_clear(frame, &state.held);
    bk_free_runtime(rt);
    assert(finalized == 1);
    assert(state.finalized == 1);
    puts("context_options: PASS");
    return 0;
}
