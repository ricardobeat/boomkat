// A class constructor called without `new` is a TypeError (§9.2.1 step 1),
// whoever makes the call.
//
// `typeof` reports "function" and IsCallable is true, so a class passes every
// callable check the spec makes: GetMethod accepts it, a Proxy handler accepts
// it as a trap, and a builtin accepts it as a callback. The TypeError comes
// when it is actually invoked. A host call that skipped the check instead
// returned undefined and carried on, which turns the error into a wrong
// answer.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function throwsTypeError(fn, m) {
    try { fn(); ok(false, m + ' (did not throw)'); }
    catch (e) { ok(e instanceof TypeError, m + ' (threw ' + e.constructor.name + ')'); }
}

class C {}
class D extends C {}

// A class is callable by every test the language offers.
ok(typeof C === 'function', 'typeof a class is "function"');
ok(C instanceof Function, 'a class is a Function');

// Calls written in script.
throwsTypeError(function () { C(); }, 'a direct call');
throwsTypeError(function () { C.call(null); }, 'Function.prototype.call');
throwsTypeError(function () { C.apply(null, []); }, 'Function.prototype.apply');
throwsTypeError(function () { Reflect.apply(C, null, []); }, 'Reflect.apply');
throwsTypeError(function () { D(); }, 'a derived class');
throwsTypeError(function () { C.bind()(); }, 'a bound class');

// Calls a builtin makes on the host's behalf.
throwsTypeError(function () { [1].map(C); }, 'an Array.prototype.map callback');
throwsTypeError(function () { [1].forEach(C); }, 'a forEach callback');
throwsTypeError(function () { [1].filter(C); }, 'a filter callback');
throwsTypeError(function () { [3, 1].sort(C); }, 'a sort comparator');
throwsTypeError(function () { [1, 2].reduce(C); }, 'a reduce callback');
throwsTypeError(function () { Array.from([1], C); }, 'an Array.from mapper');
throwsTypeError(function () { 'a'.replace(/a/, C); }, 'a replace function');
throwsTypeError(function () { JSON.stringify({ a: 1 }, C); }, 'a JSON replacer');
throwsTypeError(function () { JSON.parse('{"a":1}', C); }, 'a JSON reviver');

// Calls reached through a well-known symbol.
throwsTypeError(function () {
    var o = {}; o[Symbol.iterator] = C; return Array.from(o);
}, 'a Symbol.iterator method');
throwsTypeError(function () {
    var o = {}; o[Symbol.toPrimitive] = C; return `${o}`;
}, 'a Symbol.toPrimitive method');
throwsTypeError(function () {
    var o = {}; o[Symbol.hasInstance] = C; return 1 instanceof o;
}, 'a Symbol.hasInstance method');
throwsTypeError(function () {
    var o = {}; o[Symbol.replace] = C; return 'a'.replace(o, 'b');
}, 'a Symbol.replace method');
throwsTypeError(function () {
    var o = {}; o[Symbol.match] = C; return 'a'.match(o);
}, 'a Symbol.match method');

// Calls a Proxy makes into its handler.
throwsTypeError(function () { Reflect.setPrototypeOf(new Proxy({}, { setPrototypeOf: C }), null); },
                'a setPrototypeOf trap');
throwsTypeError(function () { Reflect.get(new Proxy({}, { get: C }), 'x'); }, 'a get trap');
throwsTypeError(function () { Reflect.has(new Proxy({}, { has: C }), 'x'); }, 'a has trap');
throwsTypeError(function () { Reflect.ownKeys(new Proxy({}, { ownKeys: C })); }, 'an ownKeys trap');
throwsTypeError(function () { Object.keys(new Proxy({}, { ownKeys: C })); }, 'ownKeys through Object.keys');

// The value a class shares its shape with -- an ordinary function -- still works.
ok([1, 2].map(function (x) { return x * 2; }).join(',') === '2,4',
   'an ordinary function callback still runs');
ok(new C() instanceof C, 'the class still constructs with new');
ok(Reflect.construct(C, []) instanceof C, 'Reflect.construct still works');
ok(new (C.bind())() instanceof C, 'a bound class still constructs');

// A rejected promise, not a thrown error, when the call is asynchronous.
var settled = null;
Promise.resolve(1).then(C).catch(function (e) { settled = e; });

if (fail === 0) {
    print('PASS: class constructor host calls (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
