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
        printf("FAIL: %s: %s\n", what, bk_error(rt));
        failures++;
    }
    return v;
}

static int expect_ok(int rc, bk_ctx rt, const char *what) {
    if (rc != BK_OK) {
        printf("FAIL: %s: %s\n", what, bk_error(rt));
        failures++;
        return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------- interrupt */

static volatile sig_atomic_t g_polls;

/* Runs on the engine thread at VM safepoints. Never calls back into the
 * engine. */
static int count_polls(bk_ctx rt, void *opaque) {
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
    bk_set_interrupt(rt, count_polls, NULL);

    signal(SIGALRM, on_alarm);
    alarm(30);                  /* in-suite watchdog: no external timeout */

    const char *src = "while(true){}";
    v = bk_eval(rt, src, strlen(src));
    rc = bk_error_code(rt);
    alarm(0);

    if (rc != BK_ERR_INTERRUPT) {
        printf("FAIL: expected interrupt, got %d (%s)\n", rc, bk_error(rt));
        failures++;
        return;
    }
    if (strcmp(bk_error(rt), "interrupted") != 0) {
        fail("bk_error is not \"interrupted\"");
    }

    /* A try/catch must not swallow the abort: run the same loop wrapped in
     * one and expect the same status. */
    const char *swallow =
        "try { while(true){} } catch (e) { /* must not run */ }";
    v = bk_eval(rt, swallow, strlen(swallow));
    rc = bk_error_code(rt);
    if (rc != BK_ERR_INTERRUPT) {
        printf("FAIL: catch swallowed the interrupt (%d, %s)\n",
               rc, bk_error(rt));
        failures++;
        return;
    }

    /* The runtime must remain usable: a plain eval succeeds. */
    v = bk_eval(rt, "1+1", 3);
    rc = bk_error_code(rt);
    if (!expect_ok(rc, rt, "runtime not usable after interrupt")) return;
    double d = 0.0;
    bk_read_number(rt, v, &d);
    bk_free(rt, v);
    if (d != 2.0) { fail("1+1 after interrupt is not 2"); return; }

    /* A finally block still runs during the unwind; script must not resume
     * after it. */
    const char *fin =
        "var seen = 0; try { while(true){} } finally { seen = 1; } ";
    v = bk_eval(rt, fin, strlen(fin));
    rc = bk_error_code(rt);
    if (rc != BK_ERR_INTERRUPT) {
        printf("FAIL: interrupt with finally (%d, %s)\n", rc, bk_error(rt));
        failures++;
        return;
    }
    v = bk_eval(rt, "seen", 4);
    rc = bk_error_code(rt);
    if (!expect_ok(rc, rt, "finally did not run during interrupt")) return;
    bk_read_number(rt, v, &d);
    bk_free(rt, v);
    if (d != 1.0) { fail("finally did not run during interrupt"); return; }

    /* A fresh eval starts with a clean budget: no unprompted callback. */
    g_polls = 0;
    v = bk_eval(rt, "40+2", 4);
    rc = bk_error_code(rt);
    if (!expect_ok(rc, rt, "eval after interrupt")) return;
    bk_free(rt, v);
    if (g_polls != 0) {
        printf("FAIL: fresh eval polled the handler %ld times\n", (long)g_polls);
        failures++;
    }

    /* Clearing the handler works and leaves the runtime fully plain. */
    const char *boom = "throw new Error('boom')";
    v = bk_eval(rt, boom, strlen(boom));
    rc = bk_error_code(rt);
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
    if (!(obj = expect_val(bk_object(rt), rt, "new_object"))) return;
    if (!(host = expect_val(bk_string(rt, "example.com", 11), rt, "new_string"))) return;
    if (!expect_ok(bk_set(rt, obj, "host", 4, host), rt, "set_prop host")) return;
    if (!(port = expect_val(bk_number(rt, 8080), rt, "new_number"))) return;
    if (!expect_ok(bk_set(rt, obj, "port", 4, port), rt, "set_prop port")) return;
    if (!(arr = expect_val(bk_array(rt), rt, "new_array"))) return;
    if (!(s1 = expect_val(bk_string(rt, "fast", 4), rt, "new_string s1"))) return;
    if (!(s2 = expect_val(bk_string(rt, "strict", 6), rt, "new_string s2"))) return;
    if (!expect_ok(bk_set_index(rt, arr, 0, s1), rt, "set_prop_index 0")) return;
    if (!expect_ok(bk_set_index(rt, arr, 1, s2), rt, "set_prop_index 1")) return;
    if (!expect_ok(bk_set(rt, obj, "opts", 4, arr), rt, "set_prop opts")) return;
    bk_free(rt, host);
    bk_free(rt, port);
    bk_free(rt, s1);
    bk_free(rt, s2);
    bk_free(rt, arr);

    /* Hand the object to JS: config.port must read 8080 from C's object. */
    bk_value g;
    if (!(g = expect_val(bk_global(rt), rt, "get_global"))) { bk_free(rt, obj); return; }
    if (!expect_ok(bk_set(rt, g, "config", 6, obj), rt, "bind global config")) { bk_free(rt, g); bk_free(rt, obj); return; }
    if ((v = bk_eval(rt, "config.port", 11))) {
        double d = 0; bk_read_number(rt, v, &d); bk_free(rt, v);
        if (d != 8080.0) { printf("FAIL: config.port = %.0f\n", d); failures++; }
    } else {
        printf("FAIL: eval config.port: %s\n", bk_error(rt)); failures++;
    }
    if ((v = bk_eval(rt, "config.opts[1]", 14))) {
        char buf[64]; size_t got = 0;
        if (bk_read_string(rt, v, buf, sizeof buf, &got) == BK_OK) {
            if (strcmp(buf, "strict") != 0) { printf("FAIL: config.opts[1]=%s\n", buf); failures++; }
        } else { fail("get_string config.opts[1]"); }
        bk_free(rt, v);
    } else { printf("FAIL: eval config.opts[1]: %s\n", bk_error(rt)); failures++; }

    /* Read properties back from C: obj.host, obj.port, obj.opts[0]. */
    bk_value p = 0;
    if ((p = bk_get(rt, obj, "host", 4))) {
        char buf[64]; size_t got = 0;
        if (bk_read_string(rt, p, buf, sizeof buf, &got) == BK_OK) {
            if (strcmp(buf, "example.com") != 0) { printf("FAIL: obj.host=%s\n", buf); failures++; }
        } else fail("get_string obj.host");
        bk_free(rt, p);
    } else { printf("FAIL: get_prop host: %s\n", bk_error(rt)); failures++; }

    /* bk_has on present and absent keys. */
    int has = -1;
    if (bk_has(rt, obj, "port", 4, &has) == BK_OK && has == 1 &&
        bk_has(rt, obj, "nope", 4, &has) == BK_OK && has == 0) {
        /* ok */
    } else { fail("has_prop present/absent"); }

    /* A missing property reads as undefined, not an error. */
    if ((p = bk_get(rt, obj, "missing", 7))) {
        if (bk_type_of(rt, p) != BK_TYPE_UNDEFINED) { fail("missing prop not undefined"); }
        bk_free(rt, p);
    } else { fail("get_prop missing"); }

    bk_free(rt, g);
    bk_free(rt, obj);
}

/* delete own property (succeeds), a prototype property (reports absent), and
 * a non-configurable own property (throws). */
static void test_delete(bk_ctx rt) {
    bk_value obj = 0, v = 0;
    if (!(v = bk_eval(rt, "var d={a:1}; Object.defineProperty(d,'c',{configurable:false}); d", strlen("var d={a:1}; Object.defineProperty(d,'c',{configurable:false}); d")))) {
        printf("FAIL: eval delete setup: %s\n", bk_error(rt)); failures++; return;
    }
    obj = v;
    int out = -1;
    if (bk_delete(rt, obj, "a", 1, &out) != BK_OK || out != 1) {
        printf("FAIL: delete own prop (out=%d)\n", out); failures++;
    }
    out = -1;
    if (bk_delete(rt, obj, "b", 1, &out) != BK_OK || out != 0) {
        printf("FAIL: delete absent prop (out=%d)\n", out); failures++;
    }
    if (bk_delete(rt, obj, "c", 1, &out) != BK_ERR_THROW) {
        printf("FAIL: delete non-configurable should throw (%s)\n", bk_error(rt)); failures++;
    }
    /* Proxy whose get trap throws must surface as BK_ERR_THROW, not crash. */
    bk_value px = 0;
    if ((px = bk_eval(rt, "new Proxy({}, { get(){ throw new Error('boom'); } })", strlen("new Proxy({}, { get(){ throw new Error('boom'); } })")))) {
        bk_value got = 0;
        got = bk_get(rt, px, "x", 1);
        if (got || bk_error_code(rt) != BK_ERR_THROW) {
            printf("FAIL: proxy get trap did not throw\n"); failures++;
        }
        if (strcmp(bk_error(rt), "Error: boom") != 0) {
            printf("FAIL: proxy error msg=%s\n", bk_error(rt)); failures++;
        }
        bk_free(rt, px);
    } else { printf("FAIL: eval proxy: %s\n", bk_error(rt)); failures++; }
    bk_free(rt, obj);
}

/* Enumeration: an own non-enumerable key appears alongside own enumerable. */
static void test_enumeration(bk_ctx rt) {
    bk_value obj = 0, keys = 0, k = 0;
    if (!(obj = bk_eval(rt, "var e={a:1}; Object.defineProperty(e,'h',{value:2,enumerable:false}); e", strlen("var e={a:1}; Object.defineProperty(e,'h',{value:2,enumerable:false}); e")))) {
        printf("FAIL: eval enum setup: %s\n", bk_error(rt)); failures++; return;
    }
    if (!(keys = bk_keys(rt, obj))) {
        printf("FAIL: own_prop_names: %s\n", bk_error(rt)); failures++; bk_free(rt, obj); return;
    }
    double n = 0;
    bk_value lenv;
    if ((lenv = bk_get(rt, keys, "length", 6))) {
        bk_read_number(rt, lenv, &n); bk_free(rt, lenv);
    }
    if (n < 2.0) { printf("FAIL: own names length %.0f\n", n); failures++; }
    int has_a = 0, has_h = 0;
    for (int i = 0; i < (int)n; i++) {
        char buf[64]; size_t got = 0;
        if ((k = bk_get_index(rt, keys, (unsigned)i))) {
            if (bk_read_string(rt, k, buf, sizeof buf, &got) == BK_OK) {
                if (strcmp(buf, "a") == 0) has_a = 1;
                if (strcmp(buf, "h") == 0) has_h = 1;
            }
            bk_free(rt, k);
        }
    }
    if (!has_a || !has_h) {
        printf("FAIL: own names a=%d h=%d\n", has_a, has_h); failures++;
    }
    bk_free(rt, keys);
    bk_free(rt, obj);
}

/* Host-side calls: define add(), call it from C; call a host function too. */
static int g_called = 0;
static void doubled(bk_ctx ctx, void *udata) {
    (void)udata;
    g_called++;
    double d = 0.0;
    bk_read_number(ctx, bk_arg(ctx, 0), &d);
    bk_return_number(ctx, d * 2.0);
}

static void test_call_rt(bk_ctx rt) {
    bk_value fn = 0, a = 0, b = 0, out = 0;
    if (!(fn = bk_eval(rt, "function add(a,b){return a+b;} add", strlen("function add(a,b){return a+b;} add")))) {
        printf("FAIL: eval add: %s\n", bk_error(rt)); failures++; return;
    }
    a = bk_number(rt, 2.0);
    b = bk_number(rt, 40.0);
    bk_value argv[2] = { a, b };
    if (!(out = bk_call(rt, fn, 0, argv, 2))) {
        printf("FAIL: call_rt add: %s\n", bk_error(rt)); failures++;
    } else {
        double d = 0; bk_read_number(rt, out, &d); bk_free(rt, out);
        if (d != 42.0) { printf("FAIL: add(2,40)=%.0f\n", d); failures++; }
    }
    bk_free(rt, a); bk_free(rt, b); bk_free(rt, fn);
    a = b = fn = 0;

    /* Host-registered function called via bk_call (fresh call context). */
    if (bk_register_fn(rt, 0, "ans", doubled, 0, 0u, NULL) != BK_OK) {
        printf("FAIL: register ans: %s\n", bk_error(rt)); failures++;
    }
    if ((fn = bk_eval(rt, "ans(21)", 7))) {
        double d = 0; bk_read_number(rt, fn, &d); bk_free(rt, fn);
        if (g_called != 1 || d != 42.0) { printf("FAIL: ans via eval (%d, %.0f)\n", g_called, d); failures++; }
    } else { printf("FAIL: eval ans(21): %s\n", bk_error(rt)); failures++; }

    g_called = 0;
    bk_value gh = 0;
    if (!(gh = bk_global(rt))) { fail("get_global for ans call"); }
    if (!(fn = bk_get(rt, gh, "ans", 3))) { fail("get_prop ans"); }
    bk_value one = bk_number(rt, 100.0);
    bk_value argv2[1] = { one };
    if (!(out = bk_call(rt, fn, 0, argv2, 1))) {
        printf("FAIL: host fn via call_rt: %s\n", bk_error(rt)); failures++;
    } else {
        double d = 0; bk_read_number(rt, out, &d); bk_free(rt, out);
        if (d != 200.0) { printf("FAIL: doubled(100)=%.0f\n", d); failures++; }
    }
    if (g_called != 1) { printf("FAIL: host fn not called via call_rt\n"); failures++; }
    bk_free(rt, one); bk_free(rt, fn); bk_free(rt, gh);
}

/* Source locations: script name + line/col on a syntax error; a runtime throw
 * reports its kind even without a resolved line. */
static void test_locations(bk_ctx rt) {
    bk_value v;
    bk_error_info info;

    const char *bad = "var x = ;";
    if ((bk_eval_named(rt, bad, strlen(bad), "foo.js", 6)) || bk_error_code(rt) != BK_ERR_SYNTAX) {
        printf("FAIL: bad source not BK_ERR_SYNTAX (%s)\n", bk_error(rt)); failures++;
    }
    memset(&info, 0, sizeof info);
    if (bk_error_info_of(rt, &info) != BK_OK) { fail("last_error_info"); }
    if (info.code != BK_ERR_SYNTAX || info.line != 1 || info.col != 10) {
        printf("FAIL: syntax loc code=%d line=%d col=%d\n", info.code, info.line, info.col); failures++;
    }
    if (!info.script_name || strcmp(info.script_name, "foo.js") != 0) {
        printf("FAIL: script_name=%s\n", info.script_name ? info.script_name : "(null)"); failures++;
    }
    if (!(v = expect_val(bk_eval(rt, "1", 1), rt, "reuse after syntax error"))) return;

    const char *bad2 = "var a = 1;\nvar b = ;";
    if ((bk_eval_named(rt, bad2, strlen(bad2), "two.js", 6)) || bk_error_code(rt) != BK_ERR_SYNTAX) {
        fail("bad2 not syntax"); failures++;
    }
    memset(&info, 0, sizeof info);
    bk_error_info_of(rt, &info);
    if (info.line != 2 || info.col != 10) {
        printf("FAIL: multi-line loc line=%d col=%d\n", info.line, info.col); failures++;
    }
    if (!(v = expect_val(bk_eval(rt, "1", 1), rt, "reuse after multi-line error"))) return;

    /* A runtime throw reports BK_ERR_THROW (line unknown for now). */
    const char *rt_src = "throw new TypeError('x')";
    if ((v = bk_eval_named(rt, rt_src, strlen(rt_src), NULL, 0)) ||
        bk_error_code(rt) != BK_ERR_THROW) {
        printf("FAIL: runtime throw not BK_ERR_THROW\n"); failures++;
    }
    memset(&info, 0, sizeof info);
    bk_error_info_of(rt, &info);
    if (info.code != BK_ERR_THROW) {
        printf("FAIL: runtime err code=%d\n", info.code); failures++;
    }
    if (!(v = expect_val(bk_eval(rt, "1", 1), rt, "reuse after runtime throw"))) return;
}

int main(void) {
    bk_ctx rt = NULL;
    if (!(rt = bk_open())) {
        printf("FAIL: bk_open\n");
        return 1;
    }

    test_interrupt(rt);
    test_config(rt);
    test_delete(rt);
    test_enumeration(rt);
    test_call_rt(rt);
    test_locations(rt);

    bk_close(rt);
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("embed_api: all ok\n");
    return 0;
}
