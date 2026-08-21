/*
 * Parallel compilation across threads, one runtime per thread.
 *
 * The compiler's last-error buffer was a process global, so two threads
 * compiling failing code at the same time raced: a thread could read the
 * other thread's message, or a splice of both. The buffer now lives on the
 * caller's Lexer, so a compile reads exactly what it wrote. Each worker
 * repeatedly compiles a source whose only invalid byte is a per-thread
 * character and asserts that the reported error names that character, and
 * that a valid compile in the same thread still succeeds.
 *
 * The class id behind private-slot binding names used to be a process global
 * too; it now lives on each runtime's heap, so threads compiling classes
 * with private fields never share a counter. Each worker also compiles a
 * class per iteration to exercise that path.
 *
 * This exercises the compile-error path only. Multi-runtime heap
 * independence under threads is covered by two_runtimes.c.
 */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "boomkat.h"

static int failures;

enum { ITER = 20000 };

struct worker_arg {
    int        id;
    char       bad;        /* the only invalid byte in this worker's source */
    bk_runtime rt;
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
    char src[64];
    int bad_saw = 0, valid_ok = 0, class_ok = 0;
    bk_value v;

    for (int i = 0; i < ITER; i++) {
        snprintf(src, sizeof src, "var %c x", w->bad);
        int rc = bk_eval(w->rt, src, (int)strlen(src), &v);
        if (rc == BK_ERR_SYNTAX) {
            const char *msg = bk_last_error(w->rt);
            if (msg && strstr(msg, "unexpected character") &&
                strchr(msg, w->bad)) {
                bad_saw++;
            }
        }
        /* A valid compile in the same thread must still work. */
        if (bk_eval(w->rt, "var ok = 40 + 2; ok", 19, &v) == BK_OK) {
            double d = 0;
            if (bk_get_number(w->rt, v, &d) == BK_OK && d == 42) valid_ok++;
            bk_value_free(w->rt, v);
        }
        /* A class with a private field; its slot id comes from this
         * runtime's own counter, not a shared process global. */
        if (bk_eval(w->rt, class_src, (int)strlen(class_src), &v) == BK_OK) {
            double d = 0;
            if (bk_get_number(w->rt, v, &d) == BK_OK && d == 7) class_ok++;
            bk_value_free(w->rt, v);
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
    static const char bads[] = { '@', '#', '`', '\\' };
    enum { N = (int)(sizeof bads / sizeof bads[0]) };
    pthread_t th[N];
    struct worker_arg args[N];

    for (int i = 0; i < N; i++) {
        args[i].id = i;
        args[i].bad = bads[i];
        if (bk_open(&args[i].rt) != BK_OK) {
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
