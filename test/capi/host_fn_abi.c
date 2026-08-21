/*
 * Phase 3 tests: host functions across the C ABI.
 *
 * Everything here goes through include/boomkat.h only -- no engine internals -- so
 * it is also the reference for what a binding author writes. Build and run via
 * `make test-host-abi`.
 */
#include <stdio.h>
#include <string.h>
#include "boomkat.h"

static int failures;
static int host_calls;

static void check(const char *label, int cond) {
    if (cond) {
        printf("ok   %s\n", label);
    } else {
        printf("FAIL %s\n", label);
        failures++;
    }
}

/* --- host functions under test ------------------------------------------ */

static void h_answer(bk_call_ctx ctx, void *udata) {
    (void)udata;
    host_calls++;
    bk_return_number(ctx, 42);
}

static void h_add(bk_call_ctx ctx, void *udata) {
    (void)udata;
    double sum = 0;
    unsigned int i, n = bk_argc(ctx);
    for (i = 0; i < n; i++) {
        double d;
        if (bk_ctx_get_number(ctx, bk_arg(ctx, i), &d) == BK_OK) sum += d;
    }
    bk_return_number(ctx, sum);
}

/* Reads the udata pointer through, proving passthrough. */
static void h_udata(bk_call_ctx ctx, void *udata) {
    bk_return_number(ctx, udata ? *(int *)udata : -1);
}

/* Returns a host-built string, including an astral character. */
static void h_greet(bk_call_ctx ctx, void *udata) {
    static const char msg[] = "hi from C \xF0\x9F\x98\x80";
    (void)udata;
    bk_return_string(ctx, msg, sizeof(msg) - 1);
}

/* Throws a TypeError. */
static void h_throws(bk_call_ctx ctx, void *udata) {
    (void)udata;
    bk_throw_error(ctx, BK_ERROR_TYPE, "host refused");
}

/* Echoes argument 0 back, exercising handle round-tripping. */
static void h_echo(bk_call_ctx ctx, void *udata) {
    (void)udata;
    bk_return(ctx, bk_arg(ctx, 0));
}

/* Reports whether it saw a construct call, stashed via the return value. */
static void h_is_new(bk_call_ctx ctx, void *udata) {
    (void)udata;
    if (!bk_is_construct(ctx)) bk_return_bool(ctx, 0);
    /* On `new` the created object is returned automatically. */
}

/* hostApply(f, x) -> f(x): the host calling back into JS. */
static void h_apply(bk_call_ctx ctx, void *udata) {
    bk_value args[1];
    bk_value out = 0;
    (void)udata;
    args[0] = bk_arg(ctx, 1);
    if (bk_call(ctx, bk_arg(ctx, 0), args, 1, 0, &out) != BK_OK) return;
    bk_return(ctx, out);
}

/* Calls a JS function that throws; the throw must propagate. */
static void h_apply_throwing(bk_call_ctx ctx, void *udata) {
    (void)udata;
    if (bk_call(ctx, bk_arg(ctx, 0), NULL, 0, 0, NULL) != BK_OK) return;
    bk_return_number(ctx, 0);
}

/* --- harness ------------------------------------------------------------- */

/* Evaluate `src`, expecting a number equal to `want`. */
static void eval_num(bk_runtime rt, const char *label, const char *src, double want) {
    bk_value v = 0;
    double got = 0;
    int rc = bk_eval(rt, src, strlen(src), &v);
    if (rc != BK_OK) {
        printf("FAIL %s: status %d (%s)\n", label, rc, bk_last_error(rt));
        failures++;
        return;
    }
    if (bk_get_number(rt, v, &got) != BK_OK) {
        printf("FAIL %s: not a number\n", label);
        failures++;
        bk_value_free(rt, v);
        return;
    }
    check(label, got == want);
    bk_value_free(rt, v);
}

/* --- value registry ------------------------------------------------------
 *
 * The registry grows on demand; there is no fixed slot cap. These cover the
 * three properties a host depends on: many handles live at once, each keeps
 * its OWN value, and a handle to a freed slot is rejected rather than
 * silently resolved to whatever landed there next.
 */

#define MANY 5000

