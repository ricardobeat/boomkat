/*
 * main.c — embedding the jse JavaScript engine from plain C99.
 *
 * Walks the whole v1 surface in the order a real embedder meets it:
 * open a runtime, evaluate JS for a value, read that value out in each type,
 * surface a thrown exception and a syntax error, then shut down.
 *
 * Build and run with `make` (see README.md).
 */

#include "jse_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Print the label, then the pending error the way an embedder would log it. */
static void report_error(jse_runtime rt, const char *label, int status)
{
    printf("%-14s %-8s %s\n", label, jseu_status_name(status), jse_last_error(rt));
}

int main(void)
{
    jse_runtime rt = NULL;
    jse_value v = JSE_INVALID_VALUE;
    int status;

    /* ---------------------------------------------------------- 1. open */
    status = jse_open(&rt);
    if (status != JSE_OK) {
        fprintf(stderr, "jse_open failed: %s\n", jseu_status_name(status));
        return EXIT_FAILURE;
    }
    printf("jse version %s\n\n", jse_version());

    /* ------------------------------------------- 2. evaluate for a number */
    {
        static const char src[] =
            "var xs = [1, 2, 3, 4, 5];\n"
            "xs.reduce(function (a, b) { return a + b; }, 0);";
        double sum = 0.0;

        status = jseu_eval_cstr(rt, src, &v);
        if (status != JSE_OK) {
            report_error(rt, "sum:", status);
            goto fail;
        }
        if (jse_get_number(rt, v, &sum) != JSE_OK) {
            fprintf(stderr, "expected a number, got %s\n",
                    jseu_type_name(jse_type_of(rt, v)));
            goto fail;
        }
        printf("sum of 1..5      = %g\n", sum);
        jse_value_free(rt, v); /* every handle from jse_eval must be freed */
        v = JSE_INVALID_VALUE;
    }

    /* ------------------------------------------- 3. evaluate for a string */
    {
        static const char src[] =
            "['jse', 'from', 'C99'].join(' ') + ' \\u2014 astral: \\u{1F600}';";
        char *text;

        status = jseu_eval_cstr(rt, src, &v);
        if (status != JSE_OK) {
            report_error(rt, "greeting:", status);
            goto fail;
        }
        text = jseu_string_dup(rt, v); /* caller owns the buffer */
        if (text == NULL) {
            fprintf(stderr, "could not read the string\n");
            goto fail;
        }
        printf("greeting         = %s\n", text);
        free(text);
        jse_value_free(rt, v);
        v = JSE_INVALID_VALUE;
    }

    /* ------------------------------- 4. booleans, and inspecting the type */
    {
        static const char src[] = "typeof globalThis.Math === 'object';";
        int flag = 0;

        status = jseu_eval_cstr(rt, src, &v);
        if (status != JSE_OK) {
            report_error(rt, "has Math:", status);
            goto fail;
        }
        jse_get_bool(rt, v, &flag);
        printf("Math is object   = %s (handle type: %s)\n",
               flag ? "true" : "false", jseu_type_name(jse_type_of(rt, v)));
        jse_value_free(rt, v);
        v = JSE_INVALID_VALUE;
    }

    /* --------------------- 5. anything at all, stringified on the JS side */
    {
        char *text = jseu_eval_to_string(rt, "({ ok: true, items: [1, 2] })");
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

    /* A thrown exception -> JSE_ERR_THROW. */
    status = jseu_eval_cstr(rt, "throw new RangeError('index out of range');", NULL);
    report_error(rt, "  throw", status);

    /* A syntax error is caught at compile time -> JSE_ERR_SYNTAX. */
    status = jseu_eval_cstr(rt, "function ( { oops", NULL);
    report_error(rt, "  bad syntax", status);

    /* Reading a string out of a number is a type error, not undefined behaviour. */
    status = jseu_eval_cstr(rt, "123;", &v);
    if (status == JSE_OK) {
        size_t len = 0;
        status = jse_get_string(rt, v, NULL, 0, &len);
        report_error(rt, "  wrong type", status);
        jse_value_free(rt, v);
        v = JSE_INVALID_VALUE;
    }

    /* The runtime is still perfectly usable after all of that. */
    {
        char *text = jseu_eval_to_string(rt, "'still running'");
        printf("\nafter errors     = %s\n", text ? text : "(error)");
        free(text);
    }

    /* --------------------------------------------------------- 7. cleanup */
    jse_close(rt); /* invalidates every outstanding handle */
    return EXIT_SUCCESS;

fail:
    if (v != JSE_INVALID_VALUE) {
        jse_value_free(rt, v);
    }
    jse_close(rt);
    return EXIT_FAILURE;
}
