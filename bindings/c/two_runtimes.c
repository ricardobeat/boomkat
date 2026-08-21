/*
 * two_runtimes.c — running two boomkat runtimes side by side in one process.
 *
 * Where main.c drives a single runtime, this opens two and shows what they do
 * and do not share:
 *
 *   1. globals    — a global set in A is invisible in B
 *   2. objects    — each runtime builds its own, with its own shapes
 *   3. strings    — the same literal interns separately in each
 *   4. handles    — a bk_value belongs to one runtime, and the engine does
 *                   not reliably catch you for using it with the other
 *   5. lifetime   — closing A leaves B untouched
 *
 * Build and run with `make run-two-runtimes` (see README.md).
 */

#include "bk_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Evaluate `src` in `rt`, print `label = result`, and report any failure. */
static int show(bk_runtime rt, const char *label, const char *src)
{
    char *text = bku_eval_to_string(rt, src);

    if (text == NULL) {
        printf("%-30s ! %s\n", label, bk_last_error(rt));
        return 0;
    }
    printf("%-30s = %s\n", label, text);
    free(text);
    return 1;
}

int main(void)
{
    bk_runtime a = NULL;
    bk_runtime b = NULL;
    bk_value   from_a = BK_INVALID_VALUE;
    double      n = 0.0;
    int         status;

    /*
     * ------------------------------------------------------ 1. two runtimes
     *
     * Nothing is process-global, so bk_open succeeds as many times as you ask
     * it to. Each runtime owns its own globals, objects, shapes and interned
     * strings, and they are independent for the whole of their lifetimes.
     *
     * Each must still be driven from one thread at a time: the engine has no
     * locking. Two threads each driving their OWN runtime share nothing and
     * are fine; two threads inside one runtime are not, and nothing stops you.
     */
    if (bk_open(&a) != BK_OK || bk_open(&b) != BK_OK) {
        fprintf(stderr, "bk_open failed\n");
        bk_close(a);
        bk_close(b);
        return EXIT_FAILURE;
    }
    printf("boomkat version %s\n\n", bk_version());

    /*
     * ------------------------------------------------------- 2. globals
     *
     * The same name, a different value in each, and neither leaks into the
     * other's global object.
     */
    printf("independent globals:\n");
    bku_eval_cstr(a, "var tag = 'A'; var n = 111;", NULL);
    bku_eval_cstr(b, "var tag = 'B'; var n = 222;", NULL);
    show(a, "  A.tag / A.n", "tag + '/' + n");
    show(b, "  B.tag / B.n", "tag + '/' + n");
    bku_eval_cstr(b, "var onlyB = 1;", NULL);
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
    bku_eval_cstr(a,
        "var o = {}; for (var i = 0; i < 200; i++) o['k' + i] = i;", NULL);
    bku_eval_cstr(b,
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
    bku_eval_cstr(a, "var s = 'shared-literal' + '';", NULL);
    bku_eval_cstr(b, "var s = 'shared-literal' + '';", NULL);
    show(a, "  A.s === literal", "s === 'shared-literal'");
    show(b, "  B.s === literal", "s === 'shared-literal'");

    /*
     * -------------------------------------------------------- 5. handles
     *
     * A bk_value is an index into ONE runtime's registry, not a pointer to a
     * value. Two runtimes at the same allocation state therefore agree on the
     * slot and generation fields; what keeps their handles apart is the id of
     * the issuing runtime, carried in the top bits of every handle.
     *
     * That makes the mistake an error rather than a wrong answer: reading A's
     * handle through B reports BK_ERR_INVALID instead of quietly returning B's
     * own value from the same slot. The check does not depend on the two
     * registries' relative state, as the second read below shows.
     *
     * A handle still means nothing outside the runtime that issued it. To move
     * a value across, read it out on one side and write it back on the other.
     */
    printf("\nhandles are per-runtime, and mixing them is refused:\n");

    /*
     * A fresh pair, so both registries start in step and issue the same
     * handle. `a` and `b` above have each allocated a different number of
     * handles by now, which would hide the collision behind a mismatched
     * generation tag and make this section look safer than it is.
     */
    {
        bk_runtime c = NULL, d = NULL;
        bk_value   vc = BK_INVALID_VALUE, vd = BK_INVALID_VALUE;

        if (bk_open(&c) != BK_OK || bk_open(&d) != BK_OK ||
            bku_eval_cstr(c, "40 + 2", &vc) != BK_OK ||
            bku_eval_cstr(d, "7", &vd) != BK_OK) {
            fprintf(stderr, "setting up the handle demo failed\n");
            bk_close(c);
            bk_close(d);
            goto fail;
        }

        printf("%-30s = %llu vs %llu (identical: %s)\n", "  C's handle vs D's handle",
               (unsigned long long)vc, (unsigned long long)vd,
               vc == vd ? "yes" : "no");

        /* Correct use: each handle read by the runtime that issued it. */
        n = -1.0;
        bk_get_number(c, vc, &n);
        printf("%-30s = %g\n", "  C's handle read by C", n);
        n = -1.0;
        bk_get_number(d, vd, &n);
        printf("%-30s = %g\n", "  D's handle read by D", n);

        /*
         * The mistake, caught. Both registries are in step -- each holds one
         * value at slot 0, generation 1 -- so the slot and generation fields
         * of the two handles are identical. What separates them is the id of
         * the issuing runtime, carried in the top bits of every handle, so D
         * refuses C's handle instead of answering with its own value.
         */
        n = -1.0;
        status = bk_get_number(d, vc, &n);
        printf("%-30s = %s  <-- refused, not answered\n",
               "  C's handle read by D", bku_status_name(status));

        /* Still refused once D's own handle is gone and its generation moves
           on: the rejection does not depend on the registries' relative
           state. */
        bk_value_free(d, vd);
        n = -1.0;
        status = bk_get_number(d, vc, &n);
        printf("%-30s = %s\n",
               "  C's handle read by D again", bku_status_name(status));

        bk_value_free(c, vc);
        bk_close(c);
        bk_close(d);
    }

    /*
     * Moving a value across is a read on one side and a write on the other.
     * `n` is read out of A through A's own reader; it is a plain C double by
     * then and belongs to neither runtime.
     */
    status = bku_eval_cstr(a, "40 + 2", &from_a);
    if (status != BK_OK) {
        fprintf(stderr, "eval in A failed: %s\n", bk_last_error(a));
        goto fail;
    }
    if (bk_get_number(a, from_a, &n) == BK_OK) {
        char src[64];
        snprintf(src, sizeof(src), "var moved = %.17g;", n);
        bku_eval_cstr(b, src, NULL);
        show(b, "  moved A->B via C", "moved");
    }

    /*
     * ------------------------------------------------------- 6. lifetime
     *
     * Closing one runtime invalidates only its own handles and leaves the
     * other entirely alone.
     */
    printf("\nclosing A leaves B alone:\n");
    bk_value_free(a, from_a);
    from_a = BK_INVALID_VALUE;
    bk_close(a);
    a = NULL;
    show(b, "  B.tag after A closed", "tag + '/' + n + '/' + o.k199");

    bk_close(b);
    return EXIT_SUCCESS;

fail:
    if (from_a != BK_INVALID_VALUE) {
        bk_value_free(a, from_a);
    }
    bk_close(a);
    bk_close(b);
    return EXIT_FAILURE;
}
