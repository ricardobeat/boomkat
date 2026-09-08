// Mapped `arguments` (ES2024 §9.4.4.8 CreateMappedArgumentsObject).
//
// In a sloppy-mode function with a simple parameter list, arguments[i] and
// formal parameter i are two views of one binding: writing either is visible
// through the other, until `delete arguments[i]` severs the pair.

function check(label, actual, expected) {
  if (actual !== expected) {
    print("FAIL " + label + ": expected " + expected + ", got " + actual);
  }
}

// --- parameter -> arguments[i] --------------------------------------------
// The store to the parameter must stay observable even when no later code
// reads the parameter itself; the register holding it is read by the
// arguments object, not by any bytecode instruction.
function paramToArgs(a, b, c) {
  a = 1;
  b = 'str';
  c = 2.1;
  return [arguments[0], arguments[1], arguments[2]];
}
var r = paramToArgs(10, 'sss', 1);
check("param->args[0]", r[0], 1);
check("param->args[1]", r[1], 'str');
check("param->args[2]", r[2], 2.1);

// The alias holds for a parameter whose only reader is the arguments object.
function writeOnlyParam(a, b) {
  b = 2;
  return arguments[1];
}
check("write-only param", writeOnlyParam(10, 20), 2);

// ...and when the assignment's RHS is another parameter.
function paramFromParam(a, b) {
  b = a;
  return arguments[1];
}
check("param from param", paramFromParam(10, 20), 10);

// --- arguments[i] -> parameter --------------------------------------------
function argsToParam(x) {
  arguments[0] = 99;
  return x;
}
check("args->param", argsToParam(1), 99);

// --- delete severs the mapping --------------------------------------------
// After delete the two are independent: the parameter keeps its value and
// arguments[i] becomes undefined.
function severed(arg) {
  delete arguments[0];
  return [arg, arguments[0]];
}
var s = severed(1);
check("delete keeps param", s[0], 1);
check("delete clears args", s[1], undefined);

// A write to the parameter after the sever must NOT reappear in arguments.
function severedThenWrite(arg) {
  delete arguments[0];
  arg = 5;
  return arguments[0];
}
check("severed stays severed", severedThenWrite(1), undefined);

// --- non-configurable but still writable stays mapped ---------------------
// Only {writable:false, configurable:false} removes the index from the map
// (step 11.b.ii); tightening configurable alone leaves the alias live.
function stillMapped(a) {
  Object.defineProperty(arguments, "0", { configurable: false });
  a = 2;
  return arguments[0];
}
check("nonconfigurable stays mapped", stillMapped(1), 2);

// --- unmapped cases -------------------------------------------------------
// Strict functions get an unmapped arguments object: the two are independent.
function strictFn(a, b) {
  "use strict";
  b = 2;
  return arguments[1];
}
check("strict is unmapped", strictFn(10, 20), 20);

// A non-simple parameter list (default, rest, or destructuring) is unmapped.
function defaultParam(a, b = 0) {
  b = 2;
  return arguments[1];
}
check("default param unmapped", defaultParam(10, 20), 20);

function restParam(a, ...rest) {
  a = 2;
  return arguments[0];
}
check("rest param unmapped", restParam(10, 20), 10);

print("mapped_arguments: done");
