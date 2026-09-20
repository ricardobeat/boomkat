// The eval-dependent half of forof_periter_env.js, kept in its own file.
//
// A direct `eval` anywhere in a scope degrades pre_scan_captures to
// capture_all, which forces every for-of in that scope onto the per-iteration
// environment path. Sharing a file with the scoping cases would therefore mask
// exactly the regression those cases exist to catch.

function assertEqual(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

// Direct eval reaches the head binding and must see this iteration's value.
var evals = [];
for (const e of [7, 8]) { evals.push(eval("e")); }
assertEqual(evals.join(","), "7,8", "direct eval reads head binding");

// A closure built inside eval still captures that iteration's binding.
var fns = [];
for (const n of [1, 2, 3]) { fns.push(eval("(function () { return n; })")); }
assertEqual(fns.map(function (f) { return f(); }).join(","), "1,2,3", "eval closure per iteration");

// const head stays const.
var threw = false;
try { eval("for (const c of [1]) { c = 2; }"); } catch (err) { threw = err instanceof TypeError; }
assertEqual(threw, true, "const head rejects assignment");

print("forof_periter_env_eval: ok");
