// A Symbol and an engine slot name are identified by flags, never by the bytes
// they store: strings spelled like their characters must stay ordinary.
var failed = false;
function check(label, ok) {
  if (!ok) { print("FAIL: " + label); failed = true; }
}

var sym = Symbol("length");
check("symbol is not its description", sym !== "length");
check("symbol key is distinct from string key", ({ [sym]: 1, length: 2 })[sym] === 1);
check("typeof symbol", typeof sym === "symbol");
check("description", sym.description === "length");
check("empty description", Symbol("").description === "" && Symbol().description === undefined);

// A symbol whose characters look like another primitive is still a symbol.
var bare = Symbol();
check("empty symbol is truthy", !!bare && (bare ? true : false));
check("empty symbol is not nullish", (bare ?? "x") === bare);
check("symbol != 0", !(bare == 0) && !(bare == -0) && !(Symbol("0") == 0));
check("symbol != empty string", !(bare == "") && !(bare === ""));
check("symbol != bigint", !(1n == Symbol("1")) && !(0n == bare));
var keyed = {};
keyed[Symbol("1")] = "sym";
keyed[1] = "idx";
check("symbol 1 is not index 1", keyed[1] === "idx" && Object.keys(keyed).length === 1);
var ta = new Float64Array(2);
check("symbol Infinity is not a numeric index", !Reflect.has(ta, Symbol("Infinity")) && !Reflect.has(ta, Symbol("-0")));

// Strings that begin with U+00FF or U+FFFF must not be taken for symbols, and
// must not collide with the engine's hidden slot names.
var names = ["ÿ", "ÿÿ", "ÿpromise", "ÿcap_resolve_tv", "ÿresources",
             "promise", "cap_resolve_tv", "resources", "￿", "￿promise"];
var o = {};
for (var i = 0; i < names.length; i++) o[names[i]] = i;
for (var i = 0; i < names.length; i++) {
  check("property " + i, o[names[i]] === i);
  check("typeof " + i, typeof names[i] === "string");
}
check("string keys only", Object.getOwnPropertyNames(o).length === names.length);
check("no symbol keys", Object.getOwnPropertySymbols(o).length === 0);

var p = Promise.resolve(1);
p["ÿpromise"] = 5;
p["promise"] = 6;
var done = false;
p.then(function (v) { done = v === 1; });
Promise.resolve().then(function () {}).then(function () {
  check("promise survives lookalike keys", done);
  if (!failed) print("ok");
});
