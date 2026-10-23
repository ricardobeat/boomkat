#include "boomkat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef USE_TRIM
extern bk_status bk_trim_caches(bk_runtime, size_t, size_t *);
#endif
struct Probe { bk_runtime runtime; unsigned failures; };
static void quiet_print(bk_ctx ctx, void *opaque) {
    struct Probe *probe = opaque;
    char text[1024]; size_t required;
    if (bk_argc(ctx) && bk_read_string(ctx, bk_arg(ctx, 0), text, sizeof(text), &required) == BK_OK
        && (strstr(text, "Error") || strstr(text, "FAIL") || strstr(text, "failed"))) {
        fprintf(stderr, "%s\n", text); probe->failures++;
    }
}
static void check_busy(bk_ctx ctx, void *opaque) {
    (void)ctx;
    struct Probe *probe = opaque;
#ifdef USE_TRIM
    size_t released = 123;
    if (bk_trim_caches(probe->runtime, 0, &released) != BK_ERR_INVALID || released != 0)
        probe->failures++;
#else
    (void)probe;
#endif
}
static int evaluate(bk_ctx context, const char *source, size_t length, const char *name) {
    bk_value value = bk_eval_ex(context, source, length, name, BK_EVAL_GLOBAL);
    if (bk_is_exception(value)) { fprintf(stderr, "%s: %s\n", name, bk_get_error_message(context)); return 1; }
    bk_free_value(context, value);
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *manifest = fopen(argv[1], "r");
    if (!manifest) return 2;
    struct Probe probe = { .runtime = bk_new_runtime() };
    if (!probe.runtime) return 2;
    unsigned phases = 0;
    size_t total_released = 0;
    char path[1024];
    while (fgets(path, sizeof(path), manifest)) {
        path[strcspn(path, "\r\n")] = 0;
        FILE *input = fopen(path, "rb");
        if (!input) return 2;
        fseek(input, 0, SEEK_END); long length = ftell(input); rewind(input);
        if (length < 0) return 2;
        char *source = malloc((size_t)length + 1);
        if (!source || fread(source, 1, (size_t)length, input) != (size_t)length) return 2;
        source[length] = 0; fclose(input);
        bk_ctx context = bk_new_context(probe.runtime);
        if (!context) return 2;
        if (bk_register_fn(context, 0, "print", quiet_print, 1, 0, &probe) != BK_OK
            || bk_register_fn(context, 0, "__trim_probe", check_busy, 0, 0, &probe) != BK_OK) return 2;
        bk_value warm = bk_eval(context, "(function(o){return o.x;})");
        bk_value object = bk_eval(context, "({x:17})");
        bk_value receiver = bk_eval(context, "undefined");
        if (bk_is_exception(warm) || bk_is_exception(object) || bk_is_exception(receiver)) return 1;
        for (unsigned n = 0; n < 2; n++) {
            bk_value result = bk_call(context, warm, receiver, &object, 1);
            double number;
            if (bk_is_exception(result) || bk_read_number(context, result, &number) != BK_OK || number != 17) return 1;
            bk_free_value(context, result);
        }
        if (evaluate(context, "__trim_probe();", 15, "probe.js")
            || evaluate(context, source, (size_t)length, path)) return 1;
        free(source);
#ifdef USE_TRIM
        size_t released = 0;
        if (bk_trim_caches(probe.runtime, 0, &released) != BK_OK) return 1;
        total_released += released;
#endif
        for (unsigned n = 0; n < 3; n++) {
            bk_value result = bk_call(context, warm, receiver, &object, 1);
            double number;
            if (bk_is_exception(result) || bk_read_number(context, result, &number) != BK_OK || number != 17) return 1;
            bk_free_value(context, result);
        }
        bk_free_value(context, warm);
        bk_free_value(context, object);
        bk_free_value(context, receiver);
        bk_free_context(context);
        phases++;
    }
    fclose(manifest);
    if (probe.failures || phases == 0) return 1;
#ifdef USE_TRIM
    if (total_released == 0) return 1;
#endif
    fprintf(stderr, "cache bytes released=%zu\n", total_released);
    bk_free_runtime(probe.runtime);
    printf("PASS phases=%u\n", phases);
    return 0;
}
