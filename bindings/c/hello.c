#include <boomkat.h>
#include <stdio.h>

/* print(value): write String(value) and a newline to the FILE* in udata. */
static void print(bk_ctx js, void *out) {
    const char *text = bk_cstr(js, bk_arg(js, 0), NULL);
    if (text) fprintf(out, "%s\n", text);
}

int main(void) {
    bk_ctx js = bk_open();
    if (!js) return 1;
    bk_register_fn(js, 0, "print", print, 1, 0u, stdout);
    int failed = bk_exec(js, "print('Hello, world from Boomkat!')");
    if (failed) fprintf(stderr, "JavaScript: %s\n", bk_error(js));
    bk_close(js);
    return failed;
}
