#include <boomkat.h>
#include <stdio.h>

static void print(bk_ctx js, void *out) {
    fprintf(out, "%s\n", bk_cstr(js, bk_arg(js, 0), NULL));
}

int main(void) {
    bk_ctx js = bk_create();
    bk_register_fn(js, 0, "print", print, 1, 0, stdout);
    int failed = bk_exec(js, "print('Hello, world from Boomkat!')");
    if (failed) fprintf(stderr, "%s\n", bk_error(js));
    bk_destroy(js);
    return failed;
}
