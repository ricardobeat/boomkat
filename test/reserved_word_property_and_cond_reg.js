// Two compiler bugs that only surfaced on the typescript 5.4.5 bundle.
//
// 1. `class` used as a PropertyName is an ordinary IdentifierName, not a class.
//    The raw-token hoist pre-scan treated every `class` token as one and called
//    skip_class_body(), which hunts forward for a `{` and skips a balanced
//    block. In `{ class: 86, ... }` that block belonged to the enclosing code,
//    so every declaration after the keyword table was swallowed and its `var`s
//    were never hoisted.
//
// 2. free_reg() released the register an `if`/`while` condition evaluated to.
//    When the condition is a bare reference to a `let`/`const`, that register
//    IS the binding's slot: it sits above reserved_regs (only params and
//    hoisted `var`s are below), so the reserved_regs guard did not protect it
//    and the next allocation inside the branch overwrote the live local.

function check(label, got, want) {
    var g = JSON.stringify(got), w = JSON.stringify(want);
    if (g !== w) { print("FAIL " + label + ": got " + g + " want " + w); }
}

// --- 1. reserved words in property position ---------------------------------

function keywordKeysThenDecls() {
    var table = {
        class: 86,
        function: 100,
        if: 101,
        return: 107,
    };
    // Everything below here used to be eaten by the bogus class-body skip.
    var afterTable = 1;
    function declaredAfter() { return 2; }
    var viaClosure = function () { return [afterTable, declaredAfter()]; };
    return [table.class, table.function, viaClosure()];
}
check("keyword keys do not swallow later declarations",
      keywordKeysThenDecls(), [86, 100, [1, 2]]);

function keywordMethodAndAccessor() {
    var o = {
        class() { return "m"; },
        get if() { return "g"; },
    };
    var after = "kept";
    return [o.class(), o.if, after];
}
check("keyword method/accessor keys", keywordMethodAndAccessor(), ["m", "g", "kept"]);

function keywordMemberName() {
    var o = {};
    o.class = 5;
    var after = 6;
    return [o.class, after];
}
check("keyword after '.'", keywordMemberName(), [5, 6]);

// Real classes must still be recognised (and their bodies still skipped by the
// pre-scan, so a method's `var` does not leak into the enclosing scope).
function realClassDeclaration() {
    class A { m() { var inner = 1; return inner; } }
    var after = 2;
    return [new A().m(), after, typeof inner];
}
check("class declaration still parses", realClassDeclaration(), [1, 2, "undefined"]);

function realClassExpression() {
    var C = class B extends Object { m() { var q = 3; return q; } };
    var after = 4;
    return [new C().m(), after];
}
check("class expression still parses", realClassExpression(), [3, 4]);

// --- 2. a condition register that is a live let/const slot ------------------

function multiMapAdd(o, key, value) {
    let values = o.get(key);
    if (values) {
        values.push(value);       // used to run against the "push" key constant
    } else {
        o.set(key, values = [value]);
    }
    return values;
}

function multiMapRoundTrip() {
    var m = new Map();
    multiMapAdd(m, "k", 1);
    multiMapAdd(m, "k", 2);
    multiMapAdd(m, "k", 3);
    return m.get("k");
}
check("let slot survives an if whose condition is that let", multiMapRoundTrip(), [1, 2, 3]);

function constConditionSlot() {
    const v = { n: 7 };
    if (v) { return v.n; }
    return -1;
}
check("const slot survives its own if condition", constConditionSlot(), 7);

function whileConditionSlot() {
    let n = 3;
    let seen = [];
    while (n) { seen.push(n); n = n - 1; }
    return seen;
}
check("let slot survives a while condition", whileConditionSlot(), [3, 2, 1]);

function ternaryConditionSlot() {
    let obj = { tag: "t" };
    return obj ? obj.tag : "none";
}
check("let slot survives a ternary condition", ternaryConditionSlot(), "t");

print("reserved_word_property_and_cond_reg: done");
