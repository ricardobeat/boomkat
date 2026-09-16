// Object.defineProperties visits keys in [[OwnPropertyKeys]] order.
//
// §20.1.2.3.1 step 2 asks the properties object for its own keys, which comes
// back as integer indices ascending, then the remaining strings in insertion
// order, then symbols in insertion order. The order is observable through the
// `defineProperty` trap of a Proxy target, and through any getter the
// descriptors are served from.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

function logTarget(log) {
    return new Proxy({}, {
        defineProperty: function (t, k) { log.push(k); return true; }
    });
}

function order(props) {
    var log = [];
    Object.defineProperties(logTarget(log), props);
    return log;
}

// Symbols come last however they were interleaved.
var descs = {};
var symA = Symbol('a'), symDuring = Symbol.for('during');
descs['before'] = { configurable: true, value: 0 };
descs[symA] = { configurable: true, value: 0 };
descs['during'] = { configurable: true, value: 0 };
descs[symDuring] = { configurable: true, value: 0 };
descs[Symbol.iterator] = { configurable: true, value: 0 };
descs['after'] = { configurable: true, value: 0 };

[['plain', descs], ['proxied', new Proxy(descs, {})]].forEach(function (c) {
    var log = order(c[1]);
    eq(log.length, 6, c[0] + ': every key is defined');
    eq(log.map(function (k) { return typeof k; }).join(','),
       'string,string,string,symbol,symbol,symbol',
       c[0] + ': strings before symbols');
    eq(log.slice(0, 3).map(String).join(','), 'before,during,after',
       c[0] + ': strings keep insertion order');
    ok(log.indexOf(symA) !== -1 && log.indexOf(symDuring) !== -1
       && log.indexOf(Symbol.iterator) !== -1,
       c[0] + ': every symbol is present');
});

// Integer indices sort ascending and lead, whatever order they were added.
var idx = {};
['10', '2', 'z', '1', 'a'].forEach(function (k) { idx[k] = { value: 0 }; });
idx[Symbol('s')] = { value: 0 };
eq(order(idx).map(String).join(','), '1,2,10,z,a,Symbol(s)',
   'indices ascending, then strings, then symbols');

// A Proxy source and a Proxy target together: the keys come from the source's
// ownKeys trap and each one reaches the target's defineProperty trap.
var bothLog = [];
Object.defineProperties(logTarget(bothLog), new Proxy(descs, {}));
eq(bothLog.length, 6, 'proxy source into proxy target defines every key');
eq(bothLog.map(function (k) { return typeof k; }).join(','),
   'string,string,string,symbol,symbol,symbol',
   'proxy source into proxy target keeps key order');

// Object.create takes the same abstract operation for its second argument.
var created = Object.create(null, descs);
eq(Object.getOwnPropertyNames(created).join(','), 'before,during,after',
   'Object.create defines the string keys');
eq(Object.getOwnPropertySymbols(created).length, 3,
   'Object.create defines the symbol keys');

// The descriptors are read in that order too, not just defined in it.
var readLog = [];
var getters = {};
Object.defineProperty(getters, 'sKey', {
    enumerable: true, get: function () { readLog.push('sKey'); return { value: 1 }; }
});
var sym = Symbol('symKey');
Object.defineProperty(getters, sym, {
    enumerable: true, get: function () { readLog.push('symKey'); return { value: 2 }; }
});
Object.defineProperty(getters, '0', {
    enumerable: true, get: function () { readLog.push('0'); return { value: 3 }; }
});
Object.defineProperties({}, getters);
eq(readLog.join(','), '0,sKey,symKey', 'descriptor getters run in key order');

// Only enumerable own properties of the source are used.
var skipped = { shown: { value: 1 } };
Object.defineProperty(skipped, 'hidden', { enumerable: false, value: { value: 2 } });
eq(order(skipped).map(String).join(','), 'shown', 'non-enumerable source keys are skipped');

if (fail === 0) {
    print('PASS: defineProperties key order (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
