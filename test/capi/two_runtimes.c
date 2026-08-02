/*
 * Multiple runtimes in one process.
 *
 * The engine kept a process-global heap pointer until plan 068 phase 4, so a
 * second runtime silently allocated into the first one's heap. Nothing here
 * could run before that landed. Every case below is a property the single
 * runtime suite cannot observe, which is why it caught none of the bugs the
 * conversion prototypes hit.
 */
#include <stdio.h>
#include <string.h>
#include "jse.h"

static int failures;
static void check(const char *label, int cond) {
    if (cond) { printf("ok   %s\n", label); }
    else      { printf("FAIL %s\n", label); failures++; }
}

static int eval_num(jse_runtime rt, const char *src, double *out) {
    jse_value v;
    if (jse_eval(rt, src, strlen(src), &v) != JSE_OK) return 0;
    int ok = jse_get_number(rt, v, out) == JSE_OK;
    jse_value_free(rt, v);
    return ok;
}

static int eval_str(jse_runtime rt, const char *src, char *buf, size_t cap) {
    jse_value v; size_t n = 0;
    if (jse_eval(rt, src, strlen(src), &v) != JSE_OK) return 0;
    int ok = jse_get_string(rt, v, buf, cap, &n) == JSE_OK;
    jse_value_free(rt, v);
    return ok;
}

/* --- 1. independent globals, objects, shapes, strings -------------------- */

static void test_independence(void) {
    jse_runtime A = NULL, B = NULL, C = NULL;
    jse_value t; double d; char s[64];

    if (jse_open(&A) != JSE_OK || jse_open(&B) != JSE_OK || jse_open(&C) != JSE_OK) {
        check("three runtimes open", 0);
        return;
    }
    check("three runtimes open", 1);

    /* Two can pass by symmetry, so the third is not redundant. */
    const char *sa = "var x=111; var s='alpha-A'; var o={}; for(var i=0;i<200;i++)o['k'+i]=i; 1";
    const char *sb = "var x=222; var s='alpha-B'; var o={}; for(var i=0;i<200;i++)o['k'+i]=i*2; 1";
    const char *sc = "var x=333; var s='alpha-C'; var o={}; for(var i=0;i<200;i++)o['k'+i]=i*3; 1";
    jse_eval(A, sa, strlen(sa), &t); jse_value_free(A, t);
    jse_eval(B, sb, strlen(sb), &t); jse_value_free(B, t);
    jse_eval(C, sc, strlen(sc), &t); jse_value_free(C, t);

    check("A.x kept its value", eval_num(A, "x", &d) && d == 111);
    check("B.x kept its value", eval_num(B, "x", &d) && d == 222);
    check("C.x kept its value", eval_num(C, "x", &d) && d == 333);

    /* Identical property sequences in each: this is what a shared shape table
       would break, because the objects would converge on one layout. */
    check("A object intact", eval_num(A, "o.k199", &d) && d == 199);
    check("B object intact", eval_num(B, "o.k199", &d) && d == 398);
    check("C object intact", eval_num(C, "o.k199", &d) && d == 597);

    check("A string intact", eval_str(A, "s", s, sizeof s) && !strcmp(s, "alpha-A"));
    check("B string intact", eval_str(B, "s", s, sizeof s) && !strcmp(s, "alpha-B"));

    /* Interning is per heap; the same literal in two heaps is two HStrings. */
    check("A interning correct", eval_num(A, "var q='shared'; q==='shared'?1:0", &d) && d == 1);
    check("B interning correct", eval_num(B, "var q='shared'; q==='shared'?1:0", &d) && d == 1);

    /* Prototype patches must not leak between runtimes. */
    const char *pa = "Array.prototype.tag=function(){return 'A';}; 1";
    jse_eval(A, pa, strlen(pa), &t); jse_value_free(A, t);
    check("A prototype patch applies", eval_str(A, "[].tag()", s, sizeof s) && !strcmp(s, "A"));
    check("B prototype unpatched", eval_num(B, "typeof [].tag==='undefined'?1:0", &d) && d == 1);

    /* Interleaved array growth. */
    const char *ga = "var a=[]; for(var i=0;i<5000;i++)a.push(i); a.length";
    const char *gb = "var a=[]; for(var i=0;i<3000;i++)a.push(i*2); a.length";
    check("A array grew", eval_num(A, ga, &d) && d == 5000);
    check("B array grew", eval_num(B, gb, &d) && d == 3000);
    check("A array intact after B grew", eval_num(A, "a[4999]", &d) && d == 4999);

    jse_close(A);
    check("B survives A closing", eval_num(B, "o.k199", &d) && d == 398);
    check("C survives A closing", eval_num(C, "x", &d) && d == 333);
    check("B can still allocate", eval_num(B, "var n={}; for(var i=0;i<80;i++)n['p'+i]=i; n.p79", &d) && d == 79);
    jse_close(B);
    check("C survives B closing", eval_num(C, "o.k199", &d) && d == 597);
    jse_close(C);
}

