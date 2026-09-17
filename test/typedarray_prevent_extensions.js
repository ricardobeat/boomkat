// [[PreventExtensions]] on a TypedArray (§10.4.5.2).
//
// It succeeds only when the view's length can no longer change. The element
// keys are the object's properties, so a view that can re-grow would gain
// properties after being made non-extensible.
//
// A length-tracking view follows its buffer, and any view over a resizable
// non-shared buffer can shrink and re-grow. A view over a growable
// SharedArrayBuffer is the exception: a GSAB only grows, so a fixed-length
// view over one keeps its length.

'use strict';

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function throwsTypeError(fn, m) {
    try { fn(); ok(false, m + ' (did not throw)'); }
    catch (e) { ok(e instanceof TypeError, m + ' (threw ' + e.constructor.name + ')'); }
}

var ctors = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
             Int32Array, Uint32Array, Float32Array, Float64Array,
             BigInt64Array, BigUint64Array];

for (var i = 0; i < ctors.length; i++) {
    var ctor = ctors[i];
    var name = ctor.name;
    var bpe = ctor.BYTES_PER_ELEMENT;

    // Resizable, non-shared: every view can shrink, so all four refuse.
    var rab = new ArrayBuffer(4 * bpe, { maxByteLength: 8 * bpe });
    var views = [
        [new ctor(rab, 0, 4), 'fixedLength'],
        [new ctor(rab, 2 * bpe, 2), 'fixedLengthWithOffset'],
        [new ctor(rab), 'lengthTracking'],
        [new ctor(rab, 2 * bpe), 'lengthTrackingWithOffset']
    ];
    for (var v = 0; v < views.length; v++) {
        var view = views[v][0], label = name + ' rab ' + views[v][1];
        throwsTypeError(function () { Object.preventExtensions(view); },
                        label + ': Object.preventExtensions');
        ok(Reflect.preventExtensions(view) === false,
           label + ': Reflect.preventExtensions returns false');
        ok(Object.isExtensible(view) === true, label + ': stays extensible');
    }

    // Growable shared: a GSAB only grows, so a fixed-length view over one
    // keeps its length and succeeds. A length-tracking view still refuses.
    var gsab = new SharedArrayBuffer(4 * bpe, { maxByteLength: 8 * bpe });
    var gFixed = new ctor(gsab, 0, 4);
    var gFixedOffset = new ctor(gsab, 2 * bpe, 2);
    Object.preventExtensions(gFixed);
    Object.preventExtensions(gFixedOffset);
    ok(Object.isExtensible(gFixed) === false, name + ' gsab fixedLength: sealed off');
    ok(Object.isExtensible(gFixedOffset) === false,
       name + ' gsab fixedLengthWithOffset: sealed off');

    throwsTypeError(function () { Object.preventExtensions(new ctor(gsab)); },
                    name + ' gsab lengthTracking');
    throwsTypeError(function () { Object.preventExtensions(new ctor(gsab, 2 * bpe)); },
                    name + ' gsab lengthTrackingWithOffset');

    // A view over a plain, non-resizable buffer is fixed-length.
    var ab = new ArrayBuffer(4 * bpe);
    var plain = new ctor(ab, 0, 4);
    Object.preventExtensions(plain);
    ok(Object.isExtensible(plain) === false, name + ' plain buffer: succeeds');
    ok(Reflect.preventExtensions(new ctor(new ArrayBuffer(4 * bpe))) === true,
       name + ' plain buffer: Reflect.preventExtensions returns true');
}

// preventExtensions leaves the elements alone; only new properties are barred.
var t = new Uint8Array(new ArrayBuffer(4));
t[0] = 7;
Object.preventExtensions(t);
t[1] = 9;
ok(t[0] === 7 && t[1] === 9, 'elements stay writable after preventExtensions');
throwsTypeError(function () { t.extra = 1; }, 'a new named property is barred');

// --- integrity levels -----------------------------------------------------
//
// SetIntegrityLevel (§7.3.15) performs [[PreventExtensions]] first and only
// then defines every own key, so a seal or freeze that fails on the elements
// has already made the object non-extensible.
//
// TestIntegrityLevel has to look at the elements too: they live in the backing
// buffer rather than the named property table, and §10.4.5.3 refuses to make
// an in-bounds index non-configurable, so a view with any element is neither
// sealed nor frozen however non-extensible it is.

var nonEmpty = new Int32Array(10);
throwsTypeError(function () { Object.seal(nonEmpty); }, 'seal a non-empty view');
ok(Object.isExtensible(nonEmpty) === false, 'a failed seal still prevents extensions');
ok(Object.isSealed(nonEmpty) === false, 'a non-empty view is not sealed');
ok(Object.isFrozen(nonEmpty) === false, 'a non-empty view is not frozen');

var nonEmpty2 = new Int32Array(1024);
throwsTypeError(function () { Object.freeze(nonEmpty2); }, 'freeze a non-empty view');
ok(Object.isExtensible(nonEmpty2) === false, 'a failed freeze still prevents extensions');
ok(Object.isSealed(nonEmpty2) === false, 'a non-empty view is not sealed after freeze');
ok(Object.isFrozen(nonEmpty2) === false, 'a non-empty view is not frozen after freeze');

// preventExtensions alone leaves the elements configurable.
var pe = new Int32Array(4);
Object.preventExtensions(pe);
ok(Object.isExtensible(pe) === false, 'preventExtensions took effect');
ok(Object.isSealed(pe) === false, 'preventExtensions alone does not seal');
ok(Object.isFrozen(pe) === false, 'preventExtensions alone does not freeze');

// An empty view has no element keys, so it seals and freezes.
var e1 = new Int32Array(0);
Object.seal(e1);
ok(Object.isExtensible(e1) === false, 'an empty view seals');
ok(Object.isSealed(e1) === true, 'an empty sealed view is sealed');
ok(Object.isFrozen(e1) === true, 'an empty sealed view is frozen');

var e2 = new Int32Array(0);
Object.freeze(e2);
ok(Object.isSealed(e2) === true, 'an empty frozen view is sealed');
ok(Object.isFrozen(e2) === true, 'an empty frozen view is frozen');

var e3 = new Int32Array(0);
Object.preventExtensions(e3);
ok(Object.isSealed(e3) === true, 'a non-extensible empty view is sealed');
ok(Object.isFrozen(e3) === true, 'a non-extensible empty view is frozen');

// A non-fixed-length view fails at the [[PreventExtensions]] step instead, so
// it stays extensible.
var rabSeal = new Int32Array(new ArrayBuffer(0, { maxByteLength: 8 }));
throwsTypeError(function () { Object.seal(rabSeal); }, 'seal a length-tracking view');
ok(Object.isExtensible(rabSeal) === true, 'a view that cannot prevent extensions stays extensible');

if (fail === 0) {
    print('PASS: TypedArray preventExtensions (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
