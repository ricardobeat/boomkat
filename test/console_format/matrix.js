// Differential matrix for util.inspect rendering: the cross product of
// container shape (array, object, Map, Set, nested) x element kind x element
// count, generated here rather than written out, so coverage does not depend on
// which combinations anyone thought to enumerate.
//
// This is the fixture that catches a LAYOUT rule inferred from too few shapes.
// The one-line/multi-line and column-grouping rules are sensitive to entry
// count, entry width and nesting height at once, and a rule that looks right
// across a handful of hand-picked cases can still be wrong; sweeping the sizes
// below against captured reference output is what makes that visible.
//
// Asserted from the shell (run.sh) against matrix.expected.txt, which is
// captured reference output. Kept portable — see run.sh for the regeneration
// command.
var elems = {
  int: function (i) { return i; },
  neg: function (i) { return -i; },
  flt: function (i) { return i + 0.5; },
  str: function (i) { return "s" + i; },
  longstr: function (i) { return "long".repeat(i + 1); },
  bool: function (i) { return i % 2 === 0; },
  nul: function () { return null; },
  undef: function () { return undefined; },
  obj: function (i) { return { k: i }; },
  arr: function (i) { return [i]; },
  nested: function (i) { return { a: { b: i } }; },
  deep: function (i) { return { a: { b: { c: i } } }; },
  sym: function (i) { return Symbol("s" + i); },
  big: function (i) { return BigInt(i); },
  fn: function () { return function nm() {}; },
  map: function (i) { return new Map([[i, i]]); },
  set: function (i) { return new Set([i]); },
  emptyobj: function () { return {}; },
  emptyarr: function () { return []; },
  negzero: function () { return -0; },
};
var sizes = [0, 1, 2, 3, 5, 6, 7, 8, 12, 20];

for (var name in elems) {
  var make = elems[name];
  for (var si = 0; si < sizes.length; si++) {
    var n = sizes[si];
    var arr = [];
    for (var i = 0; i < n; i++) arr.push(make(i));
    console.log("ARR", name, n, arr);

    var o = {};
    for (var i = 0; i < n; i++) o["k" + i] = make(i);
    console.log("OBJ", name, n, o);

    var m = new Map();
    for (var i = 0; i < n; i++) m.set("k" + i, make(i));
    console.log("MAP", name, n, m);

    var s = new Set();
    for (var i = 0; i < n; i++) s.add(make(i));
    console.log("SET", name, n, s);

    console.log("NEST", name, n, { outer: arr });
    console.log("SPEC", name, n);
  }
}
console.log("done");
