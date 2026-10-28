/* Host module loaders, native modules, invalidation and bk_import. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int resolves, loads, version = 1;

static bk_status resolve(bk_ctx ctx, const char *referrer, const char *specifier,
                         bk_module_request *req, void *opaque) {
    (void)ctx; (void)referrer;
    assert(opaque == &resolves);
    resolves++;
    if (strncmp(specifier, "app:", 4) == 0) return bk_module_set_name(req, specifier, strlen(specifier));
    if (strcmp(specifier, "missing") == 0) {
        bk_module_fail(req, bk_new_error(ctx, BK_ERROR_RANGE, "no such module"));
        return BK_ERR_INVALID;
    }
    return BK_OK;   /* fall back */
}

static bk_status load(bk_ctx ctx, const char *name, bk_module_request *req, void *opaque) {
    (void)opaque;
    loads++;
    if (strcmp(name, "app:math") == 0) {
        char src[128];
        int n = snprintf(src, sizeof src, "export const version = %d; export default function sq(x) { return x * x }", version);
        return bk_module_provide(req, src, (size_t)n);
    }
    if (strcmp(name, "app:native") == 0) {
        bk_value exports = bk_eval_ex(ctx, "({ answer: 42, greet: () => 'hi' })", 35, NULL, BK_EVAL_GLOBAL);
        return bk_module_provide_native(req, exports);
    }
    return BK_ERR_INVALID;
}

static bk_value eval_module(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "main.js", BK_EVAL_MODULE);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    return r;
}

static int truthy(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), NULL, BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    return bk_to_bool(ctx, r);
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_runtime rt = bk_get_runtime(ctx);
    bk_module_loader loader = { resolve, load, &resolves, 0 };
    assert(bk_set_module_loader(rt, &loader) == BK_OK);

    bk_value ns = eval_module(ctx, "import sq, { version } from 'app:math'; import { answer, greet } from 'app:native';"
                                   " globalThis.out = [sq(7), version, answer, greet()].join()");
    assert(!bk_is_exception(ns));
    bk_run_jobs(rt);
    assert(truthy(ctx, "out === '49,1,42,hi'"));
    int loads_before = loads;
    assert(!bk_is_exception(eval_module(ctx, "import { version } from 'app:math'; globalThis.v2 = version")));
    assert(loads == loads_before && truthy(ctx, "v2 === 1"));

    /* Invalidation reloads from the loader; old bindings keep the old instance. */
    version = 2;
    assert(bk_invalidate_module(ctx, "app:math", 8) == BK_OK);
    assert(!bk_is_exception(eval_module(ctx, "import { version } from 'app:math'; globalThis.v3 = version")));
    assert(loads == loads_before + 1 && truthy(ctx, "v3 === 2"));
    assert(bk_invalidate_module(ctx, "app:nothing", 11) == BK_ERR_INVALID);

    /* Failures: a named export the native module lacks, a rejected resolve. */
    assert(bk_is_exception(eval_module(ctx, "import { nope } from 'app:native'")));
    bk_free_value(ctx, bk_get_exception(ctx));
    assert(bk_is_exception(eval_module(ctx, "import x from 'missing'")));
    bk_free_value(ctx, bk_get_exception(ctx));

    /* bk_define_native_module wins over the loader and can be replaced. */
    bk_value ex = bk_eval_ex(ctx, "({ get lazy() { return 'read' }, default: 'dflt' })", 51, NULL, BK_EVAL_GLOBAL);
    assert(bk_define_native_module(ctx, "engine", 6, ex) == BK_OK);
    assert(!bk_is_exception(eval_module(ctx, "import d, { lazy } from 'engine'; globalThis.e1 = d + lazy")));
    assert(truthy(ctx, "e1 === 'dfltread'"));
    assert(bk_define_native_module(ctx, "engine", 6, bk_eval_ex(ctx, "({ v: 2 })", 10, NULL, BK_EVAL_GLOBAL)) == BK_OK);
    assert(!bk_is_exception(eval_module(ctx, "import { v } from 'engine'; globalThis.e2 = v")));
    assert(truthy(ctx, "e2 === 2"));
    assert(bk_define_native_module(ctx, "bad", 3, bk_new_number(ctx, 1)) == BK_ERR_TYPE);

    /* bk_import returns a promise of the namespace. */
    bk_value p = bk_import(ctx, "app:native", 10);
    assert(p);
    bk_run_jobs(rt);
    bk_promise_state st;
    assert(bk_promise_state_get(ctx, p, &st) == BK_OK && st == BK_PROMISE_FULFILLED);
    bk_value nsv = bk_promise_result(ctx, p);
    assert(bk_to_number(ctx, bk_get_property(ctx, nsv, "answer", 6)) == 42);
    bk_value bad = bk_import(ctx, "missing", 7);
    bk_run_jobs(rt);
    assert(bk_promise_state_get(ctx, bad, &st) == BK_OK && st == BK_PROMISE_REJECTED);

    /* Without filesystem fallback, an unanswered load fails. */
    bk_module_loader strict = { resolve, load, &resolves, BK_LOADER_NO_FILESYSTEM_FALLBACK };
    assert(bk_set_module_loader(rt, &strict) == BK_OK);
    assert(bk_is_exception(eval_module(ctx, "import x from './test/modules/basic/main.js'")));
    bk_free_value(ctx, bk_get_exception(ctx));
    bk_module_loader async_loader = { resolve, load, NULL, BK_LOADER_ASYNC };
    assert(bk_set_module_loader(rt, &async_loader) == BK_ERR_UNSUPPORTED);
    assert(bk_set_module_loader(rt, NULL) == BK_OK);

    bk_destroy(ctx);
    puts("module_loader: PASS");
    return 0;
}
