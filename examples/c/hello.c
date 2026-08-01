#include "jse.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    jse_runtime rt;
    if (jse_open(&rt) != JSE_OK) { fprintf(stderr, "open failed\n"); return 1; }
    printf("jse %s\n", jse_version());

    jse_value v;
    const char *src = "var xs=[1,2,3,4]; xs.map(function(n){return n*n}).join(',')";
    if (jse_eval(rt, src, strlen(src), &v) != JSE_OK) {
        fprintf(stderr, "eval: %s\n", jse_last_error(rt));
        jse_close(rt); return 1;
    }
    size_t n = 0;
    jse_get_string(rt, v, NULL, 0, &n);
    char *buf = malloc(n + 1);
    if (jse_get_string(rt, v, buf, n + 1, &n) == JSE_OK) printf("squares: %s\n", buf);
    free(buf);
    jse_value_free(rt, v);

    if (jse_eval(rt, "throw new TypeError('nope')", 27, NULL) == JSE_ERR_THROW)
        printf("caught: %s\n", jse_last_error(rt));

    jse_close(rt);
    return 0;
}
