/* Context options: no eval, cannot block, and a host-class global object. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int finalized;
static void fin(void *payload, void *opaque) { (void)opaque; assert(payload == &finalized); finalized++; }

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
    bk_class_def def = { "Window", 0, fin, NULL, NULL, 0, 0, NULL };
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

    /* Unknown flags and classes are refused. */
    bk_context_options bad = { 0x80, 0, NULL };
    assert(bk_new_context(rt, &bad) == NULL);
    bk_context_options bad_class = { 0, 999, NULL };
    assert(bk_new_context(rt, &bad_class) == NULL);

    bk_free_runtime(rt);
    assert(finalized == 1);
    puts("context_options: PASS");
    return 0;
}
