// invoke_getter allocates a per-call function scope only when the getter's
// needs_env is set, matching the CALL fast path. The scope is what keeps a
// getter's own bindings off the shared captured var_env, so eliding it for a
// getter that does reach its scope corrupts the enclosing function's.

function assertEqual(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

// The elided case: a getter whose body is pure register arithmetic never
// touches its scope, so it must still read correctly with no env allocated.
class Point {
    constructor(x, y) { this.x = x; this.y = y; }
    get magnitude() { return this.x * this.x + this.y * this.y; }
}
assertEqual(new Point(3, 4).magnitude, 25, "register-only getter");

// The guard's reason for existing. A getter that uses `arguments` has
// needs_env set, so invoke_getter declares that (always empty) arguments
// object into a scope of its own. Without the fresh scope the declaration
// lands on the *enclosing* function's var_env and overwrites its arguments,
// which shows up as a length of 0 here instead of 3.
function argumentsIsolation() {
    var holder = { get probe() { return arguments.length; } };
    var before = arguments.length;
    holder.probe;
    return before + ":" + arguments.length;
}
assertEqual(argumentsIsolation(1, 2, 3), "3:3", "getter arguments stays off caller scope");

// The getter's own arguments object is empty, whatever the caller received.
function argumentsEmpty() {
    var holder = { get probe() { return arguments.length; } };
    return holder.probe;
}
assertEqual(argumentsEmpty(1, 2, 3), 0, "getter receives no arguments");

// Repeated reads must not accumulate state on a shared scope.
function argumentsRepeat() {
    var holder = { get probe() { return arguments.length; } };
    holder.probe; holder.probe; holder.probe;
    return arguments.length;
}
assertEqual(argumentsRepeat(1, 2), 2, "repeated getter reads leave caller intact");

// A getter closing over its locals keeps one binding set per call.
var escaped = [];
var closureHolder = {
    get value() {
        let captured = escaped.length;
        escaped.push(function () { return captured; });
        return captured;
    }
};
closureHolder.value;
closureHolder.value;
closureHolder.value;
assertEqual(escaped.length, 3, "one closure per getter call");
assertEqual(escaped[0](), 0, "first closure keeps its own binding");
assertEqual(escaped[1](), 1, "second closure keeps its own binding");
assertEqual(escaped[2](), 2, "third closure keeps its own binding");

// Direct eval reads and writes the getter's own scope.
var evalHolder = {
    get computed() {
        var local = 7;
        eval("local = local * 3");
        return local;
    }
};
assertEqual(evalHolder.computed, 21, "direct eval writes getter scope");

// A getter's var write must not reach a `with` object standing in as parent.
var shared = { hit: "parent" };
with (shared) {
    var withHolder = { get p() { var hit = "own"; return hit; } };
    assertEqual(withHolder.p, "own", "getter var read");
}
assertEqual(shared.hit, "parent", "getter var does not write through with");

// A getter on the prototype chain binds `this` to the receiver.
class Base {
    get label() { return "base:" + this.tag; }
}
class Derived extends Base {
    constructor() { super(); this.tag = "derived"; }
}
assertEqual(new Derived().label, "base:derived", "inherited getter receiver");

// super.prop inside a getter resolves against the home object.
class Outer {
    get doubled() { return 21; }
}
class Inner extends Outer {
    get doubled() { return super.doubled * 2; }
}
assertEqual(new Inner().doubled, 42, "super inside getter");

// A sloppy getter boxes a primitive receiver; a strict one does not.
Object.defineProperty(Number.prototype, "boxedKind", {
    get: function () { return typeof this; },
    configurable: true
});
assertEqual((5).boxedKind, "object", "sloppy getter boxes primitive this");
Object.defineProperty(Number.prototype, "strictKind", {
    get: function () { "use strict"; return typeof this; },
    configurable: true
});
assertEqual((5).strictKind, "number", "strict getter keeps primitive this");

// Recursion through a getter must not share one scope across depths.
var depthHolder = {
    get countdown() {
        let n = this.n;
        if (n <= 0) return 0;
        return n + { n: n - 1, __proto__: depthHolder }.countdown;
    }
};
assertEqual({ n: 4, __proto__: depthHolder }.countdown, 10, "recursive getter scopes");

// A throwing getter unwinds without leaking its frame.
var thrower = { get boom() { let marker = "lost"; throw new Error(marker); } };
var caught = "";
try { thrower.boom; } catch (e) { caught = e.message; }
assertEqual(caught, "lost", "throwing getter");

print("getter_scope_elision: ok");
