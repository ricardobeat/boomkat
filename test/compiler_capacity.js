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

// Private names resolve through any depth of nested classes: each class reads
// its own #v and the outermost class's #root.
var classDepth = 30;
var nestedClasses = "";
for (var d = classDepth - 1; d >= 0; d--) {
    var inner = d == classDepth - 1 ? "0" : "new (" + nestedClasses + ")().m(o)";
    nestedClasses = "class { #v = " + d + (d == 0 ? "; #root = 100" : "") + "; m(o) { return this.#v + o.#root + " + inner + " } }";
}
check("private names in deeply nested classes",
    run("(function(){ var C = " + nestedClasses + "; var o = new C(); return o.m(o) })()"),
    sumTo(classDepth) + 100 * classDepth);
check("the same private name in deeply nested classes",
    run("(function(){ return " + "new (class { #x = 1; m() { return this.#x + ".repeat(20) + "0" + " } })().m()".repeat(20) + " })()"), 20);

// Duplicate parameter names are found however long the list or the names are.
function isSyntaxError(src) {
    try { run(src); return false; } catch (e) { return e instanceof SyntaxError; }
}
var paramList = range(40, i => "q" + i).join(",");
check("a strict duplicate past many parameters",
    isSyntaxError("'use strict'; (function(" + paramList + ", q39){})"), true);
check("a duplicate past many parameters before a later \"use strict\"",
    isSyntaxError("(function(" + paramList + ", q39){ 'use strict' })"), true);
check("an arrow duplicate past many parameters",
    isSyntaxError("((" + paramList + ", q39) => 0)"), true);
check("a method duplicate past many parameters",
    isSyntaxError("({ m(" + paramList + ", q39){} })"), true);
check("a strict duplicate long parameter name",
    isSyntaxError("'use strict'; (function(" + longName + ", " + longName + "){})"), true);
check("a sloppy duplicate past many parameters binds the last",
    run("(function(" + paramList + ", q39){ return q39 })(" + range(41, i => i).join(",") + ")"), 40);
check("distinct long parameter names sharing a prefix",
    run("'use strict'; (function(" + longName + "a, " + longName + "b){ return " + longName + "b })(1, 2)"), 2);

// A "use strict" late in a long directive prologue still applies to the whole
// body: to octal escapes before it and to the parameter list.
var directives = "'d';".repeat(20);
check("an octal escape many directives before \"use strict\"",
    isSyntaxError("(function(){ '\\07'; " + directives + " 'use strict'; })"), true);
check("an eval parameter with \"use strict\" many directives in",
    isSyntaxError("(function(eval){ " + directives + " 'use strict'; })"), true);
check("a duplicate parameter with \"use strict\" many directives in",
    isSyntaxError("(function(a, a){ " + directives + " 'use strict'; })"), true);
check("a declared function with \"use strict\" many directives in",
    isSyntaxError("function f(eval){ " + directives + " 'use strict'; }"), true);
check("a long sloppy prologue",
    run("(function(){ " + directives + " return typeof this })()"), "object");

// Inferred and bound function names are kept whole however long they are.
var hugeName = "h".repeat(200);
check("a long assigned name", run("var " + hugeName + "; " + hugeName + " = function(){}; " + hugeName + ".name"), hugeName);
check("a long var-initializer name", run("(function(){ var " + hugeName + " = () => 0; return " + hugeName + ".name })()"), hugeName);
check("a long let-initializer name", run("(function(){ let " + hugeName + " = class {}; return " + hugeName + ".name })()"), hugeName);
check("a long method name", run("({ " + hugeName + "(){} })." + hugeName + ".name"), hugeName);
check("a long property function name", run("({ " + hugeName + ": function(){} })." + hugeName + ".name"), hugeName);
check("a long getter name",
    run("Object.getOwnPropertyDescriptor({ get " + hugeName + "(){} }, '" + hugeName + "').get.name"), "get " + hugeName);
check("a long class field name", run("new (class { " + hugeName + " = function(){} })()." + hugeName + ".name"), hugeName);
check("a long private field name",
    run("new (class { #" + hugeName + " = function(){}; n() { return this.#" + hugeName + ".name } })().n()"), "#" + hugeName);
check("a long escaped identifier name",
    run("(function(){ var \\u0068" + hugeName + " = function(){}; return h" + hugeName + ".name })()"), "h" + hugeName);
check("a long bound name", run("var " + hugeName + " = function(){}; " + hugeName + ".bind().name"), "bound " + hugeName);
check("a bound name that ends in a multibyte character",
    run("var o = { " + "x".repeat(119) + "\u00e9: function(){} }; o." + "x".repeat(119) + "\u00e9.bind().name"),
    "bound " + "x".repeat(119) + "\u00e9");

// Names past the string intern cutoff (256 bytes) still resolve.
var giantName = "g".repeat(1000);
check("a long global variable", run("var " + giantName + " = 1; " + giantName), 1);
check("a long implicit global", run(giantName + "x = 2; " + giantName + "x"), 2);
check("a long local captured by a closure",
    run("(function(){ var " + giantName + " = 3; return () => " + giantName + " })()()"), 3);
check("a long property name", run("({ " + giantName + ": 4 })." + giantName), 4);
check("a long property name from a computed key", run("({ " + giantName + ": 5 })['" + giantName + "']"), 5);
check("a long global function name", run("function " + giantName + "(){ return 6 } " + giantName + "()"), 6);

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
