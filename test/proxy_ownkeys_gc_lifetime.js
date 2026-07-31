// Regression: the [[OwnPropertyKeys]] trap result must survive the
// [[GetOwnProperty]] traps that are called on its elements.
//
// proxy_partitioned_own_keys asks the ownKeys trap for an array, then calls
// getOwnPropertyDescriptor once per key to partition it by enumerability. Each
// of those calls re-enters the VM, and a nested run hits safepoints, where GC
// clears every temproot — including the pin the freshly allocated trap result
// was carrying. The array was reachable only from a C3 local the mark phase
// cannot see, so it was collected partway through the loop and the next
// `arr.array_part()[i]` read freed memory. ASAN reported a use-after-poison in
// HObject.array_part; without ASAN it was a segfault under GC pressure.
//
// The same window exposes the keys themselves. They are strings the trap built
// and nothing else names, and an interned string is NOT immune to collection:
// sweep_strings frees any entry whose refcount is 1 and which the mark phase
// did not reach, so the string table is a weak reference, not a root.
//
// The fix marks a native frame for the duration of the partition loop, which is
// the same guard builtin_dispatch already takes around every builtin handler.
//
// This reproduces only under real GC pressure, so the loop bodies allocate hard.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } }

function churn(n) {
    for (var j = 0; j < n; j++) { var junk = { a: [j, j, j], b: 'str' + j, c: { d: j } }; }
}

// --- keys exist only as trap results -----------------------------------
// Built by concatenation so they are not compile-time constants the literal
// pool would keep alive independently.
function makeProxy(count) {
    return new Proxy({}, {
        ownKeys: function () {
            var out = [];
            for (var i = 0; i < count; i++) { out.push('k' + 'ey' + i); }
            return out;
        },
        getOwnPropertyDescriptor: function () {
            // Allocating inside the trap is what drives the collection that
            // used to take the ownKeys array out from under the caller.
            churn(20);
            return { value: 1, enumerable: true, configurable: true };
        },
        get: function () { return 1; }
    });
}

var seen = [];
for (var k in makeProxy(50)) {
    seen.push(k);
    churn(100);
}
assert(seen.length === 50, 'proxy for-in visited ' + seen.length + ' keys, expected 50');
var mismatched = 0;
for (var i = 0; i < seen.length; i++) { if (seen[i] !== 'key' + i) mismatched++; }
assert(mismatched === 0, 'proxy for-in: ' + mismatched + ' keys came back wrong');

// --- Object.keys goes through the same partition loop -------------------
var ok = Object.keys(makeProxy(40));
assert(ok.length === 40, 'Object.keys returned ' + ok.length + ', expected 40');
var okBad = 0;
for (var i = 0; i < ok.length; i++) { if (ok[i] !== 'key' + i) okBad++; }
assert(okBad === 0, 'Object.keys: ' + okBad + ' keys came back wrong');

// --- getOwnPropertyNames (mode 1: no enumerability filter) --------------
var names = Object.getOwnPropertyNames(makeProxy(30));
assert(names.length === 30, 'getOwnPropertyNames returned ' + names.length + ', expected 30');

// --- non-enumerable keys land in the second partition -------------------
// They still have to survive the same window, since they are copied out of the
// array after every trap has run.
var mixed = new Proxy({}, {
    ownKeys: function () {
        var out = [];
        for (var i = 0; i < 30; i++) { out.push('m' + 'ix' + i); }
        return out;
    },
    getOwnPropertyDescriptor: function (t, k) {
        churn(20);
        var idx = parseInt(k.slice(3), 10);
        return { value: 1, enumerable: (idx % 2 === 0), configurable: true };
    },
    get: function () { return 1; }
});
var evens = [];
for (var k2 in mixed) { evens.push(k2); churn(50); }
assert(evens.length === 15, 'mixed proxy yielded ' + evens.length + ' enumerable keys, expected 15');
var evenBad = 0;
for (var i = 0; i < evens.length; i++) { if (evens[i] !== 'mix' + (i * 2)) evenBad++; }
assert(evenBad === 0, 'mixed proxy: ' + evenBad + ' keys wrong');

// --- keys held across a suspend, referenced only by the enumeration -----
// After collect_forin_keys returns, the unvisited keys live only in
// ForInState.keys, a raw array with no incref. The trap array is long gone.
function* enumerate(p) { for (var k in p) { yield k; } }
var it = enumerate(makeProxy(40));
var lazy = [it.next().value];
churn(3000);
var r;
while (!(r = it.next()).done) { lazy.push(r.value); churn(20); }
assert(lazy.length === 40, 'suspended proxy enumeration yielded ' + lazy.length + ', expected 40');
var lazyBad = 0;
for (var i = 0; i < lazy.length; i++) { if (lazy[i] !== 'key' + i) lazyBad++; }
assert(lazyBad === 0, 'suspended proxy enumeration: ' + lazyBad + ' keys wrong');

print('proxy_ownkeys_gc_lifetime: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
