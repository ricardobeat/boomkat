// Each case tests with a branch over its own body; bodies fall through in
// source order and a default clause may sit anywhere.
function run(x) {
  var out = "";
  switch (x) {
    case 1: out += "a";
    case 2: out += "b"; break;
    default: out += "d";
    case 3: out += "c";
    case 4: { out += "e"; break; }
    case 5: out += "f";
  }
  return out;
}
var want = {1: "ab", 2: "b", 3: "ce", 4: "e", 5: "f", 6: "dce", 0: "dce"};
for (var k in want) if (run(+k) !== want[k]) throw new Error("run(" + k + ") = " + run(+k));
if (run("1") !== "dce") throw new Error("strict equality");

function onlyDefault(x) { var r = 0; switch (x) { default: r = 1; } return r; }
if (onlyDefault(5) !== 1) throw new Error("only default");

function lastFalls(x) { var r = ""; switch (x) { case 1: r += "x"; break; case 2: r += "y"; } return r + "z"; }
if (lastFalls(2) !== "yz" || lastFalls(1) !== "xz" || lastFalls(3) !== "z") throw new Error("last clause");

function loops() {
  var n = 0;
  for (var i = 0; i < 6; i++) {
    switch (i & 3) { case 0: continue; case 1: n += 1; break; case 2: n += 10; default: n += 100; }
    n += 1000;
  }
  return n;
}
var expect = 0;
for (var j = 0; j < 6; j++) { var m = j & 3; if (m === 0) continue; if (m === 1) expect += 1; else if (m === 2) expect += 110; else expect += 100; expect += 1000; }
if (loops() !== expect) throw new Error("loops " + loops() + " vs " + expect);

// A string discriminant and a case expression with a side effect run in order.
var seen = [];
function t(v) { seen.push(v); return v; }
switch ("b") { case t("a"): break; case t("b"): break; case t("c"): break; }
if (seen.join() !== "a,b") throw new Error("case order " + seen);
