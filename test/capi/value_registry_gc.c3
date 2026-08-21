/// Value-registry GC tests, run under GC_STRESS + ASan.
///
/// The registry is a plain array rather than an HObject, so nothing marks it
/// transitively -- Heap.capi_mark has to walk it. Under GC_STRESS a collection
/// runs at every allocation, so a missing root turns into a deterministic
/// use-after-free here instead of a rare corruption in the field.
///
/// The C ABI is driven through its exported entry points, the same surface a
/// host uses.
module value_registry_gc;

import boomkat::capi;
import boomkat::embed;
import boomkat::types;
import std::io;

int g_fails;

fn void check(String label, bool cond) {
    if (cond) {
        io::printfn("ok   %s", label);
    } else {
        io::printfn("FAIL %s", label);
        g_fails++;
    }
}

/// Handles held across heavy allocation must keep their values alive and
/// unchanged.
///
/// The values are OBJECTS on purpose. The sweep frees anything the mark phase
/// did not reach, regardless of refcount, so an object reachable only from the
/// registry is collected out from under the host unless capi_mark walks it.
/// A held string would survive on its refcount alone and prove nothing.
fn void test_handles_survive_gc(void* rt) {
    const uint N = 96;
    ulong[N] held;
    uint made = 0;

    for (uint i = 0; i < N; i++) {
        // Each object is reachable ONLY through its handle: the expression
        // result is never stored in a global or any other live structure.
        String src = string::tformat("({ tag: 'reg-%d-value' })", i);
        ulong v = 0;
        v = capi::bk_eval(rt, (char*)src.ptr, src.len);
        if (v == 0) break;
        held[i] = v;
        made++;
    }
    check("registry: allocated handles", made == N);

    // Churn the heap with the handles outstanding. Under GC_STRESS this
    // collects constantly.
    String churn = "var s = 0; for (var i = 0; i < 400; i++) { s += ({ x: i }).x; } s";
    ulong junk = 0;
    junk = capi::bk_eval(rt, (char*)churn.ptr, churn.len);
    if (junk != 0) {
        capi::bk_free(rt, junk);
    }

    // Read each object's tag back through the engine, which dereferences the
    // held object: if it was swept, ASan reports the use-after-free here.
    uint wrong = 0;
    for (uint i = 0; i < made; i++) {
        if (capi::bk_type_of(rt, held[i]) != embed::BK_TYPE_OBJECT) { wrong++; continue; }
    }
    check("registry: held objects survive GC", wrong == 0);

    for (uint i = 0; i < made; i++) capi::bk_free(rt, held[i]);
}

/// Freed handles must stop rooting their values, or the registry is a leak that
/// GC_STRESS will not catch but a long-running host will.
fn void test_freed_handles_release(void* rt) {
    uint churned = 0;
    for (uint i = 0; i < 2000; i++) {
        String src = string::tformat("'transient-%d'", i);
        ulong v = 0;
        v = capi::bk_eval(rt, (char*)src.ptr, src.len);
        if (v == 0) break;
        capi::bk_free(rt, v);
        churned++;
    }
    check("registry: alloc/free churn under GC stress", churned == 2000);

    // The registry must still be correct afterwards.
    String src = "'final'";
    ulong v = 0;
    v = capi::bk_eval(rt, (char*)src.ptr, src.len);
    bool ok = v != 0;
    if (ok) {
        char[32] buf;
        usz written = 0;
        ok = capi::bk_read_string(rt, v, &buf[0], 32, &written) == capi::BK_OK
             && (String)buf[:written] == "final";
        capi::bk_free(rt, v);
    }
    check("registry: usable after churn", ok);
}

fn int main() {
    void* rt = capi::bk_open();
    if (rt == null) {
        io::printn("FAIL could not open runtime");
        return 1;
    }

    test_handles_survive_gc(rt);
    test_freed_handles_release(rt);

    capi::bk_close(rt);

    if (g_fails > 0) {
        io::printfn("FAILURES: %d", g_fails);
        return 1;
    }
    io::printn("all value-registry GC tests passed");
    return 0;
}
