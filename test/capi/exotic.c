/* Exotic hooks: an indexed collection class whose elements live in its C
 * payload, callable instances, subclassing, hooks that throw, and
 * bk_new_proxy. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { double items[8]; unsigned length; } Coll;

static bk_class coll_class;
static int finalized;

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "exotic.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static void expect(bk_ctx ctx, const char *src) {
    bk_value r = eval(ctx, src);
    if (r != BK_TRUE) fprintf(stderr, "expected true: %s\n", src);
    assert(r == BK_TRUE);
}

/* The array index `key` names, or -1. */
static long index_of(bk_ctx ctx, bk_atom key) {
    bk_value v = bk_atom_to_value(ctx, key);
    char buf[16];
    size_t len = 0;
    long index = -1;
    if (bk_read_string(ctx, v, buf, sizeof buf, &len) == BK_OK && len > 0 && len < 10) {
        char *end;
        long n = strtol(buf, &end, 10);
        if (*end == 0 && (n > 0 || (n == 0 && len == 1))) index = n;
    }
    bk_free_value(ctx, v);
    return index;
}

static Coll *coll_of(bk_ctx ctx, bk_value self) { return bk_get_instance_payload(ctx, self, coll_class); }

static int get_own(bk_ctx ctx, bk_value self, bk_atom key, bk_property_descriptor *desc, void *opaque) {
    (void)opaque;
    long i = index_of(ctx, key);
    if (i < 0) {
        bk_value k = bk_atom_to_value(ctx, key);
        char buf[8];
        int boom = bk_read_string(ctx, k, buf, sizeof buf, NULL) == BK_OK && !strcmp(buf, "boom");
        if (boom) { bk_throw_error(ctx, BK_ERROR_RANGE, "boom"); return -1; }
        return 0;
    }
    Coll *c = coll_of(ctx, self);
    if ((unsigned long)i >= c->length) return 1;   /* a hole */
    desc->flags = BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE | BK_PROP_WRITABLE
                | BK_PROP_HAS_ENUMERABLE | BK_PROP_ENUMERABLE | BK_PROP_HAS_CONFIGURABLE | BK_PROP_CONFIGURABLE;
    desc->value = bk_new_number(ctx, c->items[i]);
    return 1;
}

static int define_own(bk_ctx ctx, bk_value self, bk_atom key, const bk_property_descriptor *desc,
                      int *ok, void *opaque) {
    (void)opaque;
    long i = index_of(ctx, key);
    if (i < 0) return 0;
    Coll *c = coll_of(ctx, self);
    if (i >= 8 || !(desc->flags & BK_PROP_HAS_VALUE)) { *ok = 0; return 1; }
    c->items[i] = bk_to_number(ctx, desc->value);
    if ((unsigned)i >= c->length) c->length = (unsigned)i + 1;
    *ok = 1;
    return 1;
}

static int remove_key(bk_ctx ctx, bk_value self, bk_atom key, int *ok, void *opaque) {
    (void)opaque;
    long i = index_of(ctx, key);
    if (i < 0) return 0;
    Coll *c = coll_of(ctx, self);
    *ok = (unsigned long)i + 1 >= c->length;   /* only the last element */
    if (*ok && (unsigned long)i < c->length) c->length = (unsigned)i;
    return 1;
}

static int own_keys(bk_ctx ctx, bk_value self, bk_value *keys_out, void *opaque) {
    (void)opaque;
    Coll *c = coll_of(ctx, self);
    bk_value keys[8];
    for (unsigned i = 0; i < c->length; i++) {
        char buf[4];
        int n = snprintf(buf, sizeof buf, "%u", i);
        keys[i] = bk_new_string(ctx, buf, (size_t)n);
    }
    *keys_out = bk_new_array_from(ctx, keys, c->length);
    return 1;
}

static bk_value call(bk_ctx ctx, bk_value self, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)opaque;
    Coll *c = coll_of(ctx, self);
    double sum = 0;
    for (unsigned i = 0; i < c->length; i++) sum += c->items[i];
    for (unsigned i = 0; i < argc; i++) sum += bk_to_number(ctx, argv[i]);
    return bk_new_number(ctx, sum);
}

static bk_value construct(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)opaque;
    Coll *c = calloc(1, sizeof *c);
    for (unsigned i = 0; i < argc && i < 8; i++) c->items[c->length++] = bk_to_number(ctx, argv[i]);
    assert(bk_set_instance_payload(ctx, this_value, coll_class, c) == BK_OK);
    return this_value;
}

static bk_value length_getter(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)argc; (void)argv; (void)opaque;
    Coll *c = coll_of(ctx, this_value);
    if (!c) return bk_throw_error(ctx, BK_ERROR_TYPE, "not a Coll");
    return bk_new_number(ctx, c->length);
}

static void finalize(void *payload, void *opaque) { (void)opaque; free(payload); finalized++; }

static const bk_exotic_hooks hooks = { get_own, define_own, remove_key, own_keys, call };

