#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "jse.h"
/*
 * The embedding API from plans/074, exercised through include/jse.h only.
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

static int expect_ok(int rc, jse_runtime rt, const char *what) {
    if (rc != JSE_OK) {
        printf("FAIL: %s: %s\n", what, jse_last_error(rt));
        failures++;
        return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------- interrupt */

static volatile sig_atomic_t g_polls;

/* Runs on the engine thread at VM safepoints. Never calls back into the
 * engine. */
static int count_polls(jse_runtime rt, void *opaque) {
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
static void test_interrupt(jse_runtime rt) {
    jse_value v;
    int rc;

    g_polls = 0;
    jse_set_interrupt_handler(rt, count_polls, NULL);

    signal(SIGALRM, on_alarm);
    alarm(30);                  /* in-suite watchdog: no external timeout */

    const char *src = "while(true){}";
    rc = jse_eval(rt, src, strlen(src), &v);
    alarm(0);

    if (rc != JSE_ERR_INTERRUPT) {
        printf("FAIL: expected interrupt, got %d (%s)\n", rc, jse_last_error(rt));
        failures++;
        return;
    }
    if (strcmp(jse_last_error(rt), "interrupted") != 0) {
        fail("jse_last_error is not \"interrupted\"");
    }

    /* A try/catch must not swallow the abort: run the same loop wrapped in
     * one and expect the same status. */
    const char *swallow =
        "try { while(true){} } catch (e) { /* must not run */ }";
    rc = jse_eval(rt, swallow, strlen(swallow), &v);
    if (rc != JSE_ERR_INTERRUPT) {
        printf("FAIL: catch swallowed the interrupt (%d, %s)\n",
               rc, jse_last_error(rt));
        failures++;
        return;
    }

    /* The runtime must remain usable: a plain eval succeeds. */
    rc = jse_eval(rt, "1+1", 3, &v);
    if (!expect_ok(rc, rt, "runtime not usable after interrupt")) return;
    double d = 0.0;
    jse_get_number(rt, v, &d);
    jse_value_free(rt, v);
    if (d != 2.0) { fail("1+1 after interrupt is not 2"); return; }

    /* A finally block still runs during the unwind; script must not resume
     * after it. */
    const char *fin =
        "var seen = 0; try { while(true){} } finally { seen = 1; } ";
    rc = jse_eval(rt, fin, strlen(fin), &v);
    if (rc != JSE_ERR_INTERRUPT) {
        printf("FAIL: interrupt with finally (%d, %s)\n", rc, jse_last_error(rt));
        failures++;
        return;
    }
    rc = jse_eval(rt, "seen", 4, &v);
    if (!expect_ok(rc, rt, "finally did not run during interrupt")) return;
    jse_get_number(rt, v, &d);
    jse_value_free(rt, v);
    if (d != 1.0) { fail("finally did not run during interrupt"); return; }

    /* A fresh eval starts with a clean budget: no unprompted callback. */
    g_polls = 0;
    rc = jse_eval(rt, "40+2", 4, &v);
    if (!expect_ok(rc, rt, "eval after interrupt")) return;
    jse_value_free(rt, v);
    if (g_polls != 0) {
        printf("FAIL: fresh eval polled the handler %ld times\n", (long)g_polls);
        failures++;
    }

    /* Clearing the handler works and leaves the runtime fully plain. */
    const char *boom = "throw new Error('boom')";
    rc = jse_eval(rt, boom, strlen(boom), &v);
    if (rc != JSE_ERR_THROW) {
        printf("FAIL: plain throw after clearing handler (%d)\n", rc);
        failures++;
    }

    printf("interrupt: ok (%ld polls)\n", (long)g_polls);
}

/* ----------------------------------------------------- construction & props */

/* Build the plan 6.2 config object entirely from C, then read it back. */
static void test_config(jse_runtime rt) {
    jse_value obj = 0, host = 0, port = 0, arr = 0, s1 = 0, s2 = 0, v = 0;
    if (!expect_ok(jse_new_object(rt, &obj), rt, "new_object")) return;
    if (!expect_ok(jse_new_string(rt, "example.com", 11, &host), rt, "new_string")) return;
    if (!expect_ok(jse_set_prop(rt, obj, "host", 4, host), rt, "set_prop host")) return;
    if (!expect_ok(jse_new_number(rt, 8080, &port), rt, "new_number")) return;
    if (!expect_ok(jse_set_prop(rt, obj, "port", 4, port), rt, "set_prop port")) return;
    if (!expect_ok(jse_new_array(rt, &arr), rt, "new_array")) return;
    if (!expect_ok(jse_new_string(rt, "fast", 4, &s1), rt, "new_string s1")) return;
    if (!expect_ok(jse_new_string(rt, "strict", 6, &s2), rt, "new_string s2")) return;
    if (!expect_ok(jse_set_prop_index(rt, arr, 0, s1), rt, "set_prop_index 0")) return;
    if (!expect_ok(jse_set_prop_index(rt, arr, 1, s2), rt, "set_prop_index 1")) return;
    if (!expect_ok(jse_set_prop(rt, obj, "opts", 4, arr), rt, "set_prop opts")) return;
    jse_value_free(rt, host);
    jse_value_free(rt, port);
    jse_value_free(rt, s1);
    jse_value_free(rt, s2);
    jse_value_free(rt, arr);

    /* Hand the object to JS: config.port must read 8080 from C's object. */
    jse_value g;
    if (!expect_ok(jse_get_global(rt, &g), rt, "get_global")) { jse_value_free(rt, obj); return; }
    if (!expect_ok(jse_set_prop(rt, g, "config", 6, obj), rt, "bind global config")) { jse_value_free(rt, g); jse_value_free(rt, obj); return; }
    if (jse_eval(rt, "config.port", 11, &v) == JSE_OK) {
        double d = 0; jse_get_number(rt, v, &d); jse_value_free(rt, v);
        if (d != 8080.0) { printf("FAIL: config.port = %.0f\n", d); failures++; }
    } else {
        printf("FAIL: eval config.port: %s\n", jse_last_error(rt)); failures++;
    }
    if (jse_eval(rt, "config.opts[1]", 14, &v) == JSE_OK) {
        char buf[64]; size_t got = 0;
        if (jse_get_string(rt, v, buf, sizeof buf, &got) == JSE_OK) {
            if (strcmp(buf, "strict") != 0) { printf("FAIL: config.opts[1]=%s\n", buf); failures++; }
        } else { fail("get_string config.opts[1]"); }
        jse_value_free(rt, v);
    } else { printf("FAIL: eval config.opts[1]: %s\n", jse_last_error(rt)); failures++; }

    /* Read properties back from C: obj.host, obj.port, obj.opts[0]. */
    jse_value p = 0;
    if (jse_get_prop(rt, obj, "host", 4, &p) == JSE_OK) {
        char buf[64]; size_t got = 0;
        if (jse_get_string(rt, p, buf, sizeof buf, &got) == JSE_OK) {
            if (strcmp(buf, "example.com") != 0) { printf("FAIL: obj.host=%s\n", buf); failures++; }
        } else fail("get_string obj.host");
        jse_value_free(rt, p);
    } else { printf("FAIL: get_prop host: %s\n", jse_last_error(rt)); failures++; }

    /* jse_has_prop on present and absent keys. */
    int has = -1;
    if (jse_has_prop(rt, obj, "port", 4, &has) == JSE_OK && has == 1 &&
        jse_has_prop(rt, obj, "nope", 4, &has) == JSE_OK && has == 0) {
        /* ok */
    } else { fail("has_prop present/absent"); }

    /* A missing property reads as undefined, not an error. */
    if (jse_get_prop(rt, obj, "missing", 7, &p) == JSE_OK) {
        if (jse_type_of(rt, p) != JSE_TYPE_UNDEFINED) { fail("missing prop not undefined"); }
        jse_value_free(rt, p);
    } else { fail("get_prop missing"); }

    jse_value_free(rt, g);
    jse_value_free(rt, obj);
}

/* delete own property (succeeds), a prototype property (reports absent), and
 * a non-configurable own property (throws). */
static void test_delete(jse_runtime rt) {
    jse_value obj = 0, v = 0;
    if (jse_eval(rt, "var d={a:1}; Object.defineProperty(d,'c',{configurable:false}); d", sizeof "var d={a:1}; Object.defineProperty(d,'c',{configurable:false}); d" - 1, &v) != JSE_OK) {
        printf("FAIL: eval delete setup: %s\n", jse_last_error(rt)); failures++; return;
    }
    obj = v;
    int out = -1;
    if (jse_delete_prop(rt, obj, "a", 1, &out) != JSE_OK || out != 1) {
        printf("FAIL: delete own prop (out=%d)\n", out); failures++;
    }
    out = -1;
    if (jse_delete_prop(rt, obj, "b", 1, &out) != JSE_OK || out != 0) {
        printf("FAIL: delete absent prop (out=%d)\n", out); failures++;
    }
    if (jse_delete_prop(rt, obj, "c", 1, &out) != JSE_ERR_THROW) {
        printf("FAIL: delete non-configurable should throw (%s)\n", jse_last_error(rt)); failures++;
    }
    /* Proxy whose get trap throws must surface as JSE_ERR_THROW, not crash. */
    jse_value px = 0;
    if (jse_eval(rt, "new Proxy({}, { get(){ throw new Error('boom'); } })", sizeof "new Proxy({}, { get(){ throw new Error('boom'); } })" - 1, &px) == JSE_OK) {
        jse_value got = 0;
        if (jse_get_prop(rt, px, "x", 1, &got) != JSE_ERR_THROW) {
            printf("FAIL: proxy get trap did not throw\n"); failures++;
        }
        if (strcmp(jse_last_error(rt), "Error: boom") != 0) {
            printf("FAIL: proxy error msg=%s\n", jse_last_error(rt)); failures++;
        }
        jse_value_free(rt, px);
    } else { printf("FAIL: eval proxy: %s\n", jse_last_error(rt)); failures++; }
    jse_value_free(rt, obj);
}

/* Enumeration: an own non-enumerable key appears alongside own enumerable. */
static void test_enumeration(jse_runtime rt) {
    jse_value obj = 0, keys = 0, k = 0;
    if (jse_eval(rt, "var e={a:1}; Object.defineProperty(e,'h',{value:2,enumerable:false}); e", sizeof "var e={a:1}; Object.defineProperty(e,'h',{value:2,enumerable:false}); e" - 1, &obj) != JSE_OK) {
        printf("FAIL: eval enum setup: %s\n", jse_last_error(rt)); failures++; return;
    }
    if (jse_own_prop_names(rt, obj, &keys) != JSE_OK) {
        printf("FAIL: own_prop_names: %s\n", jse_last_error(rt)); failures++; jse_value_free(rt, obj); return;
    }
    double n = 0;
    jse_value lenv;
    if (jse_get_prop(rt, keys, "length", 6, &lenv) == JSE_OK) {
        jse_get_number(rt, lenv, &n); jse_value_free(rt, lenv);
    }
    if (n < 2.0) { printf("FAIL: own names length %.0f\n", n); failures++; }
    int has_a = 0, has_h = 0;
    for (int i = 0; i < (int)n; i++) {
        char buf[64]; size_t got = 0;
        if (jse_get_prop_index(rt, keys, (unsigned)i, &k) == JSE_OK) {
            if (jse_get_string(rt, k, buf, sizeof buf, &got) == JSE_OK) {
                if (strcmp(buf, "a") == 0) has_a = 1;
                if (strcmp(buf, "h") == 0) has_h = 1;
            }
            jse_value_free(rt, k);
        }
    }
    if (!has_a || !has_h) {
        printf("FAIL: own names a=%d h=%d\n", has_a, has_h); failures++;
    }
    jse_value_free(rt, keys);
    jse_value_free(rt, obj);
}

/* Host-side calls: define add(), call it from C; call a host function too. */
static int g_called = 0;
static void doubled(jse_call_ctx ctx, void *udata) {
    (void)udata;
    g_called++;
    double d = 0.0;
    jse_ctx_get_number(ctx, jse_arg(ctx, 0), &d);
    jse_return_number(ctx, d * 2.0);
}

static void test_call_rt(jse_runtime rt) {
    jse_value fn = 0, a = 0, b = 0, out = 0;
    if (jse_eval(rt, "function add(a,b){return a+b;} add", sizeof "function add(a,b){return a+b;} add" - 1, &fn) != JSE_OK) {
        printf("FAIL: eval add: %s\n", jse_last_error(rt)); failures++; return;
    }
    jse_new_number(rt, 2.0, &a);
    jse_new_number(rt, 40.0, &b);
    jse_value argv[2] = { a, b };
    if (jse_call_rt(rt, fn, argv, 2, 0, &out) != JSE_OK) {
        printf("FAIL: call_rt add: %s\n", jse_last_error(rt)); failures++;
    } else {
        double d = 0; jse_get_number(rt, out, &d); jse_value_free(rt, out);
        if (d != 42.0) { printf("FAIL: add(2,40)=%.0f\n", d); failures++; }
    }
    jse_value_free(rt, a); jse_value_free(rt, b); jse_value_free(rt, fn);
    a = b = fn = 0;

    /* Host-registered function called via jse_call_rt (fresh call context). */
    if (jse_register_fn(rt, "ans", 3, doubled, NULL, 0, 0) != JSE_OK) {
        printf("FAIL: register ans: %s\n", jse_last_error(rt)); failures++;
    }
    if (jse_eval(rt, "ans(21)", 7, &fn) == JSE_OK) {
        double d = 0; jse_get_number(rt, fn, &d); jse_value_free(rt, fn);
        if (g_called != 1 || d != 42.0) { printf("FAIL: ans via eval (%d, %.0f)\n", g_called, d); failures++; }
    } else { printf("FAIL: eval ans(21): %s\n", jse_last_error(rt)); failures++; }

    g_called = 0;
    jse_value gh = 0;
    if (jse_get_global(rt, &gh) != JSE_OK) { fail("get_global for ans call"); }
    if (jse_get_prop(rt, gh, "ans", 3, &fn) != JSE_OK) { fail("get_prop ans"); }
    jse_value one = 0; jse_new_number(rt, 100.0, &one);
    jse_value argv2[1] = { one };
    if (jse_call_rt(rt, fn, argv2, 1, 0, &out) != JSE_OK) {
        printf("FAIL: host fn via call_rt: %s\n", jse_last_error(rt)); failures++;
    } else {
        double d = 0; jse_get_number(rt, out, &d); jse_value_free(rt, out);
        if (d != 200.0) { printf("FAIL: doubled(100)=%.0f\n", d); failures++; }
    }
    if (g_called != 1) { printf("FAIL: host fn not called via call_rt\n"); failures++; }
    jse_value_free(rt, one); jse_value_free(rt, fn); jse_value_free(rt, gh);
}

/* Source locations: script name + line/col on a syntax error; a runtime throw
 * reports its kind even without a resolved line. */
static void test_locations(jse_runtime rt) {
    jse_value v;
    jse_error_info info;

    const char *bad = "var x = ;";
    if (jse_eval_with_name(rt, bad, strlen(bad), "foo.js", 6, &v) != JSE_ERR_SYNTAX) {
        printf("FAIL: bad source not JSE_ERR_SYNTAX (%s)\n", jse_last_error(rt)); failures++;
    }
    memset(&info, 0, sizeof info);
    if (jse_last_error_info(rt, &info) != JSE_OK) { fail("last_error_info"); }
    if (info.code != JSE_ERR_SYNTAX || info.line != 1 || info.col != 10) {
        printf("FAIL: syntax loc code=%d line=%d col=%d\n", info.code, info.line, info.col); failures++;
    }
    if (!info.script_name || strcmp(info.script_name, "foo.js") != 0) {
        printf("FAIL: script_name=%s\n", info.script_name ? info.script_name : "(null)"); failures++;
    }
    if (!expect_ok(jse_eval(rt, "1", 1, &v), rt, "reuse after syntax error")) return;

    const char *bad2 = "var a = 1;\nvar b = ;";
    if (jse_eval_with_name(rt, bad2, strlen(bad2), "two.js", 6, &v) != JSE_ERR_SYNTAX) {
        fail("bad2 not syntax"); failures++;
    }
    memset(&info, 0, sizeof info);
    jse_last_error_info(rt, &info);
    if (info.line != 2 || info.col != 10) {
        printf("FAIL: multi-line loc line=%d col=%d\n", info.line, info.col); failures++;
    }
    if (!expect_ok(jse_eval(rt, "1", 1, &v), rt, "reuse after multi-line error")) return;

    /* A runtime throw reports JSE_ERR_THROW (line unknown for now). */
    const char *rt_src = "throw new TypeError('x')";
    if (jse_eval_with_name(rt, rt_src, strlen(rt_src), NULL, 0, &v) != JSE_ERR_THROW) {
        printf("FAIL: runtime throw not JSE_ERR_THROW\n"); failures++;
    }
    memset(&info, 0, sizeof info);
    jse_last_error_info(rt, &info);
    if (info.code != JSE_ERR_THROW) {
        printf("FAIL: runtime err code=%d\n", info.code); failures++;
    }
    if (!expect_ok(jse_eval(rt, "1", 1, &v), rt, "reuse after runtime throw")) return;
}

int main(void) {
    jse_runtime rt = NULL;
    if (jse_open(&rt) != JSE_OK) {
        printf("FAIL: jse_open\n");
        return 1;
    }

    test_interrupt(rt);
    test_config(rt);
    test_delete(rt);
    test_enumeration(rt);
    test_call_rt(rt);
    test_locations(rt);

    jse_close(rt);
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("embed_api: all ok\n");
    return 0;
}