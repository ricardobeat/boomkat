/*
 * host_fn.c — exposing C functions to JavaScript from plain C99.
 *
 * Where main.c drives JS from C, this goes the other way: it registers C
 * callbacks as JS globals and lets a script call them. It covers the four
 * things a real embedder needs:
 *
 *   1. udata          — reaching host state from a callback without globals
 *   2. arguments      — reading them out, returning a host-built string
 *   3. throwing       — a C callback raising a TypeError that JS catches
 *   4. bk_call       — a C callback invoking a JS function passed to it
 *
 * Build and run with `make run-host-fn` (see README.md).
 */

#include "bk_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Host state. The engine passes `udata` back to every invocation untouched and
 * never dereferences it, so this is how a callback reaches its embedder
 * without a file-scope global.
 */
typedef struct {
    const char *app_name;
    int         calls;
} host_state;

/*
 * greet(name) -> string
 *
 * Reads one argument and returns a string the host built.
 *
 * Two details worth copying. First, bk_ctx_get_string uses the same two-call
 * measure-then-fill protocol as everywhere else in the ABI, so the engine
 * never hands back memory to free. Second, it is the CONTEXT-tier reader: a
 * callback holds a bk_call_ctx, and only that tier resolves the scope handles
 * bk_arg hands out. bk_ctx_runtime(ctx) reaches the runtime when one is
 * genuinely needed.
 */
static void h_greet(bk_call_ctx ctx, void *udata)
{
    host_state *st = (host_state *)udata;
    char        name[64];
    char        out[128];
    size_t      len = 0;

    st->calls++;

    /* Missing arguments arrive as undefined, not as an invalid handle. */
    if (bk_argc(ctx) < 1) {
        bk_throw_error(ctx, BK_ERROR_TYPE, "greet() needs a name");
        return;
    }

    /* Strict readers: a non-string argument is a type error, not a coercion. */
    if (bk_ctx_get_string(ctx, bk_arg(ctx, 0), name, sizeof(name), &len) != BK_OK) {
        bk_throw_error(ctx, BK_ERROR_TYPE, "greet() wants a string");
        return;
    }

    snprintf(out, sizeof(out), "hello %s, from %s", name, st->app_name);
    bk_return_string(ctx, out, strlen(out));
}

/*
 * divide(a, b) -> number
 *
 * Throws when asked to divide by zero. bk_throw_error does NOT unwind: it
 * records the throw and returns normally, so the callback must return under
 * its own power. A recorded throw beats any return value set in the same call,
 * but returning early keeps the intent obvious.
 */
static void h_divide(bk_call_ctx ctx, void *udata)
{
    double a = 0.0, b = 0.0;

    (void)udata;

    if (bk_ctx_get_number(ctx, bk_arg(ctx, 0), &a) != BK_OK ||
        bk_ctx_get_number(ctx, bk_arg(ctx, 1), &b) != BK_OK) {
        bk_throw_error(ctx, BK_ERROR_TYPE, "divide() wants two numbers");
        return;
    }
    if (b == 0.0) {
        bk_throw_error(ctx, BK_ERROR_RANGE, "division by zero");
        return;
    }
    bk_return_number(ctx, a / b);
}

/*
 * mapTwice(fn, x) -> fn(fn(x))
 *
 * The host calling back into JS. bk_call runs a JS function from inside a
 * callback; the handle it writes to out_val is runtime-owned and must be
 * freed, unlike the scope handles from bk_arg. Freeing it needs the runtime
 * that owns it, which bk_ctx_runtime(ctx) supplies — a handle names a slot in
 * one specific runtime's registry, so there is no runtime-agnostic free.
 *
 * If the callee throws, bk_call returns BK_ERR_THROW with the exception
 * already recorded on this context. The right move is to return promptly and
 * let the engine propagate it — which is what the early returns below do.
 *
 * Host recursion is bounded, so a callback that re-enters JS forever gets a
 * RangeError rather than a smashed native stack.
 */
