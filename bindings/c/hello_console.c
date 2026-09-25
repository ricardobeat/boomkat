#include <boomkat.h>
#include <stdio.h>

static void console_log(bk_ctx js, void *udata) {
    (void)udata;
    for (unsigned int i = 0; i < bk_argc(js); i++) {
        const char *text = bk_cstr(js, bk_arg(js, i), NULL);
        if (!text) return; /* A JavaScript toString threw; the engine reports it. */
        if (i) putchar(' ');
        fputs(text, stdout);
    }
    putchar('\n');
}

int main(void) {
    bk_ctx js = bk_open();
    if (!js) return 1;

    /* Console is a host module: make an object, add log(), expose it to JS. */
    bk_value console = bk_object(js);
    if (!console ||
        bk_register_fn(js, console, "log", console_log, 1, 0u, NULL) != BK_OK ||
        bk_set_globalp(js, "console", console) != BK_OK) {
        fprintf(stderr, "console setup: %s\n", bk_error(js));
        bk_free(js, console);
        bk_close(js);
        return 1;
    }
    bk_free(js, console);

    if (bk_exec(js, "console.log('Hello, world from Boomkat!')")) {
        fprintf(stderr, "JavaScript: %s\n", bk_error(js));
        bk_close(js);
        return 1;
    }
    bk_close(js);
    return 0;
}
