// A strict compare against null, undefined or a boolean that the function itself loaded, as a value
// (SEQ, SNEQ) rather than a branch, of a field that holds objects: the constant is no number, so the
// optimized compare must not take the field for one (and exit on every object it reads).
function Pair(car, cdr) { this.car = car; this.cdr = cdr; }
function walk(p) {
  var n = 0;
  while (true) {
    var rest = p.cdr;
    var end = rest === null;
    var undef = rest !== undefined;
    var flag = p.car === true;
    n += (end ? 1 : 0) + (undef ? 2 : 0) + (flag ? 4 : 0);
    if (end) return n;
    p = rest;
  }
}
var list = null;
for (var i = 0; i < 20; i++) list = new Pair(i % 3 === 0, list);
var tail = new Pair(false, null);
var total = 0;
for (var k = 0; k < 20000; k++) total += walk(k % 2 ? list : tail);
print(total);

// Equality against each constant, strict and loose, as values and as branches, over every kind of
// value: undefined, null, booleans, numbers, strings, objects (and the document.all-like none).
var values = [undefined, null, true, false, 0, 1, -0, NaN, "", "x", {}, [], function () {}];
function grid(v) {
  var s = "";
  s += (v === undefined) + "," + (v !== undefined) + "," + (v == undefined) + "," + (v != undefined) + ";";
  s += (v === null) + "," + (v !== null) + "," + (v == null) + "," + (v != null) + ";";
  s += (v === true) + "," + (v !== false) + "," + (v == true) + "," + (v != false) + ";";
  if (v === null) s += "n"; if (v !== undefined) s += "d"; if (v == null) s += "N"; if (v != undefined) s += "D";
  if (v === true) s += "t"; if (v !== false) s += "f"; if (v == false) s += "F";
  return s;
}
var out = [];
for (var r = 0; r < 3000; r++) for (var j = 0; j < values.length; j++) { var g = grid(values[j]); if (r === 0) out.push(g); }
print(out.join("|"));
