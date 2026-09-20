var failures = 0;

function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function make(value) {
    return { value: value, stable: 1 };
}

function readValue(obj) {
    return obj.value;
}

var objectA = { marker: "a" };
var objectB = { marker: "b" };
var instances = [make(11), make(22), make(objectA), make(objectB)];
for (var round = 0; round < 50; round++) {
    check("alternating primitive a", readValue(instances[0]), 11);
    check("alternating primitive b", readValue(instances[1]), 22);
    check("alternating object a", readValue(instances[2]), objectA);
    check("alternating object b", readValue(instances[3]), objectB);
}

var changed = make(30);
var peer = make(40);
check("accessor warm changed", readValue(changed), 30);
check("accessor warm peer", readValue(peer), 40);
Object.defineProperty(changed, "value", {
    configurable: true,
    enumerable: true,
    get: function () { return 31; }
});
check("data to accessor", readValue(changed), 31);
check("accessor peer", readValue(peer), 40);
delete changed.value;
check("deleted own property", readValue(changed), undefined);
changed.value = 32;
check("deleted and re-added", readValue(changed), 32);
check("re-add peer", readValue(peer), 40);

var protoA = { inherited: 51 };
var protoB = { inherited: 52 };
var inherited = Object.create(protoA);
function readInherited(obj) {
    return obj.inherited;
}
check("prototype warm", readInherited(inherited), 51);
Object.setPrototypeOf(inherited, protoB);
check("prototype mutation", readInherited(inherited), 52);
protoB.inherited = 53;
check("prototype value mutation", readInherited(inherited), 53);

var trapCalls = 0;
var proxy = new Proxy(make(60), {
    get: function (target, key) {
        trapCalls++;
        if (key === "value") return 61;
        return target[key];
    }
});
check("proxy value", readValue(proxy), 61);
check("proxy trap", trapCalls, 1);

var growing = make(70);
var growthPeer = make(80);
check("growth warm growing", readValue(growing), 70);
check("growth warm peer", readValue(growthPeer), 80);
for (var i = 0; i < 24; i++) growing["extra" + i] = i;
check("grown storage", readValue(growing), 70);
check("ungrown peer storage", readValue(growthPeer), 80);
var freshPeer = make(90);
check("fresh same-shape storage", readValue(freshPeer), 90);

if (failures === 0) print("PASS ic same-shape instances");
else throw new Error("FAILURES: " + failures);
