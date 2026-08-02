// Strings over MAX_INTERN_BYTES are left un-interned, so two separately built
// strings with equal content are distinct pointers. SameValueZero must compare
// content in that case, or Map/Set silently miss a key that === says is equal.
function build() {
    var s = "";
    for (var i = 0; i < 32; i++) s += "0123456789";
    return s;
}
var pass = 0, total = 0;
function check(cond, label) {
    total++;
    if (cond) { pass++; } else { print("FAIL: " + label); }
}

var a = build(), b = build();
check(a.length === 320, "length");
check(a === b, "=== on equal long strings");

var m = new Map();
m.set(a, "hit");
check(m.get(b) === "hit", "Map.get with an equal long key");
check(m.has(b), "Map.has with an equal long key");

var st = new Set();
st.add(a);
st.add(b);
check(st.size === 1, "Set dedups equal long strings");
check(st.has(b), "Set.has with an equal long key");

check([a].includes(b), "Array.includes with an equal long string");
check([a].indexOf(b) === 0, "Array.indexOf with an equal long string");
check(Object.is(a, b), "Object.is on equal long strings");

// Short strings are interned, so these already shared a pointer.
var x = "abc", y = "ab" + "c";
check(new Map([[x, 1]]).get(y) === 1, "Map.get with an equal short key");

print("engine/large_string_identity: " + pass + " passed, " + (total - pass) + " failed");
