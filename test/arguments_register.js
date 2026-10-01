// `arguments` read directly in a function body (the register-resident form)
// and the cases that must keep the environment binding.
function check(got, want, label) {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(label + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want));
  }
}

function sum() { var t = 0; for (var i = 0; i < arguments.length; i++) t += arguments[i]; return t; }
check(sum(), 0, "empty");
check(sum(1, 2, 3, 4, 5, 6, 7, 8), 36, "many args");

// Mapped aliasing in both directions.
function alias(a, b) { a = 10; arguments[1] = 20; return [a, b, arguments[0], arguments[1], arguments.length]; }
check(alias(1, 2), [10, 20, 10, 20, 2], "mapped");
check(alias(1), [10, undefined, 10, 20, 1], "mapped short");

// An escaping mapped object keeps the final parameter values.
function escape(a) { a = 17; return arguments; }
check(escape(1)[0], 17, "escaped mapped");

function strictArgs(a) { "use strict"; a = 5; return [arguments[0], arguments.length]; }
check(strictArgs(1, 2), [1, 2], "strict unmapped");

// Fewer / more arguments than formals, with locals alongside.
function locals(x) { var y = 7, z; return [x, y, z, arguments.length, arguments[2]]; }
check(locals(1, 2, 3), [1, 7, undefined, 3, 3], "locals");

// Reassigning, typeof, delete, and use as a value.
function reassign() { arguments = 5; return typeof arguments; }
check(reassign(1), "number", "reassign");
function typeofArgs() { return typeof arguments; }
check(typeofArgs(), "object", "typeof");
function spreadArgs() { return Array.prototype.slice.call(arguments, 1); }
check(spreadArgs(1, 2, 3), [2, 3], "slice");
function viaApply() { return sum.apply(null, arguments); }
check(viaApply(1, 2, 3), 6, "apply");
function iter() { var r = []; for (var v of arguments) r.push(v); return r; }
check(iter(4, 5), [4, 5], "iterator");

// Constructor, method, setter/getter, callback and super-call entries.
function Ctor() { this.n = arguments.length; }
check(new Ctor(1, 2, 3).n, 3, "new");
var o = { m() { return arguments.length; }, set s(v) { this.t = arguments.length + ":" + arguments[0]; }, get g() { return arguments.length; } };
check(o.m(1, 2), 2, "method");
o.s = 9; check(o.t, "1:9", "setter");
check(o.g, 0, "getter");
check([1, 2, 3].map(function () { return arguments.length; }), [3, 3, 3], "callback");
function Base() { this.n = arguments.length; }
class Derived extends Base { constructor() { super(1, 2, 3, 4); } }
check(new Derived().n, 4, "super call");
check(Reflect.construct(Ctor, [1, 2]).n, 2, "Reflect.construct");
check(Ctor.bind(null, 1).call({}, 2), undefined, "bound call");

// Forms that keep the binding in the environment.
function arrow() { return (() => arguments.length)(); }
check(arrow(1, 2), 2, "arrow");
function inner() { var f = function () { return arguments.length; }; return f(1) + arguments.length; }
check(inner(1, 2, 3), 4, "nested function");
function withEval() { return eval("arguments.length"); }
check(withEval(1, 2), 2, "eval");
function withWith() { with ({}) { return arguments.length; } }
check(withWith(1), 1, "with");
function redeclared() { var arguments; return typeof arguments; }
check(redeclared(1), "object", "var arguments");
function paramNamed(arguments) { return arguments; }
check(paramNamed(3), 3, "param named arguments");
function shadowed() { { let arguments = 4; return arguments; } }
check(shadowed(), 4, "let arguments");
function* gen() { yield arguments.length; }
check(gen(1, 2).next().value, 2, "generator");
function member() { var x = { arguments: 3 }; return x.arguments + arguments.length; }
check(member(1), 4, "member named arguments");

// Recursion and tail position.
function fact(n) { return n <= 1 ? 1 : n * fact.apply(null, [n - 1]); }
check(fact(5), 120, "recursion");
function tail(n) { if (n === 0) return arguments.length; return tail(n - 1, n); }
check(tail(100), 2, "tail");
print("ok");
