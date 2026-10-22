// `f.apply(x, arguments)` forwards the frame's arguments without building an
// arguments object; every case where that is not equivalent must behave as if
// the object had been built.
function check(got, want, label) {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(label + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want));
  }
}

function target() {
  return [this === undefined ? "u" : this === null ? "n" : typeof this, arguments.length].concat(Array.prototype.slice.call(arguments));
}
function strictTarget() {
  "use strict";
  return [this === undefined ? "u" : this === null ? "n" : typeof this, arguments.length].concat(Array.prototype.slice.call(arguments));
}
function plain() { return target.apply(this, arguments); }
function strictPlain() { "use strict"; return strictTarget.apply(this, arguments); }

// Forwarding with no, fewer, as many and more arguments than any padding.
check(plain.call({}), ["object", 0], "none");
check(plain.call({}, 1), ["object", 1, 1], "one");
check(plain.call({}, 1, 2, 3), ["object", 3, 1, 2, 3], "three");
var many = [];
for (var i = 0; i < 40; i++) many.push(i);
check(plain.apply({}, many), ["object", 40].concat(many), "forty");
for (var n = 0; n <= 20; n++) {
  check(plain.apply({}, many.slice(0, n)), ["object", n].concat(many.slice(0, n)), "n=" + n);
}

// Formals alongside the forwarded arguments.
function formals(a, b) { return target.apply(this, arguments); }
check(formals.call({}), ["object", 0], "formals none");
check(formals.call({}, 1), ["object", 1, 1], "formals fewer");
check(formals.call({}, 1, 2), ["object", 2, 1, 2], "formals equal");
check(formals.apply({}, many), ["object", 40].concat(many), "formals more");
for (var n = 0; n <= 20; n++) {
  check(formals.apply({}, many.slice(0, n)), ["object", n].concat(many.slice(0, n)), "formals n=" + n);
}

// A sloppy callee sees a boxed primitive receiver; a strict wrapper passes it as is.
check(plain.call(5, 1), ["object", 1, 1], "boxed receiver");
check(strictPlain.call(5, 1), ["number", 1, 1], "strict receiver");
check(plain.call(5, 1), ["object", 1, 1], "sloppy receiver boxed");
check(strictPlain.call(undefined, 1, 2), ["u", 2, 1, 2], "strict undefined");
check(strictPlain.call(null), ["n", 0], "strict null");
function recv() { return this; }
function strictRecv() { "use strict"; return recv.apply(this, arguments); }
check(strictRecv.call(7) === recv.call(7), false, "boxing differs by receiver");

// A different receiver expression and argument expression.
var holder = { f: target };
function viaMember(a) { return holder.f.apply(a, arguments); }
check(viaMember({}, 2), ["object", 2, {}, 2], "member callee");
function viaThis() { return this.f.apply(this.o, arguments); }
check(viaThis.call({ f: target, o: "s" }, 1), ["object", 1, 1], "this callee");

// Native targets.
function maxOf() { return Math.max.apply(null, arguments); }
check(maxOf(3, 9, 4), 9, "native");
function pushAll() { return Array.prototype.push.apply(this, arguments); }
var sink = [1];
pushAll.call(sink, 2, 3);
check(sink, [1, 2, 3], "push");
function callAll() { return target.call.apply(target, arguments); }
check(callAll({}, 1, 2), ["object", 2, 1, 2], "call.apply");

// A bound function and a class as the target.
var bound = target.bind({ b: 1 }, "x");
function viaBound() { return bound.apply(null, arguments); }
check(viaBound("y"), ["object", 2, "x", "y"], "bound");
class Klass { constructor() { this.made = true; } }
function viaClass() { return Klass.apply({}, arguments); }
var classError;
try { viaClass(1); } catch (e) { classError = e instanceof TypeError; }
check(classError, true, "class constructor");

// A non-callable receiver reaches Function.prototype.apply's own check.
function notCallable() {
  var o = { apply: Function.prototype.apply };
  return o.apply(this, arguments);
}
var notCallableError;
try { notCallable(1); } catch (e) { notCallableError = e instanceof TypeError; }
check(notCallableError, true, "apply on a non-function");

