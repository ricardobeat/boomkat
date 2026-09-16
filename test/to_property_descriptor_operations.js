// ToPropertyDescriptor asks HasProperty before Get (§6.2.5.5).
//
// Each of the six fields is tested with HasProperty and read with Get only
// when present, in the order enumerable, configurable, value, writable, get,
// set. Both are trapped operations, so a Proxy descriptor object makes the
// sequence visible. Taking the Get alone as the presence test reports every
// field present, which makes a descriptor naming only data fields look like
// it names the accessor ones too.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

var log;
function logging(target) {
    return new Proxy(target, {
        has: function (t, id) { log.push('has ' + String(id)); return id in t; },
        get: function (t, id) { log.push('get ' + String(id)); return t[id]; }
    });
}

// Object.defineProperty has three implementations to reach -- ordinary
// objects, arrays and proxies -- and all of them run this operation.
var subjects = [['ordinary', {}], ['array', []], ['proxy', new Proxy({}, {})]];

subjects.forEach(function (c) {
    log = [];
    Object.defineProperty(c[1], 'x', logging({
        enumerable: true, configurable: true, value: 3, writable: true
    }));
    eq(log.join(','),
       'has enumerable,get enumerable,has configurable,get configurable,' +
       'has value,get value,has writable,get writable,has get,has set',
       c[0] + ': a data descriptor never reads get or set');
});

// An accessor descriptor reads the two accessor fields and not the data ones.
log = [];
var accTarget = {};
Object.defineProperty(accTarget, 'y', logging({ get: function () { return 1; }, enumerable: true }));
eq(log.join(','),
   'has enumerable,get enumerable,has configurable,has value,has writable,has get,get get,has set',
   'an accessor descriptor never reads value or writable');
eq(accTarget.y, 1, 'the accessor was installed');

// A field found on the prototype counts as present: HasProperty walks the
// chain, unlike a own-property probe.
var proto = { enumerable: true };
var inherited = Object.create(proto);
inherited.value = 7;
var target = {};
Object.defineProperty(target, 'z', inherited);
var d = Object.getOwnPropertyDescriptor(target, 'z');
eq(d.value, 7, 'an own field is read');
eq(d.enumerable, true, 'an inherited field is read too');

// Absent fields default to false rather than to the target's values.
var bare = {};
Object.defineProperty(bare, 'q', { value: 1 });
var bd = Object.getOwnPropertyDescriptor(bare, 'q');
eq(bd.writable, false, 'an absent writable defaults to false');
eq(bd.enumerable, false, 'an absent enumerable defaults to false');
eq(bd.configurable, false, 'an absent configurable defaults to false');

// A field whose has trap says yes but whose get returns undefined is still
// present, so pairing it with a data field is the data+accessor TypeError.
var threw = false;
try {
    Object.defineProperty({}, 'w', new Proxy({}, {
        has: function (t, id) { return id === 'value' || id === 'get'; },
        get: function () { return undefined; }
    }));
} catch (e) { threw = e instanceof TypeError; }
ok(threw, 'value together with get is a TypeError even when get is undefined');

// A has trap that hides every field yields an empty descriptor.
var empty = {};
Object.defineProperty(empty, 'e', new Proxy({ value: 99 }, {
    has: function () { return false; }
}));
var ed = Object.getOwnPropertyDescriptor(empty, 'e');
eq(ed.value, undefined, 'a hidden value field is not read');
eq(ed.writable, false, 'an empty descriptor is non-writable');

// Reflect.defineProperty and Object.defineProperties run the same operation.
log = [];
Reflect.defineProperty({}, 'r', logging({ value: 1 }));
ok(log.indexOf('has get') !== -1 && log.indexOf('get get') === -1,
   'Reflect.defineProperty probes get without reading it');

log = [];
Object.defineProperties({}, { p: logging({ value: 1 }) });
ok(log.indexOf('has set') !== -1 && log.indexOf('get set') === -1,
   'Object.defineProperties probes set without reading it');

if (fail === 0) {
    print('PASS: ToPropertyDescriptor operations (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
