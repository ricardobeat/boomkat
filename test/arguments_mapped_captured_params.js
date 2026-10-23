// Mapped `arguments` (ES2024 §10.4.4) over formal parameters that a nested
// callable captures. A captured formal lives in the function's environment,
// so arguments[i] must read, write, unmap and freeze through that binding.

var failures = 0;
function check(label, actual, expected) {
  if (actual !== expected) {
    failures++;
    print("FAIL " + label + ": expected " + expected + ", got " + actual);
  }
}

function f1(a) { (function () { a = 9; })(); return arguments[0]; }
check("closure write -> arguments[0]", f1(1), 9);

function f2(a) { var h = function () { return a; }; arguments[0] = 5; return h(); }
check("arguments[0] write -> closure read", f2(1), 5);

function f3(a) { var h = function () { a = 7; }; h(); return [a, arguments[0]]; }
var r3 = f3(1);
check("f3 param", r3[0], 7);
check("f3 arguments[0]", r3[1], 7);

// A captured and an uncaptured formal in one function.
function f4(a, b) {
  var h = function () { return a; };
  a = 10;
  b = 20;
  arguments[1] = 21;
  arguments[0] = 11;
  return [h(), b, arguments[0], arguments[1]];
}
var r4 = f4(1, 2);
check("mixed captured read", r4[0], 11);
check("mixed uncaptured param", r4[1], 21);
check("mixed arguments[0]", r4[2], 11);
check("mixed arguments[1]", r4[3], 21);

// The arguments object outlives the frame: the values at return are kept.
function f5(a) { var h = function () { return a; }; a = 3; return arguments; }
check("escaped arguments after param write", f5(1)[0], 3);

function f6(a) { var h = function () { a = 4; }; h(); return arguments; }
check("escaped arguments after closure write", f6(1)[0], 4);

// Strict mode: no aliasing.
function f7(a) {
  "use strict";
  var h = function () { a = 9; };
  h();
  arguments[0] = 5;
  return [a, arguments[0]];
}
var r7 = f7(1);
check("strict param", r7[0], 9);
check("strict arguments[0]", r7[1], 5);

// More actuals than formals: the extra index is never mapped.
function f8(a) { var h = function () { a = 2; }; h(); arguments[1] = 8; return [arguments[0], arguments[1], arguments.length]; }
var r8 = f8(1, 5);
check("extra actual mapped index", r8[0], 2);
check("extra actual unmapped index", r8[1], 8);
check("extra actual length", r8[2], 2);

// Fewer actuals than formals: the missing index is not mapped.
function f9(a, b) {
  var h = function () { b = 6; };
  h();
  a = 1;
  return [arguments[0], arguments[1], arguments.length];
}
var r9 = f9(0);
check("fewer actuals mapped index", r9[0], 1);
check("fewer actuals unmapped index", r9[1], undefined);
check("fewer actuals length", r9[2], 1);

// delete arguments[0] ends the alias in both directions.
function f10(a) {
  var h = function () { return a; };
  delete arguments[0];
  a = 12;
  var seen = arguments[0];
  arguments[0] = 13;
  return [seen, h(), arguments[0]];
}
var r10 = f10(1);
check("deleted index after param write", r10[0], undefined);
check("deleted index closure read", r10[1], 12);
check("deleted index re-added", r10[2], 13);

// Object.freeze unmaps and keeps the current parameter values.
function f11(a) {
  var h = function () { a = 14; };
  h();
  Object.freeze(arguments);
  a = 15;
  return [arguments[0], a];
}
var r11 = f11(1);
check("frozen arguments value", r11[0], 14);
check("frozen arguments param", r11[1], 15);

// Defining a non-writable property unmaps without changing the value.
function f12(a) {
  var h = function () { a = 16; };
  h();
  Object.defineProperty(arguments, "0", { writable: false });
  a = 17;
  return [arguments[0], a];
}
var r12 = f12(1);
check("defineProperty keeps value", r12[0], 16);
check("defineProperty param independent", r12[1], 17);

// Generators and async functions keep the alias while they can resume.
function* g1(a) {
  var h = function () { a = 18; };
  h();
  yield arguments[0];
  arguments[0] = 19;
  yield a;
}
var it = g1(1);
check("generator closure write", it.next().value, 18);
check("generator arguments write", it.next().value, 19);

// Direct eval captures every formal.
function f13(a, b) {
  eval("a = 20; b = 21");
  return [arguments[0], arguments[1]];
}
var r13 = f13(1, 2);
check("eval write a", r13[0], 20);
check("eval write b", r13[1], 21);

function f14(a) {
  arguments[0] = 22;
  return eval("a");
}
check("eval read after arguments write", f14(1), 22);

// Forwarding arguments with a captured parameter.
function target() { return Array.prototype.slice.call(arguments).join(","); }
function f15(a, b) {
  var h = function () { a = "x"; };
  h();
  return target.apply(this, arguments);
}
check("apply forwarding", f15(1, 2), "x,2");

if (failures !== 0) throw new Error(failures + " check(s) failed");
print("ok");
