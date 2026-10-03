// for-of opens a plain array without the @@iterator call, and falls back to the
// full protocol the moment anything the fast open relies on is changed.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}
function collect(it) { var out = []; for (var v of it) out.push(v); return out.join(); }

check("array", collect([1, 2, 3]), "1,2,3");
check("empty", collect([]), "");
check("holes", collect([1, , 3]), "1,,3");
check("set", collect(new Set([1, 2])), "1,2");
check("map", collect(new Map([[1, 2]]).keys()), "1");
check("string", collect("ab"), "a,b");
check("generator", collect((function* () { yield 1; yield 2; })()), "1,2");
check("typed array", collect(new Uint8Array([4, 5])), "4,5");
check("arguments", (function () { return collect(arguments); })(7, 8), "7,8");

// A grown or shrunk array is observed by the running iteration.
var grow = [1, 2], seen = [];
for (var v of grow) { seen.push(v); if (grow.length < 4) grow.push(v + 10); }
check("grow", seen.join(), "1,2,11,12");

// An own @@iterator on the array wins.
var own = [1, 2];
own[Symbol.iterator] = function* () { yield "own"; };
check("own iterator", collect(own), "own");

// A replaced Array.prototype[@@iterator] is used.
var saved = Array.prototype[Symbol.iterator];
Array.prototype[Symbol.iterator] = function* () { yield "patched"; };
check("patched iterator", collect([1, 2]), "patched");
Array.prototype[Symbol.iterator] = saved;
check("restored iterator", collect([1, 2]), "1,2");

// A replaced %ArrayIteratorPrototype%.next is used.
var ArrayIteratorPrototype = Object.getPrototypeOf([][Symbol.iterator]());
var savedNext = ArrayIteratorPrototype.next;
var steps = 0;
ArrayIteratorPrototype.next = function () { steps++; return savedNext.call(this); };
check("patched next", collect([1, 2]), "1,2");
check("next was called", steps, 3);
ArrayIteratorPrototype.next = savedNext;
check("restored next", collect([1]), "1");

// A subclass or a changed prototype keeps working.
class Sub extends Array {}
check("subclass", collect(Sub.from([1, 2])), "1,2");
var protoSwap = [1, 2];
Object.setPrototypeOf(protoSwap, { [Symbol.iterator]: function* () { yield "swapped"; } });
check("swapped prototype", collect(protoSwap), "swapped");

// break and throw close the iterator, whichever way it was opened.
var closed = 0;
var iterable = { [Symbol.iterator]() { return { next() { return { value: 1, done: false }; }, return() { closed++; return {}; } }; } };
for (var v of iterable) break;
check("break closes", closed, 1);
try { for (var v of iterable) throw new Error("x"); } catch (e) {}
check("throw closes", closed, 2);
var arr = [1, 2, 3], n = 0;
for (var v of arr) { n++; if (v === 2) break; }
check("array break", n, 2);

// Errors for sources that are not iterable.
function message(f) { try { f(); } catch (e) { return e.constructor === TypeError; } return false; }
check("undefined", message(() => { for (var v of undefined); }), true);
check("object", message(() => { for (var v of {}); }), true);
check("number", message(() => { for (var v of 5); }), true);

// Nested loops, labelled continue, destructuring heads, closures per iteration.
var pairs = [];
outer: for (var a of [1, 2]) { for (var b of [1, 2]) { if (b === 2) continue outer; pairs.push(a + "" + b); } }
check("nested", pairs.join(), "11,21");
var sum = 0;
for (var [x, y] of [[1, 2], [3, 4]]) sum += x * y;
check("destructure", sum, 14);
var fs = [];
for (let v of [1, 2, 3]) fs.push(() => v);
check("closures", fs.map((f) => f()).join(), "1,2,3");

// Generators and async functions keep the iterator across suspension.
function* gen() { for (var v of [1, 2, 3]) yield v * 2; }
check("generator loop", Array.from(gen()).join(), "2,4,6");
var asyncResult;
(async function () { var t = 0; for (var v of [1, 2, 3]) { await null; t += v; } asyncResult = t; })();
Promise.resolve().then(() => Promise.resolve()).then(() => Promise.resolve()).then(() => Promise.resolve()).then(() => {
    check("async loop", asyncResult, 6);
    print("ok");
});
