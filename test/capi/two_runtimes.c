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
#include "boomkat.h"

static int failures;
static void check(const char *label, int cond) {
    if (cond) { printf("ok   %s\n", label); }
    else      { printf("FAIL %s\n", label); failures++; }
}

static int eval_num(bk_runtime rt, const char *src, double *out) {
    bk_value v;
    if (bk_eval(rt, src, strlen(src), &v) != BK_OK) return 0;
    int ok = bk_get_number(rt, v, out) == BK_OK;
    bk_value_free(rt, v);
    return ok;
}

static int eval_str(bk_runtime rt, const char *src, char *buf, size_t cap) {
    bk_value v; size_t n = 0;
    if (bk_eval(rt, src, strlen(src), &v) != BK_OK) return 0;
    int ok = bk_get_string(rt, v, buf, cap, &n) == BK_OK;
    bk_value_free(rt, v);
    return ok;
}

/* --- 1. independent globals, objects, shapes, strings -------------------- */

static void test_independence(void) {
    bk_runtime A = NULL, B = NULL, C = NULL;
    bk_value t; double d; char s[64];

    if (bk_open(&A) != BK_OK || bk_open(&B) != BK_OK || bk_open(&C) != BK_OK) {
        check("three runtimes open", 0);
        return;
    }
    check("three runtimes open", 1);

    /* Two can pass by symmetry, so the third is not redundant. */
    const char *sa = "var x=111; var s='alpha-A'; var o={}; for(var i=0;i<200;i++)o['k'+i]=i; 1";
    const char *sb = "var x=222; var s='alpha-B'; var o={}; for(var i=0;i<200;i++)o['k'+i]=i*2; 1";
    const char *sc = "var x=333; var s='alpha-C'; var o={}; for(var i=0;i<200;i++)o['k'+i]=i*3; 1";
    bk_eval(A, sa, strlen(sa), &t); bk_value_free(A, t);
    bk_eval(B, sb, strlen(sb), &t); bk_value_free(B, t);
    bk_eval(C, sc, strlen(sc), &t); bk_value_free(C, t);

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
    bk_eval(A, pa, strlen(pa), &t); bk_value_free(A, t);
    check("A prototype patch applies", eval_str(A, "[].tag()", s, sizeof s) && !strcmp(s, "A"));
    check("B prototype unpatched", eval_num(B, "typeof [].tag==='undefined'?1:0", &d) && d == 1);

    /* Interleaved array growth. */
    const char *ga = "var a=[]; for(var i=0;i<5000;i++)a.push(i); a.length";
    const char *gb = "var a=[]; for(var i=0;i<3000;i++)a.push(i*2); a.length";
    check("A array grew", eval_num(A, ga, &d) && d == 5000);
    check("B array grew", eval_num(B, gb, &d) && d == 3000);
    check("A array intact after B grew", eval_num(A, "a[4999]", &d) && d == 4999);

    bk_close(A);
    check("B survives A closing", eval_num(B, "o.k199", &d) && d == 398);
    check("C survives A closing", eval_num(C, "x", &d) && d == 333);
    check("B can still allocate", eval_num(B, "var n={}; for(var i=0;i<80;i++)n['p'+i]=i; n.p79", &d) && d == 79);
    bk_close(B);
    check("C survives B closing", eval_num(C, "o.k199", &d) && d == 597);
    bk_close(C);
}

/* --- 2. a host function in A calling into B ------------------------------ */

static bk_runtime g_other;   /* the *other* runtime, for the callback below */

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
static void h_reenter(bk_call_ctx ctx, void *udata) {
    double arg = -1, kept = -1;
    bk_value v, held;
    bk_runtime mine = bk_ctx_runtime(ctx);
    (void)udata;
    bk_ctx_get_number(ctx, bk_arg(ctx, 0), &arg);
    /* Park a distinctive value in this runtime's registry. */
    held = bk_value_persist(ctx, bk_arg(ctx, 0));
    /* Give the other runtime a live handle at the SAME registry index, holding a
       different value. Both registries number their slots from zero, so this is
       what turns a wrong-runtime read into a wrong answer rather than a clean
       miss. Kept alive across the read below, then released. */
    if (bk_eval(g_other, "-777", 4, &v) != BK_OK) v = 0;
    /* Read it back through the runtime that owns it. */
    if (bk_ctx_get_number(ctx, held, &kept) != BK_OK) kept = -2;
    bk_value_free(mine, held);
    if (v != 0) bk_value_free(g_other, v);
    bk_return_number(ctx, (arg == kept) ? kept : -1);
}

/* Same name in both runtimes, different udata: each must see its own. */
static void h_udata(bk_call_ctx ctx, void *udata) {
    bk_return_number(ctx, udata ? *(double *)udata : -1);
}

static void test_reentry(void) {
    bk_runtime A = NULL, B = NULL;
    double d, ua = 10, ub = 20;

    if (bk_open(&A) != BK_OK || bk_open(&B) != BK_OK) {
        check("reentry: two runtimes open", 0);
        return;
    }
    g_other = B;
    if (bk_register_fn(A, "hostReenter", 11, h_reenter, NULL, 1, 0) != BK_OK) {
        check("reentry: register", 0);
        bk_close(A); bk_close(B); return;
    }
    check("A persisted handle survives a call into B", eval_num(A, "hostReenter(42)", &d) && d == 42);

    /* Same name, both runtimes, distinct udata. */
    bk_register_fn(A, "whoami", 6, h_udata, &ua, 0, 0);
    bk_register_fn(B, "whoami", 6, h_udata, &ub, 0, 0);
    check("A host fn sees A's udata", eval_num(A, "whoami()", &d) && d == 10);
    check("B host fn sees B's udata", eval_num(B, "whoami()", &d) && d == 20);

    bk_close(A);
    bk_close(B);
}

/* --- 3. cross-runtime handles are refused -------------------------------- */

static void test_cross_handles(void) {
    bk_runtime A = NULL, B = NULL;
    bk_value va;
    double d; char s[64]; size_t n = 0;

    if (bk_open(&A) != BK_OK || bk_open(&B) != BK_OK) {
        check("cross: two runtimes open", 0);
        return;
    }
    if (bk_eval(A, "'from-A'", 8, &va) != BK_OK) {
        check("cross: eval in A", 0);
        bk_close(A); bk_close(B); return;
    }
    /* A's handle read through B must fail rather than answer with B's value. */
    check("A handle rejected by B (string)", bk_get_string(B, va, s, sizeof s, &n) != BK_OK);
    check("A handle rejected by B (number)", bk_get_number(B, va, &d) != BK_OK);

    /* The value itself may cross by copy, and the two strings are distinct
       HStrings even though they compare equal as text. */
    if (bk_get_string(A, va, s, sizeof s, &n) == BK_OK) {
        char expr[128];
        snprintf(expr, sizeof expr, "'%s'==='from-A'?1:0", s);
        check("value copied into B compares equal there", eval_num(B, expr, &d) && d == 1);
    } else {
        check("value copied into B compares equal there", 0);
    }

    bk_close(A);
    check("A handle rejected by B after A closed",
          bk_get_string(B, va, s, sizeof s, &n) != BK_OK);
    bk_close(B);
}

int main(void) {
    test_independence();
    test_reentry();
    test_cross_handles();
    if (failures) { printf("\nFAILURES: %d\n", failures); return 1; }
    printf("\nall multi-runtime tests passed\n");
    return 0;
}
