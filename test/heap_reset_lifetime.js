// Lifetime of engine-level caches ACROSS Heap.reset().
//
// The test262 worker resets the heap between tests: hp.reset() frees every
// object, string, env pool and shape, then the next test runs in the same
// process. Any engine-level cache that survives that teardown while still
// holding pointers INTO it becomes a field of dangling pointers, and a cache
// that is also a GC root is strictly worse than a leak -- the next mark phase
// follows each stale pointer into freed memory.
//
// This file exists because that failure mode is invisible to every other lane.
// A cache bug of this shape scores a clean run standalone, passes the
// conformance suite, and passes GC_STRESS with ASan, because none of those
// ever calls reset(): reset is reachable only from the worker loop in
// cli/test262_runner.c3, never from JS. It shows up only as MEMKILL across a
// full corpus run, where every affected test also passes under --single, which
// is a confusing signal to debug from. The promoted-builtin cache hit exactly
// this during plan 077.
//
// Run it through the WORKER, which is what makes it meaningful -- one reset
// per line of input:
//
//   make out/test262_runner_asan
//   for i in $(seq 40); do echo test/heap_reset_lifetime.js; done \
//     | ./out/test262_runner_asan --worker
//
// Executed directly it still passes; it simply is not testing anything, since
// a single run performs no reset. See `just test-heap-reset`.
//
// The body's job is to leave every reset-crossing cache POPULATED when the
// test ends, so the following reset has something real to tear down.

var pass = 0, fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Promote builtins across several namespaces. A promoted builtin is an HObject
// allocated in this heap and reachable from a cache that outlives it, which is
// the shape this file is guarding.
var builtins = [
    JSON.parse, JSON.stringify, Math.max, Math.min, Array.isArray,
    Object.keys, Object.getOwnPropertyNames, parseInt, parseFloat,
    isNaN, isFinite, String.prototype.slice, Array.prototype.map,
    Function.prototype.call, Reflect.ownKeys, Date.now
];
for (var i = 0; i < builtins.length; i++) {
    // Writing a property is what forces promotion.
    builtins[i].probe = i;
    assert(builtins[i].probe === i, 'builtin ' + i + ' holds a written property');
    assert(typeof builtins[i] === 'function', 'builtin ' + i + ' is still callable');
}

// Identity has to hold against the promoted object, not just within one read.
assert(JSON.parse === JSON.parse, 'identity after promotion');
assert(Object(Math.max) === Math.max, 'ToObject identity after promotion');
assert(Math.max(3, 7) === 7, 'promoted builtin still calls correctly');
assert(JSON.parse('{"z":9}').z === 9, 'promoted JSON.parse still parses');

// Force collections with the caches as the only root for these objects, so a
// missing mark shows up here rather than after the next reset.
var pad = [];
for (var j = 0; j < 2000; j++) { pad.push({ j: j, s: 'p' + j }); }
pad = null;
for (var k = 0; k < builtins.length; k++) {
    assert(typeof builtins[k] === 'function', 'builtin ' + k + ' survived a collection');
}

// Interned strings, shapes and env pools also cross the reset boundary.
var shaped = [];
for (var s = 0; s < 200; s++) { shaped.push({ a: s, b: 'str' + s, c: [s] }); }
assert(shaped[199].b === 'str199', 'shape and string allocations intact');

// Leave the caches populated on exit: the value of this file is what the NEXT
// reset has to tear down.
print('heap_reset_lifetime: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
