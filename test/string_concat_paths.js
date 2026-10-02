// `+` over every operand pair the concat helper decides without coercion
// (string+string, string+int, int+string, string+immediate) and the pairs it
// leaves to ToPrimitive, plus accumulation, the length cap, and symbols.
var fails = 0;
function eq(name, got, want) { if (got !== want) { fails++; print("FAIL " + name + ": " + got + " != " + want); } }
var s = "ab", n = 42;
eq("str+str", s + "cd", "abcd");
eq("str+int", s + n, "ab42");
eq("int+str", n + s, "42ab");
eq("str+negint", s + (-7), "ab-7");
eq("str+imm", s + 3, "ab3");
eq("str+double", s + 1.5, "ab1.5");
eq("str+bool", s + true, "abtrue");
eq("str+null", s + null, "abnull");
eq("str+undef", s + undefined, "abundefined");
eq("obj+str", ({ toString: function () { return "o"; } }) + s, "oab");
eq("str+obj", s + ({ valueOf: function () { return 5; } }), "ab5");
eq("empty", "" + "", "");
eq("chain", s + " " + n + "!", "ab 42!");
var acc = "";
for (var i = 0; i < 100; i++) acc += i;
eq("accumulate int", acc.length, 190);
acc = "x";
for (var i = 0; i < 1000; i++) acc += "yz";
eq("accumulate str", acc.length, 2001);
var shared = "q".repeat(40), alias = shared;
shared += "r";
eq("accumulator aliased", alias.length, 40);
eq("accumulator result", shared.length, 41);
var self = "w".repeat(40); self += self;
eq("self append", self.length, 80);
function f(a, b) { return a + b; }
eq("in function", f("a", "b"), "ab");
eq("in function int", f("a", 1), "a1");
eq("in function int first", f(1, "a"), "1a");
eq("numbers", f(1, 2), 3);
eq("doubles", f(0.5, 0.25), 0.75);
var sym = Symbol("x"), threw = false;
try { s + sym; } catch (e) { threw = e instanceof TypeError; }
eq("symbol rhs", threw, true);
threw = false;
try { sym + s; } catch (e) { threw = e instanceof TypeError; }
eq("symbol lhs", threw, true);
var big = "a".repeat(1 << 29), threw2 = false;
try { var t = big + big + big + big; } catch (e) { threw2 = e instanceof RangeError; }
eq("length cap", threw2, true);
print(fails === 0 ? "ok" : "failed");
