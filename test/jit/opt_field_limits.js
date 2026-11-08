// Property reads and writes that the optimizing tier declines to handle: more receiver
// shapes than a polymorphic read compares, a read through a two-link prototype chain, an
// array `length`, an accessor pair, an absent key and a string value. Every shape is
// exercised in a hot loop, so a regression in the optimizing tier shows up as a
// difference against the baseline.

var N = 6000;

// 1. Six distinct receiver shapes at one read site, each with an own numeric `x`.
function makeShape(k) {
    switch (k) {
        case 0: return { x: 10 };
        case 1: return { a: 1, x: 20 };
        case 2: return { a: 1, b: 2, x: 30 };
        case 3: return { a: 1, b: 2, c: 3, x: 40 };
        case 4: return { a: 1, b: 2, c: 3, d: 4, x: 50 };
        default: return { a: 1, b: 2, c: 3, d: 4, e: 5, x: 60 };
    }
}

function readX(o) { return o.x; }
function bumpX(o) { var v = o.x; o.x = v + 1; return v; }

var shapes = [];
for (var sk = 0; sk < 6; sk++) shapes.push(makeShape(sk));

var readTotal = 0;
for (var i1 = 0; i1 < N; i1++) readTotal += readX(shapes[i1 % 6]);

// The same six shapes at a write site.
var bumpTotal = 0;
for (var i1b = 0; i1b < N; i1b++) bumpTotal += bumpX(shapes[i1b % 6]);

var perShape = N / 6;
var wantRead = 0;
var wantBump = 0;
for (var vk = 0; vk < 6; vk++) {
    var init = (vk + 1) * 10;
    var v = shapes[vk].x;
    if (typeof v !== "number") throw new Error("shapes: x is not a number");
    if (v !== init + perShape) {
        throw new Error("shapes: shape " + vk + " has x " + v + ", expected " + (init + perShape));
    }
    wantRead += init * perShape;
    wantBump += init * perShape + perShape * (perShape - 1) / 2;
}
if (readTotal !== wantRead) {
    throw new Error("shapes: read total is " + readTotal + ", expected " + wantRead);
}
if (bumpTotal !== wantBump) {
    throw new Error("shapes: write total is " + bumpTotal + ", expected " + wantBump);
}

// 2. A read through a prototype chain two links deep, and a write that creates an own
//    property on the child without changing either prototype.
var base = { x: 1 };
var proto1 = Object.create(base);
var proto2 = Object.create(proto1);
var child = Object.create(proto2);
var childWrite = Object.create(proto2);

function readInherited(o) { return o.x; }
function writeInherited(o, v) { o.x = v; }

var inheritedTotal = 0;
for (var i2 = 0; i2 < N; i2++) inheritedTotal += readInherited(child);
if (inheritedTotal !== N) {
    throw new Error("prototype read: total is " + inheritedTotal + ", expected " + N);
}
if (child.x !== 1) throw new Error("prototype read: x is " + child.x + ", expected 1");
if (Object.prototype.hasOwnProperty.call(child, "x")) {
    throw new Error("prototype read: the child gained an own property");
}

for (var i3 = 0; i3 < N; i3++) writeInherited(childWrite, i3);
if (childWrite.x !== N - 1) {
    throw new Error("prototype write: x is " + childWrite.x + ", expected " + (N - 1));
}
if (!Object.prototype.hasOwnProperty.call(childWrite, "x")) {
    throw new Error("prototype write: no own property was created");
}
if (proto2.x !== 1) throw new Error("prototype write: proto2.x is " + proto2.x);
if (proto1.x !== 1) throw new Error("prototype write: proto1.x is " + proto1.x);
if (base.x !== 1) throw new Error("prototype write: base.x is " + base.x);

// 3. `length` on an array in a hot loop: the value must follow a push.
var arr = [1, 2, 3];
function arrayLength(a) { return a.length; }

var lengthTotal = 0;
for (var i4 = 0; i4 < N; i4++) lengthTotal += arrayLength(arr);
if (lengthTotal !== N * 3) {
    throw new Error("array length: total is " + lengthTotal + ", expected " + N * 3);
}
if (arrayLength(arr) !== 3) {
    throw new Error("array length: length is " + arrayLength(arr) + ", expected 3");
}

arr.push(4);
if (arr.length !== 4) throw new Error("array length: after push length is " + arr.length);
var lengthTotal2 = 0;
for (var i5 = 0; i5 < N; i5++) lengthTotal2 += arrayLength(arr);
if (lengthTotal2 !== N * 4) {
    throw new Error("array length after push: total is " + lengthTotal2 + ", expected " + N * 4);
}

// 4. An accessor pair: the getter must run and the setter must receive the written value.
var getterCalls = 0;
var setterCalls = 0;
var lastSet = -1;
var accessor = {
    get x() { getterCalls++; return 42; },
    set x(v) { setterCalls++; lastSet = v; }
};
function accessX(o, v) { var r = o.x; o.x = v; return r; }

var accessorTotal = 0;
for (var i6 = 0; i6 < N; i6++) accessorTotal += accessX(accessor, i6);
if (accessorTotal !== N * 42) {
    throw new Error("accessor: total is " + accessorTotal + ", expected " + N * 42);
}
if (getterCalls !== N) {
    throw new Error("accessor: the getter ran " + getterCalls + " times, expected " + N);
}
if (setterCalls !== N) {
    throw new Error("accessor: the setter ran " + setterCalls + " times, expected " + N);
}
if (lastSet !== N - 1) {
    throw new Error("accessor: the setter received " + lastSet + ", expected " + (N - 1));
}

// 5. An absent property read, and a write that adds a new property to a plain object.
var empty = {};
var grown = {};
function readMissing(o) { return o.missing; }
function writeMissing(o) { o.missing = 1; }

var undefinedCount = 0;
for (var i7 = 0; i7 < N; i7++) {
    var m = readMissing(empty);
    if (m === undefined) undefinedCount++;
}
if (undefinedCount !== N) {
    throw new Error("absent read: " + undefinedCount + " of " + N + " reads were undefined");
}
if ("missing" in empty) throw new Error("absent read: the object gained the property");

for (var i8 = 0; i8 < N; i8++) writeMissing(grown);
if (!("missing" in grown)) throw new Error("absent write: the property was not added");
if (grown.missing !== 1) throw new Error("absent write: missing is " + grown.missing);

// 6. A property whose value is a string: the read must observe the current value, so the
//    string cannot be held in a register across the loop.
var words = ["one", "two", "three", "four", "five"];
var holder = { s: words[0] };
function readString(o) { return o.s; }

var wordIndex = 0;
var stringReads = 0;
for (var i9 = 0; i9 < N; i9++) {
    if (i9 % 500 === 0) {
        holder.s = words[wordIndex % words.length];
        wordIndex++;
    }
    var s = readString(holder);
    var want = words[(wordIndex - 1) % words.length];
    if (s !== want) throw new Error("string read: got " + s + ", expected " + want);
    if (s.length !== want.length) {
        throw new Error("string read: length is " + s.length + ", expected " + want.length);
    }
    stringReads++;
}
if (stringReads !== N) {
    throw new Error("string read: " + stringReads + " reads, expected " + N);
}

print("opt_field_limits: ok");
