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

print("compiler_capacity: " + passed + " passed");
