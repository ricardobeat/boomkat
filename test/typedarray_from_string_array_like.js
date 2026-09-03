// %TypedArray%.from's array-like fallback path (used when the source has no
// @@iterator method, e.g. after `delete String.prototype[Symbol.iterator]`)
// must still treat a primitive string source as array-like via its own
// .length and indexed characters. Two bugs were found together:
//
// 1. The source-object check only accepted `source.is_object()`, so a
//    string PRIMITIVE (source.is_object() === false) was skipped entirely
//    -- src_obj stayed null, src_len stayed 0, and the result was always
//    empty.
// 2. Fixing that with a plain ToObject-style wrapper (to_object_for_lookup,
//    used elsewhere for prototype-chain method lookups like @@iterator)
//    wasn't enough: that wrapper is a plain OBJECT, not a real STRING-exotic
//    object, so indexed character reads (via a generic property lookup)
//    still missed -- only .length, itself materialised as a real own
//    property at wrap time, worked. Character indices are served lazily by
//    arr_get_elem/arr_get_elem_vm specifically; a generic get_prop lookup
//    never sees them. Switched to arr_to_object (the same String-exotic
//    wrapper Array.prototype methods use) plus arr_get_elem_vm for the
//    per-index read.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var savedIterator = String.prototype[Symbol.iterator];
delete String.prototype[Symbol.iterator];

try {
    var r1 = Array.from(Int8Array.from("works", (s) => s.codePointAt(0)));
    check("array-like string source, mapped", r1.join(","), "119,111,114,107,115");

    var r2 = Array.from(Uint32Array.from("hi"));
    check("array-like string source length", r2.length, 2);
} finally {
    String.prototype[Symbol.iterator] = savedIterator;
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
