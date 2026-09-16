// A missing argument is `undefined`.
//
// No builtin has an arity check of its own: calling one with fewer arguments
// than its `length` behaves exactly as passing `undefined` for each one that
// is absent. A builtin that returns early on a short argument list skips the
// coercion the spec requires, which is observable when that coercion throws
// (ToObject on undefined) or produces a real value (ToPropertyKey(undefined)
// is the key "undefined", ToString(undefined) is "undefined").

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

// Run `f` with no arguments and with one explicit `undefined`, and require the
// same outcome from both: the same value, or the same error constructor.
function same(label, missing, explicit) {
    function outcome(f) {
        try { return { v: f(), threw: false }; }
        catch (e) { return { v: e.constructor, threw: true }; }
    }
    var a = outcome(missing), b = outcome(explicit);
    ok(a.threw === b.threw,
       label + ': both throw or neither (' + a.threw + ' vs ' + b.threw + ')');
    if (a.threw === b.threw) {
        ok(a.v === b.v || String(a.v) === String(b.v),
           label + ': same result (' + String(a.v) + ' vs ' + String(b.v) + ')');
    }
}

var target = {};
target['undefined'] = 5;

// ToObject(undefined) throws, so these throw with no argument too.
same('Object.getOwnPropertyDescriptor',
     function () { return Object.getOwnPropertyDescriptor(); },
     function () { return Object.getOwnPropertyDescriptor(undefined); });
same('Object.keys',
     function () { return Object.keys(); },
     function () { return Object.keys(undefined); });
same('Object.getPrototypeOf',
     function () { return Object.getPrototypeOf(); },
     function () { return Object.getPrototypeOf(undefined); });

// undefined is not a Symbol, so keyFor throws either way.
same('Symbol.keyFor',
     function () { return Symbol.keyFor(); },
     function () { return Symbol.keyFor(undefined); });

// ToString(undefined) is "undefined", so Symbol.for() registers that key.
same('Symbol.for',
     function () { return String(Symbol.for()); },
     function () { return String(Symbol.for(undefined)); });
ok(Symbol.for() === Symbol.for(undefined), 'Symbol.for() hits the same registry entry');
ok(Symbol.keyFor(Symbol.for()) === 'undefined', 'the registered key is "undefined"');

// ToPropertyKey(undefined) is the key "undefined", so a missing key is a real
// lookup rather than a miss.
same('Object.getOwnPropertyDescriptor key',
     function () { return JSON.stringify(Object.getOwnPropertyDescriptor(target)); },
     function () { return JSON.stringify(Object.getOwnPropertyDescriptor(target, undefined)); });
same('Object.hasOwn key',
     function () { return Object.hasOwn(target); },
     function () { return Object.hasOwn(target, undefined); });
same('hasOwnProperty',
     function () { return target.hasOwnProperty(); },
     function () { return target.hasOwnProperty(undefined); });
same('Reflect.get',
     function () { return Reflect.get(target); },
     function () { return Reflect.get(target, undefined); });
same('Reflect.has',
     function () { return Reflect.has(target); },
     function () { return Reflect.has(target, undefined); });

ok(Object.hasOwn(target) === true, 'Object.hasOwn finds the "undefined" key');
ok(Object.getOwnPropertyDescriptor(target).value === 5,
   'getOwnPropertyDescriptor reads the "undefined" key');

// Object.hasOwn has no arity requirement: ToObject rejects the first argument.
same('Object.hasOwn no args',
     function () { return Object.hasOwn(); },
     function () { return Object.hasOwn(undefined, undefined); });

// A missing key still runs the proxy trap, and a revoked proxy still throws.
var seen = [];
var p = new Proxy({}, {
    getOwnPropertyDescriptor: function (t, k) { seen.push(String(k)); return undefined; }
});
Object.getOwnPropertyDescriptor(p);
ok(seen.length === 1 && seen[0] === 'undefined',
   'a missing key reaches the proxy trap as "undefined"');

var rv = Proxy.revocable({}, {});
rv.revoke();
var threw = false;
try { Object.getOwnPropertyDescriptor(rv.proxy); } catch (e) { threw = e instanceof TypeError; }
ok(threw, 'a revoked proxy throws even with no key argument');

// These return their argument unchanged when it is not an Object, so with no
// argument they return undefined -- which IS the argument.
ok(Object.preventExtensions() === undefined, 'Object.preventExtensions() returns undefined');
ok(Object.seal() === undefined, 'Object.seal() returns undefined');
ok(Object.freeze() === undefined, 'Object.freeze() returns undefined');
ok(Object.isExtensible() === false, 'Object.isExtensible() is false');

if (fail === 0) {
    print('PASS: missing argument is undefined (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
