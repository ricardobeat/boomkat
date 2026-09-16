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

if (fail === 0) {
    print('PASS: TypedArray preventExtensions (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
