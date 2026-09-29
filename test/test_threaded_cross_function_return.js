// A primitive return to another compiled function must resume with that
// caller's variable and property IC state.
var crossReturnGlobal = 3;
var crossReturnObject = { value: 5 };

function crossReturnCallee(n) {
    return n + 1;
}

function crossReturnCaller(limit) {
    var total = 0;
    for (var i = 0; i < limit; i++) {
        total += crossReturnCallee(i);
        total += crossReturnObject.value;
        total += crossReturnGlobal;
    }
    return total;
}

var crossReturnResult = crossReturnCaller(1000);
if (crossReturnResult !== 508500) {
    throw new Error('cross-function threaded return lost caller state: ' + crossReturnResult);
}

// Primitive method and getter returns release their tracked `this` register
// before resuming the caller's frame.
var crossReturnReceiver = {
    value: 7,
    method: function (object, text) {
        var tempObject = object;
        var tempText = text;
        return this.value + tempObject.value + tempText.length;
    }
};
Object.defineProperty(crossReturnReceiver, 'next', {
    get: function () { return this.value + 2; }
});

function crossReturnMethodAndGetterCaller(limit) {
    var total = 0;
    for (var i = 0; i < limit; i++) {
        total += crossReturnReceiver.method(crossReturnTempObject, crossReturnTempText);
        total += crossReturnReceiver.next;
    }
    return total;
}

var crossReturnTempObject = { value: 10 };
var crossReturnTempText = 'owned';
var methodAndGetterResult = crossReturnMethodAndGetterCaller(1000);
if (methodAndGetterResult !== 31000) {
    throw new Error('primitive method/getter return lost caller state: ' + methodAndGetterResult);
}

function crossReturnSelfMethod(text) {
    var tempText = text;
    if (tempText.length === 0) throw new Error('missing temporary string');
    return this;
}

var crossReturnSelfReceiver = { value: 13, self: crossReturnSelfMethod };
var crossReturnSelfResult = crossReturnSelfReceiver.self(crossReturnTempText);
if (crossReturnSelfResult !== crossReturnSelfReceiver) {
    throw new Error('threaded receiver return lost object identity');
}

function crossReturnTemporaryReceiver() {
    return ({ value: 17, self: crossReturnSelfMethod }).self(crossReturnTempText);
}
var crossReturnTemporaryResult = crossReturnTemporaryReceiver();
if (crossReturnTemporaryResult.value !== 17) {
    throw new Error('threaded receiver return lost the temporary receiver');
}

function crossReturnSloppyThis() { return this; }
if (crossReturnSloppyThis() !== globalThis) {
    throw new Error('threaded borrowed callee return lost sloppy this');
}
