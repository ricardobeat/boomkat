#define _POSIX_C_SOURCE 200809L
#include "boomkat.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static unsigned rejected, handled, pending;
static uint64_t last_id;
static bk_value retained;

static void rejection(bk_ctx ctx, uint64_t id, bk_value promise,
                      bk_value reason, int is_handled, void *opaque) {
    assert(opaque == &pending);
    assert(bk_get_type(ctx, promise) == BK_TYPE_OBJECT);
    if (is_handled) {
        assert(id == last_id);
        handled++;
        pending--;
        bk_free_value(ctx, retained);
        retained = 0;
    } else {
        assert(!retained);
        retained = bk_dup_value(ctx, promise);
        assert(retained);
        last_id = id;
        rejected++;
        pending++;
        assert(bk_get_type(ctx, reason) != BK_TYPE_UNDEFINED);
    }
}

static void eval_ok(bk_ctx ctx, const char *src) {
    bk_value v = bk_eval_ex(ctx, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
    if (!v) fprintf(stderr, "eval failed: %s\n", bk_get_error_message(ctx));
    assert(v);
    bk_free_value(ctx, v);
    assert(bk_run_jobs(bk_get_runtime(ctx)) == BK_OK);
}

static void *watchdog(void *ctx) {
    struct timespec delay = {0, 25000000};
    nanosleep(&delay, NULL);
    bk_request_interrupt(bk_get_runtime(ctx));
    return NULL;
}

static void expect_interrupt(bk_ctx ctx, const char *src) {
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, watchdog, ctx));
    bk_value v = bk_eval_ex(ctx, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
    if (v) {
        bk_free_value(ctx, v);
        assert(bk_run_jobs(bk_get_runtime(ctx)) == BK_ERR_INTERRUPT);
        v = BK_EXCEPTION;
    }
    assert(!pthread_join(thread, NULL));
    if (v || bk_get_error_code(ctx) != BK_ERR_INTERRUPT)
        fprintf(stderr, "expected interrupt for %s: %d %s\n", src, bk_get_error_code(ctx), bk_get_error_message(ctx));
    assert(!v && bk_get_error_code(ctx) == BK_ERR_INTERRUPT);
    bk_clear_interrupt(bk_get_runtime(ctx));
    eval_ok(ctx, "if (1+1 !== 2) throw 'recovery';");
}

int main(void) {
    alarm(20);
    bk_ctx ctx = bk_new_context(bk_new_runtime(NULL));
    assert(ctx);
    bk_set_promise_rejection_tracker(bk_get_runtime(ctx), rejection, &pending);
    eval_ok(ctx, "var p = Promise.reject('first');");
    assert(rejected == 1 && handled == 0 && pending == 1);
    assert(bk_run_jobs(bk_get_runtime(ctx)) == BK_OK);
    assert(rejected == 1);
    eval_ok(ctx, "p.catch(function() {}); p.catch(function() {});");
    assert(handled == 1 && pending == 0);
    eval_ok(ctx, "p = Promise.reject('same turn'); Promise.resolve().then(function() { p.catch(function() {}); });");
    assert(rejected == 2 && handled == 2 && pending == 0);
    eval_ok(ctx, "p = (async function() { throw 'async'; })();");
    assert(rejected == 3 && pending == 1);
    eval_ok(ctx, "(async function() { try { await p; } catch (e) {} })();");
    assert(handled == 3 && pending == 0);
    eval_ok(ctx, "p = Promise.resolve().then(function() { throw 'job'; });");
    assert(rejected == 4 && pending == 1);
    eval_ok(ctx, "p.catch(function() {});");
    assert(handled == 4 && pending == 0);
    eval_ok(ctx, "p = Promise.reject('adopt'); var q = Promise.resolve({then: function(resolve) { resolve(p); }}); q.catch(function() {});");
    assert(pending == 0);
    unsigned before = rejected;
    eval_ok(ctx, "new Promise(function(resolve, reject) { resolve(1); reject(2); }).then(function() {});");
    assert(rejected == before);
    bk_set_promise_rejection_tracker(bk_get_runtime(ctx), NULL, NULL);

    expect_interrupt(ctx, "while (true) {}");
    expect_interrupt(ctx, "try { while (true) {} } catch(e) { throw 'caught'; }");
    expect_interrupt(ctx, "try { while (true) {} } finally { globalThis.cleaned = 1; }");
    eval_ok(ctx, "if (cleaned !== 1) throw 'finally';");
    expect_interrupt(ctx, "Promise.resolve().then(function() { while (true) {} });");
    expect_interrupt(ctx, "var text = 'a'.repeat(40) + '!'; /^(a+)+$/.test(text);");
    expect_interrupt(ctx, "var rx = new RegExp('^(a+)+$'); rx.exec(text);");
    expect_interrupt(ctx, "text.search(/^(a+)+$/);");
    expect_interrupt(ctx, "text.replace(/^(a+)+$/g, 'b');");
    expect_interrupt(ctx, "text.split(/(a+)+$/);");
    expect_interrupt(ctx, "var unicodeText = 'é'.repeat(40) + '!'; /^(é+)+$/.test(unicodeText);");
    eval_ok(ctx, "var afterTermination = 0;");
    expect_interrupt(ctx, "(function() { try { while (true) {} } finally { return 1; } })(); afterTermination = 1;");
    eval_ok(ctx, "if (afterTermination !== 0) throw 'return swallowed termination';");
    expect_interrupt(ctx, "outer: while (true) { try { while (true) {} } finally { break outer; } } afterTermination = 2;");
    eval_ok(ctx, "if (afterTermination !== 0) throw 'break swallowed termination';");
    bk_free_runtime(bk_get_runtime(ctx));
    puts("runtime hooks: PASS");
    return 0;
}