static void h_map_twice(bk_call_ctx ctx, void *udata)
{
    bk_runtime rt = bk_ctx_runtime(ctx);
    bk_value fn   = bk_arg(ctx, 0);
    bk_value once = 0;
    bk_value twice = 0;
    bk_value args[1];

    (void)udata;

    args[0] = bk_arg(ctx, 1);
    if (bk_call(ctx, fn, args, 1, 0, &once) != BK_OK) {
        return; /* the callee's exception is already recorded */
    }

    args[0] = once;
    if (bk_call(ctx, fn, args, 1, 0, &twice) != BK_OK) {
        bk_value_free(rt, once);
        return;
    }

    bk_return(ctx, twice);

    /*
     * Both handles came from bk_call, so both are ours to release. Freeing
     * `twice` after handing it to bk_return is safe: the return value has
     * already been recorded on the context by then.
     */
    bk_value_free(rt, once);
    bk_value_free(rt, twice);
}

/* Evaluate `src`, print `label = result`, and report any failure. */
static int show(bk_runtime rt, const char *label, const char *src)
{
    char *text = bku_eval_to_string(rt, src);

    if (text == NULL) {
        printf("%-16s ! %s\n", label, bk_last_error(rt));
        free(text);
        return 0;
    }
    printf("%-16s = %s\n", label, text);
    free(text);
    return 1;
}

int main(void)
{
    bk_runtime rt = NULL;
    host_state  st;
    int         status;

    st.app_name = "c99-example";
    st.calls    = 0;

    status = bk_open(&rt);
    if (status != BK_OK) {
        fprintf(stderr, "bk_open failed: %s\n", bku_status_name(status));
        return EXIT_FAILURE;
    }
    printf("boomkat version %s\n\n", bk_version());

    /*
     * ------------------------------------------------------ 1. registration
     *
     * Each call binds a C function as a JS global. `arity` becomes the
     * function's .length; the trailing 0 means it is not constructable, so
     * `new greet()` throws a TypeError. Registration lasts the runtime's
     * lifetime. Note the explicit name lengths — the ABI takes UTF-8 bytes
     * plus a length rather than assuming NUL termination.
     */
    if (bk_register_fn(rt, "greet", 5, h_greet, &st, 1, 0) != BK_OK ||
        bk_register_fn(rt, "divide", 6, h_divide, NULL, 2, 0) != BK_OK ||
        bk_register_fn(rt, "mapTwice", 8, h_map_twice, NULL, 2, 0) != BK_OK) {
        fprintf(stderr, "registration failed: %s\n", bk_last_error(rt));
        bk_close(rt);
        return EXIT_FAILURE;
    }

    /*
     * -------------------------------------------- 2. arguments and returns
     *
     * A host function is an ordinary JS function object, so it works
     * everywhere one does: called directly, or handed to a built-in.
     */
    printf("host functions called from JS:\n");
    show(rt, "  greet", "greet('world')");
    show(rt, "  via map", "['ada', 'alan'].map(greet).join(' / ')");
    show(rt, "  divide", "divide(84, 2)");
    show(rt, "  .length", "greet.length + ', ' + divide.length");

    /*
     * ------------------------------------------------ 3. throwing from C
     *
     * The throw crosses into JS as a real Error object, so an ordinary
     * try/catch sees it with the right constructor and message.
     */
    printf("\nerrors thrown by C, caught by JS:\n");
    show(rt, "  by zero",
         "(function () { try { divide(1, 0); }"
         " catch (e) { return e.constructor.name + ': ' + e.message; } })()");
    show(rt, "  wrong type",
         "(function () { try { greet(42); }"
         " catch (e) { return e.constructor.name + ': ' + e.message; } })()");
    show(rt, "  not a ctor",
         "(function () { try { new greet('x'); }"
         " catch (e) { return e.constructor.name; } })()");

    /*
     * ------------------------------------------- 4. C calling back into JS
     */
    printf("\nC calling JS back through bk_call:\n");
    show(rt, "  double", "mapTwice(function (x) { return x * 2; }, 5)");
    show(rt, "  arrow", "mapTwice(x => x + '!', 'go')");
    show(rt, "  builtin", "mapTwice(Math.sqrt, 81)");
    show(rt, "  callee throws",
         "(function () { try { mapTwice(function () { throw new EvalError('nope'); }, 1); }"
         " catch (e) { return e.constructor.name + ': ' + e.message; } })()");

    /*
     * --------------------------------------------------- 5. host state
     *
     * `calls` was incremented through the udata pointer on every greet(),
     * proving the passthrough reached host memory rather than a copy.
     */
    printf("\ngreet() reached host state %d times\n", st.calls);

    bk_close(rt);
    return EXIT_SUCCESS;
}
