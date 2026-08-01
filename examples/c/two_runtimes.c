/*
 * two_runtimes.c -- proof that two runtimes coexist in one process.
 *
 * Under the previous design both runtimes shared one process-global heap
 * pointer, so whichever opened last owned it: the first runtime's objects were
 * allocated from and interned into the second's heap. This interleaves work
 * between two open runtimes, which is the case that silently corrupted.
 *
 * Build and run with:
 *     make two-runtimes
 */
#include "jse.h"
#include <stdio.h>
#include <string.h>

static int eval_num(jse_runtime rt, const char *src, double *out) {
    jse_value v;
    int rc = jse_eval(rt, src, strlen(src), &v);
    if (rc != JSE_OK) {
        fprintf(stderr, "eval failed (%d): %s\n", rc, jse_last_error(rt));
        return rc;
    }
    rc = jse_get_number(rt, v, out);
    jse_value_free(rt, v);
    return rc;
}

static int eval_str(jse_runtime rt, const char *src, char *buf, size_t cap) {
    jse_value v;
    int rc = jse_eval(rt, src, strlen(src), &v);
    if (rc != JSE_OK) {
        fprintf(stderr, "eval failed (%d): %s\n", rc, jse_last_error(rt));
        return rc;
    }
    size_t n = 0;
    rc = jse_get_string(rt, v, buf, cap, &n);
    jse_value_free(rt, v);
    return rc;
}

int main(void) {
    jse_runtime a, b;
    int fails = 0;

    if (jse_open(&a) != JSE_OK) { fprintf(stderr, "open A failed\n"); return 1; }
    if (jse_open(&b) != JSE_OK) { fprintf(stderr, "open B failed\n"); jse_close(a); return 1; }
    printf("both runtimes open: A=%p B=%p\n", (void *)a, (void *)b);

    /* Distinct global state per runtime. */
    double n = 0;
    if (eval_num(a, "var x = 111; x", &n) != JSE_OK || n != 111) {
        printf("FAIL: A x = %g (want 111)\n", n); fails++;
    }
    if (eval_num(b, "var x = 222; x", &n) != JSE_OK || n != 222) {
        printf("FAIL: B x = %g (want 222)\n", n); fails++;
    }
    /* Re-read A after B wrote its own x: a shared heap would show 222. */
    if (eval_num(a, "x", &n) != JSE_OK || n != 111) {
        printf("FAIL: A x after B = %g (want 111)\n", n); fails++;
    } else {
        printf("ok: A.x=111 survived B.x=222\n");
    }

    /* Interleaved object + property work, which is what exercises the
       per-object shape transitions and the string intern table. */
    if (eval_num(a, "var o = {}; for (var i = 0; i < 200; i++) o['k' + i] = i; o.k199", &n) != JSE_OK || n != 199) {
        printf("FAIL: A object build = %g\n", n); fails++;
    }
    if (eval_num(b, "var o = {}; for (var i = 0; i < 200; i++) o['k' + i] = i * 2; o.k199", &n) != JSE_OK || n != 398) {
        printf("FAIL: B object build = %g\n", n); fails++;
    }
    if (eval_num(a, "o.k199", &n) != JSE_OK || n != 199) {
        printf("FAIL: A o.k199 after B = %g (want 199)\n", n); fails++;
    } else {
        printf("ok: A.o.k199=199 survived B's 200-property build\n");
    }

    /* String interning is pointer identity engine-wide, so a shared table
       across runtimes is the subtlest corruption of all. */
    char buf[64];
    if (eval_str(a, "var s = 'alpha' + '-A'; s", buf, sizeof buf) != JSE_OK || strcmp(buf, "alpha-A")) {
        printf("FAIL: A string = %s\n", buf); fails++;
    }
    if (eval_str(b, "var s = 'alpha' + '-B'; s", buf, sizeof buf) != JSE_OK || strcmp(buf, "alpha-B")) {
        printf("FAIL: B string = %s\n", buf); fails++;
    }
    if (eval_str(a, "s", buf, sizeof buf) != JSE_OK || strcmp(buf, "alpha-A")) {
        printf("FAIL: A string after B = %s (want alpha-A)\n", buf); fails++;
    } else {
        printf("ok: A.s='alpha-A' survived B interning 'alpha-B'\n");
    }

    /* Close in the opposite order to the one they were opened in, so each
       teardown runs while the other heap is still live. */
    jse_close(a);
    if (eval_num(b, "o.k100 + x", &n) != JSE_OK || n != 200 + 222) {
        printf("FAIL: B unusable after closing A = %g (want %d)\n", n, 200 + 222); fails++;
    } else {
        printf("ok: B still works after A closed\n");
    }
    jse_close(b);

    printf(fails ? "FAILED (%d)\n" : "PASS\n", fails);
    return fails != 0;
}
