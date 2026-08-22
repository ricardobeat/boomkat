// GC lifetime across NATIVE RE-ENTRY: a builtin calls back into the VM.
//
// Every builtin that invokes a JS callback re-enters through call_fn, and that
// path assigns Activation.this_binding raw, borrowing the caller's reference
// rather than taking one. Refcount liveness is not reachability: the sweep frees
// whatever the mark phase did not reach regardless of refcount, so any value
// reachable ONLY through such a frame is a candidate for collection mid-call.
// The receiver is the obvious one, but the same question applies to the
// callback's arguments, its return value in flight, and the intermediate
// objects a multi-step protocol (iterators, promise reactions, proxy traps)
// holds between steps.
//
// There are ~159 call_fn sites across the builtins. This covers the families
// rather than the sites: array iteration with a thisArg, sort/replace comparator
// callbacks, the iterator protocol, proxy traps, promise reactions, and the
// coercion hooks (valueOf/toString/@@toPrimitive). Each allocates hard enough to
// make a collection due DURING the callback, and each checks a value that only
// the borrowed frame could be keeping alive.
//
// Under GC_STRESS every allocation collects, so these windows are always hit;
// in a normal build they are timing-dependent and usually pass either way. Run
// this under out/boomkat_gc_stress, where POOL_BYPASS also makes any surviving
// use-after-free an ASAN report rather than a silent recycled read.

var pass = 0, fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Allocation inside a callback is what makes a collection fall due while the
// native frame is live.
function churn(n) {
    var pad = [];
    for (var i = 0; i < n; i++) { pad.push({ i: i, s: 'x' + i }); }
    return pad.length;
}

// --- Array iteration with an explicit thisArg -------------------------------
// The thisArg is handed to the callback frame by the builtin and is reachable
// from nothing else once the literal is no longer referenced.
(function () {
    var ops = ['forEach', 'map', 'filter', 'some', 'every', 'find', 'findIndex', 'flatMap'];
    for (var k = 0; k < ops.length; k++) {
        var op = ops[k];
        var seen = -1;
        [1, 2, 3][op](function () { churn(200); seen = this.tag; return true; }, { tag: 7 });
        assert(seen === 7, op + ' preserves a borrowed thisArg across a collection');
    }
})();

// --- Comparator and replacer callbacks -------------------------------------
(function () {
    var arr = [5, 3, 1, 4, 2];
    var sorted = arr.slice().sort(function (a, b) { churn(100); return a - b; });
    assert(sorted.join(',') === '1,2,3,4,5', 'sort comparator across a collection');

    var out = 'a1b2'.replace(/\d/g, function (m) { churn(100); return '<' + m + '>'; });
    assert(out === 'a<1>b<2>', 'replace callback across a collection');

    var reduced = [1, 2, 3].reduce(function (acc, x) { churn(100); return acc + x; }, 0);
    assert(reduced === 6, 'reduce callback across a collection');
})();

// --- The iterator protocol --------------------------------------------------
// next() is re-entered per step; the iterator and its result objects live
// between steps only through the native frame driving them.
(function () {
    var iterable = {};
    iterable[Symbol.iterator] = function () {
        var n = 0;
        return {
            next: function () {
                churn(200);
                n++;
                return n <= 3 ? { value: n * 10, done: false } : { value: undefined, done: true };
            }
        };
    };
    var collected = [];
    for (var v of iterable) { collected.push(v); }
    assert(collected.join(',') === '10,20,30', 'for-of drives a custom iterator across collections');
    assert(Array.from(iterable).join(',') === '10,20,30', 'Array.from over a custom iterator');
    assert([].concat(...[[1, 2], [3]]).join(',') === '1,2,3', 'spread over iterables');

    var m = new Map([[1, 'a'], [2, 'b']]);
    var acc = '';
    m.forEach(function (val) { churn(100); acc += val; });
    assert(acc === 'ab', 'Map.forEach callback across a collection');

    var s = new Set([1, 2]);
    var total = 0;
    s.forEach(function (val) { churn(100); total += val; });
    assert(total === 3, 'Set.forEach callback across a collection');
})();

