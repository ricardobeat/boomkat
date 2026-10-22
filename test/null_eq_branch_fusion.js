// Loose-equality and null-comparison branches (JMP_EQ/JMP_NEQ/JMP_NULL/JMP_NNULL)
// and `!x` feeding a branch. Each shape is checked against an oracle that
// materializes the comparison result in a value context, which never fuses.
var failures = 0;
function check(name, actual, expected) {
  if (actual !== expected && !(actual !== actual && expected !== expected)) {
    failures++;
    print("FAIL " + name + ": got " + String(actual) + ", expected " + String(expected));
  }
}

var dda = __isHTMLDDA();
var valueOfCalls = 0;
var counting = { valueOf: function () { valueOfCalls++; return 1; } };
var values = [
  null, undefined, 0, 1, -0, NaN, 2147483647, 1.5, "", "0", "1", "null", "a",
  true, false, {}, [], [0], dda, counting, Symbol.iterator, 10n, 1n, 0n,
];
var names = ["null", "undefined", "0", "1", "-0", "NaN", "int-max", "1.5", "''", "'0'", "'1'",
  "'null'", "'a'", "true", "false", "{}", "[]", "[0]", "dda", "counting", "symbol", "10n", "1n", "0n"];

// Branch forms under test.
function eqBranch(x, y) { if (x == y) return true; return false; }
function neqBranch(x, y) { if (x != y) return true; return false; }
function eqNullRight(x) { if (x == null) return true; return false; }
function neqNullRight(x) { if (x != null) return true; return false; }
function eqNullLeft(x) { if (null == x) return true; return false; }
function neqNullLeft(x) { if (null != x) return true; return false; }
function eqVoid(x) { if (x == void 0) return true; return false; }
function neqUndefGlobal(x) { if (x != undefined) return true; return false; }
function notBranch(x) { if (!x) return true; return false; }
function truthyBranch(x) { if (!!x) return true; return false; }
function ternaryEq(x, y) { return x == y ? 1 : 2; }
function ternaryNull(x) { return x == null ? 1 : 2; }
function whileNotNull(x) { var n = 0; while (x != null && n < 3) n++; return n; }
function orChain(x, y) { if (x == null || y == null) return true; return false; }
function andChain(x, y) { if (x != null && y != null) return true; return false; }
function notAnd(x, y) { if (!x && !y) return true; return false; }
function notOr(x, y) { if (!x || y) return true; return false; }

// Oracles: the result goes through a register that outlives the compare.
function eqValue(x, y) { var r = x == y; return r; }
function neqValue(x, y) { var r = x != y; return r; }
function nullValue(x) { var r = x == null; return r; }
function notValue(x) { var r = !x; return r; }

function sweep(label, run) {
  // Repeat so the loop warms the threaded handlers as well as the switch.
  for (var rep = 0; rep < 3; rep++) run(label);
}

sweep("eq/neq", function () {
  for (var i = 0; i < values.length; i++) {
    for (var j = 0; j < values.length; j++) {
      var tag = names[i] + " vs " + names[j];
      check("== " + tag, eqBranch(values[i], values[j]), eqValue(values[i], values[j]));
      check("!= " + tag, neqBranch(values[i], values[j]), neqValue(values[i], values[j]));
      check("?: " + tag, ternaryEq(values[i], values[j]), eqValue(values[i], values[j]) ? 1 : 2);
      check("|| " + tag, orChain(values[i], values[j]),
        nullValue(values[i]) || nullValue(values[j]));
      check("&& " + tag, andChain(values[i], values[j]),
        !nullValue(values[i]) && !nullValue(values[j]));
      check("!&& " + tag, notAnd(values[i], values[j]),
        notValue(values[i]) && notValue(values[j]));
      check("!|| " + tag, notOr(values[i], values[j]),
        notValue(values[i]) || !!values[j]);
    }
  }
});

sweep("null", function () {
  for (var i = 0; i < values.length; i++) {
    var v = values[i];
    var isNullish = v === null || v === undefined || v === dda;
    check("x==null " + names[i], eqNullRight(v), isNullish);
    check("x!=null " + names[i], neqNullRight(v), !isNullish);
    check("null==x " + names[i], eqNullLeft(v), isNullish);
    check("null!=x " + names[i], neqNullLeft(v), !isNullish);
    check("x==void0 " + names[i], eqVoid(v), isNullish);
    check("x!=undefined " + names[i], neqUndefGlobal(v), !isNullish);
    check("?:null " + names[i], ternaryNull(v), isNullish ? 1 : 2);
    check("while " + names[i], whileNotNull(v), isNullish ? 0 : 3);
    check("!x " + names[i], notBranch(v), notValue(v));
    check("!!x " + names[i], truthyBranch(v), !notValue(v));
  }
  check("dda == null", dda == null, true);
  check("null == dda", null == dda, true);
  check("dda == undefined", dda == undefined, true);
  check("dda != null", dda != null, false);
  check("dda is falsy", !dda, true);
  check("dda === null", dda === null, false);
  check("dda == 0", dda == 0, false);
  check("dda == ''", dda == "", false);
});

// The null side never reaches ToPrimitive; the other side runs valueOf once.
valueOfCalls = 0;
for (var k = 0; k < 10; k++) {
  if (counting == null) failures++;
  if (null == counting) failures++;
  if (counting != null) { } else failures++;
}
check("valueOf not called by null compare", valueOfCalls, 0);
for (var k = 0; k < 10; k++) { if (counting == 1) { } else failures++; }
check("valueOf once per == 1", valueOfCalls, 10);

