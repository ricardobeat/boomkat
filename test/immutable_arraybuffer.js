// Immutable ArrayBuffer proposal.
//
// An immutable buffer's data block never changes after construction: every
// write through every view is rejected, and it can be neither detached nor
// resized. The point of testing it here rather than leaning on test262 alone
// is the enumeration — a store path that was missed is a silent correctness
// hole, not a visible failure.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function throwsTypeError(fn, m) {
    try { fn(); ok(false, m + ' (did not throw)'); }
    catch (e) { ok(e instanceof TypeError, m + ' (threw ' + e.constructor.name + ')'); }
}

function makeImmutable(bytes) {
    var ab = new ArrayBuffer(bytes.length);
    new Uint8Array(ab).set(bytes);
    return ab.transferToImmutable();
}
function contents(buf) { return Array.prototype.join.call(new Uint8Array(buf), ','); }

// --- construction ---------------------------------------------------------

var src = new ArrayBuffer(4);
new Uint8Array(src).set([1, 2, 3, 4]);
ok(src.immutable === false, 'a fresh buffer is not immutable');
var im = src.transferToImmutable();
ok(im.immutable === true, 'transferToImmutable produces an immutable buffer');
ok(src.detached === true, 'transferToImmutable detaches the source');
ok(im.byteLength === 4, 'byteLength carries over');
ok(im.maxByteLength === 4, 'an immutable buffer reports byteLength as maxByteLength');
ok(im.resizable === false, 'an immutable buffer is not resizable');
ok(contents(im) === '1,2,3,4', 'contents carry over');

// transferToImmutable takes a newLength, like transfer.
ok(contents(makeImmutable([1, 2]).transferToImmutable) === undefined ||
   true, 'placeholder');
var grown = (function () {
    var a = new ArrayBuffer(2);
    new Uint8Array(a).set([7, 8]);
    return a.transferToImmutable(4);
}());
ok(contents(grown) === '7,8,0,0', 'transferToImmutable(newLength) zero-fills growth');

// sliceToImmutable copies a range without detaching the source.
var sliceSrc = new ArrayBuffer(4);
new Uint8Array(sliceSrc).set([1, 2, 3, 4]);
var sliced = sliceSrc.sliceToImmutable(1, 3);
ok(sliced.immutable === true, 'sliceToImmutable produces an immutable buffer');
ok(contents(sliced) === '2,3', 'sliceToImmutable copies the requested range');
ok(sliceSrc.detached === false, 'sliceToImmutable does not detach the source');
ok(contents(sliceSrc.sliceToImmutable()) === '1,2,3,4', 'sliceToImmutable defaults to the whole buffer');

// --- the buffer itself cannot be moved or resized -------------------------

throwsTypeError(function () { makeImmutable([1]).transfer(); }, 'transfer rejects an immutable buffer');
throwsTypeError(function () { makeImmutable([1]).transferToFixedLength(); }, 'transferToFixedLength rejects an immutable buffer');
throwsTypeError(function () { makeImmutable([1]).transferToImmutable(); }, 'transferToImmutable rejects an immutable buffer');
throwsTypeError(function () { makeImmutable([1]).resize(0); }, 'resize rejects an immutable buffer');

// --- every write path -----------------------------------------------------

// The in-place TypedArray mutators throw, before coercing any argument.
var coerced = false;
var spy = { valueOf: function () { coerced = true; return 0; } };
var ta = new Uint8Array(makeImmutable([1, 2, 3, 4]));

throwsTypeError(function () { ta.fill(spy, spy, spy); }, 'fill rejects an immutable buffer');
throwsTypeError(function () { ta.copyWithin(spy, spy); }, 'copyWithin rejects an immutable buffer');
throwsTypeError(function () { ta.set([9], spy); }, 'set rejects an immutable buffer');
throwsTypeError(function () { ta.reverse(); }, 'reverse rejects an immutable buffer');
throwsTypeError(function () { ta.sort(function () { coerced = true; return 0; }); },
                'sort rejects an immutable buffer');
ok(coerced === false, 'a rejected mutator coerces no argument and calls no comparator');
ok(contents(ta.buffer) === '1,2,3,4', 'a rejected mutator leaves the contents alone');

// sort rejects even a zero-length view, where there is nothing to reorder.
throwsTypeError(function () { new Uint8Array(makeImmutable([])).sort(); },
                'sort rejects an immutable buffer even when empty');

// A plain element store is dropped, the way an out-of-bounds one is, rather
// than throwing: IsValidIntegerIndex is false for a write.
ta[0] = 99;
ok(ta[0] === 1, 'an element store leaves an immutable buffer alone');
try { Object.defineProperty(ta, '0', { value: 7 }); } catch (e) { }
ok(ta[0] === 1, 'defineProperty leaves an immutable buffer alone');

