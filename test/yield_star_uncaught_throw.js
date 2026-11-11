// An exception escaping a delegate of `yield*` must reach the consumer as the
// thrown value. Spread consumes the generator through a re-entrant call, and
// the throw used to surface there as the generator's {done: true} result.
function check(label, got, want) {
    print((got === want ? "ok " : "FAIL ") + label + ": " + got);
}

function* recur(n) { if (n > 0) { yield n; yield* recur(n - 1); } }
check("recur", "" + [...recur(3)], "3,2,1");

function* boom(n) { if (n > 0) { yield n; yield* boom(n - 1); } else throw new Error("boom"); }
function* inner() { yield 1; throw new Error("x"); }
function* outer() { yield* inner(); }

function thrown(f) {
    try { f(); return "no throw"; } catch (e) { return e instanceof Error ? e.message : JSON.stringify(e); }
}
check("spread nested", thrown(function () { [...boom(3)]; }), "boom");
check("spread", thrown(function () { [...outer()]; }), "x");
check("spread arg", thrown(function () { Math.max(...outer()); }), "x");
check("for-of", thrown(function () { for (var v of outer()); }), "x");
check("Array.from", thrown(function () { Array.from(outer()); }), "x");
