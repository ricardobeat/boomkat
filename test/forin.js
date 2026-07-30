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
// --- Symbol keys are never enumerated (EnumerateObjectProperties yields
//     only String keys, ES2024 14.7.5.9) ---
var sym_s = Symbol("s");
var sym_obj = {};
sym_obj[sym_s] = 1;
sym_obj.plain = 2;
var sym_keys = [];
for (var k in sym_obj) { sym_keys.push(String(k)); }
assert(sym_keys.length == 1, "for-in with symbol key: 1 key yielded");
assert(sym_keys[0] == "plain", "for-in with symbol key: yields only the string key");

// A yielded symbol used in string context throws; enumerating none must not.
var sym_only = {};
sym_only[Symbol("only")] = 1;
var sym_only_count = 0;
var sym_only_threw = 0;
try {
    for (var k in sym_only) { var concat = "x" + k; sym_only_count = sym_only_count + 1; }
} catch (e) { sym_only_threw = 1; }
assert(sym_only_threw == 0, "for-in over symbol-only object does not throw");
assert(sym_only_count == 0, "for-in over symbol-only object: 0 iterations");

// Non-enumerable symbol is likewise absent, and does not hide string keys.
var sym_ne = {};
Object.defineProperty(sym_ne, Symbol("ne"), { value: 1, enumerable: false });
sym_ne.visible = 2;
var sym_ne_keys = [];
for (var k in sym_ne) { sym_ne_keys.push(String(k)); }
assert(sym_ne_keys.length == 1 && sym_ne_keys[0] == "visible",
       "for-in skips non-enumerable symbol, keeps string key");

// Symbols on the prototype chain are skipped too.
var sym_proto = {};
sym_proto[Symbol("proto")] = 1;
sym_proto.inherited = 2;
var sym_child = Object.create(sym_proto);
sym_child.own = 3;
var sym_chain = [];
for (var k in sym_child) { sym_chain.push(String(k)); }
assert(sym_chain.length == 2, "for-in skips prototype symbol key");
assert(sym_chain[0] == "own" && sym_chain[1] == "inherited",
       "for-in prototype walk order preserved with symbols present");

// Well-known symbols on the object are not enumerated.
var sym_wk = { a: 1 };
sym_wk[Symbol.iterator] = function () {};
sym_wk[Symbol.toStringTag] = "T";
var sym_wk_keys = [];
for (var k in sym_wk) { sym_wk_keys.push(String(k)); }
assert(sym_wk_keys.length == 1 && sym_wk_keys[0] == "a",
       "for-in skips well-known symbol keys");

// Symbols remain reachable through the own-keys paths.
assert(Object.getOwnPropertySymbols(sym_obj).length == 1,
       "getOwnPropertySymbols still reports the symbol");
assert(Object.keys(sym_obj).join(",") == "plain", "Object.keys unaffected");
assert(JSON.stringify(sym_obj) == '{"plain":2}', "JSON.stringify unaffected");
var sym_copy = Object.assign({}, sym_obj);
assert(sym_copy[sym_s] == 1, "Object.assign still copies symbol-keyed props");

// A Proxy whose ownKeys returns symbols must not leak them into for-in.
var sym_px = Symbol("px");
var px_target = { a: 2 };
px_target[sym_px] = 1;
var px = new Proxy(px_target, {
    ownKeys: function () { return ["a", sym_px]; },
    getOwnPropertyDescriptor: function (t, k) {
        return { value: 1, enumerable: true, configurable: true };
    }
});
var px_keys = [];
for (var k in px) { px_keys.push(String(k)); }
assert(px_keys.length == 1 && px_keys[0] == "a",
       "for-in over Proxy skips symbols from ownKeys trap");

print("PASS: " + pass + " / " + (pass + fail) + " assertions");
if (fail > 0) { print("SOME TESTS FAILED"); }
