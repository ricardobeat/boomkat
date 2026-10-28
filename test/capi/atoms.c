/* Atoms and atom-keyed property access. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_value eval(bk_ctx ctx, const char *source) {
    bk_value result = bk_eval_ex(ctx, source, strlen(source), "atoms.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(result)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(result));
    return result;
}

static int same(bk_ctx ctx, bk_value a, bk_value b) {
    bk_value pair[2] = { a, b };
    bk_value is = eval(ctx, "Object.is");
    bk_value r = bk_call(ctx, is, BK_UNDEFINED, pair, 2);
    bk_free_value(ctx, is);
    return r == BK_TRUE;
}

static void keys_are(bk_ctx ctx, bk_value object, unsigned flags, const char *want) {
    bk_value keys = bk_get_own_property_keys(ctx, object, flags);
    assert(!bk_is_exception(keys));
    bk_set_global_property(ctx, "__keys", 6, keys);
    bk_value text = eval(ctx, "__keys.map(String).join(',')");
    const char *got = bk_cstr(ctx, text, NULL);
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "flags %u: got '%s', want '%s'\n", flags, got, want);
        assert(0);
    }
    bk_free_value(ctx, text);
    bk_free_value(ctx, keys);
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_value obj = eval(ctx, "var s = Symbol('tag'); var o = {name: 'n', 2: 'two', [s]: 'sym'}; o");

    /* Atom-keyed access matches char* access for strings, indices and symbols. */
    bk_atom name = bk_new_atom(ctx, "name", 4);
    bk_atom two = bk_new_atom_index(ctx, 2);
    bk_value sym = eval(ctx, "s");
    bk_atom tag = bk_value_to_atom(ctx, sym);
    assert(name && two && tag && name != two && two != tag);
    assert(bk_new_atom(ctx, "name", 4) == name);       /* one key, one atom */
    bk_free_atom(ctx, name);
    assert(bk_new_atom(ctx, "2", 1) == two);
    bk_free_atom(ctx, two);
    bk_value two_str = bk_new_string(ctx, "2", 1);
    assert(bk_value_to_atom(ctx, two_str) == two);
    bk_free_atom(ctx, two);
    bk_value num = bk_new_number(ctx, 2);
    assert(bk_value_to_atom(ctx, num) == two);
    bk_free_atom(ctx, two);

    bk_value a = bk_get_property_atom(ctx, obj, name), b = bk_get_property(ctx, obj, "name", 4);
    assert(same(ctx, a, b));
    bk_free_value(ctx, a); bk_free_value(ctx, b);
    a = bk_get_property_atom(ctx, obj, two); b = bk_get_property_uint32(ctx, obj, 2);
    assert(same(ctx, a, b));
    bk_free_value(ctx, a); bk_free_value(ctx, b);
    a = bk_get_property_atom(ctx, obj, tag);
    assert(bk_string_length(ctx, a) == 3);
    bk_free_value(ctx, a);

    bk_value v = bk_new_number(ctx, 7);
    assert(bk_set_property_atom(ctx, obj, tag, v) == BK_OK);
    bk_free_value(ctx, v);
    bk_value check = eval(ctx, "o[s] === 7");
    assert(check == BK_TRUE);
    int has = 0;
    assert(bk_has_property_atom(ctx, obj, tag, &has) == BK_OK && has == 1);
    int deleted = 0;
    assert(bk_delete_property_atom(ctx, obj, two, &deleted) == BK_OK && deleted == 1);
    assert(bk_has_property_atom(ctx, obj, two, &has) == BK_OK && has == 0);
    assert(bk_has_property(ctx, obj, "2", 1, &has) == BK_OK && has == 0);

    bk_value back = bk_atom_to_value(ctx, tag);
    assert(same(ctx, back, sym));
    bk_free_value(ctx, back);
    back = bk_atom_to_value(ctx, name);
    char buf[8];
    assert(bk_read_string(ctx, back, buf, sizeof buf, NULL) == BK_OK && strcmp(buf, "name") == 0);
    bk_free_value(ctx, back);

    /* Atoms are valid in every context of the runtime. */
    bk_ctx other = bk_new_context(bk_get_runtime(ctx));
    a = bk_get_property_atom(other, obj, name);
    assert(bk_read_string(other, a, buf, sizeof buf, NULL) == BK_OK && strcmp(buf, "n") == 0);
    bk_free_value(other, a);

    /* ToPropertyKey runs JS and reports its throw. */
    bk_value bad = eval(ctx, "({ toString() { throw new RangeError('no key') } })");
    assert(bk_value_to_atom(ctx, bad) == 0 && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_free_value(ctx, bk_get_exception(ctx));
    bk_free_value(ctx, bad);

    /* A key held only by an atom survives collection. */
    bk_atom fresh = bk_new_atom(ctx, "only-in-an-atom", 15);
    bk_free_value(ctx, eval(ctx, "for (var i = 0; i < 20000; i++) ({k: 'x' + i}); 0"));
    back = bk_atom_to_value(ctx, fresh);
    assert(bk_string_length(ctx, back) == 15);
    bk_free_value(ctx, back);
    bk_free_atom(ctx, fresh);
    assert(bk_atom_to_value(ctx, fresh) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_INVALID);

    /* Many atoms, freed out of order, keep lookups exact. */
    bk_atom many[500];
    for (int i = 0; i < 500; i++) {
        char key[16];
        int n = snprintf(key, sizeof key, "k%d", i);
        many[i] = bk_new_atom(ctx, key, (size_t)n);
        assert(many[i]);
    }
    for (int i = 0; i < 500; i += 3) bk_free_atom(ctx, many[i]);
    for (int i = 0; i < 500; i++) {
        char key[16];
        int n = snprintf(key, sizeof key, "k%d", i);
        bk_atom again = bk_new_atom(ctx, key, (size_t)n);
        if (i % 3 != 0) assert(again == many[i]);
        else many[i] = again;
    }
    for (int i = 0; i < 500; i++) {
        bk_value s = bk_atom_to_value(ctx, many[i]);
        char key[16], got[16];
        snprintf(key, sizeof key, "k%d", i);
        assert(bk_read_string(ctx, s, got, sizeof got, NULL) == BK_OK && strcmp(got, key) == 0);
        bk_free_value(ctx, s);
        bk_free_atom(ctx, many[i]);
        if (i % 3 != 0) bk_free_atom(ctx, many[i]);
    }

    /* Own keys. */
    bk_value keyed = eval(ctx,
        "var k = {b: 1, 1: 1, a: 1, [Symbol('x')]: 1, 0: 1};"
        "Object.defineProperty(k, 'hidden', {value: 1, enumerable: false}); k");
    keys_are(ctx, keyed, BK_KEYS_OWN, "0,1,b,a,hidden,Symbol(x)");
    keys_are(ctx, keyed, BK_KEYS_STRINGS, "0,1,b,a,hidden");
    keys_are(ctx, keyed, BK_KEYS_SYMBOLS, "Symbol(x)");
    keys_are(ctx, keyed, BK_KEYS_STRINGS | BK_KEYS_ENUMERABLE_ONLY, "0,1,b,a");
    keys_are(ctx, keyed, BK_KEYS_STRINGS | BK_KEYS_SKIP_INDICES, "b,a,hidden");
    bk_value arr = eval(ctx, "[5, 6]");
    keys_are(ctx, arr, BK_KEYS_STRINGS, "0,1,length");
    keys_are(ctx, arr, BK_KEYS_ENUMERABLE_ONLY, "0,1");
    bk_value proxy = eval(ctx,
        "var log = []; new Proxy({p: 1, q: 2}, {"
        " ownKeys(t) { log.push('ownKeys'); return Reflect.ownKeys(t) },"
        " getOwnPropertyDescriptor(t, k) { log.push(k);"
        "   var d = Reflect.getOwnPropertyDescriptor(t, k); if (k === 'q') d.enumerable = false; return d } })");
    /* q is non-enumerable only through the trap, which breaks no invariant
       because q is configurable. */
    keys_are(ctx, proxy, BK_KEYS_ENUMERABLE_ONLY, "p");
    bk_value log = eval(ctx, "log.join()");
    assert(strcmp(bk_cstr(ctx, log, NULL), "ownKeys,p,q") == 0);
    assert(bk_get_own_property_keys(ctx, obj, 99) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_INVALID);
    assert(bk_get_own_property_keys(ctx, num, 0) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_TYPE);

    bk_free_atom(ctx, name);
    bk_free_atom(ctx, two);
    bk_free_atom(ctx, tag);
    bk_free_context(other);
    bk_destroy(ctx);
    puts("atoms: PASS");
    return 0;
}
