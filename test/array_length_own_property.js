// An array's "length" is an own property with fixed attributes
// {writable:true, enumerable:false, configurable:false}, and it lives in the
// array_len_ptr exotic slot rather than the named-property table.
//
// Two bugs this guards:
//  1. Key listings (getOwnPropertyNames / Reflect.ownKeys) walked only the
//     named table, so `length` vanished for every array whose length was
//     never materialised there — which is most of them.
//  2. arr_set_length_or_throw's fallback defined a materialised `length` with
//     PROP_FLAGS_WEC, making it enumerable+configurable. It then showed up in
//     console output and propertyIsEnumerable, and the snapshot went stale
//     whenever a dense fast path bumped array_len_ptr without the table.
//
// Both are attribute/identity invariants that must hold no matter how the
// array was built, so the cases below cover the distinct construction paths.

var pass = 0;
var fail = 0;
function assert(cond, msg) {
    if (cond) { pass = pass + 1; }
    else { print("FAIL: " + msg); fail = fail + 1; }
}

function build(tag, make) { return { tag: tag, a: make() }; }

var cases = [
    build("literal",        function () { return [1, 2, 3]; }),
    build("empty",          function () { return []; }),
    build("new Array(3)",   function () { return new Array(3); }),
    build("empty+push",     function () { var a = []; a.push(1); return a; }),
    build("empty+unshift",  function () { var a = []; a.unshift(1); return a; }),
    build("idx store",      function () { var a = []; a[0] = 1; return a; }),
    build("literal+push",   function () { var a = [1, 2, 3]; a.push(4); return a; }),
    build("push then pop",  function () { var a = []; a.push(1); a.pop(); return a; }),
    build("set length",     function () { var a = [1, 2, 3]; a.length = 2; return a; })
];

for (var i = 0; i < cases.length; i++) {
    var tag = cases[i].tag;
    var a = cases[i].a;

    // "length" is always an own property, however the array was built.
    assert(Object.getOwnPropertyNames(a).indexOf("length") !== -1,
           tag + ": getOwnPropertyNames includes length");
    assert(Reflect.ownKeys(a).indexOf("length") !== -1,
           tag + ": ownKeys includes length");
    assert(Object.prototype.hasOwnProperty.call(a, "length"),
           tag + ": hasOwnProperty length");

    // ...with the spec-mandated attributes.
    var d = Object.getOwnPropertyDescriptor(a, "length");
    assert(d.writable === true,      tag + ": length writable");
    assert(d.enumerable === false,   tag + ": length non-enumerable");
    assert(d.configurable === false, tag + ": length non-configurable");
    assert(a.propertyIsEnumerable("length") === false,
           tag + ": length not enumerable via propertyIsEnumerable");
    assert(d.value === a.length, tag + ": descriptor value matches live length");

    // Non-enumerable means it stays out of the enumerable-key views.
    assert(Object.keys(a).indexOf("length") === -1, tag + ": keys omits length");
    var seen = [];
    for (var k in a) { seen.push(k); }
    assert(seen.indexOf("length") === -1, tag + ": for-in omits length");
}

// "length" sorts after the index keys but before other named properties: it
// exists from creation, ahead of anything the program adds.
var ord = [1, 2];
ord.foo = "x";
ord.bar = "y";
assert(Object.getOwnPropertyNames(ord).join(",") === "0,1,length,foo,bar",
       "length ordered before later-added named properties");
assert(Reflect.ownKeys(ord).join(",") === "0,1,length,foo,bar",
       "ownKeys uses the same ordering");

// Exactly one "length" entry, even when a path materialised a table copy.
var dup = [];
dup.push(1);
var names = Object.getOwnPropertyNames(dup);
var n = 0;
for (var j = 0; j < names.length; j++) { if (names[j] === "length") n++; }
assert(n === 1, "length listed exactly once");

// The live length must win over any stale materialised snapshot.
var stale = [];
stale.push(1);
stale.push(2);
stale[5] = 6;
assert(stale.length === 6, "length tracks dense fast-path writes");
assert(Object.getOwnPropertyDescriptor(stale, "length").value === 6,
       "descriptor reads the live length, not a snapshot");

print("array_length_own_property: " + pass + " passed, " + fail + " failed");
if (fail > 0) { throw new Error("array_length_own_property failed"); }
