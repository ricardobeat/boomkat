/*
 * The whole point of the v2 surface: embedding the engine is a dozen lines.
 *
 * This is the program printed in include/boomkat.h and docs/embedding.md,
 * verbatim, plus an assertion so it is a test rather than a demo. It must
 * compile clean at -std=c99 -Wall -Wextra -pedantic.
 */
#include <stdio.h>
#include <string.h>
#include <boomkat.h>

int main(void) {
    bk_ctx js = bk_open();
    bk_value v = bk_eval_str(js, "[1,2,3].map(n => n*n).join()");
    if (!v) { fprintf(stderr, "%s\n", bk_error(js)); return 1; }
    printf("%s\n", bk_cstr(js, v, NULL));

    if (strcmp(bk_cstr(js, v, NULL), "1,4,9") != 0) {
        fprintf(stderr, "FAIL: expected 1,4,9\n");
        return 1;
    }

    /* Four bk_cstr results stay live at once, which is what makes the ring
       worth having: this is the shape a real host's logging takes. */
    {
        bk_value a = bk_eval_str(js, "'alpha'");
        bk_value b = bk_eval_str(js, "42");
        bk_value c = bk_eval_str(js, "({x:1})");
        bk_value d = bk_eval_str(js, "[7,8]");
        char joined[128];
        snprintf(joined, sizeof joined, "%s|%s|%s|%s",
                 bk_cstr(js, a, NULL), bk_cstr(js, b, NULL),
                 bk_cstr(js, c, NULL), bk_cstr(js, d, NULL));
        if (strcmp(joined, "alpha|42|[object Object]|7,8") != 0) {
            fprintf(stderr, "FAIL: ring buffers collided: %s\n", joined);
            return 1;
        }
        bk_free(js, a); bk_free(js, b); bk_free(js, c); bk_free(js, d);
    }

    bk_free(js, v);
    bk_close(js);
    printf("dozen_lines: all ok\n");
    return 0;
}