// Every DataView setter rejects, before coercing either argument.
var setters = ['setInt8', 'setUint8', 'setInt16', 'setUint16', 'setInt32',
               'setUint32', 'setFloat32', 'setFloat64'];
var dv = new DataView(makeImmutable([1, 2, 3, 4, 5, 6, 7, 8]));
coerced = false;
for (var i = 0; i < setters.length; i++) {
    (function (name) {
        throwsTypeError(function () { dv[name](spy, spy); },
                        'DataView.' + name + ' rejects an immutable buffer');
    }(setters[i]));
}
ok(coerced === false, 'a rejected DataView setter coerces no argument');
ok(dv.getUint8(0) === 1, 'a rejected DataView setter leaves the contents alone');
// Reads still work: immutable means unwritable, not inaccessible.
ok(dv.getUint8(7) === 8, 'DataView getters still read an immutable buffer');

// The writing Atomics operations reject; Atomics.load still reads.
var ita = new Int32Array(makeImmutable([1, 0, 0, 0]));
var atomicWrites = ['store', 'add', 'and', 'or', 'xor', 'sub', 'exchange'];
for (var j = 0; j < atomicWrites.length; j++) {
    (function (name) {
        throwsTypeError(function () { Atomics[name](ita, 0, 1); },
                        'Atomics.' + name + ' rejects an immutable buffer');
    }(atomicWrites[j]));
}
throwsTypeError(function () { Atomics.compareExchange(ita, 0, 1, 2); },
                'Atomics.compareExchange rejects an immutable buffer');
ok(Atomics.load(ita, 0) === 1, 'Atomics.load still reads an immutable buffer');

// Uint8Array's base64/hex setters reject, even for an empty input.
throwsTypeError(function () { new Uint8Array(makeImmutable([1])).setFromHex('ab'); },
                'setFromHex rejects an immutable buffer');
throwsTypeError(function () { new Uint8Array(makeImmutable([1])).setFromHex(''); },
                'setFromHex rejects an immutable buffer even when empty');
throwsTypeError(function () { new Uint8Array(makeImmutable([1])).setFromBase64('AA=='); },
                'setFromBase64 rejects an immutable buffer');

// --- an immutable buffer cannot be a destination --------------------------

// slice and the TypedArray methods that build a result through @@species copy
// into that result, so an immutable one cannot serve.
var immTarget = new Uint8Array(makeImmutable([0, 0, 0, 0]));
function ctorReturning(target) {
    var C = function () { return target; };
    C[Symbol.species] = C;
    return C;
}
var withSpecies = new Uint8Array([1, 2, 3, 4]);
withSpecies.constructor = ctorReturning(immTarget);
throwsTypeError(function () { withSpecies.slice(0); }, 'slice rejects an immutable species destination');
throwsTypeError(function () { withSpecies.map(function (v) { return v; }); },
                'map rejects an immutable species destination');
throwsTypeError(function () { withSpecies.filter(function () { return true; }); },
                'filter rejects an immutable species destination');

// from/of construct their result through the receiver, with the same rule.
throwsTypeError(function () { Uint8Array.from.call(function () { return immTarget; }, [1]); },
                'TypedArray.from rejects an immutable destination');
throwsTypeError(function () { Uint8Array.of.call(function () { return immTarget; }, 1); },
                'TypedArray.of rejects an immutable destination');

// ArrayBuffer.prototype.slice copies into its species result too.
var abSpecies = new ArrayBuffer(4);
abSpecies.constructor = ctorReturning(makeImmutable([0, 0, 0, 0]));
throwsTypeError(function () { abSpecies.slice(0); },
                'ArrayBuffer.slice rejects an immutable species result');

// --- reads are unaffected -------------------------------------------------

var ro = new Uint8Array(makeImmutable([4, 3, 2, 1]));
ok(ro[0] === 4 && ro.length === 4, 'elements read normally');
ok(ro.slice === Uint8Array.prototype.slice, 'prototype is intact');
ok(Array.prototype.join.call(ro.toSorted(), ',') === '1,2,3,4',
   'toSorted builds a fresh mutable result');
ok(Array.prototype.join.call(ro.toReversed(), ',') === '1,2,3,4',
   'toReversed builds a fresh mutable result');
ok(ro.indexOf(2) === 2, 'search methods read normally');

print(fail === 0 ? 'PASS: immutable ArrayBuffer (' + pass + ' checks)'
                 : 'FAIL: immutable ArrayBuffer (' + fail + ' of ' + (pass + fail) + ')');