// An own `apply` property replaces the intrinsic and receives the arguments object.
var captured;
function replaced() { return 1; }
replaced.apply = function (self, args) { captured = args; return args.length; };
function viaReplaced() { return replaced.apply(this, arguments); }
check(viaReplaced(4, 5, 6), 3, "own apply");
check(Object.prototype.toString.call(captured), "[object Arguments]", "own apply object class");
check(Array.prototype.slice.call(captured), [4, 5, 6], "own apply elements");
check(viaReplaced(), 0, "own apply empty");

// Not a function at all: an ordinary object method named apply.
var plainObj = { apply: function (t, args) { return [typeof t, args.length]; } };
function viaObject() { return plainObj.apply(this, arguments); }
check(viaObject.call("s", 1, 2), ["object", 2], "object apply");

// Function.prototype.apply replaced for every function, then restored.
var realApply = Function.prototype.apply;
var seen = 0;
Function.prototype.apply = function (t, args) { seen++; return realApply.call(this, t, args); };
check(plain.call({}, 1, 2), ["object", 2, 1, 2], "patched apply");
Function.prototype.apply = realApply;
check(seen, 1, "patched apply ran once");
check(plain.call({}, 1, 2), ["object", 2, 1, 2], "restored apply");

// `arguments` read elsewhere keeps the object.
function alsoRead() { var n = arguments.length; return [n, target.apply(this, arguments)]; }
check(alsoRead.call({}, 1, 2), [2, ["object", 2, 1, 2]], "also read");
function twice() { return [target.apply(this, arguments), target.apply(this, arguments)]; }
check(twice.call({}, 1), [["object", 1, 1], ["object", 1, 1]], "two forwards");
function alsoEscapes() { target.apply(this, arguments); return arguments; }
check(alsoEscapes.call({}, 8, 9).length, 2, "escapes");
function typeofToo() { return [typeof arguments, target.apply(this, arguments).length]; }
check(typeofToo.call({}, 1), ["object", 3], "typeof");

// An arrow function inside reads the enclosing arguments.
function arrowInside() { var f = () => target.apply(null, arguments); return f(); }
check(arrowInside(1, 2), ["object", 2, 1, 2], "arrow");
function arrowOwn() { return (() => 1)() + target.apply(this, arguments).length; }
check(arrowOwn.call({}, 1), 4, "arrow beside");

// Sloppy mapped arguments: the current parameter values are forwarded.
function mapped(a, b) { a = 10; return target.apply(this, arguments); }
check(mapped.call({}, 1, 2), ["object", 2, 10, 2], "mapped write");
check(mapped.call({}, 1), ["object", 1, 10], "mapped short");
function mappedBoth(a, b) { a = 10; b = 20; return target.apply(this, arguments); }
check(mappedBoth.call({}, 1), ["object", 1, 10], "mapped unpassed parameter stays unmapped");
function mappedUpdate(a) { a++; a += 5; return target.apply(this, arguments); }
check(mappedUpdate.call({}, 1), ["object", 1, 7], "mapped update");
function mappedLoop(a, b) { for (a in { x: 1 }); return target.apply(this, arguments); }
check(mappedLoop.call({}, 1, 2), ["object", 2, "x", 2], "mapped for-in target");
function mappedPattern(a, b) { [a, b] = [b, a]; return target.apply(this, arguments); }
check(mappedPattern.call({}, 1, 2), ["object", 2, 2, 1], "mapped destructuring");
function mappedVar(a) { var a = 3; return target.apply(this, arguments); }
check(mappedVar.call({}, 1), ["object", 1, 3], "mapped var");

// With `arguments` read elsewhere the object exists, and apply still reads the live parameters.
function mappedObject(a) { a = 10; var n = arguments.length; return target.apply(this, arguments); }
check(mappedObject.call({}, 1), ["object", 1, 10], "mapped object apply");
function mappedReflect(a) { a = 10; return Reflect.apply(target, this, arguments); }
check(mappedReflect.call({}, 1), ["object", 1, 10], "mapped Reflect.apply");

// The object created for a replaced apply stays aliased to the live frame.
var kept;
function aliasTarget() {}
aliasTarget.apply = function (self, args) { kept = args; };
function aliasLive(a) { aliasTarget.apply(this, arguments); a = 5; return kept[0]; }
check(aliasLive(1), 5, "late object aliases parameters");

