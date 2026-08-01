/*
 * smoke.c -- minimal proof the jse_ ABI links and runs from plain C99.
 *
 * Links the STATIC archive (out/jse_static.a). Build and run with:
 *     make smoke
 */
#include "jse.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    jse_runtime rt;
    if (jse_open(&rt) != JSE_OK) {
        fprintf(stderr, "jse_open failed\n");
        return 1;
    }

    const char *src = "40 + 2";
    jse_value v;
    int rc = jse_eval(rt, src, strlen(src), &v);
    if (rc != JSE_OK) {
        fprintf(stderr, "eval failed (%d): %s\n", rc, jse_last_error(rt));
        jse_close(rt);
        return 1;
    }

    double n = 0.0;
    if (jse_get_number(rt, v, &n) != JSE_OK) {
        fprintf(stderr, "not a number (type %d)\n", jse_type_of(rt, v));
        jse_value_free(rt, v);
        jse_close(rt);
        return 1;
    }

    printf("%g\n", n);

    jse_value_free(rt, v);
    jse_close(rt);
    return n == 42.0 ? 0 : 1;
}