static void test_many_live_handles(bk_runtime rt) {
    static bk_value h[MANY];
    int i, made = 0, wrong = 0, scope_bit = 0;

    for (i = 0; i < MANY; i++) {
        char src[64];
        snprintf(src, sizeof src, "%d", i);
        if (bk_eval(rt, src, strlen(src), &h[i]) != BK_OK) break;
        /* Bit 31 is reserved for scope handles; a global id must never set it. */
        if (h[i] & 0x80000000u) scope_bit++;
        made++;
    }
    check("5000 live handles allocated", made == MANY);
    check("no global id collides with the scope bit", scope_bit == 0);

    /* Each handle must still read back its own distinct value. */
    for (i = 0; i < made; i++) {
        double d = -1;
        if (bk_get_number(rt, h[i], &d) != BK_OK || d != (double)i) wrong++;
    }
    check("each of 5000 handles reads back its own value", wrong == 0);

    for (i = 0; i < made; i++) bk_value_free(rt, h[i]);
}

static void test_stale_handle_rejected(bk_runtime rt) {
    bk_value a, b;
    double d;
    int i, resolved = 0;
    bk_value reuse[64];

    if (bk_eval(rt, "111", 3, &a) != BK_OK) { check("stale: setup", 0); return; }
    bk_value_free(rt, a);

    /* Force the freed index to be handed out again. */
    for (i = 0; i < 64; i++) {
        char src[32];
        snprintf(src, sizeof src, "%d", 900 + i);
        if (bk_eval(rt, src, strlen(src), &reuse[i]) != BK_OK) reuse[i] = 0;
    }

    /* The stale handle must be rejected -- never resolved to a new occupant. */
    d = -1;
    check("stale handle is rejected", bk_get_number(rt, a, &d) != BK_OK);
    check("stale handle yields no value", d == -1);
    check("stale handle reports invalid", bk_type_of(rt, a) == BK_TYPE_UNDEFINED);

    for (i = 0; i < 64; i++) {
        if (reuse[i] && bk_get_number(rt, reuse[i], &d) == BK_OK && d == (double)(900 + i)) resolved++;
    }
    check("reused slots resolve to their own new values", resolved == 64);

    /* Double free must not corrupt the free list. */
    bk_value_free(rt, a);
    bk_value_free(rt, a);
    if (bk_eval(rt, "222", 3, &b) == BK_OK) {
        check("registry usable after double free", bk_get_number(rt, b, &d) == BK_OK && d == 222);
        bk_value_free(rt, b);
    } else {
        check("registry usable after double free", 0);
    }
    for (i = 0; i < 64; i++) if (reuse[i]) bk_value_free(rt, reuse[i]);
}

/* A handle freed once must stay rejected no matter how many alloc/free cycles
 * follow. The generation counter is finite, so a slot that runs out of distinct
 * generations has to be retired rather than recycled: without that, the counter
 * returns to a value the stale handle still carries and the two become
 * bit-identical, which resolves silently to an unrelated value.
 *
 * The loop must run well past the generation space (32767) to prove anything.
 * A shorter run passes even when the counter does wrap. */
static void test_stale_handle_never_resolves(bk_runtime rt) {
    bk_value stale;
    long i, cycles = 200000;
    int leaked = 0;

    if (bk_eval(rt, "111", 3, &stale) != BK_OK) {
        check("stale handle never resolves", 0);
        return;
    }
    bk_value_free(rt, stale);

    for (i = 0; i < cycles; i++) {
        bk_value t;
        double g;
        char s[32];
        snprintf(s, sizeof s, "%ld", 1000000 + i);
        if (bk_eval(rt, s, strlen(s), &t) != BK_OK) { leaked = -1; break; }
        if (bk_get_number(rt, stale, &g) == BK_OK) { leaked = 1; bk_value_free(rt, t); break; }
        bk_value_free(rt, t);
    }
    check("stale handle never resolves across generation wrap", leaked == 0);
}

/* bk_get_string's two-call protocol. The conversion sink counts every byte it
 * produces, including those past the buffer, so a short buffer still reports the
 * true size. The sink state is per-call and lives on bk_get_string's stack, so
 * one call cannot disturb another. */
