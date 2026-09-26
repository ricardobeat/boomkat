// A sloppy function called with an undefined receiver sees the global object
// as `this` through every form that can read it. The call path skips the
// coercion only for a body that has none of them.
var passed = 0;
var global = this;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

function plain() { return this; }
check("this", plain(), global);

function viaArrow() { return (() => this)(); }
check("an arrow captures this", viaArrow(), global);

function viaNestedArrow() { return (() => () => this)()(); }
check("a nested arrow captures this", viaNestedArrow(), global);

function viaEval() { return eval("this"); }
check("direct eval reads this", viaEval(), global);

function viaArrowEval() { return (() => eval("this"))(); }
check("direct eval in an arrow reads this", viaArrowEval(), global);

// The accessors are strict so they report the receiver they were given
// rather than coercing an undefined one to the global object themselves.
var proto = { get who() { "use strict"; return this; } };
var obj = { __proto__: proto, m() { return super.who; } };
var detached = obj.m;
check("super property access passes this as the receiver", detached(), global);

var receiver;
var setProto = { set v(x) { "use strict"; receiver = this; } };
var setObj = { __proto__: setProto, m() { super.v = 7; } };
var detachedSet = setObj.m;
detachedSet();
check("super property assignment passes this as the receiver", receiver, global);

function viaDefault(a = this) { return a; }
check("a parameter default reads this", viaDefault(), global);

function ignores(n) { return n <= 1 ? n : ignores(n - 1) + ignores(n - 2); }
check("a body that ignores this still runs", ignores(10), 55);

function strictInside() { "use strict"; return this; }
check("strict code keeps an undefined this", strictInside(), undefined);

function boxes() { return typeof this; }
check("a primitive receiver is boxed", boxes.call(5), "object");

print("sloppy_this_observers: " + passed + " passed");