/* --- 2. a host function in A calling into B ------------------------------ */

static jse_runtime g_other;   /* the *other* runtime, for the callback below */

/*
 * Reads its argument, evaluates on a different runtime, then reads back a value
 * it persisted into its OWN runtime's registry.
 *
 * The persisted handle is the discriminating part. An argument handle carries
 * the scope bit and resolves straight off the context, so it stays correct
 * however the runtime is found. A persisted handle is an index into one
 * runtime's registry, so resolving it against the wrong runtime answers with
 * whatever that runtime happens to hold at the same index. That is the failure
 * the context tier exists to prevent, and it needs a call into a second runtime
 * to become reachable at all.
 */
static void h_reenter(jse_call_ctx ctx, void *udata) {
    double arg = -1, kept = -1;
    jse_value v, held;
    jse_runtime mine = jse_ctx_runtime(ctx);
    (void)udata;
    jse_ctx_get_number(ctx, jse_arg(ctx, 0), &arg);
    /* Park a distinctive value in this runtime's registry. */
    held = jse_value_persist(ctx, jse_arg(ctx, 0));
    /* Give the other runtime a live handle at the SAME registry index, holding a
       different value. Both registries number their slots from zero, so this is
       what turns a wrong-runtime read into a wrong answer rather than a clean
       miss. Kept alive across the read below, then released. */
    if (jse_eval(g_other, "-777", 4, &v) != JSE_OK) v = 0;
    /* Read it back through the runtime that owns it. */
    if (jse_ctx_get_number(ctx, held, &kept) != JSE_OK) kept = -2;
    jse_value_free(mine, held);
    if (v != 0) jse_value_free(g_other, v);
    jse_return_number(ctx, (arg == kept) ? kept : -1);
}

/* Same name in both runtimes, different udata: each must see its own. */
static void h_udata(jse_call_ctx ctx, void *udata) {
    jse_return_number(ctx, udata ? *(double *)udata : -1);
}

static void test_reentry(void) {
    jse_runtime A = NULL, B = NULL;
    double d, ua = 10, ub = 20;

    if (jse_open(&A) != JSE_OK || jse_open(&B) != JSE_OK) {
        check("reentry: two runtimes open", 0);
        return;
    }
    g_other = B;
    if (jse_register_fn(A, "hostReenter", 11, h_reenter, NULL, 1, 0) != JSE_OK) {
        check("reentry: register", 0);
        jse_close(A); jse_close(B); return;
    }
    check("A persisted handle survives a call into B", eval_num(A, "hostReenter(42)", &d) && d == 42);

    /* Same name, both runtimes, distinct udata. */
    jse_register_fn(A, "whoami", 6, h_udata, &ua, 0, 0);
    jse_register_fn(B, "whoami", 6, h_udata, &ub, 0, 0);
    check("A host fn sees A's udata", eval_num(A, "whoami()", &d) && d == 10);
    check("B host fn sees B's udata", eval_num(B, "whoami()", &d) && d == 20);

    jse_close(A);
    jse_close(B);
}

/* --- 3. cross-runtime handles are refused -------------------------------- */

static void test_cross_handles(void) {
    jse_runtime A = NULL, B = NULL;
    jse_value va;
    double d; char s[64]; size_t n = 0;

    if (jse_open(&A) != JSE_OK || jse_open(&B) != JSE_OK) {
        check("cross: two runtimes open", 0);
        return;
    }
    if (jse_eval(A, "'from-A'", 8, &va) != JSE_OK) {
        check("cross: eval in A", 0);
        jse_close(A); jse_close(B); return;
    }
    /* A's handle read through B must fail rather than answer with B's value. */
    check("A handle rejected by B (string)", jse_get_string(B, va, s, sizeof s, &n) != JSE_OK);
    check("A handle rejected by B (number)", jse_get_number(B, va, &d) != JSE_OK);

    /* The value itself may cross by copy, and the two strings are distinct
       HStrings even though they compare equal as text. */
    if (jse_get_string(A, va, s, sizeof s, &n) == JSE_OK) {
        char expr[128];
        snprintf(expr, sizeof expr, "'%s'==='from-A'?1:0", s);
        check("value copied into B compares equal there", eval_num(B, expr, &d) && d == 1);
    } else {
        check("value copied into B compares equal there", 0);
    }

    jse_close(A);
    check("A handle rejected by B after A closed",
          jse_get_string(B, va, s, sizeof s, &n) != JSE_OK);
    jse_close(B);
}

int main(void) {
    test_independence();
    test_reentry();
    test_cross_handles();
    if (failures) { printf("\nFAILURES: %d\n", failures); return 1; }
    printf("\nall multi-runtime tests passed\n");
    return 0;
}
