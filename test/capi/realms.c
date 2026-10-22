#include "boomkat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(bk_ctx ctx, const char *source) {
    bk_value value = bk_eval_ex(ctx, source, strlen(source), "<eval>", BK_EVAL_GLOBAL);
    int ok = 0;
    if (!value || bk_read_bool(ctx, value, &ok) != BK_OK || !ok) {
        fprintf(stderr, "FAIL: %s: %s\n", source, bk_get_error_message(ctx));
        exit(1);
    }
    bk_free_value(ctx, value);
}

static bk_value bounce(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *primary) {
    (void)this_value; (void)argc; (void)argv;
    check((bk_ctx)primary, "typeof secret === 'undefined'");
    bk_value result = bk_eval_ex(ctx, "secret === 42", strlen("secret === 42"), "<eval>", BK_EVAL_GLOBAL);
    return result;

    return bk_new_undefined(ctx);
}

int main(void) {
    bk_ctx primary = bk_new_context(bk_new_runtime());
    bk_ctx other = bk_new_context(bk_get_runtime(primary));
    if (!primary || !other) return 1;
    bk_value global = bk_get_global_object(other);
    if (bk_set_global_property(primary, "other", 5, global) != BK_OK) return 1;
    bk_free_value(primary, global);
    check(primary, "globalThis !== other && Object !== other.Object && Math.max !== other.Math.max");
    check(primary, "delete Math.floor.name; delete Math.floor.length; true");
    bk_ctx third = bk_new_context(bk_get_runtime(other));
    if (!third) return 1;
    check(third, "Math.floor.name === 'floor' && Math.floor.length === 1");
    bk_free_context(third);
    check(primary, "Symbol.iterator === other.Symbol.iterator && Symbol.for('realm') === other.Symbol.for('realm')");
    check(other, "var secret = 42; true");
    check(primary, "typeof secret === 'undefined' && other.secret === 42");
    check(primary, "other.Function('return this')() === other");
    check(primary, "Function.prototype.call.call(other.Function('return this'), null) === other");
    check(primary, "Reflect.apply(other.Function('return Object.getPrototypeOf(this)'), 1, []) === other.Number.prototype");
    check(primary, "Object.getPrototypeOf(other.eval) === other.Function.prototype && typeof other.eval.call === 'function'");
    check(primary, "Object.getPrototypeOf(other.Function('return []')()) === other.Array.prototype");
    check(primary, "try { other.JSON.parse('{'); false } catch(e) { e instanceof other.SyntaxError && !(e instanceof SyntaxError) }");
    check(primary, "other.Math.max.call(null, 2, 3) === 3 && Math.max.apply(null, [4, 5]) === 5");
    check(primary, "var C = other.Function(''); C.prototype = null; Object.getPrototypeOf(Reflect.construct(Boolean, [], C)) === other.Boolean.prototype");
    check(primary, "Object.getPrototypeOf(Array.prototype.map.call(new other.Array(1), function(x){return x})) === Array.prototype");
    check(primary, "var g = other.Function('return function*(){yield []; return this}')()(); Object.getPrototypeOf(g.next().value) === other.Array.prototype && g.next().value === other");
    check(primary, "other.eval('Promise.resolve().then(function(){globalThis.done = [] instanceof Array})'); true");
    bk_run_jobs(bk_get_runtime(primary));
    check(primary, "other.done === true");
    check(primary, "typeof Intl === typeof other.Intl");
    check(primary, "typeof Intl === 'undefined' || other.Intl.NumberFormat('en').format(1234) === '1,234'");
    check(primary, "typeof Intl === 'undefined' || other.Intl.NumberFormat.prototype.formatToParts.call(new Intl.NumberFormat('en'), 1).length > 0");
    check(primary, "typeof Intl === 'undefined' || other.Intl.DateTimeFormat('en', {timeZone:'UTC'}).format(0).length > 0");
    bk_fn_def callbacks[] = {{"bounce", bounce, 0, 0u, primary}, BK_FN_END};
    if (bk_set_function_list(other, 0, callbacks) != BK_OK) return 1;
    check(primary, "other.bounce()");
    check(primary, "var stores = 0; Object.defineProperty(other.Array.prototype, '0', {set:function(v){stores += v}, configurable:true}); other.eval('var a=[]; a[0]=3'); stores === 3");
    check(primary, "delete other.Array.prototype[0]; true");
    check(primary, "var species = Object.getOwnPropertyDescriptor(Array, Symbol.species); Object.defineProperty(Array, Symbol.species, {configurable:true, value:other.Array}); var mapped = [1].map(function(x){return x}); Object.defineProperty(Array, Symbol.species, species); Object.getPrototypeOf(mapped) === other.Array.prototype");
    const char *dependency = "globalThis.loads=(globalThis.loads||0)+1; export const array=[]; export const global=globalThis";
    const char *entry = "import {array,global} from 'shared'; if(global!==globalThis || !(array instanceof Array) || loads!==1) throw Error('module realm');";
    if (bk_define_module(primary, "shared", 6, dependency, strlen(dependency)) != BK_OK) return 1;
    for (int i = 0; i < 3; i++) {
        bk_ctx ctx = i == 1 ? other : primary;
        bk_value module = bk_eval_ex(ctx, entry, strlen(entry), "entry", BK_EVAL_MODULE);
        if (!module) { fprintf(stderr, "module: %s\n", bk_get_error_message(ctx)); return 1; }
        bk_free_value(ctx, module);
    }
    bk_free_context(other);
    check(primary, "other.Function('return secret')() === 42");
    bk_free_runtime(bk_get_runtime(primary));
    puts("realms: all ok");
    return 0;
}