// Evaluation order and side effects of ToPrimitive in a branch condition.
var log = [];
function lhs() { log.push("lhs"); return { valueOf: function () { log.push("L.valueOf"); return 5; } }; }
function rhs() { log.push("rhs"); return 5; }
function orderBranch() { if (lhs() == rhs()) return "eq"; return "ne"; }
check("order result", orderBranch(), "eq");
check("order log", log.join(","), "lhs,rhs,L.valueOf");

// A throwing valueOf unwinds from the fused branch; the handler sees live state.
function throwing() { return { valueOf: function () { throw new Error("boom"); } }; }
function catches(x) {
  var seen = "none";
  try {
    if (x == 1) seen = "equal";
    else seen = "different";
  } catch (e) {
    seen = "caught " + e.message;
  }
  return seen;
}
check("throw in ==", catches(throwing()), "caught boom");
check("no throw", catches(1), "equal");
check("no throw 2", catches(2), "different");
function throwsOut(x) { if (x != 1) return "ne"; return "eq"; }
var threw = false;
try { throwsOut(throwing()); } catch (e) { threw = e.message === "boom"; }
check("throw propagates", threw, true);

// Branch targets between the null load and the compare, and onto the branch.
function midPairLoad(x, c) { if (x == (c ? null : 1)) return "eq"; return "ne"; }
check("mid load c, x null", midPairLoad(null, true), "eq");
check("mid load c, x 1", midPairLoad(1, true), "ne");
check("mid load !c, x 1", midPairLoad(1, false), "eq");
check("mid load !c, x null", midPairLoad(null, false), "ne");
function midPairLeft(x, c) { if ((c ? null : undefined) == x) return "eq"; return "ne"; }
check("mid left c", midPairLeft(undefined, true), "eq");
check("mid left !c", midPairLeft(null, false), "eq");
check("mid left 0", midPairLeft(0, true), "ne");
function midPairBoth(x, y, c) { if (x == (c ? null : y)) return "eq"; return "ne"; }
check("mid both c", midPairBoth(undefined, 3, true), "eq");
check("mid both !c", midPairBoth(3, 3, false), "eq");
check("mid both !c ne", midPairBoth(undefined, 3, false), "ne");
function joinOnBranch(a, b, c) {
  var r = 0;
  if (c) { r = a == null; } else { r = b == null; }
  if (r) return "yes";
  return "no";
}
check("join c null", joinOnBranch(null, 1, true), "yes");
check("join c non-null", joinOnBranch(1, null, true), "no");
check("join !c null", joinOnBranch(1, null, false), "yes");
check("join !c non-null", joinOnBranch(null, 1, false), "no");
function sharedNull(x, y) {
  var n = null;
  var a = x == n;
  var b = y != n;
  if (x == n) a = !a;
  return [a, b].join();
}
check("null register reused", sharedNull(null, 1), "false,true");
check("null register reused 2", sharedNull(1, null), "false,false");

// `!x` feeding a branch: the negation is read again, rewritten in place, or loops.
function notReused(x) { var n = !x; if (n) return "n:" + n; return "t:" + n; }
function notInPlace(x) { x = !x; if (x) return "was falsy"; return "was truthy"; }
function notLoop(limit) { var done = false, n = 0; while (!done) { n++; if (n >= limit) done = true; } return n; }
function notInTry(x) { try { if (!x) return "falsy"; return "truthy"; } catch (e) { return "caught"; } }
function notValueUse(x) { var r = !x ? "a" : "b"; return r + (!x); }
for (var m = 0; m < values.length; m++) {
  var tv = !!values[m];
  check("notReused " + names[m], notReused(values[m]), tv ? "t:false" : "n:true");
  check("notInPlace " + names[m], notInPlace(values[m]), tv ? "was truthy" : "was falsy");
  check("notInTry " + names[m], notInTry(values[m]), tv ? "truthy" : "falsy");
  check("notValueUse " + names[m], notValueUse(values[m]), (tv ? "b" : "a") + (!tv));
}
check("notLoop", notLoop(2000), 2000);

// Backward branches charge the safepoint budget and bail to the switch.
function countdown(x) {
  var n = 0;
  while (x != null) { n++; if (n >= 5000) x = null; }
  return n;
}
check("loop on null", countdown(1), 5000);
function skipNulls(a) {
  var n = 0;
  for (var i = 0; i < a.length; i++) { if (a[i] == null) continue; n++; }
  return n;
}
var arr = [];
for (var q = 0; q < 1000; q++) arr.push(q % 3 === 0 ? null : (q % 3 === 1 ? undefined : q));
check("skip nulls", skipNulls(arr), 333);

// Strings: interned, built at runtime and numeric forms.
var built = "ab" + "c".repeat(2);
check("string ==", eqBranch(built, "abcc"), true);
check("string != ", neqBranch(built, "abcd"), true);
check("number string", eqBranch("12", 12), true);
check("number string 2", neqBranch("12", 13), true);
check("bool number", eqBranch(true, 1), true);
check("NaN == NaN", eqBranch(NaN, NaN), false);
check("NaN != NaN", neqBranch(NaN, NaN), true);
check("NaN == null", eqNullRight(NaN), false);
check("-0 == 0", eqBranch(-0, 0), true);
check("1.5 == 1.5", eqBranch(1.5, 1.5), true);

if (failures !== 0) throw new Error(failures + " failures");
print("PASS null_eq_branch_fusion");
