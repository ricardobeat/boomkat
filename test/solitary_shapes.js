// Past a size threshold, an object on a shape no other object has reached
// stops registering its shape transitions. Objects built that way must still
// read, write, enumerate, and delete like any other, alone or side by side.
var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

function build(n, prefix) {
    var o = {};
    for (var i = 0; i < n; i++) o[prefix + i] = i;
    return o;
}

function read(o, k) { return o[k]; }

var a = build(300, "k");
var b = build(300, "k");
var sumA = 0, sumB = 0;
for (var i = 0; i < 300; i++) {
    sumA += read(a, "k" + i);
    sumB += read(b, "k" + i);
}
check("every key of the first object", sumA, 44850);
check("every key of a second object built the same way", sumB, 44850);
check("key count", Object.keys(a).length, 300);
check("insertion order", Object.keys(b)[299], "k299");

a.k250 = "changed";
check("a write lands on its own object", a.k250 + "/" + b.k250, "changed/250");

delete a.k100;
check("delete removes the key", "k100" in a, false);
check("delete leaves the other object alone", b.k100, 100);
check("keys after delete", Object.keys(a).length, 299);
a.k100 = "back";
check("a deleted key can be added again", a.k100, "back");
check("a re-added key enumerates last", Object.keys(a)[299], "k100");

Object.defineProperty(b, "k200", { value: 7, writable: false });
b.k200 = 8;
check("a read-only redefinition sticks", b.k200, 7);
check("redefinition leaves the twin writable", (a.k200 = 9, a.k200), 9);

var proto = build(100, "p");
var child = Object.create(proto);
check("an inherited key of a large prototype", child.p99, 99);
proto.extra = "late";
check("a key added to a large prototype is inherited", child.extra, "late");
child.p99 = "own";
check("an own key shadows the large prototype", child.p99 + "/" + proto.p99, "own/99");

print("solitary_shapes: " + passed + " passed");
