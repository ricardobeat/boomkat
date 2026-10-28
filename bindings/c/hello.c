#include <boomkat.h>
#include <stdio.h>

static bk_value print(bk_ctx js, bk_value self, unsigned argc, const bk_value *argv, void *out) {
    (void)self;
    fprintf(out, "%s\n", argc ? bk_cstr(js, argv[0], NULL) : "");
    return BK_UNDEFINED;
}

int main(void) {
    bk_ctx js = bk_create();
    bk_register_fn(js, 0, "print", print, 1, 0, stdout);
    int failed = bk_exec(js, "print('Hello, world from Boomkat!')");
    if (failed) fprintf(stderr, "%s\n", bk_error(js));
    bk_destroy(js);
    return failed;
}