static void test_string_sink(bk_runtime rt) {
    bk_value v, v2;
    size_t need = 0, need2 = 0, got = 0, n2 = 0;
    char small[4], big[256], b2[64];
    const char *src = "'hi \\u{1F600} there'";
    const char *s2 = "'second'";

    if (bk_eval(rt, src, strlen(src), &v) != BK_OK) {
        check("string sink: eval", 0);
        return;
    }
    check("sizing call reports a length",
          bk_get_string(rt, v, NULL, 0, &need) == BK_OK && need > 0);
    check("short buffer fails but reports the true size",
          bk_get_string(rt, v, small, sizeof small, &need2) != BK_OK && need2 == need);
    check("full copy matches the sized length",
          bk_get_string(rt, v, big, sizeof big, &got) == BK_OK && got == need);

    if (bk_eval(rt, s2, strlen(s2), &v2) == BK_OK) {
        bk_get_string(rt, v2, b2, sizeof b2, &n2);
        check("a later call is not disturbed by an earlier one",
              n2 == 6 && strcmp(b2, "second") == 0);
        bk_value_free(rt, v2);
    }
    bk_value_free(rt, v);
}

static void test_churn(bk_runtime rt) {
    int i, bad = 0;
    /* Allocate and free far past the old 1024 cap and past the point where a
     * leaked shape slot per free used to exhaust the engine. */
    for (i = 0; i < 200000; i++) {
        bk_value v;
        double d;
        if (bk_eval(rt, "7", 1, &v) != BK_OK) { bad = 1; break; }
        if (bk_get_number(rt, v, &d) != BK_OK || d != 7) { bad = 1; break; }
        bk_value_free(rt, v);
    }
    check("200k alloc/free cycles stay correct", bad == 0);
}

static void test_handles_survive_gc(bk_runtime rt) {
    bk_value held[256];
    bk_value junk;
    int i, wrong = 0;
    char buf[64];
    static const char *CHURN =
        "var s = 0; for (var i = 0; i < 20000; i++) { s += ({ x: i }).x; } s";

    /* Strings, not primitives: these are heap values, so only a real GC root
     * keeps them alive across a collection. */
    for (i = 0; i < 256; i++) {
        snprintf(buf, sizeof buf, "'held-%d'", i);
        if (bk_eval(rt, buf, strlen(buf), &held[i]) != BK_OK) held[i] = 0;
    }
    /* Churn the heap so a collection runs with the handles outstanding. */
    if (bk_eval(rt, CHURN, strlen(CHURN), &junk) == BK_OK) bk_value_free(rt, junk);

    for (i = 0; i < 256; i++) {
        char got[64];
        size_t n = 0;
        snprintf(buf, sizeof buf, "held-%d", i);
        if (!held[i]) { wrong++; continue; }
        if (bk_get_string(rt, held[i], got, sizeof got, &n) != BK_OK) { wrong++; continue; }
        if (strcmp(got, buf) != 0) wrong++;
    }
    check("host-held values survive GC", wrong == 0);
    for (i = 0; i < 256; i++) if (held[i]) bk_value_free(rt, held[i]);
}

