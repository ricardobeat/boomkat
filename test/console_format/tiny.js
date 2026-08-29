// Fixture for the SLIM build's tiny value formatter (src/builtins/inspect_tiny.c3).
//
// Unlike cases.js and matrix.js, this is NOT diffed against captured Node
// output: the tiny formatter deliberately renders less (no column layout, no
// per-class forms for Map/Set/Date/RegExp), so byte equality with another
// runtime is the wrong bar. It is diffed against tiny.expected.txt, which
// records this formatter's own contract.
//
// The formatter is reachable only by writing to stdout — it cannot be called
// from JS and a replaced console.log would bypass it entirely — so each case
// prints and the driver diffs the whole stream.
//
// Run: bash test/console_format/run_tiny.sh out/boomkat   (SLIM build)

// --- shapes ---------------------------------------------------------------
console.log("hi");
console.log({});
console.log([]);
console.log({ a: 1, b: true });
console.log([1, 2, 3]);
console.log({ s: "x" });
console.log([1, , 3]);

// --- keys -----------------------------------------------------------------
console.log({ ok_key: 1 });
console.log({ "needs space": 1 });
console.log({ "9bad": 1 });

// --- scalars --------------------------------------------------------------
console.log(-0);
console.log([NaN, Infinity]);
console.log(undefined);
console.log(null);
console.log(Symbol("s"));
console.log({ [Symbol("k")]: 1 });
console.log(1.5, 1e21);

// --- strings: escaping only what would corrupt the line -------------------
console.log(["it's", 'say "hi"', "tab\there", "nl\nhere"]);

// --- functions ------------------------------------------------------------
console.log(function foo() {});
console.log(function () {});

// --- class tags: less detail than the full formatter, still identifying ----
console.log(new Map([[1, 2]]), new Set([1]), /ab+c/g, new Date(0), new Error("x"));

// --- depth ----------------------------------------------------------------
console.log({ a: { b: { c: { d: 1 } } } });
console.log([[1, [2, [3]]]]);

// --- format specifiers ----------------------------------------------------
// %s renders one level shallower than a plain argument.
console.log("%s", { a: { b: { c: 1 } } });
console.log("%o", { a: 1 });

// --- behaviour: the two rules that are not about looks --------------------

// 1. Rendering must not invoke a getter. `hits` staying 0 is the assertion:
//    if rendering called it, logging a value would be a side effect.
let hits = 0;
console.log({ get boom() { hits++; return "ran"; } });
console.log("getter invocations:", hits);

// 2. A cycle must terminate. Before a depth bound existed this recursed until
//    the stack went, so reaching the lines after it at all is the assertion.
const cyc = {};
cyc.self = cyc;
console.log(cyc);

// A long array must not produce an unbounded line.
const big = [];
for (let i = 0; i < 40; i++) big.push(i);
console.log(big);

console.log("done");
