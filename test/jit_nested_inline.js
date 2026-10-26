// Expanding a callee that itself calls a method, two levels deep.
var failures = 0;
function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function Leaf() { this.value = 3; }
Leaf.prototype.triple = function () { return this.value * 3; };
Leaf.prototype.tripled = function () { return this.triple(); };
Leaf.prototype.wrapped = function () { return this.tripled() + 1; };
Leaf.prototype.setState = function (s) { this.state = s; };
Leaf.prototype.readState = function () { return this.state; };
Leaf.prototype.setAndRead = function (s) {
    this.setState(s);
    return this.readState();
};

var leaf = new Leaf();
for (var round = 0; round < 400; round++) {
    check("one level", leaf.triple(), 9);
    check("two levels", leaf.tripled(), 9);
    check("three levels", leaf.wrapped(), 10);
    check("nested setter", leaf.setAndRead(round), round);
    check("state survives", leaf.state, round);
}

if (failures == 0) print("ok");
