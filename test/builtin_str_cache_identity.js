// String equality is pointer identity engine-wide, and the builtins read their
// fixed key strings from Heap.strs[] rather than re-interning the literal on
// every call. That only works because init_builtin_strs puts each literal into
// the same string table any later intern would search, so both routes yield one
// pointer.
//
// A key that reached Heap.strs[] without being interned, or a literal that
// drifted out of step with its BuiltinStr, would break `===`, property lookup,
// Map/Set, indexOf, switch, and JSON silently rather than by crashing. These
// probes reach every one of those surfaces with a *computed* string, which is
// interned by the normal path, and compare it against a builtin-supplied key.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}

// 1. Basic === on a computed string
t("concat-seq", "ab" === "a" + "b", true);
t("concat-seq-key", ("last" + "Index") === "lastIndex", true);

// 2. Computed string as an object key, read back
var o = {};
o["last" + "Index"] = 42;
t("computed-key", o.lastIndex, 42);
var o2 = {};
o2["gro" + "ups"] = 7;
t("computed-key2", o2["groups"], 7);

// 3. Same string in Map and Set
var m = new Map();
m.set("ind" + "ex", 1);
t("map-get", m.get("index"), 1);
var s = new Set();
s.add("inp" + "ut");
t("set-has", s.has("input"), true);

// 4. indexOf / lastIndexOf
t("indexOf", "xxlastIndexyy".indexOf("last" + "Index"), 2);

// 5. switch on a computed string
function sw(x) { switch (x) { case "sticky": return "S"; case "dotAll": return "D"; default: return "?"; } }
t("switch1", sw("stic" + "ky"), "S");
t("switch2", sw("dot" + "All"), "D");

// 6. JSON round-trip of a computed key
var j = {}; j["uni" + "code"] = true;
t("json", JSON.stringify(j), '{"unicode":true}');
t("json-parse", JSON.parse('{"flags":9}')["fla" + "gs"], 9);

// 7. Object.keys / for-in see the computed key
t("keys", Object.keys(j)[0], "unicode");
var seen = ""; for (var k in j) seen += k;
t("forin", seen, "unicode");

// 8. RegExp result shape uses the cached keys correctly
var r = /(\w+)@(\w+)/.exec("user@example");
t("re-0", r[0], "user@example");
t("re-1", r[1], "user");
t("re-index", r.index, 0);
t("re-input", r.input, "user@example");
t("re-groups", r.groups, undefined);
t("re-length", r.length, 3);
var rn = /(?<user>\w+)@(?<host>\w+)/.exec("bob@host");
t("re-named", rn.groups.user, "bob");
t("re-named2", rn.groups["ho" + "st"], "host");

// 9. lastIndex is a real, writable own property of the regexp
var g = /a/g;
t("lastIndex-init", g.lastIndex, 0);
g.exec("aaa");
t("lastIndex-adv", g.lastIndex, 1);
g.lastIndex = 0;
t("lastIndex-set", g.lastIndex, 0);
t("lastIndex-key", Object.getOwnPropertyNames(g).indexOf("lastIndex") >= 0, true);

// 10. flag accessors
var f = /a/gimsuy;
t("flags", f.flags, "gimsuy");
t("global", f.global, true);
t("sticky", f.sticky, true);
t("dotAll", f.dotAll, true);
t("unicode", f.unicode, true);
t("ignoreCase", f.ignoreCase, true);
t("multiline", f.multiline, true);
t("source", f.source, "a");
t("hasIndices", f.hasIndices, false);
var d = /(a)/d.exec("a");
t("indices", d.indices[0][0], 0);

// 11. replace/split/match use the same keys
t("replace", "a1b2".replace(/(\d)/g, "[$1]"), "a[1]b[2]");
t("split", "a1b2".split(/\d/).join(","), "a,b,");
t("match", "aXbX".match(/X/g).length, 2);
t("matchAll", Array.from("aXbX".matchAll(/X/g)).length, 2);

// 12. Long (non-interned) computed string identity still works
var long = "";
for (var i = 0; i < 40; i++) long += "0123456789";
t("long-len", long.length, 400);
var lo = {}; lo[long] = 5;
t("long-key", lo[long], 5);

// 13. Symbol.* keys are unaffected
t("symbol-key", typeof Symbol.iterator, "symbol");
t("array-iter", [1,2][Symbol.iterator]().next().value, 1);

// 14. length / constructor / name / prototype identity
t("len-key", ({}).hasOwnProperty("leng" + "th"), false);
t("arr-len", [1,2,3]["leng" + "th"], 3);
t("ctor", ({}).constructor === Object, true);
t("fn-name", (function foo(){}).name, "foo");

for (var i = 0; i < out.length; i++) print(out[i]);
