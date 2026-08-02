/*
 * two_runtimes.c — running two jse runtimes side by side in one process.
 *
 * Where main.c drives a single runtime, this opens two and shows what they do
 * and do not share:
 *
 *   1. globals    — a global set in A is invisible in B
 *   2. objects    — each runtime builds its own, with its own shapes
 *   3. strings    — the same literal interns separately in each
 *   4. handles    — a jse_value belongs to one runtime, and the engine does
 *                   not reliably catch you for using it with the other
 *   5. lifetime   — closing A leaves B untouched
 *
 * Build and run with `make run-two-runtimes` (see README.md).
 */

#include "jse_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Evaluate `src` in `rt`, print `label = result`, and report any failure. */
static int show(jse_runtime rt, const char *label, const char *src)
{
    char *text = jseu_eval_to_string(rt, src);

    if (text == NULL) {
        printf("%-30s ! %s\n", label, jse_last_error(rt));
        return 0;
    }
    printf("%-30s = %s\n", label, text);
    free(text);
    return 1;
}

int main(void)
{
    jse_runtime a = NULL;
    jse_runtime b = NULL;
    jse_value   from_a = JSE_INVALID_VALUE;
    double      n = 0.0;
    int         status;

    /*
     * ------------------------------------------------------ 1. two runtimes
     *
     * Nothing is process-global, so jse_open succeeds as many times as you ask
     * it to. Each runtime owns its own globals, objects, shapes and interned
     * strings, and they are independent for the whole of their lifetimes.
     *
     * Each must still be driven from one thread at a time: the engine has no
     * locking. Two threads each driving their OWN runtime share nothing and
     * are fine; two threads inside one runtime are not, and nothing stops you.
     */
    if (jse_open(&a) != JSE_OK || jse_open(&b) != JSE_OK) {
        fprintf(stderr, "jse_open failed\n");
        jse_close(a);
        jse_close(b);
        return EXIT_FAILURE;
    }
    printf("jse version %s\n\n", jse_version());

    /*
     * ------------------------------------------------------- 2. globals
     *
     * The same name, a different value in each, and neither leaks into the
     * other's global object.
     */
    printf("independent globals:\n");
    jseu_eval_cstr(a, "var tag = 'A'; var n = 111;", NULL);
    jseu_eval_cstr(b, "var tag = 'B'; var n = 222;", NULL);
    show(a, "  A.tag / A.n", "tag + '/' + n");
    show(b, "  B.tag / B.n", "tag + '/' + n");
    jseu_eval_cstr(b, "var onlyB = 1;", NULL);
    show(b, "  B.onlyB", "typeof globalThis.onlyB");
    show(a, "  A.onlyB", "typeof globalThis.onlyB");

    /*
     * -------------------------------------------------------- 3. objects
     *
     * Both build an object through the same property sequence, which drives
     * the same shape transitions in each. Separate shape tables mean the two
     * do not interfere; each reads back exactly what it wrote.
     */
    printf("\nindependent objects and shapes:\n");
    jseu_eval_cstr(a,
        "var o = {}; for (var i = 0; i < 200; i++) o['k' + i] = i;", NULL);
    jseu_eval_cstr(b,
        "var o = {}; for (var i = 0; i < 200; i++) o['k' + i] = i * 10;", NULL);
    show(a, "  A.o.k199", "o.k199");
    show(b, "  B.o.k199", "o.k199");
    show(a, "  A key count", "Object.keys(o).length");

    /*
     * -------------------------------------------------------- 4. strings
     *
     * Strings are interned per runtime, so the same literal is a different
     * HString in each. Equality is only ever asked within one runtime, which
     * is why that costs nothing.
     */
    printf("\nindependent string interning:\n");
    jseu_eval_cstr(a, "var s = 'shared-literal' + '';", NULL);
    jseu_eval_cstr(b, "var s = 'shared-literal' + '';", NULL);
    show(a, "  A.s === literal", "s === 'shared-literal'");
    show(b, "  B.s === literal", "s === 'shared-literal'");

    /*
     * -------------------------------------------------------- 5. handles
     *
     * A jse_value is an index into ONE runtime's registry, not a pointer to a
     * value, and the index is NOT tagged with which runtime it came from. Two
     * runtimes at the same allocation state hand out bit-identical handles, as
     * the first line below shows.
     *
     * So passing a handle to the wrong runtime's reader is NOT reliably caught.
     * It is caught only when that slot happens to be free or to carry a
     * different generation in the other runtime; when both registries are in
     * step, the read succeeds and quietly answers with the OTHER runtime's
     * value. Both outcomes are printed below, from the same pair of runtimes.
     *
     * Pairing a handle with its runtime is therefore the host's job, and the
     * engine will not check it for you. To move a value across, read it out on
     * one side and write it back on the other; no handle means anything in
     * both.
     */
    printf("\nhandles are per-runtime, and mixing them is not diagnosed:\n");

    /*
     * A fresh pair, so both registries start in step and issue the same
     * handle. `a` and `b` above have each allocated a different number of
     * handles by now, which would hide the collision behind a mismatched
     * generation tag and make this section look safer than it is.
     */
    {
        jse_runtime c = NULL, d = NULL;
        jse_value   vc = JSE_INVALID_VALUE, vd = JSE_INVALID_VALUE;

        if (jse_open(&c) != JSE_OK || jse_open(&d) != JSE_OK ||
            jseu_eval_cstr(c, "40 + 2", &vc) != JSE_OK ||
            jseu_eval_cstr(d, "7", &vd) != JSE_OK) {
            fprintf(stderr, "setting up the handle demo failed\n");
            jse_close(c);
            jse_close(d);
            goto fail;
        }

        printf("%-30s = %u vs %u (identical: %s)\n", "  C's handle vs D's handle",
               vc, vd, vc == vd ? "yes" : "no");

        /* Correct use: each handle read by the runtime that issued it. */
        n = -1.0;
        jse_get_number(c, vc, &n);
        printf("%-30s = %g\n", "  C's handle read by C", n);
        n = -1.0;
        jse_get_number(d, vd, &n);
        printf("%-30s = %g\n", "  D's handle read by D", n);

        /*
         * The silent case. Both registries are in step, so D resolves C's
         * handle and answers with its OWN value, 7, and returns JSE_OK.
         */
        n = -1.0;
        status = jse_get_number(d, vc, &n);
        printf("%-30s = %s, n=%g  <-- D's value, not C's\n",
               "  C's handle read by D", jseu_status_name(status), n);

        /*
         * The caught case, from the same pair. Freeing a handle in D moves its
         * generation counter on, so C's handle now names a slot D considers
         * stale and D rejects it. Identical mistake; only the registries'
         * relative state differs, which is why this is not a check you can
         * lean on.
         */
        jse_value_free(d, vd);
        n = -1.0;
        status = jse_get_number(d, vc, &n);
        printf("%-30s = %s, n=%g  <-- caught, only by luck\n",
               "  C's handle read by D again", jseu_status_name(status), n);

        jse_value_free(c, vc);
        jse_close(c);
        jse_close(d);
    }

    /*
     * Moving a value across is a read on one side and a write on the other.
     * `n` is read out of A through A's own reader; it is a plain C double by
     * then and belongs to neither runtime.
     */
    status = jseu_eval_cstr(a, "40 + 2", &from_a);
    if (status != JSE_OK) {
        fprintf(stderr, "eval in A failed: %s\n", jse_last_error(a));
        goto fail;
    }
    if (jse_get_number(a, from_a, &n) == JSE_OK) {
        char src[64];
        snprintf(src, sizeof(src), "var moved = %.17g;", n);
        jseu_eval_cstr(b, src, NULL);
        show(b, "  moved A->B via C", "moved");
    }

    /*
     * ------------------------------------------------------- 6. lifetime
     *
     * Closing one runtime invalidates only its own handles and leaves the
     * other entirely alone.
     */
    printf("\nclosing A leaves B alone:\n");
    jse_value_free(a, from_a);
    from_a = JSE_INVALID_VALUE;
    jse_close(a);
    a = NULL;
    show(b, "  B.tag after A closed", "tag + '/' + n + '/' + o.k199");

    jse_close(b);
    return EXIT_SUCCESS;

fail:
    if (from_a != JSE_INVALID_VALUE) {
        jse_value_free(a, from_a);
    }
    jse_close(a);
    jse_close(b);
    return EXIT_FAILURE;
}