// --- Proxy traps ------------------------------------------------------------
// Each trap is a native re-entry whose target and handler are held by the
// proxy's internal slots rather than by any register the marker walks.
(function () {
    var target = { a: 1, b: 2 };
    var p = new Proxy(target, {
        get: function (t, k) { churn(200); return t[k]; },
        has: function (t, k) { churn(200); return k in t; },
        ownKeys: function (t) { churn(200); return Reflect.ownKeys(t); },
        getOwnPropertyDescriptor: function (t, k) {
            churn(100);
            return Reflect.getOwnPropertyDescriptor(t, k);
        }
    });
    assert(p.a === 1, 'proxy get trap across a collection');
    assert(('b' in p) === true, 'proxy has trap across a collection');
    assert(Object.keys(p).join(',') === 'a,b', 'proxy ownKeys trap across a collection');
})();

// --- Coercion hooks ---------------------------------------------------------
// valueOf/toString/@@toPrimitive are called from deep inside native coercion,
// with the object reachable only from the operand slot.
(function () {
    var vo = { valueOf: function () { churn(200); return 41; } };
    assert(vo + 1 === 42, 'valueOf across a collection');

    var ts = { toString: function () { churn(200); return 'str'; } };
    assert(ts + '!' === 'str!', 'toString across a collection');

    var tp = {};
    tp[Symbol.toPrimitive] = function () { churn(200); return 5; };
    assert(tp * 2 === 10, '@@toPrimitive across a collection');

    assert(JSON.stringify({ x: { toJSON: function () { churn(200); return 'j'; } } }) === '{"x":"j"}',
        'toJSON across a collection');
    assert(JSON.stringify({ a: 1 }, function (k, v) { churn(50); return v; }) === '{"a":1}',
        'JSON replacer across a collection');
    assert(JSON.parse('{"a":1}', function (k, v) { churn(50); return v; }).a === 1,
        'JSON reviver across a collection');
})();

// --- Accessors invoked through the native path ------------------------------
(function () {
    for (var i = 0; i < 50; i++) {
        var host = { _v: i, get val() { churn(100); return this._v; }, set val(x) { churn(100); this._v = x; } };
        var d = Object.getOwnPropertyDescriptor(host, 'val');
        assert(d.get.call(host) === i, 'getter invoked with a borrowed receiver');
        d.set.call(host, i + 1);
        assert(host._v === i + 1, 'setter invoked with a borrowed receiver');
    }
})();

// --- Promise reactions ------------------------------------------------------
// Reactions run from the microtask drain, long after the frame that created
// them is gone, so their captured values must be rooted by the job itself.
var pending = 0, finished = 0;

function group(fn) { pending++; fn(); }

group(function () {
    var captured = { tag: 'reaction' };
    Promise.resolve(1).then(function (v) {
        churn(300);
        assert(v === 1 && captured.tag === 'reaction', 'then callback keeps its captured value');
        finished++;
    });
});

group(function () {
    var thenable = { then: function (res) { churn(300); res('thenable'); } };
    Promise.resolve(thenable).then(function (v) {
        assert(v === 'thenable', 'thenable adoption across a collection');
        finished++;
    });
});

group(function () {
    Promise.all([Promise.resolve('a'), 'b']).then(function (vals) {
        churn(300);
        assert(vals.join(',') === 'a,b', 'Promise.all resolves across a collection');
        finished++;
    });
});

group(function () {
    (async function () {
        var local = { n: 11 };
        await Promise.resolve();
        churn(300);
        await Promise.resolve();
        assert(local.n === 11, 'async body local survives two suspensions');
        finished++;
    })();
});

var polls = 0;
function report() {
    if (finished < pending && polls++ < 200000) {
        Promise.resolve().then(report);
        return;
    }
    assert(finished === pending, 'only ' + finished + '/' + pending + ' async groups settled');
    print('callback_gc_lifetime: ' + pass + ' passed, ' + fail + ' failed');
    if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
}
report();
