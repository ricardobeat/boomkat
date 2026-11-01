#include <boomkat.h>
#include <stdio.h>

static bk_value add(bk_ctx js, bk_value self, unsigned argc, const bk_value *argv, void *opaque) {
    (void)self; (void)opaque;
    double total = 0;
    for (unsigned i = 0; i < argc; i++) {
        double value;
        if (bk_read_number(js, argv[i], &value) != BK_OK) {
            return bk_throw_error(js, BK_ERROR_TYPE, "add expects numbers");
        }
        total += value;
    }
    return bk_new_number(js, total);
}

/* Values made inside a callback are locals of the call: nothing to free. */
static bk_value twice(bk_ctx js, bk_value self, unsigned argc, const bk_value *argv, void *opaque) {
    (void)self; (void)opaque; (void)argc;
    bk_value fn = bk_arg(js, 0), value = bk_arg(js, 1);
    bk_value first = bk_call(js, fn, BK_UNDEFINED, &value, 1);
    if (bk_is_exception(first)) return BK_EXCEPTION;
    return bk_call(js, argv[0], BK_UNDEFINED, &first, 1);
}

int main(void) {
    bk_ctx js = bk_create();
    bk_register_fn(js, 0, "add", add, 2, 0, NULL);
    bk_register_fn(js, 0, "twice", twice, 2, 0, NULL);
    bk_value result = bk_eval(js, "add(40,2) + twice(x => x*2, 3)");
    int failed = bk_is_exception(result);
    if (failed) fprintf(stderr, "%s\n", bk_error(js));
    else printf("%s\n", bk_cstr(js, result, NULL));
    bk_free(js, result);
    bk_destroy(js);
    return failed;
}
