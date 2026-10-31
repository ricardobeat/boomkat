// Deterministic registration failures after 0, 1 or 2 successful stores.
module promise_failures;
import boomkat;
import boomkat::capi;
import boomkat::embed;
import boomkat::heap;
import std::io;

alias Reallocator = fn void*(void*, void*, usz);
Reallocator saved_realloc;
void* registry;
uint failures;

fn void* fail_registry_growth(void* user, void* old, usz size) {
    if (old == registry) { failures++; return null; }
    return saved_realloc(user, old, size);
}

fn void test_registry(uint spare, bool c3_api) {
    JsContext cx;
    cx.create()!!;
    defer cx.destroy();
    // Warm the registry, then exhaust its free list up to the requested edge.
    (void)cx.number(1)!!;
    while (cx.rt.free_head != embed::SLOT_FREE_END || cx.rt.slot_count + spare < cx.rt.slot_cap) {
        (void)cx.number(1)!!;
    }
    uint before = cx.rt.live;
    registry = cx.rt.slots;
    saved_realloc = cx.rt.heap.realloc_func;
    cx.rt.heap.realloc_func = &fail_registry_growth;
    uint failed_before = failures;
    if (c3_api) {
        JsDeferred? made = cx.deferred();
        bool failed;
        if (catch err = made) { assert(err == boomkat::VALUE_TABLE_FULL); failed = true; }
        assert(failed);
    } else {
        ulong resolve = 999;
        ulong reject = 999;
        ulong promise = capi::bk_new_promise(cx.context, &resolve, &reject);
        assert(promise == 0 && resolve == 0 && reject == 0);
        assert(capi::bk_get_error_code(cx.context) == embed::BK_ERR_FULL);
    }
    cx.rt.heap.realloc_func = saved_realloc;
    assert(failures == failed_before + 1);
    assert(cx.rt.live == before);
    ulong resolve, reject;
    ulong promise = capi::bk_new_promise(cx.context, &resolve, &reject);
    assert(promise != 0 && resolve != 0 && reject != 0);
    capi::bk_free_value(cx.context, promise);
    capi::bk_free_value(cx.context, resolve);
    capi::bk_free_value(cx.context, reject);
    assert(cx.rt.live == before);
}

fn void test_local(uint spare) {
    JsContext cx;
    cx.create()!!;
    defer cx.destroy();
    uint scope = capi::bk_scope_open(cx.context);
    assert(scope != 0);
    for (uint i = 0; i < 131072 - spare; i++) {
        assert(capi::bk_new_number(cx.context, 1) != 0);
    }
    uint before = cx.rt.heap.host_vals_len;
    ulong resolve = 999;
    ulong reject = 999;
    assert(capi::bk_new_promise(cx.context, &resolve, &reject) == 0);
    assert(resolve == 0 && reject == 0);
    assert(capi::bk_get_error_code(cx.context) == embed::BK_ERR_FULL);
    assert(cx.rt.heap.host_vals_len == before);
    // Every spare local remains available after rollback.
    for (uint i = 0; i < spare; i++) assert(capi::bk_new_number(cx.context, 2) != 0);
    assert(capi::bk_new_number(cx.context, 3) == 0);
    capi::bk_scope_close(cx.context, scope);
    assert(cx.rt.heap.host_vals_len == 0);
}

fn void main() {
    for (uint spare = 0; spare < 3; spare++) {
        test_registry(spare, false);
        test_registry(spare, true);
        test_local(spare);
    }
    JsContext cx;
    cx.create()!!;
    defer cx.destroy();
    ulong aliased = 999;
    assert(capi::bk_new_promise(cx.context, &aliased, &aliased) == 0);
    assert(aliased == 0 && capi::bk_get_error_code(cx.context) == embed::BK_ERR_INVALID);
    io::printn("promise registration failures: PASS");
}
