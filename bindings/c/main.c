/*
 * main.c -- embedding the boomkat JavaScript engine from plain C99.
 *
 * Walks the surface in the order a real embedder meets it: open a context,
 * evaluate for a value, read it out, build values from C, reach into an
 * object, and surface the two kinds of failure.
 *
 * Build and run with `make` (see README.md).
 */

#include <boomkat.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Log the pending failure the way an embedder would. */
static void report(bk_ctx js, const char *label)
{
    printf("%-16s %-9s %s\n", label, bk_status_str(bk_error_code(js)), bk_error(js));
}

int main(void)
{
    bk_ctx js = bk_open();
    if (!js) {
        fprintf(stderr, "bk_open failed\n");
        return EXIT_FAILURE;
    }
    printf("boomkat version %s\n\n", bk_version());

    /* ------------------------------------------------------ 1. read a value
     *
     * A handle-returning call fails by returning 0, so the check is the same
     * shape for every call below.
     */
    {
        bk_value v = bk_eval_str(js,
            "var xs = [1, 2, 3, 4, 5];\n"
            "xs.reduce(function (a, b) { return a + b; }, 0);");
        double sum = 0.0;
        if (!v) { report(js, "sum:"); goto fail; }
        if (bk_read_number(js, v, &sum) != BK_OK) {
            fprintf(stderr, "expected a number, got %s\n",
                    bk_type_str(bk_type_of(js, v)));
            goto fail;
        }
        printf("sum of 1..5      = %g\n", sum);
        bk_free(js, v);           /* every handle you are given, you free */
    }

    /* ---------------------------------------------------- 2. any value as text
     *
     * bk_cstr coerces the way String(v) does and hands back storage the
     * context owns, so printing a result takes no buffer and no free. Four
     * results stay live at once, which is why they can share one printf.
     */
    {
        bk_value n = bk_eval_str(js, "6 * 7");
        bk_value s = bk_eval_str(js, "'hi ' + String.fromCodePoint(0x1F600)");
        bk_value a = bk_eval_str(js, "[1,2,3].map(x => x * x)");
        bk_value o = bk_eval_str(js, "({ kind: 'config' })");
        printf("as text          = %s | %s | %s | %s\n",
               bk_cstr(js, n, NULL), bk_cstr(js, s, NULL),
               bk_cstr(js, a, NULL), bk_cstr(js, o, NULL));
        bk_free(js, n); bk_free(js, s); bk_free(js, a); bk_free(js, o);
    }

    /* ------------------------------------------------ 3. build values from C
     *
     * Nothing here goes through JS source, so none of it can be a string
     * injection.
     */
    {
        bk_value cfg  = bk_object(js);
        bk_value host = bk_str(js, "example.com");
        bk_value port = bk_number(js, 8080);

        bk_setp(js, cfg, "host", host);
        bk_setp(js, cfg, "port", port);
        bk_free(js, host);
        bk_free(js, port);

        bk_set_globalp(js, "config", cfg);
        {
            bk_value v = bk_eval_str(js, "config.host + ':' + config.port");
            printf("built in C       = %s\n", bk_cstr(js, v, NULL));
            bk_free(js, v);
        }

        /* ...and read back out the same way. */
        {
            bk_value p = bk_getp(js, cfg, "port");
            double d = 0;
            bk_read_number(js, p, &d);
            printf("config.port      = %g\n", d);
            bk_free(js, p);
        }
        bk_free(js, cfg);
    }

    /* --------------------------------------------------- 4. calling into JS */
    {
        bk_value fn = bk_eval_str(js, "(function add(a, b) { return a + b; })");
        bk_value args[2];
        bk_value out;
        args[0] = bk_number(js, 40);
        args[1] = bk_number(js, 2);
        out = bk_call(js, fn, 0, args, 2);
        printf("add(40, 2)       = %s\n", bk_cstr(js, out, NULL));
        bk_free(js, args[0]); bk_free(js, args[1]);
        bk_free(js, out); bk_free(js, fn);
    }

    /* ------------------------------------------------------- 5. the failures
     *
     * Both kinds report through the same two calls, and the context stays
     * usable afterwards.
     */
    printf("\n");
    if (!bk_eval_str(js, "var = = =")) report(js, "syntax error:");
    if (!bk_eval_str(js, "null.x"))    report(js, "thrown:");

    {
        bk_error_info info;
        bk_value v = bk_eval_named(js, "\n\nlet y = ;", 10, "config.js", 9);
        if (!v && bk_error_info_of(js, &info) == BK_OK) {
            printf("%-16s %s:%d:%d\n", "located at:",
                   info.script_name ? info.script_name : "?", info.line, info.col);
        }
    }

    {
        bk_value v = bk_eval_str(js, "'still here'");
        printf("%-16s %s\n", "after failure:", bk_cstr(js, v, NULL));
        bk_free(js, v);
    }

    bk_close(js);
    return EXIT_SUCCESS;

fail:
    bk_close(js);
    return EXIT_FAILURE;
}
