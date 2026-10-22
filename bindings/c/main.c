#include <boomkat.h>
#include <stdio.h>

int main(void) {
    bk_ctx js = bk_create();
    bk_value result = bk_eval(js, "[1,2,3].map(x => x*x).join(',')");
    if (bk_is_exception(result)) fprintf(stderr, "%s\n", bk_error(js));
    else puts(bk_cstr(js, result, NULL));
    int failed = bk_is_exception(result);
    bk_free(js, result);
    bk_destroy(js);
    return failed;
}
