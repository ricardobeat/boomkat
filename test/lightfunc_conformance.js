// Built-in functions must be indistinguishable from ordinary function objects.
//
// The engine stores most builtins as "lightfuncs": a TVal carrying only a
// builtin index, with no HObject behind it. That is invisible to a plain call,
// but every operation that treats a function AS AN OBJECT can see it, and each
// such operation needs the lightfunc to behave like the real object it stands
// for. The three subjects below are the same thing to a JS program, so every
// row must agree across all three; a row that differs is a lightfunc leaking
// its representation. Reference values verified against JavaScriptCore and V8.
var pass = 0;
var fail = 0;

// Each probe runs in its own try: several of these operations currently throw
// on a lightfunc, and one throw must not hide the rest of the report.
function check(label, thunk, expected) {
  var actual;
  try {
    actual = thunk();
  } catch (e) {
    fail = fail + 1;
    print("FAIL " + label + ": threw " + e.name + ": " + e.message);
    return;
  }
  if (actual === expected) {
    pass = pass + 1;
  } else {
    fail = fail + 1;
    print("FAIL " + label + ": got " + String(actual) + ", want " + String(expected));
  }
}

function suite(tag, f) {
  check(tag + " typeof", function () { return typeof f; }, "function");
  // ToObject on something that is already an object returns it unchanged
  // (ES2015 §7.1.13); boxing a function into a wrapper is observable both by
  // identity and by typeof.
  check(tag + " ToObject identity", function () { return Object(f) === f; }, true);
  check(tag + " ToObject typeof", function () { return typeof Object(f); }, "function");
  check(tag + " instanceof Function", function () { return f instanceof Function; }, true);
  check(tag + " instanceof Object", function () { return f instanceof Object; }, true);
  check(tag + " getPrototypeOf", function () { return Object.getPrototypeOf(f) === Function.prototype; }, true);
  check(tag + " Reflect.getPrototypeOf", function () { return Reflect.getPrototypeOf(f) === Function.prototype; }, true);
  check(tag + " isExtensible", function () { return Object.isExtensible(f); }, true);
  check(tag + " Reflect.isExtensible", function () { return Reflect.isExtensible(f); }, true);
  // A fresh, extensible function is neither frozen nor sealed: it still has
  // configurable own properties (name, length).
  check(tag + " isFrozen", function () { return Object.isFrozen(f); }, false);
  check(tag + " isSealed", function () { return Object.isSealed(f); }, false);
  check(tag + " in operator", function () { return "name" in f; }, true);
  check(tag + " Reflect.ownKeys has name", function () { return Reflect.ownKeys(f).indexOf("name") >= 0; }, true);
  check(tag + " toString tag", function () { return Object.prototype.toString.call(f); }, "[object Function]");
  check(tag + " call is callable", function () { return typeof f.call; }, "function");
  check(tag + " bind is callable", function () { return typeof f.bind(null); }, "function");
  // Object identity has to be stable enough to key a collection.
  check(tag + " Map key", function () {
    var m = new Map();
    m.set(f, "v");
    return m.get(f);
  }, "v");
  check(tag + " WeakSet member", function () {
    var w = new WeakSet();
    w.add(f);
    return w.has(f);
  }, true);
}

// A lightfunc builtin, a builtin that is a real HObject, and a user function.
suite("lightfunc", JSON.parse);
suite("hobject", Array.prototype.map);
suite("user", function () {});

// Property writes on a builtin must work like any other function object. Done
// on a scratch builtin so the rest of the suite is unaffected by the mutation.
var target = Math.max;
check("defineProperty", function () {
  Object.defineProperty(target, "definedProp", { value: 1, configurable: true, writable: true });
  return target.definedProp;
}, 1);
check("assignment", function () {
  target.assignedProp = 5;
  return target.assignedProp;
}, 5);
check("delete", function () {
  delete target.assignedProp;
  return target.assignedProp;
}, undefined);

print("pass:", pass, "fail:", fail);
