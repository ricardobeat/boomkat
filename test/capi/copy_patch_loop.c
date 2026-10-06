#include "boomkat.h"
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int polls;
static int stop(bk_ctx ctx, void *opaque) { (void)ctx; (void)opaque; return ++polls >= 10; }
static void timeout(int signal) { (void)signal; _exit(2); }
int main(void) {
    bk_ctx ctx = bk_open();
    if (!ctx) return 1;
    const char *warm = "function hot(n){let s=0;for(let i=0;i<n;i++)s+=i;return s;} hot(200000)";
    bk_value value = bk_eval(ctx, warm, strlen(warm));
    if (!value) return 3;
    bk_free(ctx, value);
    bk_set_interrupt(ctx, stop, NULL);
    signal(SIGALRM, timeout);
    alarm(5);
    const char *run = "hot(1000000000000)";
    value = bk_eval(ctx, run, strlen(run));
    alarm(0);
    if (bk_error_code(ctx) != BK_ERR_INTERRUPT || polls != 10) return 4;
    bk_set_interrupt(ctx, NULL, NULL);
    value = bk_eval(ctx, "1+1", 3);
    if (!value) return 5;
    bk_free(ctx, value);
    bk_close(ctx);
    puts("PASS native-loop interrupt and teardown");
    return 0;
}
