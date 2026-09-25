#include <stdio.h>
#include <string.h>
#include "boomkat.h"
/*
 * Strict eval and ES modules through include/boomkat.h only: bk_set_strict,
 * bk_eval_module, and host-defined modules from bk_define_module.
 *
 * Prints a PASS line per section and exits non-zero on any failure, like the
 * other test/capi binaries.
 */
static int failures;

static void fail(const char *what, bk_ctx js) {
    printf("FAIL: %s: %s\n", what, js ? bk_error(js) : "");
    failures++;
}

/* Evaluate `src` and compare String(result) with `want`. */
static void expect_eval(bk_ctx js, const char *src, const char *want) {
    bk_value v = bk_eval_str(js, src);
    const char *got = v ? bk_cstr(js, v, NULL) : NULL;
    if (!got || strcmp(got, want) != 0) {
        printf("FAIL: %s => %s (want %s) %s\n", src, got ? got : "<error>", want,
               v ? "" : bk_error(js));
        failures++;
    }
    bk_free(js, v);
}

static void expect_eval_fails(bk_ctx js, const char *src, bk_status code) {
    bk_value v = bk_eval_str(js, src);
    if (v || bk_error_code(js) != code) {
        printf("FAIL: %s should fail with %s, got %s\n", src, bk_status_str(code),
               v ? "a value" : bk_status_str(bk_error_code(js)));
        failures++;
    }
    bk_free(js, v);
}

/* Evaluate `src` as module `name` and compare String(namespace[key]). */
static void expect_export(bk_ctx js, const char *name, const char *src,
                          const char *key, const char *want) {
    bk_value ns = bk_eval_module(js, src, strlen(src), name, strlen(name));
    if (!ns) { fail(name, js); return; }
    bk_value v = bk_getp(js, ns, key);
    const char *got = v ? bk_cstr(js, v, NULL) : NULL;
    if (!got || strcmp(got, want) != 0) {
        printf("FAIL: %s export %s = %s (want %s)\n", name, key, got ? got : "<error>", want);
        failures++;
    }
    bk_free(js, v);
    bk_free(js, ns);
}

static void test_strict(void) {
    bk_ctx js = bk_open();
    int before = failures;

    /* The default is sloppy. */
    expect_eval(js, "(function () { return this === globalThis; })()", "true");
    expect_eval(js, "implicitGlobal = 1; typeof implicitGlobal", "number");

    bk_set_strict(js, 1);
    expect_eval(js, "(function () { return this; })()", "undefined");
    expect_eval_fails(js, "with ({}) {}", BK_ERR_SYNTAX);
    expect_eval_fails(js, "undeclaredName = 1", BK_ERR_THROW);
    /* Strict source is script code, so its declarations outlive the call. */
    expect_eval(js, "function add(a, b) { return a + b; } var base = 40;", "undefined");
    expect_eval(js, "add(base, 2)", "42");
    expect_eval(js, "let shared = 'kept';", "undefined");
    expect_eval(js, "shared", "kept");
    /* GlobalDeclarationInstantiation throws the SyntaxError at run time. */
    expect_eval_fails(js, "let shared = 'again';", BK_ERR_THROW);
    if (!strstr(bk_error(js), "SyntaxError")) fail("redeclared let throws a SyntaxError", js);

    bk_set_strict(js, 0);
    expect_eval(js, "with ({ w: 7 }) { w }", "7");

    bk_close(js);
    if (failures == before) printf("PASS: bk_set_strict\n");
}

static void test_eval_module(void) {
    bk_ctx js = bk_open();
    int before = failures;

    expect_export(js, "main.js",
                  "export const answer = 6 * 7; export default 'dflt';",
                  "answer", "42");
    expect_export(js, "main.js", "export default 'dflt';", "default", "dflt");
    /* Module scope: top-level declarations are not globals. */
    expect_export(js, "scope.js", "var hidden = 1; export const seen = typeof globalThis.hidden;",
                  "seen", "undefined");
    /* Top-level await settles before bk_eval_module returns. */
    expect_export(js, "tla.js", "export const v = await Promise.resolve('awaited');",
                  "v", "awaited");

    const char *bad = "export const = 1;";
    if (bk_eval_module(js, bad, strlen(bad), "bad.js", 6) || bk_error_code(js) != BK_ERR_SYNTAX)
        fail("syntax error reports BK_ERR_SYNTAX", js);
    const char *throws = "throw new TypeError('from module');";
    if (bk_eval_module(js, throws, strlen(throws), "throws.js", 9) ||
        bk_error_code(js) != BK_ERR_THROW || !strstr(bk_error(js), "from module"))
        fail("a throw reports BK_ERR_THROW with its message", js);
    const char *missing = "import { x } from './does-not-exist.js';";
    if (bk_eval_module(js, missing, strlen(missing), "missing.js", 10))
        fail("an unloadable import fails", js);

    /* The runtime keeps working after a failed module. */
    expect_eval(js, "1 + 1", "2");

    bk_close(js);
    if (failures == before) printf("PASS: bk_eval_module\n");
}

static void define(bk_ctx js, const char *name, const char *src) {
    if (bk_define_module(js, name, strlen(name), src, strlen(src)) != BK_OK)
        fail(name, js);
}

static void test_define_module(void) {
    bk_ctx js = bk_open();
    int before = failures;

    define(js, "lib", "export function greet(n) { return 'hi ' + n; }");
    define(js, "app/util.js", "export const twice = (x) => x * 2;");
    define(js, "app/config.js", "import { twice } from './util.js'; export const size = twice(21);");

    expect_export(js, "entry.js",
                  "import { greet } from 'lib'; export const msg = greet('there');",
                  "msg", "hi there");
    /* Relative imports resolve against the importer's name. */
    expect_export(js, "app/main.js",
                  "import { size } from './config.js'; export const out = size;",
                  "out", "42");
    /* A dynamic import finds defined modules too. */
    expect_export(js, "dyn.js",
                  "const m = await import('lib'); export const msg = m.greet('dyn');",
                  "msg", "hi dyn");

    /* A later definition serves imports that load after it. */
    define(js, "late", "export const v = 'first';");
    define(js, "late", "export const v = 'second';");
    expect_export(js, "late_user.js", "export { v } from 'late';", "v", "second");

    if (bk_define_module(js, NULL, 0, "x", 1) != BK_ERR_INVALID)
        fail("a NULL name is BK_ERR_INVALID", js);

    bk_close(js);
    if (failures == before) printf("PASS: bk_define_module\n");
}

int main(void) {
    test_strict();
    test_eval_module();
    test_define_module();
    return failures ? 1 : 0;
}
