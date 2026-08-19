// ITER_NEXT_FAST reads array elements straight out of the dense storage,
// skipping the .next() call and the {value, done} object it allocates. It has
// to refuse in every case where that would be observable, and this file is the
// record of which ones those are.
//
// Written to run unmodified under QuickJS and node, so the expectations are
// cross-checked rather than self-asserted.
var pass = 0, fail = 0;
function eq(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; print("FAIL " + label + ": got " + got + " want " + want); }
}

// The basic case the fast path exists for.
var s = 0;
for (const x of [1, 2, 3]) { s += x; }
eq("plain array", s, 6);

// Nested loops: each needs its own fast-exit branch. A shared one leaves the
// outer branch unpatched, jumping to offset zero -- an infinite loop.
var n = 0;
for (const x of [1, 2]) { for (const y of [10, 20]) { n += x * y; } }
eq("nested", n, 90);

// A hole is not a plain dense element; reading it must still yield undefined.
var holes = [];
for (const x of [1, , 3]) { holes.push(String(x)); }
eq("holes", holes.join(","), "1,undefined,3");

// An accessor element's getter is user code and must run.
var withGetter = [1, 2];
Object.defineProperty(withGetter, 1, { get: function () { return 42; } });
var g = [];
for (const x of withGetter) { g.push(x); }
eq("accessor element", g.join(","), "1,42");

// The iterator re-reads length every step, so growth and truncation during
// iteration are both visible.
var grow = [1, 2, 3], grown = [], guard = 0;
for (const x of grow) { grown.push(x); if (x === 1) grow.push(4); if (guard++ > 10) break; }
eq("grows during", grown.join(","), "1,2,3,4");

var shrink = [1, 2, 3, 4], shrunk = [];
for (const x of shrink) { shrunk.push(x); shrink.length = 2; }
eq("shrinks during", shrunk.join(","), "1,2");

// A patched %ArrayIteratorPrototype%.next must be called: user code can count
// the calls, so the fast path has to detect the patch and stand down. The
// count is elements + 1 for the final done step.
var proto = Object.getPrototypeOf([][Symbol.iterator]());
var original = proto.next, calls = 0;
proto.next = function () { calls++; return original.call(this); };
var patched = [];
for (const x of [1, 2, 3]) { patched.push(x); }
proto.next = original;
eq("patched next runs", patched.join(","), "1,2,3");
eq("patched next call count", calls, 4);

// Non-array iterables go through the generic path untouched.
var set = 0;
for (const x of new Set([7])) { set = x; }
eq("Set", set, 7);

var mapKey = 0;
for (const e of new Map([[1, 2]])) { mapKey = e[0]; }
eq("Map", mapKey, 1);

var str = "";
for (const c of "abc") { str += c; }
eq("string", str, "abc");

function* gen() { yield 1; yield 2; }
var fromGen = 0;
for (const x of gen()) { fromGen += x; }
eq("generator", fromGen, 3);

// keys() and entries() synthesise their value rather than returning the
// element, so only the default values() iterator may take the fast path.
var keys = [];
for (const k of ["a", "b"].keys()) { keys.push(k); }
eq("keys()", keys.join(","), "0,1");

var entries = [];
for (const e of ["a"].entries()) { entries.push(e[0] + ":" + e[1]); }
eq("entries()", entries.join(","), "0:a");

// Breaking early leaves the iterator unexhausted; resuming it must continue
// from where it stopped rather than restart.
var it = [1, 2, 3][Symbol.iterator]();
var firstTwo = [];
for (const x of it) { firstTwo.push(x); if (x === 2) break; }
var rest = [];
for (const x of it) { rest.push(x); }
eq("break then resume", firstTwo.join(",") + "|" + rest.join(","), "1,2|3");

// Destructuring heads consume the same values.
var sum = 0;
for (const [a, b] of [[1, 2], [3, 4]]) { sum += a * b; }
eq("destructuring head", sum, 14);

// An empty array produces the done step immediately.
var ran = 0;
for (const x of []) { ran++; }
eq("empty array", ran, 0);

print(fail === 0 ? "test_forof_fast_path: all passed"
                 : "test_forof_fast_path: " + fail + " FAILED");
