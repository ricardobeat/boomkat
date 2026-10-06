/* Each runtime repeatedly compiles a different syntax error, then valid code
 * and a private-field class. Distinct diagnostics detect cross-thread writes
 * to the compiler error buffer. Heap independence is covered by two_runtimes.c.
 */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "boomkat.h"

static int failures;

enum { ITER = 20000 };

struct worker_arg {
    int        id;
    const char *source;
    const char *diagnostic;
    bk_ctx rt;
};

static void check(const char *label, int cond) {
    if (cond) { printf("ok   %s\n", label); }
    else      { printf("FAIL %s\n", label); failures++; }
}

static const char class_src[] =
    "class C { #v = 7; get() { return this.#v; } }\n"
    "new C().get()";

static void *worker(void *opaque) {
    struct worker_arg *w = (struct worker_arg *)opaque;
    int bad_saw = 0, valid_ok = 0, class_ok = 0;
    bk_value v;

    for (int i = 0; i < ITER; i++) {
        v = bk_eval(w->rt, w->source, strlen(w->source));
        if (!v && bk_error_code(w->rt) == BK_ERR_SYNTAX) {
            const char *msg = bk_error(w->rt);
            if (msg && strstr(msg, w->diagnostic)) {
                bad_saw++;
            }
        }
        /* A valid compile in the same thread must still work. */
        if ((v = bk_eval(w->rt, "var ok = 40 + 2; ok", 19))) {
            double d = 0;
            if (bk_read_number(w->rt, v, &d) == BK_OK && d == 42) valid_ok++;
            bk_free(w->rt, v);
        }
        /* A class with a private field; its slot id comes from this
         * runtime's own counter, not a shared process global. */
        if ((v = bk_eval(w->rt, class_src, strlen(class_src)))) {
            double d = 0;
            if (bk_read_number(w->rt, v, &d) == BK_OK && d == 7) class_ok++;
            bk_free(w->rt, v);
        }
    }

    printf("thread %d: %d/%d error messages correct, %d/%d valid compiles ok, %d/%d classes ok\n",
           w->id, bad_saw, ITER, valid_ok, ITER, class_ok, ITER);
    if (bad_saw != ITER) { printf("FAIL thread %d: error message race\n", w->id); failures++; }
    if (valid_ok != ITER) { printf("FAIL thread %d: valid compile broke\n", w->id); failures++; }
    if (class_ok != ITER) { printf("FAIL thread %d: class compile broke\n", w->id); failures++; }
    return NULL;
}

int main(void) {
    static const char *sources[] = {
        "var @ x", "/*", "let x; let x;",
        "'use strict'; function f(x,x){}"
    };
    static const char *diagnostics[] = {
        "unexpected character '@'", "unterminated multi-line comment",
        "redeclaration of a lexical name", "duplicate parameter names"
    };
    enum { N = (int)(sizeof sources / sizeof sources[0]) };
    pthread_t th[N];
    struct worker_arg args[N];

    for (int i = 0; i < N; i++) {
        args[i].id = i;
        args[i].source = sources[i];
        args[i].diagnostic = diagnostics[i];
        if (!(args[i].rt = bk_open())) {
            printf("FAIL: could not open runtime %d\n", i);
            failures++;
            args[i].rt = NULL;
        }
    }
    check("four runtimes open", args[0].rt && args[1].rt && args[2].rt && args[3].rt);

    for (int i = 0; i < N; i++) {
        if (args[i].rt) pthread_create(&th[i], NULL, worker, &args[i]);
    }
    for (int i = 0; i < N; i++) {
        if (args[i].rt) pthread_join(th[i], NULL);
    }
    for (int i = 0; i < N; i++) {
        if (args[i].rt) bk_close(args[i].rt);
    }

    if (failures) { printf("\nFAILURES: %d\n", failures); return 1; }
    printf("compile-threads: all passed\n");
    return 0;
}
