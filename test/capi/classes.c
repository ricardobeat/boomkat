/* Host classes: definition, construction from C and JS, brand checks,
 * subclassing and finalization. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { double x, y; } vec;

static int freed, freed_points;
static bk_class Vec, Vec3, Point;

static void free_vec(void *payload, void *opaque) {
    assert(opaque == (void *)&Vec);
    free(payload);
    freed++;
}

static void free_point(void *payload, void *opaque) {
    (void)opaque;
    free(payload);
    freed_points++;
}

static bk_value construct_vec(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    assert(opaque == (void *)&Vec);
    vec *v = malloc(sizeof *v);
    v->x = argc > 0 ? bk_to_number(ctx, argv[0]) : 0;
    v->y = argc > 1 ? bk_to_number(ctx, argv[1]) : 0;
    assert(bk_set_instance_payload(ctx, this_value, Vec, v) == BK_OK);
    return BK_UNDEFINED;
}

static bk_value vec_len(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)argc; (void)argv; (void)opaque;
    vec *v = bk_get_instance_payload(ctx, this_value, Vec);
    if (!v) return bk_throw_error(ctx, BK_ERROR_TYPE, "not a Vec");
    return bk_new_number(ctx, v->x * v->x + v->y * v->y);
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "classes.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static int truthy(bk_ctx ctx, const char *src) { return bk_to_bool(ctx, eval(ctx, src)); }

int main(void) {
    bk_ctx ctx = bk_create();
    bk_value ctor, proto;
    bk_class_def vdef = { "Vec", 0, free_vec, construct_vec, 2, 0, &Vec };
    Vec = bk_define_class(ctx, &vdef, &ctor, &proto);
    assert(Vec != 0);
    bk_set_global_property(ctx, "Vec", 3, ctor);
    bk_value len = bk_new_c_function(ctx, vec_len, "len", 0, 0, NULL, NULL, NULL);
    bk_set_property(ctx, proto, "len", 3, len);

    assert(truthy(ctx, "new Vec(3, 4).len() === 25 && new Vec(1, 1) instanceof Vec && Vec.name === 'Vec' && Vec.length === 2"));
    assert(truthy(ctx, "Object.getPrototypeOf(new Vec()) === Vec.prototype && Vec.prototype.constructor === Vec"));
    assert(truthy(ctx, "(() => { try { Vec(1, 2); return false } catch (e) { return e instanceof TypeError } })()"));
    /* A stolen method fails its brand check. */
    assert(truthy(ctx, "(() => { try { Vec.prototype.len.call({}); return false } catch (e) { return e.message === 'not a Vec' } })()"));

    /* A JS subclass gets a host instance through super(). */
    assert(truthy(ctx, "class V2 extends Vec { constructor() { super(5, 12); this.tag = 1 } }"
                       " const v2 = new V2(); v2.len() === 169 && v2 instanceof V2 && v2.tag === 1"));

    /* From C, with and without new_target. */
    vec *raw = malloc(sizeof *raw);
    raw->x = 1; raw->y = 2;
    bk_value inst = bk_new_instance(ctx, Vec, raw, 0);
    assert(bk_get_instance_payload(ctx, inst, Vec) == raw && bk_get_instance_class(ctx, inst) == Vec);
    bk_set_global_property(ctx, "made", 4, inst);
    assert(truthy(ctx, "made.len() === 5 && made instanceof Vec"));
    assert(bk_set_instance_payload(ctx, inst, Vec, raw) == BK_ERR_INVALID);
    bk_value sub = eval(ctx, "class Sub extends Vec {}; Sub");
    bk_value inst2 = bk_new_instance(ctx, Vec, NULL, sub);
    bk_set_global_property(ctx, "made2", 5, inst2);
    assert(truthy(ctx, "made2 instanceof Sub"));
    assert(bk_get_instance_payload(ctx, inst2, Vec) == NULL);
    assert(bk_get_instance_payload(ctx, eval(ctx, "({})"), Vec) == NULL);
    assert(bk_get_instance_class(ctx, eval(ctx, "({})")) == 0);

    /* A C subclass: brand checks accept it for the parent, not the reverse. */
    bk_value ctor3;
    bk_class_def v3def = { "Vec3", Vec, free_vec, NULL, 0, 0, &Vec };
    Vec3 = bk_define_class(ctx, &v3def, &ctor3, NULL);
    bk_set_global_property(ctx, "Vec3", 4, ctor3);
    assert(truthy(ctx, "Object.getPrototypeOf(Vec3) === Vec && Object.getPrototypeOf(Vec3.prototype) === Vec.prototype"));
    assert(truthy(ctx, "(() => { try { new Vec3(); return false } catch (e) { return e.message === 'Illegal constructor' } })()"));
    vec *raw3 = calloc(1, sizeof *raw3);
    bk_value i3 = bk_new_instance(ctx, Vec3, raw3, 0);
    assert(bk_get_instance_payload(ctx, i3, Vec) == raw3 && bk_get_instance_payload(ctx, i3, Vec3) == raw3);
    assert(bk_get_instance_payload(ctx, inst, Vec3) == NULL);
    assert(bk_set_instance_payload(ctx, i3, Vec3, NULL) == BK_OK);   /* detach: no finalizer */
    free(raw3);
    bk_free_value(ctx, i3);

    /* Invalid definitions. */
    bk_class_def bad = { "Bad", 999, NULL, NULL, 0, 0, NULL };
    assert(bk_define_class(ctx, &bad, NULL, NULL) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);
    bk_class_def badflags = { "Bad", 0, NULL, NULL, 0, 8, NULL };
    assert(bk_define_class(ctx, &badflags, NULL, NULL) == 0);

    /* Deferred finalizers wait for bk_run_finalizers. */
    bk_class_def pdef = { "Point", 0, free_point, NULL, 0, BK_CLASS_DEFER_FINALIZE, NULL };
    Point = bk_define_class(ctx, &pdef, NULL, NULL);
    for (int i = 0; i < 1000; i++) bk_free_value(ctx, bk_new_instance(ctx, Point, malloc(8), 0));
    eval(ctx, "for (let i = 0; i < 200000; i++) ({ a: [i] })");
    assert(freed_points == 0);
    unsigned ran = bk_run_finalizers(bk_get_runtime(ctx));
    assert(ran > 0 && freed_points == (int)ran);
    assert(bk_run_finalizers(bk_get_runtime(ctx)) == 0);

    bk_destroy(ctx);
    assert(freed_points == 1000);
    /* Every Vec payload created: 3 from JS checks, V2, made; the rest had none. */
    printf("classes: PASS (freed %d)\n", freed);
    return 0;
}
