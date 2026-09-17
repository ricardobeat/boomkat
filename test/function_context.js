// Function-context capture semantics: arrow lexical this/new.target/arguments,
// super in methods and eval, named-funcexpr shadowing, param-scope separation,
// optional-chain call receivers, array index integrality.
// All cases here are expected to PASS on current main. Cases blocked on the
// plan 059 HomeObject unification (object-literal eval-super, eval super(),
// nested-eval new.target, escaped-arrow super() detection) are NOT included —
// add them as plan 059 phases land.
var fails = 0;
function t(name, fn) {
  var r;
  try { r = fn(); } catch (e) { r = "threw " + e; }
  if (r !== true) { fails++; print("FAIL " + name + " -> " + r); }
}

// --- arrow lexical this / new.target / arguments ---
t("arrow-in-method captures receiver", function () {
  var o = { v: 42, m: function () { return () => this.v; } };
  return { v: 1, f: o.m() }.f() === 42;
});
t("arrow .call() ignores thisArg", function () {
  var o = { v: 7, m: function () { return () => this.v; } };
  return o.m().call({ v: 99 }) === 7;
});
t("arrow via bind ignores bound this", function () {
  var o = { v: 8, m: function () { return (() => this.v).bind({ v: 0 })(); } };
  return o.m() === 8;
});
t("arrow as builtin callback", function () {
  var o = { v: 3, m: function () { return [1].map(() => this.v)[0]; } };
  return o.m() === 3;
});
t("arrow sees enclosing arguments", function () {
  function g() { var a = () => arguments[0]; return a(99); }
  return g(11) === 11;
});
t("arrow new.target survives enclosing return", function () {
  function F() { this.a = () => new.target; }
  return new F().a() === F;
});
t("arrow in generator captures generator this", function () {
  var o = { v: 77, g: function* () { yield (() => this.v)(); } };
  return o.g().next().value === 77;
});

// --- super in methods / class eval ---
t("arrow super in class method", function () {
  class A { get x() { return 10; } }
  class B extends A { m() { return (() => super.x)(); } }
  return new B().m() === 10;
});
t("arrow super in static method", function () {
  class A { static s() { return "as"; } }
  class B extends A { static m() { return (() => super.s())(); } }
  return B.m() === "as";
});
t("object-literal shorthand arrow super", function () {
  var proto = { x: 50 };
  var obj = { m() { return (() => super.x)(); } };
  Object.setPrototypeOf(obj, proto);
  return obj.m() === 50;
});
t("arrow this pre-super() throws ReferenceError", function () {
  var got = null;
  class A { }
  class B extends A { constructor() { var a = () => this; try { a(); got = "no-throw"; } catch (e) { got = e; } super(); } }
  new B();
  return got instanceof ReferenceError;
});
t("arrow this post-super() sees instance", function () {
  class A { }
  class B extends A { constructor() { var a = () => this; super(); this.me = a(); } }
  var b = new B();
  return b.me === b;
});
t("eval sees this in method", function () {
  var o = { v: 6, m: function () { return eval("this.v"); } };
  return o.m() === 6;
});
t("eval super.prop in class method", function () {
  class A { get x() { return 20; } }
  class B extends A { m() { return eval("super.x"); } }
  return new B().m() === 20;
});
t("eval arrow capturing super in class method", function () {
  class A { get x() { return 30; } }
  class B extends A { m() { return eval("(() => super.x)")(); } }
  return new B().m() === 30;
});
t("eval new.target in ctor", function () {
  function F() { this.nt = eval("new.target"); }
  return new F().nt === F;
});
t("delete super.x throws ReferenceError", function () {
  var obj = { m() { try { delete super.x; return "no-throw"; } catch (e) { return e instanceof ReferenceError; } } };
  Object.setPrototypeOf(obj, { x: 1 });
  return obj.m() === true;
});
t("indirect eval new.target is SyntaxError", function () {
  try { (0, eval)("new.target"); return "no-throw"; } catch (e) { return e instanceof SyntaxError; }
});
t("indirect eval arrow new.target is SyntaxError", function () {
  try { (0, eval)("() => new.target"); return "no-throw"; } catch (e) { return e instanceof SyntaxError; }
});
t("direct eval arrow new.target allowed in function", function () {
  function g() { return eval("(() => new.target)")(); }
  return g() === undefined;
});

// --- param scope vs body var scope (arrow reparse path) ---
// NOTE: outer vars here are globals on purpose — writes to an ENCLOSING
// FUNCTION's locals from param-default expressions are a separate, known
// capture-analysis gap (backlog X3), affecting ordinary functions too.
var fc_x = "outside", fc_pp = null, fc_pb = null;
t("default-param closure sees outer var, not body var", function () {
  ((_ = fc_pp = function () { return fc_x; }) => { var fc_x = "inside"; fc_pb = function () { return fc_x; }; })();
  return fc_pp() === "outside" && fc_pb() === "inside";
});

// --- named funcexpr shadowing ---
t("body var shadows funcexpr name", function () {
  var f = function n() { var n; var g = function () { return n; }; return g(); };
  return f() === undefined;
});
t("funcexpr name visible when unshadowed", function () {
  var f = function n() { var g = function () { return n; }; return g(); };
  return f() === f;
});
t("recursion via funcexpr name", function () {
  var f = function fact(x) { return x < 2 ? 1 : x * fact(x - 1); };
  return f(5) === 120;
});

// --- optional chain call receivers ---
// A non-short-circuited optional chain is a Reference like plain member
// access; parens preserve it (test262 optional-call-preserves-this.js).
t("(o?.m)() keeps receiver", function () {
  var o = { m: function () { return this; } };
  return (o?.m)() === o;
});
t("(o.m)() keeps receiver", function () {
  var o = { m: function () { return this; } };
  return (o.m)() === o;
});
t("o?.m() keeps receiver", function () {
  var o = { m: function () { return this; } };
  return o?.m() === o;
});
t("(o.a?.m)() keeps receiver", function () {
  var o = { a: { m: function () { return this; } } };
  return (o.a?.m)() === o.a;
});
t("(0, o.m)() drops receiver (comma does GetValue)", function () {
  var o = { m: function () { return this; } };
  // Sloppy: the unbound call substitutes globalThis (ES2024 §10.4.1.2).
  // A strict callee keeps undefined.
  var strictM = function () { "use strict"; return this; };
  return (0, o.m)() === globalThis && (0, strictM)() === undefined;
});

// --- array index integrality ---
t("arr[1.1] does not corrupt arr[1]", function () {
  var arr = [39, 42];
  arr[1.1] = "other";
  return arr[1] === 42 && arr["1.1"] === "other" && arr[1.1] === "other";
});
t("integral double is a valid index", function () {
  var a = [1, 2, 3];
  return a[1.0] === 2;
});

if (fails === 0) { print("function_context: all pass"); } else { print("function_context: " + fails + " FAILED"); }
