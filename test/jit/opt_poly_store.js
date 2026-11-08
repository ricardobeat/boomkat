// Polymorphic property read and write sites in the optimizing tier: one hot function sees
// four different receiver shapes at the same read site and the same write site, a shape
// created by adding the property after construction, and a receiver whose value lives on
// the prototype.

function make(v) {
    // Four shapes with the numeric property x at a different slot each time.
    switch (v) {
        case 0: return { x: v };
        case 1: return { a: 10, x: v };
        case 2: return { a: 10, b: 20, x: v };
        case 3: return { a: 10, b: 20, c: 30, x: v };
    }
    // The property is added after construction: the store site sees a shape transition.
    var o = { d: 40 };
    o.x = v;
    return o;
}

// The hot function: one read site and one write site, reached with every shape above.
function bump(o, d) {
    var v = o.x;
    o.x = v + d;
    return o;
}

// The addend sequence, recomputed by the test to get the expected values.
function addend(i) {
    return ((i >> 2) & 1) === 0 ? 2 : -1;
}

var N = 20000;
var objs = [make(0), make(1), make(2), make(3)];
var init = [objs[0].x, objs[1].x, objs[2].x, objs[3].x];

for (var i = 0; i < N; i++) {
    bump(objs[i % 4], addend(i));
}

// The expected values, from the same addend sequence over the same call order.
var expected = [init[0], init[1], init[2], init[3]];
for (var j = 0; j < N; j++) expected[j % 4] += addend(j);

for (var k = 0; k < 4; k++) {
    if (objs[k].x !== expected[k]) {
        throw new Error("shape " + k + ": x is " + objs[k].x + ", expected " + expected[k]);
    }
    if (typeof objs[k].x !== "number") {
        throw new Error("shape " + k + ": x is not a number");
    }
}

// A shape whose property was added after construction takes the same store site.
var added = make(4);
bump(added, 3);
if (added.x !== 7) throw new Error("added shape: x is " + added.x + ", expected 7");
if (typeof added.x !== "number") throw new Error("added shape: x is not a number");

// A receiver whose x lives on the prototype: the write must create an own property.
var proto = { x: 5 };
var child = Object.create(proto);
bump(child, 3);
if (child.x !== 8) throw new Error("prototype receiver: x is " + child.x + ", expected 8");
if (typeof child.x !== "number") throw new Error("prototype receiver: x is not a number");
if (!Object.prototype.hasOwnProperty.call(child, "x")) {
    throw new Error("prototype receiver: the write did not create an own property");
}
if (proto.x !== 5) throw new Error("prototype receiver: the prototype value changed");

print("opt_poly_store: ok");
