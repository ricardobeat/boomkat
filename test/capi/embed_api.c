#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "boomkat.h"
/*
 * The embedding API from plans/074, exercised through include/boomkat.h only.
 *
 * Each section prints a PASS line and the binary exits non-zero on the first
 * failure, like the other test/capi binaries. The interrupt section does not
 * rely on an external timeout: the in-suite SIGALRM watchdog is part of the
 * binary ("an in-suite watchdog is the whole point", plan 070 E1).
 *
 * The alarm path is POSIX-only; CI builds on other hosts rely on their own
 * timeout for the interrupt section.
 */
static int failures;

static void fail(const char *what) {
    printf("FAIL: %s\n", what);
    failures++;
}

/* A handle-returning call succeeded if the handle is non-zero. */
static bk_value expect_val(bk_value v, bk_ctx rt, const char *what) {
    if (!v) {
        printf("FAIL: %s: %s\n", what, bk_get_error_message(rt));
        failures++;
    }
    return v;
}

static int expect_ok(int rc, bk_ctx rt, const char *what) {
    if (rc != BK_OK) {
        printf("FAIL: %s: %s\n", what, bk_get_error_message(rt));
        failures++;
        return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------- interrupt */

static volatile sig_atomic_t g_polls;

/* Runs on the engine thread at VM safepoints. Never calls back into the
 * engine. */
static int count_polls(bk_runtime rt, void *opaque) {
    (void)rt; (void)opaque;
    return ++g_polls >= 1000;   /* abort after 1000 polls */
}

static void on_alarm(int sig) {
    (void)sig;
    write(2, "FAIL: engine never polled the interrupt handler\n", 47);
    _exit(1);
}

/* The plan 070 E1 shape: install a handler, run while(true){}, expect the
 * interrupt status, then prove the runtime still works. */
static void test_interrupt(bk_ctx rt) {
    bk_value v;
    int rc;

    g_polls = 0;
    bk_set_interrupt(bk_get_runtime(rt), count_polls, NULL);

    signal(SIGALRM, on_alarm);
    alarm(30);                  /* in-suite watchdog: no external timeout */

    const char *src = "while(true){}";
    v = bk_eval_ex(rt, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    alarm(0);

    if (rc != BK_ERR_INTERRUPT) {
        printf("FAIL: expected interrupt, got %d (%s)\n", rc, bk_get_error_message(rt));
        failures++;
        return;
    }
    if (strcmp(bk_get_error_message(rt), "interrupted") != 0) {
        fail("bk_get_error_message is not \"interrupted\"");
    }

    /* A try/catch must not swallow the abort: run the same loop wrapped in
     * one and expect the same status. */
    const char *swallow =
        "try { while(true){} } catch (e) { /* must not run */ }";
    v = bk_eval_ex(rt, swallow, strlen(swallow), "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    if (rc != BK_ERR_INTERRUPT) {
        printf("FAIL: catch swallowed the interrupt (%d, %s)\n",
               rc, bk_get_error_message(rt));
        failures++;
        return;
    }

    /* The runtime must remain usable: a plain eval succeeds. */
    v = bk_eval_ex(rt, "1+1", 3, "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    if (!expect_ok(rc, rt, "runtime not usable after interrupt")) return;
    double d = 0.0;
    bk_read_number(rt, v, &d);
    bk_free_value(rt, v);
    if (d != 2.0) { fail("1+1 after interrupt is not 2"); return; }

    /* A finally block still runs during the unwind; script must not resume
     * after it. */
    const char *fin =
        "var seen = 0; try { while(true){} } finally { seen = 1; } ";
    v = bk_eval_ex(rt, fin, strlen(fin), "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    if (rc != BK_ERR_INTERRUPT) {
        printf("FAIL: interrupt with finally (%d, %s)\n", rc, bk_get_error_message(rt));
        failures++;
        return;
    }
    v = bk_eval_ex(rt, "seen", 4, "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    if (!expect_ok(rc, rt, "finally did not run during interrupt")) return;
    bk_read_number(rt, v, &d);
    bk_free_value(rt, v);
    if (d != 1.0) { fail("finally did not run during interrupt"); return; }

    /* A fresh eval starts with a clean budget: no unprompted callback. */
    g_polls = 0;
    v = bk_eval_ex(rt, "40+2", 4, "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    if (!expect_ok(rc, rt, "eval after interrupt")) return;
    bk_free_value(rt, v);
    if (g_polls != 0) {
        printf("FAIL: fresh eval polled the handler %ld times\n", (long)g_polls);
        failures++;
    }

    /* Clearing the handler works and leaves the runtime fully plain. */
    const char *boom = "throw new Error('boom')";
    v = bk_eval_ex(rt, boom, strlen(boom), "<eval>", BK_EVAL_GLOBAL);
    rc = bk_get_error_code(rt);
    if (rc != BK_ERR_THROW) {
        printf("FAIL: plain throw after clearing handler (%d)\n", rc);
        failures++;
    }

    printf("interrupt: ok (%ld polls)\n", (long)g_polls);
}

/* ----------------------------------------------------- construction & props */

/* Build the plan 6.2 config object entirely from C, then read it back. */
static void test_config(bk_ctx rt) {
    bk_value obj = 0, host = 0, port = 0, arr = 0, s1 = 0, s2 = 0, v = 0;
    if (!(obj = expect_val(bk_new_object(rt), rt, "new_object"))) return;
    if (!(host = expect_val(bk_new_string(rt, "example.com", 11), rt, "new_string"))) return;
    if (!expect_ok(bk_set_property(rt, obj, "host", 4, host), rt, "set_prop host")) return;
    if (!(port = expect_val(bk_new_number(rt, 8080), rt, "new_number"))) return;
    if (!expect_ok(bk_set_property(rt, obj, "port", 4, port), rt, "set_prop port")) return;
    if (!(arr = expect_val(bk_new_array(rt), rt, "new_array"))) return;
    if (!(s1 = expect_val(bk_new_string(rt, "fast", 4), rt, "new_string s1"))) return;
    if (!(s2 = expect_val(bk_new_string(rt, "strict", 6), rt, "new_string s2"))) return;
    if (!expect_ok(bk_set_property_uint32(rt, arr, 0, s1), rt, "set_prop_index 0")) return;
    if (!expect_ok(bk_set_property_uint32(rt, arr, 1, s2), rt, "set_prop_index 1")) return;
    if (!expect_ok(bk_set_property(rt, obj, "opts", 4, arr), rt, "set_prop opts")) return;
    bk_free_value(rt, host);
    bk_free_value(rt, port);
    bk_free_value(rt, s1);
    bk_free_value(rt, s2);
    bk_free_value(rt, arr);

    /* Hand the object to JS: config.port must read 8080 from C's object. */
    bk_value g;
    if (!(g = expect_val(bk_get_global_object(rt), rt, "get_global"))) { bk_free_value(rt, obj); return; }
    if (!expect_ok(bk_set_property(rt, g, "config", 6, obj), rt, "bind global config")) { bk_free_value(rt, g); bk_free_value(rt, obj); return; }
    if ((v = bk_eval_ex(rt, "config.port", 11, "<eval>", BK_EVAL_GLOBAL))) {
        double d = 0; bk_read_number(rt, v, &d); bk_free_value(rt, v);
        if (d != 8080.0) { printf("FAIL: config.port = %.0f\n", d); failures++; }
    } else {
        printf("FAIL: eval config.port: %s\n", bk_get_error_message(rt)); failures++;
    }
    if ((v = bk_eval_ex(rt, "config.opts[1]", 14, "<eval>", BK_EVAL_GLOBAL))) {
        char buf[64]; size_t got = 0;
        if (bk_read_string(rt, v, buf, sizeof buf, &got) == BK_OK) {
            if (strcmp(buf, "strict") != 0) { printf("FAIL: config.opts[1]=%s\n", buf); failures++; }
        } else { fail("get_string config.opts[1]"); }
        bk_free_value(rt, v);
    } else { printf("FAIL: eval config.opts[1]: %s\n", bk_get_error_message(rt)); failures++; }

    /* Read properties back from C: obj.host, obj.port, obj.opts[0]. */
    bk_value p = 0;
    if ((p = bk_get_property(rt, obj, "host", 4))) {
        char buf[64]; size_t got = 0;
        if (bk_read_string(rt, p, buf, sizeof buf, &got) == BK_OK) {
            if (strcmp(buf, "example.com") != 0) { printf("FAIL: obj.host=%s\n", buf); failures++; }
        } else fail("get_string obj.host");
        bk_free_value(rt, p);
    } else { printf("FAIL: get_prop host: %s\n", bk_get_error_message(rt)); failures++; }

    /* bk_has_property on present and absent keys. */
    int has = -1;
    if (bk_has_property(rt, obj, "port", 4, &has) == BK_OK && has == 1 &&
        bk_has_property(rt, obj, "nope", 4, &has) == BK_OK && has == 0) {
        /* ok */
    } else { fail("has_prop present/absent"); }

    /* A missing property reads as undefined, not an error. */
    if ((p = bk_get_property(rt, obj, "missing", 7))) {
        if (bk_get_type(rt, p) != BK_TYPE_UNDEFINED) { fail("missing prop not undefined"); }
        bk_free_value(rt, p);
    } else { fail("get_prop missing"); }

    bk_free_value(rt, g);
    bk_free_value(rt, obj);
}

/* delete own property (succeeds), a prototype property (reports absent), and
 * a non-configurable own property (throws). */
static void test_delete(bk_ctx rt) {
    bk_value obj = 0, v = 0;
    if (!(v = bk_eval_ex(rt, "var d={a:1}; Object.defineProperty(d,'c',{configurable:false}); d", strlen("var d={a:1}; Object.defineProperty(d,'c',{configurable:false}); d"), "<eval>", BK_EVAL_GLOBAL))) {
        printf("FAIL: eval delete setup: %s\n", bk_get_error_message(rt)); failures++; return;
    }
    obj = v;
    int out = -1;
    if (bk_delete_property(rt, obj, "a", 1, &out) != BK_OK || out != 1) {
        printf("FAIL: delete own prop (out=%d)\n", out); failures++;
    }
    out = -1;
    if (bk_delete_property(rt, obj, "b", 1, &out) != BK_OK || out != 0) {
        printf("FAIL: delete absent prop (out=%d)\n", out); failures++;
    }
    if (bk_delete_property(rt, obj, "c", 1, &out) != BK_ERR_THROW) {
        printf("FAIL: delete non-configurable should throw (%s)\n", bk_get_error_message(rt)); failures++;
    }
    /* Proxy whose get trap throws must surface as BK_ERR_THROW, not crash. */
    bk_value px = 0;
    if ((px = bk_eval_ex(rt, "new Proxy({}, { get(){ throw new Error('boom'); } })", strlen("new Proxy({}, { get(){ throw new Error('boom'); } })"), "<eval>", BK_EVAL_GLOBAL))) {
        bk_value got = 0;
        got = bk_get_property(rt, px, "x", 1);
        if (got || bk_get_error_code(rt) != BK_ERR_THROW) {
            printf("FAIL: proxy get trap did not throw\n"); failures++;
        }
        if (strcmp(bk_get_error_message(rt), "Error: boom") != 0) {
            printf("FAIL: proxy error msg=%s\n", bk_get_error_message(rt)); failures++;
        }
        bk_free_value(rt, px);
    } else { printf("FAIL: eval proxy: %s\n", bk_get_error_message(rt)); failures++; }
    bk_free_value(rt, obj);
}

static bk_value eval_global(bk_ctx rt, const char *src) {
    return bk_eval_ex(rt, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
}

/* Deletion goes through each object's [[Delete]]: array elements, typed
 * array indices, and proxy traps are not entries in the property table. */
static void test_delete_exotic(bk_ctx rt) {
    int out = -1;
    bk_value arr = expect_val(eval_global(rt, "[1,2,3]"), rt, "eval array");
    if (arr) {
        if (bk_delete_property(rt, arr, "1", 1, &out) != BK_OK || out != 1) {
            printf("FAIL: delete array element (out=%d)\n", out); failures++;
        }
        bk_value hole = bk_get_property_uint32(rt, arr, 1);
        if (!hole || !bk_is_undefined(rt, hole)) fail("deleted array element still present");
        bk_free_value(rt, hole);
        out = -1;
        if (bk_delete_property(rt, arr, "7", 1, &out) != BK_OK || out != 0) {
            printf("FAIL: delete absent array element (out=%d)\n", out); failures++;
        }
        bk_free_value(rt, arr);
    }
    bk_value ta = expect_val(eval_global(rt, "new Uint8Array(4)"), rt, "eval typed array");
    if (ta) {
        if (bk_delete_property(rt, ta, "1", 1, &out) != BK_ERR_THROW) {
            fail("delete typed array index should throw");
        }
        out = -1;
        if (bk_delete_property(rt, ta, "9", 1, &out) != BK_OK || out != 0) {
            printf("FAIL: delete out-of-range typed array index (out=%d)\n", out); failures++;
        }
        bk_free_value(rt, ta);
    }
    bk_value px = expect_val(eval_global(rt,
        "var trapped = []; new Proxy({}, { deleteProperty(t, k) { trapped.push(k); return true; } })"),
        rt, "eval delete proxy");
    if (px) {
        out = -1;
        if (bk_delete_property(rt, px, "x", 1, &out) != BK_OK || out != 1) {
            printf("FAIL: proxy delete (out=%d)\n", out); failures++;
        }
        bk_value seen = eval_global(rt, "trapped.join()");
        char buf[8];
        size_t len = 0;
        if (!seen || bk_read_string(rt, seen, buf, sizeof buf, &len) != BK_OK || strcmp(buf, "x") != 0) {
            fail("proxy deleteProperty trap not called");
        }
        bk_free_value(rt, seen);
        bk_free_value(rt, px);
    }
}

/* Property reads on primitives box the base and keep it as the receiver. */
static void test_get_primitive(bk_ctx rt) {
    bk_value s = bk_str(rt, "abc");
    bk_value len = bk_get_property(rt, s, "length", 6);
    double n = 0;
    if (!len || bk_read_number(rt, len, &n) != BK_OK || n != 3) {
        printf("FAIL: \"abc\".length: %s\n", bk_get_error_message(rt)); failures++;
    }
    bk_value ch = bk_get_property_uint32(rt, s, 1);
    char buf[4];
    size_t blen = 0;
    if (!ch || bk_read_string(rt, ch, buf, sizeof buf, &blen) != BK_OK || strcmp(buf, "b") != 0) {
        printf("FAIL: \"abc\"[1]: %s\n", bk_get_error_message(rt)); failures++;
    }
    bk_value num = bk_new_number(rt, 1.5);
    bk_value fixed = bk_get_property(rt, num, "toFixed", 7);
    if (!fixed || !bk_is_function(rt, fixed)) fail("(1.5).toFixed is not a function");
    bk_value getter = eval_global(rt,
        "Object.defineProperty(Number.prototype, 'self', { get() { 'use strict'; return typeof this; }, configurable: true })");
    bk_value self = bk_get_property(rt, num, "self", 4);
    char type[16];
    if (!self || bk_read_string(rt, self, type, sizeof type, &blen) != BK_OK || strcmp(type, "number") != 0) {
        fail("primitive getter receiver is not the primitive");
    }
    bk_value undef = BK_UNDEFINED;
    if (bk_get_property(rt, undef, "x", 1) || bk_get_error_code(rt) != BK_ERR_TYPE) {
        fail("reading a property of undefined should fail with BK_ERR_TYPE");
    }
    bk_free_value(rt, s); bk_free_value(rt, len); bk_free_value(rt, ch);
    bk_free_value(rt, num); bk_free_value(rt, fixed); bk_free_value(rt, getter);
    bk_free_value(rt, self); bk_free_value(rt, undef);
}

/* new.target is a borrowed call handle: a constructor returns it without
 * freeing it, and a plain call sees undefined. */
static bk_value new_target_fn(bk_ctx ctx, bk_value this_value, unsigned argc,
                              const bk_value *argv, void *opaque) {
    (void)this_value; (void)argc; (void)argv; (void)opaque;
    bk_value nt = bk_get_new_target(ctx);
    if (!nt) return bk_throw_error(ctx, BK_ERROR_TYPE, "no new.target handle");
    if (bk_is_undefined(ctx, nt)) return bk_str(ctx, "plain");
    return bk_dup_value(ctx, nt);
}

static void test_new_target(bk_ctx rt) {
    bk_value fn = expect_val(bk_new_c_function(rt, new_target_fn, "NT", 0, BK_CTOR, NULL, NULL, NULL), rt, "new NT fn");
    if (!fn) return;
    if (!expect_ok(bk_set_global_property(rt, "NT", 2, fn), rt, "install NT")) { bk_free_value(rt, fn); return; }
    bk_value r = eval_global(rt, "new NT() === NT && NT() === 'plain' && Reflect.construct(NT, [], Array) === Array");
    int ok = 0;
    if (!r || bk_read_bool(rt, r, &ok) != BK_OK || !ok) {
        printf("FAIL: new.target handle: %s\n", bk_get_error_message(rt)); failures++;
    }
    if (bk_get_new_target(rt) != 0) fail("bk_get_new_target outside a callback should be 0");
    bk_free_value(rt, r);
    bk_free_value(rt, fn);
}

/* Enumeration: an own non-enumerable key appears alongside own enumerable. */
static void test_enumeration(bk_ctx rt) {
    bk_value obj = 0, keys = 0, k = 0;
    if (!(obj = bk_eval_ex(rt, "var e={a:1}; Object.defineProperty(e,'h',{value:2,enumerable:false}); e", strlen("var e={a:1}; Object.defineProperty(e,'h',{value:2,enumerable:false}); e"), "<eval>", BK_EVAL_GLOBAL))) {
        printf("FAIL: eval enum setup: %s\n", bk_get_error_message(rt)); failures++; return;
    }
    if (!(keys = bk_get_own_property_keys(rt, obj, BK_KEYS_STRINGS))) {
        printf("FAIL: own_prop_names: %s\n", bk_get_error_message(rt)); failures++; bk_free_value(rt, obj); return;
    }
    double n = 0;
    bk_value lenv;
    if ((lenv = bk_get_property(rt, keys, "length", 6))) {
        bk_read_number(rt, lenv, &n); bk_free_value(rt, lenv);
    }
    if (n < 2.0) { printf("FAIL: own names length %.0f\n", n); failures++; }
    int has_a = 0, has_h = 0;
    for (int i = 0; i < (int)n; i++) {
        char buf[64]; size_t got = 0;
        if ((k = bk_get_property_uint32(rt, keys, (unsigned)i))) {
            if (bk_read_string(rt, k, buf, sizeof buf, &got) == BK_OK) {
                if (strcmp(buf, "a") == 0) has_a = 1;
                if (strcmp(buf, "h") == 0) has_h = 1;
            }
            bk_free_value(rt, k);
        }
    }
    if (!has_a || !has_h) {
        printf("FAIL: own names a=%d h=%d\n", has_a, has_h); failures++;
    }
    bk_free_value(rt, keys);
    bk_free_value(rt, obj);
}

/* Host-side calls: define add(), call it from C; call a host function too. */
static int g_called = 0;
static bk_value doubled(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *udata) {
    (void)this_value; (void)argc; (void)argv;
    (void)udata;
    g_called++;
    double d = 0.0;
    bk_read_number(ctx, ((0) < argc ? argv[0] : BK_EXCEPTION), &d);
    return bk_new_number(ctx, d * 2.0);

    return BK_UNDEFINED;
}

/* Evaluates its argument as a separate script, the way a host `load()` or
 * test262's $262.evalScript does. */
static bk_value h_eval_script(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *udata) {
    (void)this_value; (void)argc; (void)argv;
    size_t len = 0;
    const char *src = bk_to_cstring(ctx, ((0) < argc ? argv[0] : BK_EXCEPTION), &len);
    (void)udata;
    bk_value v = bk_eval_ex(ctx, src, len, "<eval>", BK_EVAL_GLOBAL);
    bk_free_cstring(ctx, src);
    if (v) bk_free_value(ctx, v);

    return BK_UNDEFINED;
}

/* A host callback can evaluate a script while another is running. It runs
 * as its own global Script: its declarations land on the global object and
 * its `this` is the global object. */
/* A heap limit far above the script's needs runs a GC-heavy script to
 * completion. */
static void test_memory_limit(bk_ctx unused) {
    static const char src[] =
        "let a = []; for (let i = 0; i < 200000; i++) a.push({ i }); a.length";
    (void)unused;
    bk_runtime_options options = { 0 };
    options.heap_limit = (uint64_t)1 << 40;
    bk_runtime runtime = bk_new_runtime(&options);
    bk_ctx rt = bk_new_context(runtime);
    bk_value v = bk_eval_ex(rt, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
    if (!v) { printf("FAIL: memory limit: %s\n", bk_get_error_message(rt)); failures++; goto done; }
    if (bk_to_number(rt, v) != 200000) {
        printf("FAIL: memory limit: got %g\n", bk_to_number(rt, v)); failures++;
    }
    bk_free_value(rt, v);
    printf("PASS: memory limit\n");
done:
    bk_free_context(rt);
    bk_free_runtime(runtime);
}

static void test_nested_eval(bk_ctx rt) {
    static const char src[] =
        "evalScript('function nested() { return this === globalThis }'); nested() && typeof nested";
    if (bk_set_function_list(rt, 0, (const bk_fn_def[]){{"evalScript", h_eval_script, 1, 0u, NULL}, BK_FN_END}) != BK_OK) {
        printf("FAIL: register evalScript: %s\n", bk_get_error_message(rt)); failures++; return;
    }
    bk_value v = bk_eval_ex(rt, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
    if (!v) { printf("FAIL: nested eval: %s\n", bk_get_error_message(rt)); failures++; return; }
    const char *text = bk_to_cstring(rt, v, NULL);
    if (!text || strcmp(text, "function") != 0) {
        printf("FAIL: nested eval: got %s\n", text); failures++;
    }
    bk_free_cstring(rt, text);
    bk_free_value(rt, v);
    printf("PASS: nested eval\n");
}

static void test_call_rt(bk_ctx rt) {
    bk_value fn = 0, a = 0, b = 0, out = 0;
    if (!(fn = bk_eval_ex(rt, "function add(a,b){return a+b;} add", strlen("function add(a,b){return a+b;} add"), "<eval>", BK_EVAL_GLOBAL))) {
        printf("FAIL: eval add: %s\n", bk_get_error_message(rt)); failures++; return;
    }
    a = bk_new_number(rt, 2.0);
    b = bk_new_number(rt, 40.0);
    bk_value argv[2] = { a, b };
    if (!(out = bk_call(rt, fn, 0, argv, 2))) {
        printf("FAIL: call_rt add: %s\n", bk_get_error_message(rt)); failures++;
    } else {
        double d = 0; bk_read_number(rt, out, &d); bk_free_value(rt, out);
        if (d != 42.0) { printf("FAIL: add(2,40)=%.0f\n", d); failures++; }
    }
    bk_free_value(rt, a); bk_free_value(rt, b); bk_free_value(rt, fn);
    a = b = fn = 0;

    /* Host-registered function called via bk_call (fresh call context). */
    if (bk_set_function_list(rt, 0, (const bk_fn_def[]){{"ans", doubled, 0, 0u, NULL}, BK_FN_END}) != BK_OK) {
        printf("FAIL: register ans: %s\n", bk_get_error_message(rt)); failures++;
    }
    if ((fn = bk_eval_ex(rt, "ans(21)", 7, "<eval>", BK_EVAL_GLOBAL))) {
        double d = 0; bk_read_number(rt, fn, &d); bk_free_value(rt, fn);
        if (g_called != 1 || d != 42.0) { printf("FAIL: ans via eval (%d, %.0f)\n", g_called, d); failures++; }
    } else { printf("FAIL: eval ans(21): %s\n", bk_get_error_message(rt)); failures++; }

    g_called = 0;
    bk_value gh = 0;
    if (!(gh = bk_get_global_object(rt))) { fail("get_global for ans call"); }
    if (!(fn = bk_get_property(rt, gh, "ans", 3))) { fail("get_prop ans"); }
    bk_value one = bk_new_number(rt, 100.0);
    bk_value argv2[1] = { one };
    if (!(out = bk_call(rt, fn, 0, argv2, 1))) {
        printf("FAIL: host fn via call_rt: %s\n", bk_get_error_message(rt)); failures++;
    } else {
        double d = 0; bk_read_number(rt, out, &d); bk_free_value(rt, out);
        if (d != 200.0) { printf("FAIL: doubled(100)=%.0f\n", d); failures++; }
    }
    if (g_called != 1) { printf("FAIL: host fn not called via call_rt\n"); failures++; }
    bk_free_value(rt, one); bk_free_value(rt, fn); bk_free_value(rt, gh);
}

/* Source locations: script name + line/col on a syntax error; a runtime throw
 * reports its kind even without a resolved line. */
static void test_locations(bk_ctx rt) {
    bk_value v;
    bk_error_info info;

    const char *bad = "var x = ;";
    if ((bk_eval_ex(rt, bad, strlen(bad), "foo.js", BK_EVAL_GLOBAL)) || bk_get_error_code(rt) != BK_ERR_SYNTAX) {
        printf("FAIL: bad source not BK_ERR_SYNTAX (%s)\n", bk_get_error_message(rt)); failures++;
    }
    memset(&info, 0, sizeof info);
    if (bk_get_error_info(rt, &info) != BK_OK) { fail("last_error_info"); }
    if (info.code != BK_ERR_SYNTAX || info.line != 1 || info.col != 9) {
        printf("FAIL: syntax loc code=%d line=%d col=%d\n", info.code, info.line, info.col); failures++;
    }
    if (!info.script_name || strcmp(info.script_name, "foo.js") != 0) {
        printf("FAIL: script_name=%s\n", info.script_name ? info.script_name : "(null)"); failures++;
    }
    if (!(v = expect_val(bk_eval_ex(rt, "1", 1, "<eval>", BK_EVAL_GLOBAL), rt, "reuse after syntax error"))) return;

    const char *bad2 = "var a = 1;\nvar b = ;";
    if ((bk_eval_ex(rt, bad2, strlen(bad2), "two.js", BK_EVAL_GLOBAL)) || bk_get_error_code(rt) != BK_ERR_SYNTAX) {
        fail("bad2 not syntax"); failures++;
    }
    memset(&info, 0, sizeof info);
    bk_get_error_info(rt, &info);
    if (info.line != 2 || info.col != 9) {
        printf("FAIL: multi-line loc line=%d col=%d\n", info.line, info.col); failures++;
    }
    if (!(v = expect_val(bk_eval_ex(rt, "1", 1, "<eval>", BK_EVAL_GLOBAL), rt, "reuse after multi-line error"))) return;

    /* A runtime throw reports BK_ERR_THROW (line unknown for now). */
    const char *rt_src = "throw new TypeError('x')";
    if ((v = bk_eval_ex(rt, rt_src, strlen(rt_src), NULL, BK_EVAL_GLOBAL)) ||
        bk_get_error_code(rt) != BK_ERR_THROW) {
        printf("FAIL: runtime throw not BK_ERR_THROW\n"); failures++;
    }
    memset(&info, 0, sizeof info);
    bk_get_error_info(rt, &info);
    if (info.code != BK_ERR_THROW) {
        printf("FAIL: runtime err code=%d\n", info.code); failures++;
    }
    if (!(v = expect_val(bk_eval_ex(rt, "1", 1, "<eval>", BK_EVAL_GLOBAL), rt, "reuse after runtime throw"))) return;
}

int main(void) {
    bk_ctx rt = NULL;
    if (!(rt = bk_new_context(bk_new_runtime(NULL)))) {
        printf("FAIL: bk_new_context\n");
        return 1;
    }

    test_interrupt(rt);
    test_config(rt);
    test_delete(rt);
    test_delete_exotic(rt);
    test_get_primitive(rt);
    test_new_target(rt);
    test_enumeration(rt);
    test_call_rt(rt);
    test_locations(rt);
    test_nested_eval(rt);
    test_memory_limit(rt);

    bk_free_runtime(bk_get_runtime(rt));
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("embed_api: all ok\n");
    return 0;
}