int main(void) {
    bk_ctx ctx = bk_create();
    bk_class_def def = { .name = "Coll", .finalize = finalize, .construct = construct, .exotic = &hooks };
    bk_value ctor, proto;
    coll_class = bk_define_class(ctx, &def, &ctor, &proto);
    assert(coll_class != 0);
    bk_value getter = bk_new_c_function(ctx, length_getter, "length", 0, 0, NULL, NULL, NULL);
    bk_atom length = bk_new_atom(ctx, "length", 6);
    bk_property_descriptor d = { .flags = BK_PROP_HAS_GET | BK_PROP_HAS_CONFIGURABLE | BK_PROP_CONFIGURABLE, .get = getter };
    int ok = 0;
    assert(bk_define_property(ctx, proto, length, &d, &ok) == BK_OK && ok);
    bk_free_atom(ctx, length);
    bk_free_value(ctx, getter);
    bk_value global = bk_get_global_object(ctx);
    assert(bk_set_property(ctx, global, "Coll", 4, ctor) == BK_OK);
    bk_free_value(ctx, global);

    /* Indexed reads, writes, has, keys and delete go through the hooks. */
    eval(ctx, "globalThis.c = new Coll(1, 2, 3)");
    expect(ctx, "c[0] === 1 && c[2] === 3 && c[3] === undefined && c.length === 3");
    expect(ctx, "1 in c && !(5 in c) && 'length' in c && c instanceof Coll");
    expect(ctx, "JSON.stringify(Object.keys(c)) === '[\"0\",\"1\",\"2\"]'");
    expect(ctx, "(c[3] = 10, c.length === 4 && c[3] === 10)");
    expect(ctx, "Reflect.set(c, 9, 1) === false && Reflect.defineProperty(c, 1, { get() {} }) === false");
    expect(ctx, "Reflect.deleteProperty(c, 0) === false && delete c[3] && c.length === 3");
    expect(ctx, "JSON.stringify(Object.getOwnPropertyDescriptor(c, 1)) === '{\"value\":2,\"writable\":true,\"enumerable\":true,\"configurable\":true}'");
    expect(ctx, "[...Object.values(c)].join() === '1,2,3'");
    /* Non-index keys are ordinary properties of the instance. */
    expect(ctx, "(c.tag = 'x', c.tag === 'x' && Object.getPrototypeOf(c) === Coll.prototype)");
    /* Callable instances. */
    expect(ctx, "typeof c === 'function' && c(4) === 10");
    /* A throwing hook throws into JS. */
    expect(ctx, "(() => { try { c.boom; return false } catch (e) { return e instanceof RangeError && e.message === 'boom' } })()");
    /* Subclasses from JS get exotic instances too. */
    expect(ctx, "class Sub extends Coll { first() { return this[0] } }; const s = new Sub(7, 8); s.first() === 7 && s.length === 2 && s instanceof Sub");

    /* The C side sees the instance and its payload. */
    bk_value c = eval(ctx, "c");
    Coll *pc = bk_get_instance_payload(ctx, c, coll_class);
    assert(pc && pc->length == 3 && pc->items[1] == 2);
    assert(bk_get_instance_class(ctx, c) == coll_class);
    bk_free_value(ctx, c);
    bk_value made = bk_new_instance(ctx, coll_class, calloc(1, sizeof(Coll)), 0);
    bk_atom zero = bk_new_atom_index(ctx, 0);
    assert(bk_set_property_atom(ctx, made, zero, bk_new_number(ctx, 5)) == BK_OK);
    bk_value got = bk_get_property_atom(ctx, made, zero);
    assert(bk_to_number(ctx, got) == 5);
    bk_free_value(ctx, got);
    bk_free_atom(ctx, zero);
    bk_free_value(ctx, made);

    /* bk_new_proxy is new Proxy(target, handler). */
    bk_value target = eval(ctx, "({ a: 1 })");
    bk_value handler = eval(ctx, "({ get: (t, k) => k === 'b' ? 2 : t[k] })");
    bk_value p = bk_new_proxy(ctx, target, handler);
    assert(p != 0);
    bk_value b = bk_get_property(ctx, p, "b", 1);
    bk_value a = bk_get_property(ctx, p, "a", 1);
    assert(bk_to_number(ctx, a) == 1 && bk_to_number(ctx, b) == 2);
    assert(bk_new_proxy(ctx, target, BK_UNDEFINED) == 0 && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_free_value(ctx, a);
    bk_free_value(ctx, b);
    bk_free_value(ctx, p);
    bk_free_value(ctx, target);
    bk_free_value(ctx, handler);

    eval(ctx, "delete globalThis.c; for (let i = 0; i < 2000; i++) new Coll(i)");
    bk_free_value(ctx, ctor);
    bk_free_value(ctx, proto);
    bk_destroy(ctx);
    assert(finalized >= 2000);
    printf("exotic: PASS\n");
    return 0;
}
