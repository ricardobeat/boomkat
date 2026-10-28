/* Parallel compiles keep independent diagnostics and private class names on
 * each runtime. Distinct parser failures make cross-thread error leakage visible. */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "boomkat.h"

static int failures;

enum { ITER = 20000 };

struct worker_arg {
    int        id;
    const char *source;
    const char *message;
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
        v = bk_eval_ex(w->rt, w->source, strlen(w->source), "<eval>", BK_EVAL_GLOBAL);
        if (!v && bk_get_error_code(w->rt) == BK_ERR_SYNTAX) {
            const char *msg = bk_get_error_message(w->rt);
            if (msg && strcmp(msg, w->message) == 0) {
                bad_saw++;
            }
        }
        /* A valid compile in the same thread must still work. */
        if ((v = bk_eval_ex(w->rt, "var ok = 40 + 2; ok", 19, "<eval>", BK_EVAL_GLOBAL))) {
            double d = 0;
            if (bk_read_number(w->rt, v, &d) == BK_OK && d == 42) valid_ok++;
            bk_free_value(w->rt, v);
        }
        /* A class with a private field; its slot id comes from this
         * runtime's own counter, not a shared process global. */
        if ((v = bk_eval_ex(w->rt, class_src, strlen(class_src), "<eval>", BK_EVAL_GLOBAL))) {
            double d = 0;
            if (bk_read_number(w->rt, v, &d) == BK_OK && d == 7) class_ok++;
            bk_free_value(w->rt, v);
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
    const char *sources[] = {"var @ x", "var = x", "let a; let a;", "const x;"};
    enum { N = 4 };
    pthread_t th[N];
    struct worker_arg args[N];

    for (int i = 0; i < N; i++) {
        args[i].id = i;
        args[i].source = sources[i];
        if (!(args[i].rt = bk_new_context(bk_new_runtime(NULL), NULL))) {
            printf("FAIL: could not open runtime %d\n", i);
            failures++;
            args[i].rt = NULL;
        }
    }
    char messages[N][512];
    for (int i = 0; i < N; i++) {
        bk_value v = bk_eval_ex(args[i].rt, sources[i], strlen(sources[i]), "invalid.js", BK_EVAL_GLOBAL);
        if (v || bk_get_error_code(args[i].rt) != BK_ERR_SYNTAX) return 1;
        snprintf(messages[i], sizeof messages[i], "%s", bk_get_error_message(args[i].rt));
        args[i].message = messages[i];
        for (int j = 0; j < i; j++) if (strcmp(messages[i], messages[j]) == 0) return 1;
    }
    check("four runtimes open", args[0].rt && args[1].rt && args[2].rt && args[3].rt);

    for (int i = 0; i < N; i++) {
        if (args[i].rt) pthread_create(&th[i], NULL, worker, &args[i]);
    }
    for (int i = 0; i < N; i++) {
        if (args[i].rt) pthread_join(th[i], NULL);
    }
    for (int i = 0; i < N; i++) {
        if (args[i].rt) bk_free_runtime(bk_get_runtime(args[i].rt));
    }

    if (failures) { printf("\nFAILURES: %d\n", failures); return 1; }
    printf("compile-threads: all passed\n");
    return 0;
}