// Strict arguments keep the values passed, even after a parameter changes.
function strictWrite(a, b) { "use strict"; a = 10; return target.apply(this, arguments); }
check(strictWrite.call({}, 1, 2), ["object", 2, 1, 2], "strict write");
function strictClosure(a) { "use strict"; (function () { a = 9; })(); return target.apply(this, arguments); }
check(strictClosure.call({}, 1), ["object", 1, 1], "strict closure write");
function strictRead(a, b) { "use strict"; return [a + b, target.apply(this, arguments)]; }
check(strictRead.call({}, 1, 2), [3, ["object", 2, 1, 2]], "strict read");

// A nested scope that declares its own `arguments`.
function shadow() {
  var inner = (function () { let arguments = [7, 8]; return target.apply(null, arguments); })();
  return [inner, target.apply(this, arguments)];
}
check(shadow.call({}, 1), [["object", 2, 7, 8], ["object", 1, 1]], "shadowed arguments");

function blockShadow() {
  var r;
  { let arguments = [7, 8]; r = target.apply(null, arguments); }
  return [r, target.apply(this, arguments)];
}
check(blockShadow.call({}, 1), [["object", 2, 7, 8], ["object", 1, 1]], "block shadowed arguments");

// Construction through a wrapper that forwards to initialize.
var Class = {
  create: function () {
    return function () { this.initialize.apply(this, arguments); };
  }
};
var Point = Class.create();
Point.prototype.initialize = function (x, y) { this.x = x; this.y = y; this.n = arguments.length; };
var pt = new Point(3, 4);
check([pt.x, pt.y, pt.n], [3, 4, 2], "new wrapper");
check(new Point(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12).n, 12, "new wrapper many");
check(new Point().n, 0, "new wrapper none");
var Sub = Class.create();
Sub.prototype = Object.create(Point.prototype);
Sub.prototype.initialize = function () { Point.prototype.initialize.apply(this, arguments); this.sub = true; };
var sub = new Sub(5, 6);
check([sub.x, sub.y, sub.sub], [5, 6, true], "subclass wrapper");

// Callers that pass the arguments outside the interpreter's own call path.
check([1, 2].map(function () { return target.apply(null, arguments).length; }), [5, 5], "map callback");
check(Reflect.apply(plain, {}, [1, 2]), ["object", 2, 1, 2], "Reflect.apply");
check(Reflect.construct(Point, [7, 8]).x, 7, "Reflect.construct");
var accessor = { set v(x) { this.got = target.apply(null, arguments); } };
accessor.v = 4;
check(accessor.got, ["object", 1, 4], "setter");
check(plain.bind({}, 1)(2), ["object", 2, 1, 2], "bound wrapper");
check(String(plain.apply({}, [1])), "object,1,1", "apply on the wrapper");

// Recursion and results used in place.
function countdown(n) { return n === 0 ? 0 : 1 + countdown.apply(this, [n - 1]); }
check(countdown(50), 50, "recursion");
function self(n) { return n <= 0 ? 0 : 1 + self.apply(this, arguments.length ? [n - 1] : []); }
check(self(10), 10, "self apply");
function nested() { return [1, plain.apply(this, arguments)]; }
check(nested.call({}, 2), [1, ["object", 1, 2]], "nested result");

// Objects passed through survive collection.
var objs = [];
function keep() { return target.apply(this, arguments); }
for (var j = 0; j < 2000; j++) objs.push(keep.call({}, { j: j }, [j], "s" + j));
check(objs[1999].slice(2).map(function (v) { return JSON.stringify(v); }), ['{"j":1999}', "[1999]", '"s1999"'], "gc");

// A throw inside the forwarded call unwinds the wrapper.
function thrower() { throw new RangeError("boom"); }
function viaThrower() { return thrower.apply(this, arguments); }
var thrown;
try { viaThrower(1, 2, 3); } catch (e) { thrown = e.message; }
check(thrown, "boom", "throw");
check(plain.call({}, 1), ["object", 1, 1], "usable after throw");

console.log("apply_forward_arguments ok");
