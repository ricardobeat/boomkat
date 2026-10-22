#include <boomkat.h>
#include <stdio.h>

static void add(bk_ctx js, void *opaque) {
    (void)opaque;
    double total = 0;
    for (unsigned i = 0; i < bk_argc(js); i++) {
        double value;
        if (bk_read_number(js, bk_arg(js, i), &value) != BK_OK) {
            bk_throw_error(js, BK_ERROR_TYPE, "add expects numbers");
            return;
        }
        total += value;
    }
    bk_return_number(js, total);
}

static void twice(bk_ctx js, void *opaque) {
    (void)opaque;
    bk_value fn = bk_arg(js, 0), value = bk_arg(js, 1);
    bk_value first = bk_call(js, fn, 0, &value, 1);
    if (bk_is_exception(first)) return;
    bk_value result = bk_call(js, fn, 0, &first, 1);
    if (!bk_is_exception(result)) bk_return(js, result);
    bk_free(js, result);
    bk_free(js, first);
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
