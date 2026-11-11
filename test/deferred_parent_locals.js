// A deferred child reaches its parent's bindings by name. The parent keeps those
// in its environment and is free to hold every other local in a register.
var failures = 0;
function check(label, got, want) {
  got = String(got);
  if (got !== want) { failures++; print("FAIL: " + label + " — expected " + want + ", got " + got); }
}

function counter() {
  var a = 1, b = 2, untouched = 40;
  function inc() { a++; return a; }
  b += inc();
  a += 10;
  untouched += 2;
  return [a, b, inc(), untouched];
}
check("write through a deferred child", counter(), "12,4,13,42");

function writer() {
  var seen = 0, local = 5;
  function set(v) { seen = v; }
  set(local + 1);
  local = seen * 2;
  return [seen, local];
}
check("child writes, parent reads", writer(), "6,12");

function loops() {
  var fns = [];
  for (let i = 0; i < 3; i++) {
    let j = i * 10;
    fns.push(function () { return i + j; });
  }
  var out = [];
  for (var k = 0; k < fns.length; k++) out.push(fns[k]());
  return out;
}
check("per-iteration bindings", loops(), "0,11,22");

function grandchild() {
  var x = 1, y = 100;
  function mid() {
    var z = 10;
    function leaf() { x += z; return x; }
    return leaf() + leaf();
  }
  y += mid();
  return [x, y];
}
check("grandchild reaches two levels up", grandchild(), "21,132");

function caught() {
  var get;
  try { throw 7; } catch (e) { get = function () { return e; }; e = e + 1; }
  return get();
}
check("catch parameter", caught(), "8");

function params(p, q) {
  function swap() { var t = p; p = q; q = t; }
  swap();
  return [p, q, arguments[0], arguments[1]];
}
check("captured parameters alias arguments", params(1, 2), "2,1,2,1");

function later() {
  function read() { return v; }
  var before = read();
  var v = 3;
  return [before, read()];
}
check("var declared after the child", later(), ",3");

function tdz() {
  function read() { return w; }
  try { read(); return "no throw"; } catch (err) { var name = err.name; }
  let w = 1;
  return name + read();
}
check("lexical binding in its dead zone", tdz(), "ReferenceError1");

if (failures === 0) print("deferred parent locals: OK");
