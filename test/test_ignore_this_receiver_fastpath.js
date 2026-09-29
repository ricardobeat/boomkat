function assertEq(actual, expected, label) {
    if (actual !== expected) {
        throw new Error(label + ': expected ' + expected + ', got ' + actual);
    }
}

class Receiver {
    constructor(id) { this.id = id; }

    // Strict class method with no direct or arrow-captured `this` use.
    ignoreAndAllocate(seed) {
        var latest;
        for (var i = 0; i < 32; i++) latest = { value: seed + i };
        return latest.value;
    }

    throwWithoutThis() {
        var allocated = { value: 1 };
        throw allocated.value;
    }

    readThis() { return this.id; }

    arrowCapturesThis() {
        var capture = () => this;
        return capture();
    }

    evalReadsThis() { return eval('this'); }
}

var receiver = new Receiver(41);
for (var n = 0; n < 16; n++) {
    assertEq(receiver.ignoreAndAllocate(n), n + 31, 'ignored receiver allocation');
    var caught = false;
    try {
        receiver.throwWithoutThis();
    } catch (value) {
        caught = value === 1;
    }
    assertEq(caught, true, 'throw after ignored receiver call');
    assertEq(receiver.readThis(), 41, 'pooled activation receiver');
}

assertEq(new Receiver(7).ignoreAndAllocate(10), 41, 'temporary receiver');
assertEq(receiver.arrowCapturesThis(), receiver, 'nested arrow receiver');
assertEq(receiver.evalReadsThis(), receiver, 'direct eval receiver');

class Parent {
    throughSuper() { return this; }
}
class Child extends Parent {
    throughSuper() { return super.throughSuper(); }
}
var child = new Child();
assertEq(child.throughSuper(), child, 'super call receiver');

function tailTarget() { return 81; }
function tailAfterIgnoredCall(value) {
    value.ignoreAndAllocate(0);
    return tailTarget();
}
assertEq(tailAfterIgnoredCall(receiver), 81, 'caller tail return cleanup');
