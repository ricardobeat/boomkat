/* bk_define_property and bk_get_own_property. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int getter_calls;

static bk_value getter(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)argc; (void)argv; (void)opaque;
    getter_calls++;
    return bk_new_number(ctx, 42);
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "desc.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_value obj = eval(ctx, "globalThis.o = {}; o");
    bk_atom x = bk_new_atom(ctx, "x", 1), y = bk_new_atom(ctx, "y", 1), z = bk_new_atom(ctx, "z", 1);
    bk_value get = bk_new_c_function(ctx, getter, "get x", 0, 0, NULL);
    int ok = -1, found = -1;

    bk_property_descriptor acc = { BK_PROP_HAS_GET | BK_PROP_HAS_ENUMERABLE | BK_PROP_ENUMERABLE, 0, get, 0 };
    assert(bk_define_property(ctx, obj, x, &acc, &ok) == BK_OK && ok == 1);
    assert(bk_to_number(ctx, eval(ctx, "o.x")) == 42 && getter_calls == 1);
    assert(bk_to_bool(ctx, eval(ctx, "Object.keys(o).join() === 'x'")));

    bk_property_descriptor ro = { BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE, bk_new_number(ctx, 7), 0, 0 };
    assert(bk_define_property(ctx, obj, y, &ro, &ok) == BK_OK && ok == 1);
    assert(bk_to_bool(ctx, eval(ctx, "o.y === 7 && !Object.getOwnPropertyDescriptor(o, 'y').writable"
                                     " && !Object.getOwnPropertyDescriptor(o, 'y').configurable")));
    /* Redefining a non-configurable property is refused, not thrown. */
    bk_property_descriptor change = { BK_PROP_HAS_VALUE, bk_new_number(ctx, 8), 0, 0 };
    assert(bk_define_property(ctx, obj, y, &change, &ok) == BK_OK && ok == 0);
    assert(bk_get_exception(ctx) == BK_UNDEFINED);

    bk_property_descriptor d;
    assert(bk_get_own_property(ctx, obj, x, &d, &found) == BK_OK && found == 1);
    assert(d.flags == (BK_PROP_HAS_GET | BK_PROP_HAS_SET | BK_PROP_HAS_ENUMERABLE |
                       BK_PROP_HAS_CONFIGURABLE | BK_PROP_ENUMERABLE));
    assert(bk_strict_equals(ctx, d.get, get) && d.set == BK_UNDEFINED && d.value == BK_UNDEFINED);
    assert(getter_calls == 1);
    bk_free_value(ctx, d.get);
    assert(bk_get_own_property(ctx, obj, y, &d, &found) == BK_OK && found == 1);
    assert(d.flags == (BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE | BK_PROP_HAS_ENUMERABLE |
                       BK_PROP_HAS_CONFIGURABLE));
    assert(bk_to_number(ctx, d.value) == 7);
    assert(bk_get_own_property(ctx, obj, z, &d, &found) == BK_OK && found == 0);

    /* Invalid descriptors. */
    bk_property_descriptor both = { BK_PROP_HAS_VALUE | BK_PROP_HAS_GET, BK_NULL, get, 0 };
    assert(bk_define_property(ctx, obj, z, &both, &ok) == BK_ERR_INVALID);
    bk_property_descriptor bad = { BK_PROP_HAS_SET, 0, 0, bk_new_number(ctx, 1) };
    assert(bk_define_property(ctx, obj, z, &bad, &ok) == BK_ERR_TYPE);
    assert(bk_define_property(ctx, bk_new_number(ctx, 1), z, &ro, &ok) == BK_ERR_TYPE);

    /* Proxies run their traps; a throwing trap is an exception. */
    bk_value p = eval(ctx, "globalThis.log = []; new Proxy({}, {"
                           " defineProperty(t, k, d) { log.push('def ' + k); return Reflect.defineProperty(t, k, d) },"
                           " getOwnPropertyDescriptor(t, k) { log.push('gopd ' + k);"
                           "   if (k === 'z') throw new Error('trap'); return Reflect.getOwnPropertyDescriptor(t, k) } })");
    bk_property_descriptor pv = { BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE | BK_PROP_WRITABLE |
                                  BK_PROP_HAS_ENUMERABLE | BK_PROP_ENUMERABLE |
                                  BK_PROP_HAS_CONFIGURABLE | BK_PROP_CONFIGURABLE, bk_new_number(ctx, 3), 0, 0 };
    assert(bk_define_property(ctx, p, x, &pv, &ok) == BK_OK && ok == 1);
    assert(bk_get_own_property(ctx, p, x, &d, &found) == BK_OK && found == 1 && bk_to_number(ctx, d.value) == 3);
    assert(bk_get_own_property(ctx, p, z, &d, &found) == BK_ERR_THROW && found == 0);
    bk_free_value(ctx, bk_get_exception(ctx));
    assert(bk_to_bool(ctx, eval(ctx, "log.join() === 'def x,gopd x,gopd z'")));

    /* Symbol keys and array indices. */
    bk_value sym = eval(ctx, "globalThis.s = Symbol('k'); s");
    bk_atom sa = bk_value_to_atom(ctx, sym);
    assert(bk_define_property(ctx, obj, sa, &pv, &ok) == BK_OK && ok == 1);
    assert(bk_to_bool(ctx, eval(ctx, "o[s] === 3")));
    bk_value arr = eval(ctx, "globalThis.a = [1, 2]; a");
    bk_atom i5 = bk_new_atom_index(ctx, 5);
    assert(bk_define_property(ctx, arr, i5, &pv, &ok) == BK_OK && ok == 1);
    assert(bk_to_bool(ctx, eval(ctx, "a.length === 6 && a[5] === 3")));
    bk_atom len = bk_new_atom(ctx, "length", 6);
    assert(bk_get_own_property(ctx, arr, len, &d, &found) == BK_OK && found == 1 && bk_to_number(ctx, d.value) == 6);

    bk_destroy(ctx);
    puts("descriptors: PASS");
    return 0;
}
