// for-in basic tests
var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass = pass + 1; }
    else { print("FAIL: " + msg); fail = fail + 1; }
}

// --- Basic object enumeration ---
var obj = { a: 1, b: 2, c: 3 };
var count = 0;
var found_a = 0;
var found_b = 0;
var found_c = 0;
for (var k in obj) {
    count = count + 1;
    if (k == "a") { found_a = 1; }
    if (k == "b") { found_b = 1; }
    if (k == "c") { found_c = 1; }
}
assert(count >= 3, "for-in finds at least 3 keys on {a,b,c}");
assert(found_a == 1, "key 'a' found");
assert(found_b == 1, "key 'b' found");
assert(found_c == 1, "key 'c' found");

// --- Nested for-in ---
var outer = { x: 1, y: 2 };
var inner = { a: 10, b: 20 };
var total = 0;
for (var o in outer) {
    for (var i in inner) {
        total = total + 1;
    }
}
assert(total > 0, "nested for-in iterates some items");

// --- Null/undefined skip ---
var n_count = 0;
for (var k in null) { n_count = n_count + 1; }
assert(n_count == 0, "for-in null: 0 iterations");

var u_count = 0;
for (var k in undefined) { u_count = u_count + 1; }
assert(u_count == 0, "for-in undefined: 0 iterations");

// --- Array indices enumeration ---
var arr = [10, 20, 30];
var idx_count = 0;
for (var i in arr) {
    idx_count = idx_count + 1;
}
assert(idx_count >= 3, "for-in on array finds at least 3 keys");

// --- Prototype-chain shadowing ---
// A non-enumerable own property hides a same-named enumerable one further up
// the chain (EnumerateObjectProperties records every own key it visits).
var shadow_base = { sk: 1 };
var shadow_obj = Object.create(shadow_base);
Object.defineProperty(shadow_obj, "sk", { value: 2, enumerable: false });
var shadow_count = 0;
for (var k in shadow_obj) { shadow_count = shadow_count + 1; }
assert(shadow_count == 0, "non-enumerable own key shadows inherited enumerable");

// Deeper than the lazily-probed level window, exercising the eager fallback.
var deep = { dk: 1 };
for (var i = 0; i < 25; i++) { deep = Object.create(deep); }
Object.defineProperty(deep, "dk", { value: 0, enumerable: false });
var deep_count = 0;
for (var k in deep) { deep_count = deep_count + 1; }
assert(deep_count == 0, "shadowing holds past the lazy level window");

// --- Large key sets ---
// Enough keys to promote the de-duplication set to its hash index, with a
// second level whose keys all miss: the probe must terminate on every miss.
var many_base = {};
for (var i = 0; i < 60; i++) { many_base["h" + i] = i; }
var many = Object.create(many_base);
for (var i = 0; i < 60; i++) { many["g" + i] = i; }
var many_count = 0;
for (var k in many) { many_count = many_count + 1; }
assert(many_count == 120, "120 keys across two levels enumerate once each");

print("PASS: " + pass + " / " + (pass + fail) + " assertions");
if (fail > 0) { print("SOME TESTS FAILED"); }
