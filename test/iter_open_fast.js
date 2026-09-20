// ITER_OPEN_FAST builds the array iterator directly for a plain array source.
// It must refuse whenever the observable protocol could differ, so these cover
// the patches and shapes that force the generic GetIterator sequence.

function assertEqual(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

// The fast case.
var [a, b] = [1, 2];
assertEqual(a + ":" + b, "1:2", "plain array");

var [c] = [7, 8, 9];
assertEqual(c, 7, "short pattern leaves rest unread");

var [d, e, f] = [1, 2];
assertEqual(d + ":" + e + ":" + String(f), "1:2:undefined", "long pattern binds undefined");

var [[g], [h]] = [[1], [2]];
assertEqual(g + ":" + h, "1:2", "nested patterns");

var [i, ...rest] = [1, 2, 3];
assertEqual(i + ":" + rest.join(","), "1:2,3", "rest element");

var [, j, , k] = [1, 2, 3, 4];
assertEqual(j + ":" + k, "2:4", "elisions");

// Holes must not be read as data: get_array_idx refuses, so the generic path
// runs and the hole reads as undefined.
var sparse = [1, , 3];
var [s0, s1, s2] = sparse;
assertEqual(String(s0) + ":" + String(s1) + ":" + String(s2), "1:undefined:3", "sparse array");

// A patched ArrayIteratorPrototype.next must still be called.
var proto = Object.getPrototypeOf([][Symbol.iterator]());
var origNext = proto.next;
var nextCalls = 0;
proto.next = function () { nextCalls++; return origNext.call(this); };
var [p, q] = [10, 20];
proto.next = origNext;
assertEqual(p + ":" + q, "10:20", "patched next still binds");
if (nextCalls < 2) throw new Error("patched next not called: " + nextCalls);

// A patched Array.prototype[Symbol.iterator] must be honoured.
var origIter = Array.prototype[Symbol.iterator];
var iterCalls = 0;
Array.prototype[Symbol.iterator] = function () { iterCalls++; return origIter.call(this); };
var [t, u] = [30, 40];
Array.prototype[Symbol.iterator] = origIter;
assertEqual(t + ":" + u, "30:40", "patched @@iterator still binds");
assertEqual(iterCalls, 1, "patched @@iterator called once");

// A custom @@iterator on the instance shadows the intrinsic.
var custom = [1, 2];
custom[Symbol.iterator] = function () {
    var n = 0;
    return { next: function () { n++; return { value: n * 100, done: n > 2 }; } };
};
var [v, w] = custom;
assertEqual(v + ":" + w, "100:200", "own @@iterator wins");

// Non-array iterables go through the generic path.
var [m, n] = new Set([5, 6]);
assertEqual(m + ":" + n, "5:6", "Set destructuring");

var [x1, x2] = "hi";
assertEqual(x1 + x2, "hi", "string destructuring");

function args() { var [y1, y2] = arguments; return y1 + ":" + y2; }
assertEqual(args(1, 2), "1:2", "arguments destructuring");

// A subclass whose prototype is not Array.prototype must refuse.
class MyArr extends Array {}
var sub = MyArr.from([1, 2]);
var [z1, z2] = sub;
assertEqual(z1 + ":" + z2, "1:2", "Array subclass");

// Defaults still apply to absent and undefined elements.
var [e1 = 9, e2 = 8] = [1];
assertEqual(e1 + ":" + e2, "1:8", "defaults on exhaustion");
var [u1 = 5] = [undefined];
assertEqual(u1, 5, "default on explicit undefined");

// A getter element is observable, so the read must still run it exactly once.
var getterHits = 0;
var withGetter = [];
Object.defineProperty(withGetter, 0, {
    get: function () { getterHits++; return 42; }, configurable: true, enumerable: true
});
withGetter.length = 1;
var [gv] = withGetter;
assertEqual(gv, 42, "getter element value");
assertEqual(getterHits, 1, "getter ran exactly once");

// Iterator close: a pattern that stops early must call return() once.
var closes = 0;
function closable() {
    var i = 0;
    return { [Symbol.iterator]: function () { return this; },
             next: function () { return { value: i++, done: false }; },
             return: function () { closes++; return { done: true }; } };
}
var [k1] = closable();
assertEqual(k1, 0, "early stop value");
assertEqual(closes, 1, "return called once on early stop");

// A throwing element target must close the iterator exactly once.
closes = 0;
var threw = false;
try {
    var target = {};
    Object.defineProperty(target, "p", { set: function () { throw new Error("boom"); } });
    [target.p] = closable();
} catch (err) { threw = true; }
assertEqual(threw, true, "throwing target rethrows");
assertEqual(closes, 1, "return called once on throw");

// for-of over arrays shares the same open path.
var acc = [];
for (const [q1, q2] of [[1, 2], [3, 4]]) { acc.push(q1 + "" + q2); }
assertEqual(acc.join(","), "12,34", "for-of destructuring");

// Mutating the array during destructuring reads the live contents.
var live = [1, 2, 3];
var mutator = { get 0() { live.length = 1; return 99; } };
var [l1, l2] = live;
assertEqual(l1 + ":" + String(l2), "1:2", "live array read");

print("iter_open_fast: ok");
