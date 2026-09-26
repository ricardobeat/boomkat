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

print("compiler_capacity: " + passed + " passed");
