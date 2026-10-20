var N = 1000000;

class Counter {
    constructor() { this.value = 0; }
    add(delta) { this.value += delta; }
}

function addDirect(receiver, delta) {
    "use strict";
    receiver.value += delta;
}

var methodCounter = new Counter();
var directCounter = new Counter();

function methodCalls() {
    for (var i = 0; i < N; i++) methodCounter.add(1);
    return methodCounter.value;
}

function directCalls() {
    for (var i = 0; i < N; i++) addDirect(directCounter, 1);
    return directCounter.value;
}

var start = Date.now();
var directResult = directCalls();
print('PHASE direct-strict-call ' + (Date.now() - start));
start = Date.now();
var methodResult = methodCalls();
print('PHASE method-this-call ' + (Date.now() - start));

if (directResult !== N || methodResult !== N) {
    throw new Error('ordinary method entry checksum mismatch');
}
