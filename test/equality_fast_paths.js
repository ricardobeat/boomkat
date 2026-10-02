// ==, !=, === and !== over operand pairs the threaded handler decides inline
// (fastints, identical bit patterns, distinct interned strings) and the pairs it
// leaves to the switch (NaN, -0, coercions, built strings).
var fails = 0;
function eq(name, got, want) { if (got !== want) { fails++; print("FAIL " + name + ": " + got + " != " + want); } }
var sym = Symbol("s"), sym2 = Symbol("s"), obj = {}, obj2 = {}, nan = NaN, big = 10n;
var built = "ab" + "c".repeat(1), lit = "abc", other = "abd";
var vals = [0, 1, -0, 2147483648, 1.5, nan, "", "1", lit, built, null, undefined, true, false, obj, obj2, sym, sym2, big, 1n];
function loose(a, b) { return a == b; }
function strict(a, b) { return a === b; }
function nloose(a, b) { return a != b; }
function nstrict(a, b) { return a !== b; }
for (var i = 0; i < vals.length; i++) {
  for (var j = 0; j < vals.length; j++) {
    var a = vals[i], b = vals[j];
    eq("== vs !=", loose(a, b), !nloose(a, b));
    eq("=== vs !==", strict(a, b), !nstrict(a, b));
    if (strict(a, b)) eq("=== implies ==", loose(a, b), true);
  }
}
eq("fastint ==", loose(3, 3), true);
eq("fastint !=", loose(3, 4), false);
eq("NaN ===", strict(nan, nan), false);
eq("NaN !==", nstrict(nan, nan), true);
eq("-0 === 0", strict(-0, 0), true);
eq("same interned", strict(lit, "abc"), true);
eq("distinct interned", strict(lit, other), false);
eq("built string", strict(built, lit), true);
eq("string vs number", loose("1", 1), true);
eq("null == undefined", loose(null, undefined), true);
eq("null === undefined", strict(null, undefined), false);
eq("same object", strict(obj, obj), true);
eq("distinct objects", strict(obj, obj2), false);
eq("same symbol", strict(sym, sym), true);
eq("distinct symbols", strict(sym, sym2), false);
eq("bigint", strict(big, 10n), true);
eq("bigint == number", loose(big, 10), true);
var r = 1; r = (lit == "abc"); eq("result register reuse", r, true);
var s = "x" + Math.random(); var t = s; t = (lit == other); eq("releases old string", t, false);
print(fails === 0 ? "ok" : "failed");