int main(void) {
    bk_runtime rt = NULL;
    int udata_val = 99;

    if (bk_open(&rt) != BK_OK) {
        fprintf(stderr, "bk_open failed\n");
        return 1;
    }

    if (bk_register_fn(rt, "hostAnswer", 10, h_answer, NULL, 0, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostAdd", 7, h_add, NULL, 2, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostUdata", 9, h_udata, &udata_val, 0, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostGreet", 9, h_greet, NULL, 0, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostThrows", 10, h_throws, NULL, 0, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostEcho", 8, h_echo, NULL, 1, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "HostIsNew", 9, h_is_new, NULL, 0, 1) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostApply", 9, h_apply, NULL, 2, 0) != BK_OK) return 1;
    if (bk_register_fn(rt, "hostApplyThrowing", 17, h_apply_throwing, NULL, 1, 0) != BK_OK) return 1;

    /* dispatch shapes */
    eval_num(rt, "plain call", "hostAnswer()", 42);
    eval_num(rt, "typeof", "typeof hostAnswer === 'function' ? 1 : 0", 1);
    eval_num(rt, "arguments", "hostAdd(40, 2)", 42);
    eval_num(rt, "argc varies", "hostAdd(1,2,3,4,5,6,7,8,9)", 45);
    eval_num(rt, "missing args", "hostAdd()", 0);
    eval_num(rt, ".call", "hostAdd.call(null, 40, 2)", 42);
    eval_num(rt, ".apply", "hostAdd.apply(null, [40, 2])", 42);
    eval_num(rt, ".bind", "hostAdd.bind(null, 40)(2)", 42);
    eval_num(rt, "as a method", "({m: hostAnswer}).m()", 42);
    eval_num(rt, "as a getter",
             "var o = {}; Object.defineProperty(o, 'p', {get: hostAnswer}); o.p", 42);
    eval_num(rt, "builtin callback", "[3,1,2].map(hostAnswer).join(',') === '42,42,42' ? 1 : 0", 1);
    eval_num(rt, ".name", "hostAdd.name === 'hostAdd' ? 1 : 0", 1);
    eval_num(rt, ".length", "hostAdd.length", 2);

    /* udata and strings */
    eval_num(rt, "udata passthrough", "hostUdata()", 99);
    eval_num(rt, "host string", "hostGreet().indexOf('hi from C') === 0 ? 1 : 0", 1);
    eval_num(rt, "astral survives", "hostGreet().charCodeAt(10) === 0xD83D ? 1 : 0", 1);

    /* handle round-tripping */
    eval_num(rt, "echo number", "hostEcho(42)", 42);
    eval_num(rt, "echo string", "hostEcho('x') === 'x' ? 1 : 0", 1);
    eval_num(rt, "echo null", "hostEcho(null) === null ? 1 : 0", 1);
    eval_num(rt, "echo undefined", "hostEcho(undefined) === undefined ? 1 : 0", 1);
    eval_num(rt, "echo object identity", "var o = {}; hostEcho(o) === o ? 1 : 0", 1);

    /* throwing */
    eval_num(rt, "host throw kind",
             "var k = 0; try { hostThrows(); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);
    eval_num(rt, "host throw message",
             "var m = ''; try { hostThrows(); } catch (e) { m = e.message; } m === 'host refused' ? 1 : 0", 1);
    eval_num(rt, "engine survives throw", "hostAdd(20, 22)", 42);

    /* construct */
    eval_num(rt, "new on non-ctor throws",
             "var k = 0; try { new hostAdd(); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);
    eval_num(rt, "new on ctor yields object",
             "typeof new HostIsNew() === 'object' ? 1 : 0", 1);

    /* host calling JS */
    eval_num(rt, "host calls JS", "hostApply(function (x) { return x * 2; }, 21)", 42);
    eval_num(rt, "host calls arrow", "hostApply(x => x + 40, 2)", 42);
    eval_num(rt, "host calls builtin", "hostApply(Math.abs, -42)", 42);
    eval_num(rt, "callee throw propagates",
             "var k = 0; try { hostApplyThrowing(function () { throw new RangeError('x'); }); }"
             " catch (e) { k = (e instanceof RangeError) ? 1 : 0; } k", 1);
    eval_num(rt, "call non-function throws",
             "var k = 0; try { hostApply(42, 1); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);
    eval_num(rt, "runaway host recursion throws",
             "var k = 0; try { hostApply(function f(n) { return hostApply(f, n); }, 1); }"
             " catch (e) { k = 1; } k", 1);
    eval_num(rt, "engine usable after recursion", "hostAdd(21, 21)", 42);

    /* value registry */
    test_many_live_handles(rt);
    test_stale_handle_rejected(rt);
    test_string_sink(rt);
    test_churn(rt);
    test_stale_handle_never_resolves(rt);
    test_handles_survive_gc(rt);

    printf("\nhost callbacks dispatched: %d\n", host_calls);
    bk_close(rt);

    if (failures) {
        printf("FAILURES: %d\n", failures);
        return 1;
    }
    printf("all host-function ABI tests passed\n");
    return 0;
}
