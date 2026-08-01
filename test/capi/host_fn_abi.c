/*
 * Phase 3 tests: host functions across the C ABI.
 *
 * Everything here goes through include/jse.h only -- no engine internals -- so
 * it is also the reference for what a binding author writes. Build and run via
 * `make test-host-abi`.
 */
#include <stdio.h>
#include <string.h>
#include "jse.h"

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

static void h_answer(jse_call_ctx ctx, void *udata) {
    (void)udata;
    host_calls++;
    jse_return_number(ctx, 42);
}

static void h_add(jse_call_ctx ctx, void *udata) {
    (void)udata;
    double sum = 0;
    unsigned int i, n = jse_argc(ctx);
    for (i = 0; i < n; i++) {
        double d;
        if (jse_get_number(NULL, jse_arg(ctx, i), &d) == JSE_OK) sum += d;
    }
    jse_return_number(ctx, sum);
}

/* Reads the udata pointer through, proving passthrough. */
static void h_udata(jse_call_ctx ctx, void *udata) {
    jse_return_number(ctx, udata ? *(int *)udata : -1);
}

/* Returns a host-built string, including an astral character. */
static void h_greet(jse_call_ctx ctx, void *udata) {
    static const char msg[] = "hi from C \xF0\x9F\x98\x80";
    (void)udata;
    jse_return_string(ctx, msg, sizeof(msg) - 1);
}

/* Throws a TypeError. */
static void h_throws(jse_call_ctx ctx, void *udata) {
    (void)udata;
    jse_throw_error(ctx, JSE_ERROR_TYPE, "host refused");
}

/* Echoes argument 0 back, exercising handle round-tripping. */
static void h_echo(jse_call_ctx ctx, void *udata) {
    (void)udata;
    jse_return(ctx, jse_arg(ctx, 0));
}

/* Reports whether it saw a construct call, stashed via the return value. */
static void h_is_new(jse_call_ctx ctx, void *udata) {
    (void)udata;
    if (!jse_is_construct(ctx)) jse_return_bool(ctx, 0);
    /* On `new` the created object is returned automatically. */
}

/* hostApply(f, x) -> f(x): the host calling back into JS. */
static void h_apply(jse_call_ctx ctx, void *udata) {
    jse_value args[1];
    jse_value out = 0;
    (void)udata;
    args[0] = jse_arg(ctx, 1);
    if (jse_call(ctx, jse_arg(ctx, 0), args, 1, 0, &out) != JSE_OK) return;
    jse_return(ctx, out);
}

/* Calls a JS function that throws; the throw must propagate. */
static void h_apply_throwing(jse_call_ctx ctx, void *udata) {
    (void)udata;
    if (jse_call(ctx, jse_arg(ctx, 0), NULL, 0, 0, NULL) != JSE_OK) return;
    jse_return_number(ctx, 0);
}

/* --- harness ------------------------------------------------------------- */

/* Evaluate `src`, expecting a number equal to `want`. */
static void eval_num(jse_runtime rt, const char *label, const char *src, double want) {
    jse_value v = 0;
    double got = 0;
    int rc = jse_eval(rt, src, strlen(src), &v);
    if (rc != JSE_OK) {
        printf("FAIL %s: status %d (%s)\n", label, rc, jse_last_error(rt));
        failures++;
        return;
    }
    if (jse_get_number(rt, v, &got) != JSE_OK) {
        printf("FAIL %s: not a number\n", label);
        failures++;
        jse_value_free(rt, v);
        return;
    }
    check(label, got == want);
    jse_value_free(rt, v);
}

int main(void) {
    jse_runtime rt = NULL;
    int udata_val = 99;

    if (jse_open(&rt) != JSE_OK) {
        fprintf(stderr, "jse_open failed\n");
        return 1;
    }

    if (jse_register_fn(rt, "hostAnswer", 10, h_answer, NULL, 0, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostAdd", 7, h_add, NULL, 2, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostUdata", 9, h_udata, &udata_val, 0, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostGreet", 9, h_greet, NULL, 0, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostThrows", 10, h_throws, NULL, 0, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostEcho", 8, h_echo, NULL, 1, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "HostIsNew", 9, h_is_new, NULL, 0, 1) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostApply", 9, h_apply, NULL, 2, 0) != JSE_OK) return 1;
    if (jse_register_fn(rt, "hostApplyThrowing", 17, h_apply_throwing, NULL, 1, 0) != JSE_OK) return 1;

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

    printf("\nhost callbacks dispatched: %d\n", host_calls);
    jse_close(rt);

    if (failures) {
        printf("FAILURES: %d\n", failures);
        return 1;
    }
    printf("all host-function ABI tests passed\n");
    return 0;
}
