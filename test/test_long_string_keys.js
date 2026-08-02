// Strings over MAX_INTERN_BYTES (256) are left un-interned, so two separately
// built strings with equal content are distinct pointers. Property-key lookup
// compares by pointer identity, so every store and lookup boundary must
// canonicalize the key: put_prop interns on store, and
// builtin_to_property_key_vm / get_prop_key intern on lookup. A miss anywhere
// reads undefined on a key that === reports present.
function build(n) {
    var s = "";
    for (var i = 0; i < n; i++) s += "0123456789";
    return s;
}
var pass = 0, total = 0;
function check(cond, label) {
    total++;
    if (cond) { pass++; } else { print("FAIL: " + label); }
}

var a = build(33);   // 330 chars
var b = build(33);   // equal content, distinct pointer
check(a === b, "=== on equal long strings");

// Plain property store and read through every lookup surface.
var o = {};
o[a] = 42;
check(o[a] === 42, "o[long] store and read");
check(o[b] === 42, "o[equal-other-long] read");
check(a in o, "in operator with long key");
check(b in o, "in operator with the other long key");
check(o.hasOwnProperty(a), "hasOwnProperty(long a)");
check(o.hasOwnProperty(b), "hasOwnProperty(long b)");
var od = Object.getOwnPropertyDescriptor(o, b);
check(od !== undefined && od.value === 42, "getOwnPropertyDescriptor(long key)");

// Object.keys enumeration carries the canonical key.
var ks = Object.keys(o);
check(ks.length === 1 && ks[0] === a, "Object.keys yields the canonical key");

// JSON round-trip: JSON.parse builds fresh un-interned keys from the text.
var j = JSON.stringify(o);
var o2 = JSON.parse(j);
check(o2[a] === 42, "JSON round-trip read with long key");
check(o2[b] === 42, "JSON round-trip read with the other long key");
check(o2.hasOwnProperty(b), "hasOwnProperty on parsed long key");
check(Object.keys(o2)[0] === a, "parsed key is the canonical pointer");

// JSON reviver with duplicate long keys: last value wins, and the recorded
// entry key must match the stored (canonical) key.
var dup = '{"' + a + '":1,"' + a + '":2}';
var seen = [];
var revived = JSON.parse(dup, function (k, v) {
    if (k === a) seen.push(v);
    return v;
});
check(revived[a] === 2, "reviver round-trip last-wins");
check(seen.length === 1 && seen[0] === 2, "reviver sees the surviving value once");

// delete with a long key.
var o3 = {};
o3[a] = 1;
delete o3[b];
check(!o3.hasOwnProperty(a), "delete with the other long key removes it");
check(Object.keys(o3).length === 0, "object empty after long-key delete");

// Object.groupBy groups by callback key; equal long keys must land in one group.
if (typeof Object.groupBy === "function") {
    var groups = Object.groupBy([1, 2, 3], function () { return a; });
    var gk = Object.keys(groups);
    check(gk.length === 1, "Object.groupBy coalesces equal long keys");
    check(groups[b].length === 3, "Object.groupBy groups all three items");
}

// Object.defineProperty with a long key, then read through the descriptor.
var o4 = {};
Object.defineProperty(o4, b, { value: 7, enumerable: true });
check(o4[a] === 7, "defineProperty(long key) store and read");
check(Object.getOwnPropertyDescriptor(o4, a).value === 7, "descriptor for the other long key");

// Object.fromEntries keys.
if (typeof Object.fromEntries === "function") {
    var fe = Object.fromEntries([[a, 9]]);
    check(fe[b] === 9, "Object.fromEntries with a long key");
}

// Short strings still share a pointer and symbols stay unique.
var x = "abc", y = "ab" + "c";
var os = {};
os[x] = 1;
check(os[y] === 1, "short interned key still matches");
var sa = Symbol("k"), sb = Symbol("k");
os[sa] = 2;
check(os[sb] === undefined, "distinct symbols stay distinct keys");
check(os[sa] === 2, "symbol key reads back");

print("test_long_string_keys: " + pass + " passed, " + (total - pass) + " failed");
