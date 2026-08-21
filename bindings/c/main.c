/*
 * main.c — embedding the boomkat JavaScript engine from plain C99.
 *
 * Walks the whole v1 surface in the order a real embedder meets it:
 * open a runtime, evaluate JS for a value, read that value out in each type,
 * surface a thrown exception and a syntax error, then shut down.
 *
 * Build and run with `make` (see README.md).
 */

#include "bk_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Print the label, then the pending error the way an embedder would log it. */
static void report_error(bk_runtime rt, const char *label, int status)
{
    printf("%-14s %-8s %s\n", label, bku_status_name(status), bk_last_error(rt));
}

int main(void)
{
    bk_runtime rt = NULL;
    bk_value v = BK_INVALID_VALUE;
    int status;

    /* ---------------------------------------------------------- 1. open */
    status = bk_open(&rt);
    if (status != BK_OK) {
        fprintf(stderr, "bk_open failed: %s\n", bku_status_name(status));
        return EXIT_FAILURE;
    }
    printf("boomkat version %s\n\n", bk_version());

    /* ------------------------------------------- 2. evaluate for a number */
    {
        static const char src[] =
            "var xs = [1, 2, 3, 4, 5];\n"
            "xs.reduce(function (a, b) { return a + b; }, 0);";
        double sum = 0.0;

        status = bku_eval_cstr(rt, src, &v);
        if (status != BK_OK) {
            report_error(rt, "sum:", status);
            goto fail;
        }
        if (bk_get_number(rt, v, &sum) != BK_OK) {
            fprintf(stderr, "expected a number, got %s\n",
                    bku_type_name(bk_type_of(rt, v)));
            goto fail;
        }
        printf("sum of 1..5      = %g\n", sum);
        bk_value_free(rt, v); /* every handle from bk_eval must be freed */
        v = BK_INVALID_VALUE;
    }

    /* ------------------------------------------- 3. evaluate for a string */
    {
        static const char src[] =
            "['boomkat', 'from', 'C99'].join(' ') + ' \\u2014 astral: \\u{1F600}';";
        char *text;

        status = bku_eval_cstr(rt, src, &v);
        if (status != BK_OK) {
            report_error(rt, "greeting:", status);
            goto fail;
        }
        text = bku_string_dup(rt, v); /* caller owns the buffer */
        if (text == NULL) {
            fprintf(stderr, "could not read the string\n");
            goto fail;
        }
        printf("greeting         = %s\n", text);
        free(text);
        bk_value_free(rt, v);
        v = BK_INVALID_VALUE;
    }

    /* ------------------------------- 4. booleans, and inspecting the type */
    {
        static const char src[] = "typeof globalThis.Math === 'object';";
        int flag = 0;

        status = bku_eval_cstr(rt, src, &v);
        if (status != BK_OK) {
            report_error(rt, "has Math:", status);
            goto fail;
        }
        bk_get_bool(rt, v, &flag);
        printf("Math is object   = %s (handle type: %s)\n",
               flag ? "true" : "false", bku_type_name(bk_type_of(rt, v)));
        bk_value_free(rt, v);
        v = BK_INVALID_VALUE;
    }

    /* --------------------- 5. anything at all, stringified on the JS side */
    {
        char *text = bku_eval_to_string(rt, "({ ok: true, items: [1, 2] })");
        printf("object as string = %s\n\n", text ? text : "(error)");
        free(text);
    }

    /*
     * ------------------------------------------------- 6. failure handling
     *
     * Errors are surfaced as a status code plus a message on the runtime.
     * Nothing aborts or longjmps across the boundary, so an embedder handles
     * a bad script exactly like any other failed C call: check, log, continue.
     */
    printf("errors are values, not crashes:\n");

    /* A thrown exception -> BK_ERR_THROW. */
    status = bku_eval_cstr(rt, "throw new RangeError('index out of range');", NULL);
    report_error(rt, "  throw", status);

    /* A syntax error is caught at compile time -> BK_ERR_SYNTAX. */
    status = bku_eval_cstr(rt, "function ( { oops", NULL);
    report_error(rt, "  bad syntax", status);

    /* Reading a string out of a number is a type error, not undefined behaviour. */
    status = bku_eval_cstr(rt, "123;", &v);
    if (status == BK_OK) {
        size_t len = 0;
        status = bk_get_string(rt, v, NULL, 0, &len);
        report_error(rt, "  wrong type", status);
        bk_value_free(rt, v);
        v = BK_INVALID_VALUE;
    }

    /* The runtime is still perfectly usable after all of that. */
    {
        char *text = bku_eval_to_string(rt, "'still running'");
        printf("\nafter errors     = %s\n", text ? text : "(error)");
        free(text);
    }

    /* --------------------------------------------------------- 7. cleanup */
    bk_close(rt); /* invalidates every outstanding handle */
    return EXIT_SUCCESS;

fail:
    if (v != BK_INVALID_VALUE) {
        bk_value_free(rt, v);
    }
    bk_close(rt);
    return EXIT_FAILURE;
}
