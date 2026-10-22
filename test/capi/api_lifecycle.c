#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_ctx expected_context;
static int marker;

static bk_value sum(bk_ctx ctx, bk_value receiver, unsigned argc,
                    const bk_value *argv, void *opaque) {
    (void)receiver;
    assert(ctx == expected_context);
    assert(opaque == &marker && bk_get_context_opaque(ctx) == &marker);
    double total = 0;
    for (unsigned i = 0; i < argc; i++) total += bk_to_number(ctx, argv[i]);
    return bk_new_number(ctx, total);
}

static bk_value cross_read(bk_ctx ctx, bk_value receiver, unsigned argc,
                           const bk_value *argv, void *peer) {
    (void)ctx; (void)receiver;
    assert(argc == 1);
    return bk_get_property((bk_ctx)peer, argv[0], "tag", 3);
}

static bk_value catch_value(bk_ctx ctx, bk_value receiver, unsigned argc,
                            const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque;
    assert(argc == 1);
    bk_value result = bk_call(ctx, argv[0], 0, NULL, 0);
    assert(bk_is_exception(result));
    return bk_get_exception(ctx);
}

static bk_value eval(bk_ctx ctx, const char *source) {
    bk_value result = bk_eval_ex(ctx, source, strlen(source), "api-test.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(result)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(result));
    return result;
}

static void check(bk_ctx ctx, const char *source) {
    bk_value result = eval(ctx, source);
    assert(bk_to_bool(ctx, result));
    bk_free_value(ctx, result);
}

int main(void) {
    bk_runtime runtime = bk_new_runtime();
    bk_ctx first = bk_new_context(runtime), second = bk_new_context(runtime);
    assert(runtime && first && second && first != second);
    bk_set_runtime_opaque(runtime, &marker);
    bk_set_context_opaque(second, &marker);
    assert(bk_get_runtime(second) == runtime && bk_get_runtime_opaque(runtime) == &marker);
    assert(bk_get_context_opaque(first) == NULL);
    expected_context = second;
    bk_value callback = bk_new_c_function(second, sum, "sum", 0, 0, &marker);
    assert(callback);
    bk_set_global_property(first, "sum", 3, callback);
    bk_free_value(first, callback);
    callback = bk_new_c_function(second, cross_read, "crossRead", 1, 0, first);
    bk_set_global_property(first, "crossRead", 9, callback);
    bk_free_value(first, callback);
    check(first, "crossRead({tag:42})===42");
    check(first, "sum(1,2,3) === 6 && sum.length === 0");
    check(first, "sum(...Array(40).fill(1)) === 40");
    bk_value args[40];
    for (unsigned i = 0; i < 40; i++) args[i] = bk_new_number(first, 1);
    callback = eval(first, "sum");
    bk_value result = bk_call(first, callback, 0, args, 40);
    assert(result && bk_to_number(first, result) == 40);
    bk_free_value(first, result);
    assert(bk_is_exception(bk_call(first, callback, 0, args, 65536)));
    result = bk_get_exception(first);
    bk_value name = bk_get_property(first, result, "name", 4);
    const char *error_name = bk_to_cstring(first, name, NULL);
    assert(error_name && strcmp(error_name, "RangeError") == 0);
    bk_free_cstring(first, error_name);
    bk_free_value(first, name);
    bk_free_value(first, result);
    bk_value call = eval(first, "Function.prototype.call");
    result = bk_call(first, call, callback, args, 40);
    assert(result && bk_to_number(first, result) == 39);
    bk_free_value(first, result);
    bk_free_value(first, call);
    bk_value apply = eval(first, "Function.prototype.apply");
    bk_value list = bk_new_array_from(first, args, 40);
    bk_value apply_args[] = {args[0], list};
    result = bk_call(first, apply, callback, apply_args, 2);
    assert(result && bk_to_number(first, result) == 40);
    bk_free_value(first, result);
    bk_free_value(first, list);
    bk_free_value(first, apply);
    bk_free_value(first, callback);
    for (unsigned i = 0; i < 40; i++) bk_free_value(first, args[i]);

    const char *throws = "throw ({tag:42})";
    assert(bk_is_exception(bk_eval_ex(first, throws, strlen(throws), "throw.js", 0)));
    bk_value unrelated = eval(second, "({tag:99})");
    result = bk_get_exception(first);
    assert(result);
    bk_value tag = bk_get_property(second, result, "tag", 3);
    assert(tag && bk_to_number(second, tag) == 42);
    bk_free_value(second, tag);
    bk_free_value(first, result);
    bk_free_value(second, unrelated);
    result = bk_get_exception(second);
    assert(bk_get_type(second, result) == BK_TYPE_UNDEFINED);
    bk_free_value(second, result);

    callback = bk_new_c_function(first, catch_value, "catchValue", 1, 0, NULL);
    bk_set_global_property(first, "catchValue", 10, callback);
    bk_free_value(first, callback);
    check(first, "var thrown={tag:7}; catchValue(function(){throw thrown}) === thrown");
    check(first, "catchValue(function(){throw 'borrowed exception'}) === 'borrowed exception'");
    check(first, "catchValue(function(){throw undefined}) === undefined");

    result = eval(first, "'a\\0😀'");
    size_t length;
    const char *text = bk_to_cstring(first, result, &length);
    assert(text && length == 6 && text[0] == 'a' && text[1] == 0);
    bk_free_value(first, result);
    for (int i = 0; i < 20; i++) {
        result = eval(second, "'other'");
        const char *other = bk_to_cstring(second, result, NULL);
        bk_free_cstring(second, other);
        bk_free_value(second, result);
    }
    assert(text[0] == 'a' && text[1] == 0 && (unsigned char)text[2] == 0xF0);
    bk_free_cstring(first, text);

    check(first, "var order=''; Promise.resolve().then(function(){order+='a'}); order===''");
    check(second, "var order=''; Promise.resolve().then(function(){order+='b'}); order===''");
    assert(bk_is_job_pending(runtime));
    bk_ctx job_context;
    assert(bk_execute_pending_job(runtime, &job_context) == 1 && job_context == first);
    check(first, "order==='a'");
    check(second, "order===''");
    assert(bk_execute_pending_job(runtime, &job_context) == 1 && job_context == second);
    check(second, "order==='b'");
    assert(bk_execute_pending_job(runtime, &job_context) == 0 && job_context == NULL);

    bk_value global = bk_get_global_object(first);
    bk_set_global_property(second, "first", 5, global);
    bk_free_value(second, global);
    bk_free_context(first);
    check(second, "first.sum(8,9) === 17");
    callback = eval(second, "first.sum");
    bk_free_context(second);
    bk_ctx third = bk_new_context(runtime);
    check(third, "typeof sum==='undefined'");
    bk_set_global_property(third, "escaped", 7, callback);
    bk_free_value(third, callback);
    check(third, "escaped(20,22)===42");
    bk_free_context(third);
    bk_free_runtime(runtime);
    puts("runtime/context API: PASS");
    return 0;
}
