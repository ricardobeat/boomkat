// Function.prototype.bind reads the target through the object protocol, and
// Function.prototype.toString emits only a valid NativeFunction name.
//
// §20.2.3.2 steps 3-4 are HasOwnProperty(Target, "length") and
// Get(Target, "length"): both are trapped operations, so a Proxy target serves
// them from its handler and keeps nothing in a property table of its own.
//
// §20.2.3.5 puts the function's `name` into the NativeFunction grammar only
// when it is a valid PropertyName. A bound anonymous function is named
// "bound " -- with the trailing space -- which is not one.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + String(a) + ', want ' + String(b) + ')'); }

// A Proxy target's length and name reach the bound function.
var proxy = new Proxy(function () {}, {
    getOwnPropertyDescriptor: function (t, n) {
        ok(n === 'length', 'only "length" is probed for own-ness (saw ' + String(n) + ')');
        return { value: 3, configurable: true };
    },
    get: function (t, n) {
        if (n === 'length') return 3;
        if (n === 'name') return 'hello world';
        ok(false, 'unexpected get of ' + String(n));
    }
});
var bound = Function.prototype.bind.call(proxy);
eq(bound.name, 'bound hello world', 'a proxy target supplies the name');
eq(bound.length, 3, 'a proxy target supplies the length');

// Bound arguments come off the target's length.
var withArgs = Function.prototype.bind.call(proxy, null, 1);
eq(withArgs.length, 2, 'each bound argument lowers the length');

// A target with no own "length" gives 0, and the trap is still consulted.
var noLen = new Proxy(function (a, b) {}, {
    getOwnPropertyDescriptor: function () { return undefined; },
    get: function (t, n) { return n === 'name' ? 'x' : undefined; }
});
eq(Function.prototype.bind.call(noLen).length, 0, 'no own length means 0');

// Non-numeric and out-of-range lengths.
var fun = function () {};
Object.defineProperty(fun, 'name', { value: 1337 });
Object.defineProperty(fun, 'length', { value: '15' });
eq(fun.bind().name, 'bound ', 'a non-string name becomes ""');
eq(fun.bind().length, 0, 'a non-number length is 0');

Object.defineProperty(fun, 'length', { value: Number.MAX_SAFE_INTEGER });
eq(fun.bind().length, Number.MAX_SAFE_INTEGER, 'a large length survives exactly');
Object.defineProperty(fun, 'length', { value: Infinity });
eq(fun.bind().length, Infinity, 'an infinite length stays infinite');
Object.defineProperty(fun, 'length', { value: -100 });
eq(fun.bind().length, 0, 'a negative length clamps to 0');
Object.defineProperty(fun, 'length', { value: 4.7 });
eq(fun.bind().length, 4, 'a fractional length truncates');
Object.defineProperty(fun, 'length', { value: NaN });
eq(fun.bind().length, 0, 'NaN becomes 0');

// A length served by a getter is read, not taken from a slot.
var viaGetter = function () {};
Object.defineProperty(viaGetter, 'length', { get: function () { return 7; }, configurable: true });
eq(viaGetter.bind().length, 7, 'a length getter is called');

var rest = function f(a) {};
eq(rest.length, 1, 'a plain function reports its own length');
eq(rest.bind().length, 1, 'bind carries it over');

// --- NativeFunction syntax -----------------------------------------------

var nativeCode = /^function\s*(?:get|set)?\s*(\w+|'[^']*'|"[^"]*"|\d+|\[[^\]]+\])?\s*\(\s*\)\s*\{\s*\[native code\]\s*\}$/;
function conforms(fn, label) {
    var s = fn.toString();
    ok(nativeCode.test(s), label + ' conforms to NativeFunction syntax (' + JSON.stringify(s) + ')');
}

conforms(function () {}.bind(), 'a bound anonymous function');
conforms(function fn() {}.bind(), 'a bound named function');
conforms(function () {}.bind().bind(), 'a twice-bound function');
conforms(Array, 'a constructor');
conforms(Object.prototype.toString, 'a prototype method');
conforms(Math.asin, 'a namespace method');
conforms(RegExp.prototype[Symbol.split], 'a symbol-keyed method');
conforms(Object.getOwnPropertyDescriptor(RegExp.prototype, 'flags').get, 'a getter');
conforms(Object.getOwnPropertyDescriptor(Object.prototype, '__proto__').get, 'a __proto__ getter');
conforms(Object.getOwnPropertyDescriptor(Object.prototype, '__proto__').set, 'a __proto__ setter');

// The name property itself keeps the "bound " prefix; only the grammar drops it.
eq(function () {}.bind().name, 'bound ', 'a bound anonymous function is named "bound "');
eq(function fn() {}.bind().name, 'bound fn', 'a bound named function keeps the target name');
ok(Array.toString().indexOf('Array') !== -1, 'a valid name stays in the text');
ok(RegExp.prototype[Symbol.split].toString().indexOf('[Symbol.split]') !== -1,
   'a computed name stays in the text');
ok(Object.getOwnPropertyDescriptor(RegExp.prototype, 'flags').get.toString().indexOf('get flags') !== -1,
   'an accessor keeps its get prefix');

if (fail === 0) {
    print('PASS: bind and NativeFunction syntax (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
