// A lexical for-of head gets a fresh binding per iteration, but the freshness
// is only observable when something outlives the iteration. The compiler skips
// the per-iteration environment when no head name is captured; these are the
// cases that must still see distinct bindings when it does not skip.

function assertEqual(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

// The case the whole gate turns on: a closure per iteration must capture that
// iteration's binding, not the last one. Without a per-iteration env this
// reports "3,3,3".
var fns = [];
for (const x of [1, 2, 3]) { fns.push(function () { return x; }); }
assertEqual(fns.map(function (f) { return f(); }).join(","), "1,2,3", "const closure capture");

var lets = [];
for (let y of [4, 5, 6]) { lets.push(() => y); }
assertEqual(lets.map(function (f) { return f(); }).join(","), "4,5,6", "let arrow capture");

// Capture from a nested block still pins the head binding.
var nested = [];
for (const n of [1, 2]) { { const inner = n * 10; nested.push(() => inner + n); } }
assertEqual(nested.map(function (f) { return f(); }).join(","), "11,22", "nested block capture");

// Destructuring heads: any captured leaf must keep every leaf fresh.
var pairs = [];
for (const [a, b] of [[1, 2], [3, 4]]) { pairs.push(() => a + ":" + b); }
assertEqual(pairs.map(function (f) { return f(); }).join(","), "1:2,3:4", "array pattern capture");

var objs = [];
for (const { k, v } of [{ k: "a", v: 1 }, { k: "b", v: 2 }]) { objs.push(() => k + v); }
assertEqual(objs.map(function (f) { return f(); }).join(","), "a1,b2", "object pattern capture");

// A captured leaf beside an uncaptured one: both share the iteration.
var mixed = [];
for (const [p, q] of [[1, 2], [3, 4]]) { mixed.push(() => q); }
assertEqual(mixed.map(function (f) { return f(); }).join(","), "2,4", "partially captured pattern");

// The uncaptured path: plain reads and writes across iterations.
var sum = 0;
for (const s of [1, 2, 3, 4]) { sum += s; }
assertEqual(sum, 10, "uncaptured const accumulate");

var wsum = 0;
for (let w of [1, 2, 3]) { w = w * 2; wsum += w; }
assertEqual(wsum, 12, "let head is writable");

// break and continue must not leave a stray env behind.
var parts = [];
for (const t of [1, 2, 3, 4, 5]) {
    if (t === 2) continue;
    if (t === 4) break;
    parts.push(function () { return t; });
}
assertEqual(parts.map(function (f) { return f(); }).join(","), "1,3", "capture across continue/break");

// A throw out of the body unwinds cleanly and the iterator closes.
var closed = false;
var iterable = {
    [Symbol.iterator]() {
        var i = 0;
        return { next() { return { value: i++, done: i > 5 }; },
                 return() { closed = true; return { done: true }; } };
    }
};
try { for (const z of iterable) { if (z === 2) throw new Error("stop"); } } catch (err) {}
assertEqual(closed, true, "iterator closed on throw");

// Nested for-of loops each keep their own binding.
var grid = [];
for (const i of [1, 2]) { for (const j of [3, 4]) { grid.push(() => i * j); } }
assertEqual(grid.map(function (f) { return f(); }).join(","), "3,4,6,8", "nested loop captures");

// A bare (undeclared) target is not lexical and keeps last-value semantics.
var bare;
var bares = [];
for (bare of [1, 2, 3]) { bares.push(function () { return bare; }); }
assertEqual(bares.map(function (f) { return f(); }).join(","), "3,3,3", "bare target shares one binding");

// `var` heads also share one binding, per spec.
var vars = [];
for (var vv of [1, 2, 3]) { vars.push(function () { return vv; }); }
assertEqual(vars.map(function (f) { return f(); }).join(","), "3,3,3", "var head shares one binding");

// Block scoping, the other job the environment does. These are what the
// uncaptured (hoisted-env) path must not regress: a lexical head binding is
// scoped to the loop and must not survive it, whether or not anything captured
// it. test262 language/statements/for-of/head-let-destructuring.js covers the
// destructuring form; the plain identifier form had no coverage here before.
for (let [dx] of [[34]]) {}
assertEqual(typeof dx, "undefined", "destructuring head does not leak");

for (let ix of [1]) {}
assertEqual(typeof ix, "undefined", "identifier head does not leak");

for (const cx of [1]) {}
assertEqual(typeof cx, "undefined", "const head does not leak");

for (const { ox } of [{ ox: 1 }]) {}
assertEqual(typeof ox, "undefined", "object pattern head does not leak");

// A head binding must not be visible to a later loop's head either.
var seen = [];
for (let sx of [1, 2]) { seen.push(typeof sx); }
assertEqual(seen.join(","), "number,number", "head binding readable inside body");

// Breaking out still leaves no binding behind.
for (let bx of [1, 2, 3]) { break; }
assertEqual(typeof bx, "undefined", "head does not leak after break");

// Nor does throwing through the loop.
try { for (let tx of [1, 2]) { throw new Error("x"); } } catch (err) {}
assertEqual(typeof tx, "undefined", "head does not leak after throw");

// A same-named outer binding is shadowed by the head, then restored.
var shadow = "outer";
for (let shadow of [1]) { assertEqual(shadow, 1, "head shadows outer"); }
assertEqual(shadow, "outer", "outer binding restored after loop");

print("forof_periter_env: ok");
