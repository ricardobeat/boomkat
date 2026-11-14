// A deferred body compiles from its own source, where an enclosing function's
// declarations are out of sight. A free name is a global only when no function
// around the body binds it and nothing around it can bind it later.
var failures = 0;
function check(label, got, want) {
  got = String(got);
  if (got !== want) { failures++; print("FAIL: " + label + " — expected " + want + ", got " + got); }
}

var g = "global";
let lex = "lexical";
function top() { return g + "/" + lex; }
check("script function reads globals", top(), "global/lexical");
g = "changed";
check("and sees a later write", top(), "changed/lexical");

function shadow() {
  var g = "local";
  function inner() { return g; }
  return inner();
}
check("a parent var shadows the global", shadow(), "local");

function deep() {
  var g = "outer";
  function mid() {
    function leaf() { return g + "/" + lex; }
    return leaf();
  }
  return mid();
}
check("a grandparent var shadows through a deferred parent", deep(), "outer/lexical");

function param(g) {
  function inner() { return g; }
  return inner();
}
check("a parameter shadows the global", param("arg"), "arg");

function blockScoped() {
  { let g = "block"; var f = function () { return g; }; }
  return f();
}
check("a block binding shadows the global", blockScoped(), "block");

function viaEval() {
  eval("var g = 'from eval'");
  function inner() { return g; }
  return inner();
}
check("a direct eval may bind the name", viaEval(), "from eval");

function evalAbove() {
  function mid() {
    function leaf() { return g; }
    return leaf();
  }
  eval("var g = 'above'");
  return mid();
}
check("a direct eval two levels up", evalAbove(), "above");

function viaWith() {
  var f;
  with ({ g: "from with" }) { f = function () { return g; }; }
  return f();
}
check("a with object may bind the name", viaWith(), "from with");

function writes() {
  function set() { counter = (typeof counter === "undefined" ? 0 : counter) + 1; }
  set(); set();
  return counter;
}
check("an undeclared write creates a global", writes(), "2");
check("visible to the script", counter, "2");

function missing() {
  function read() { return neverDeclared; }
  try { read(); return "no throw"; } catch (e) { return e.name; }
}
check("an unresolvable name throws", missing(), "ReferenceError");

function lateGlobal() {
  function read() { return declaredLater; }
  return read();
}
var declaredLater = "late";
check("a global declared after the function", lateGlobal(), "late");

function tdzGlobal() {
  function read() { return stillDead; }
  try { return read(); } catch (e) { return e.name; }
}
check("a global lexical binding in its dead zone", tdzGlobal(), "ReferenceError");
let stillDead = 1;
check("and after it initializes", tdzGlobal(), "1");

function selfName() {
  function fact(n) { return n < 2 ? 1 : n * fact(n - 1); }
  return fact(5);
}
check("a nested declaration calls itself", selfName(), "120");

check("typeof an undeclared name in a nested body",
  (function () { function t() { return typeof nope; } return t(); })(), "undefined");

if (failures === 0) print("deferred free names: OK");
