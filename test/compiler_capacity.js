// The compiler's bookkeeping must grow with the source. Each check builds a
// program past a size that some fixed table once held, and compares its
// result with the value every element contributes.
var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

function range(n, fn) {
    var out = [];
    for (var i = 0; i < n; i++) out.push(fn(i));
    return out;
}

function sumTo(n) { return n * (n - 1) / 2; }

var run = eval;

check("a class with many methods",
    run("var C = class {" + range(100, i => "m" + i + "(){ return " + i + " }").join("") + "};" +
        "var s = 0; for (var i = 0; i < 100; i++) s += new C()['m' + i](); s"),
    sumTo(100));
check("a class with many static accessors",
    run("var C = class {" + range(100, i => "static get m" + i + "(){ return " + i + " } static set m" + i + "(v){}").join("") + "};" +
        "var s = 0; for (var i = 0; i < 100; i++) s += C['m' + i]; s"),
    sumTo(100));
check("a class with many private methods",
    run("var C = class {" + range(100, i => "#m" + i + "(){ return " + i + " } g" + i + "(){ return this.#m" + i + "() }").join("") + "};" +
        "var c = new C(), s = 0; for (var i = 0; i < 100; i++) s += c['g' + i](); s"),
    sumTo(100));

var names = range(100, i => "a" + i).join(",");
var values = "[" + range(100, i => i).join(",") + "]";
var props = "{" + range(100, i => "a" + i + ":" + i).join(",") + "}";
var total = range(100, i => "a" + i).join("+");
check("a var array pattern with many elements",
    run("(function(){ var [" + names + "] = " + values + "; return " + total + " })()"), sumTo(100));
check("a let object pattern with many properties",
    run("(function(){ let {" + names + "} = " + props + "; return " + total + " })()"), sumTo(100));
check("a parameter pattern with many elements",
    run("(function([" + names + "]){ return " + total + " })(" + values + ")"), sumTo(100));
check("an array assignment pattern with many elements",
    run("(function(){ var " + names + "; [" + names + "] = " + values + "; return " + total + " })()"), sumTo(100));
check("an object assignment pattern with many properties",
    run("(function(){ var " + names + "; ({" + names + "} = " + props + "); return " + total + " })()"), sumTo(100));
check("a for-of head pattern with many elements",
    run("(function(){ for (const [" + names + "] of [" + values + "]) return " + total + " })()"), sumTo(100));
check("a bare for-of pattern with many elements",
    run("(function(){ var " + names + "; for ([" + names + "] of [" + values + "]); return " + total + " })()"), sumTo(100));
check("a for-in head pattern with many elements",
    run("(function(){ for (let [" + names + "] in {" + "k".repeat(100) + ": 0}) return a99 })()"), "k");
check("a catch pattern with many elements",
    run("(function(){ try { throw " + values + " } catch ([" + names + "]) { return " + total + " } })()"), sumTo(100));

var longName = "n".repeat(70);
check("a pattern binding with a long name",
    run("(function({" + longName + "}){ return " + longName + " })({" + longName + ": 7})"), 7);
check("the inferred name of a long pattern default",
    run("(function({" + longName + " = function(){}}){ return " + longName + ".name })({})"), longName);

var defaulted = range(40, i => "p" + i + " = " + i).join(",");
var defaultedSum = range(40, i => "p" + i).join("+");
check("a function with many parameter defaults",
    run("(function(" + defaulted + "){ return " + defaultedSum + " })()"), sumTo(40));
check("an arrow with many parameter defaults",
    run("((" + defaulted + ") => " + defaultedSum + ")()"), sumTo(40));
check("a method with many parameter defaults",
    run("(class { m(" + defaulted + "){ return " + defaultedSum + " } })").prototype.m(), sumTo(40));
var patternDefaults = range(40, i => "[d" + i + "] = [" + i + "]").join(",");
var patternSum = range(40, i => "d" + i).join("+");
check("a function with many pattern parameter defaults",
    run("(function(" + patternDefaults + "){ return " + patternSum + " })()"), sumTo(40));
check("an arrow with many pattern parameter defaults",
    run("((" + patternDefaults + ") => " + patternSum + ")()"), sumTo(40));

// Every lexical head binding gets a fresh copy per iteration, so each closure
// sees the values of its own iteration.
var heads = range(20, i => "h" + i + " = " + i).join(",");
var headList = range(20, i => "h" + i).join(",");
check("a for-loop head with many captured bindings",
    run("(function(){ var fs = []; for (let " + heads + "; h0 < 3; h0++, h19++) fs.push(() => [" + headList + "].join()); " +
        "return fs.map(f => f()).join('|') })()"),
    [0, 1, 2].map(k => range(20, i => i == 0 ? k : i == 19 ? 19 + k : i).join()).join("|"));
check("a for-in head pattern with many captured bindings",
    run("(function(){ var fs = []; for (let [" + names + "] in {ab: 0, cd: 0}) fs.push(() => a0 + a1 + (a99 === undefined)); " +
        "return fs.map(f => f()).join() })()"), "abtrue,cdtrue");

// Control flow nested past any small fixed depth.
function nest(n, open, close, inner) { return open.repeat(n) + inner + close.repeat(n); }
check("a break out of many nested try blocks runs every finally",
    run("(function(){ var log = 0; for (;;) { " + nest(20, "try { ", " } finally { log++ } ", "break;") + " } return log })()"), 20);
check("a break from a try inside a loop inside many try blocks runs its finally",
    run("(function(){ var log = 0; " + nest(10, "try { ", " } finally {} ",
        "for (;;) { try { break; } finally { log++ } }") + " return log })()"), 1);
check("a labelled continue across many nested loops",
    run("(function(){ var n = 0; outer: for (var i = 0; i < 3; i++) { " +
        nest(30, "for (;;) { ", " } ", "n++; continue outer;") + " } return n })()"), 3);
check("a break out of 200 nested loops",
    run("(function(){ var n = 0; " + nest(200, "while (true) { ", " break; } ", "n++;") + " return n })()"), 1);
check("many nested labels",
    run("(function(){ var n = 0; " + range(30, i => "l" + i + ": { ").join("") + "n++; break l0; n++; " +
        "}".repeat(30) + " return n })()"), 1);
var arms = range(3000, i => "case " + i + ": return " + i + ";").join(" ");
check("a switch with many cases",
    run("(function(x){ switch (x) { " + arms + " } })(2999)"), 2999);

// Nesting deep enough to exhaust the native stack is an error, not a crash.
function throwsOnDeepNesting(src) {
    try { run(src); return false; } catch (e) { return e instanceof SyntaxError || e instanceof RangeError; }
}
[["blocks", "{".repeat(100000)],
 ["parentheses", "(".repeat(100000)],
 ["unary operators", "!".repeat(100000) + "1"],
 ["assignments", "a=".repeat(100000) + "1"],
 ["conditionals", "1?".repeat(50000) + "1" + ":1".repeat(50000)],
 ["arrows", "()=>".repeat(100000) + "1"],
 ["functions", "(function(){".repeat(10000) + "})()".repeat(10000)],
 ["classes", "(class{m(){return ".repeat(10000) + "1" + "}})".repeat(10000)]].forEach(function (c) {
    check("deeply nested " + c[0], throwsOnDeepNesting(c[1]), true);
});
check("moderately nested functions",
    run("(function(){return ".repeat(60) + "7" + "})()".repeat(60)), 7);

print("compiler_capacity: " + passed + " passed");
