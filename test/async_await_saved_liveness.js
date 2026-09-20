var failures = 0;

function check(condition, label) {
    if (!condition) {
        failures++;
        print("FAIL: " + label);
    }
}

async function boundedLive(seed) {
    var kept = { n: seed };
    var total = 0;
    var dead = { discarded: true };
    dead = seed + 100;
    for (var i = 0; i < 4; i++) {
        total = total + i;
        if ((i & 1) === 0) total = total + seed;
    }
    var resumed = await seed;
    dead = resumed * 2;
    for (var j = 0; j < 3; j++) total++;
    return kept.n + total + dead;
}

async function pendingOrder(log) {
    log.push("start");
    var value = await new Promise(function (resolve) {
        log.push("executor");
        resolve(7);
    });
    log.push("resume");
    return value;
}

async function tryFinallyFallback() {
    var seen = 0;
    try {
        await Promise.reject("reject");
    } catch (e) {
        seen = e === "reject" ? 1 : 100;
    } finally {
        seen += 2;
    }
    return seen;
}

async function closureFallback() {
    var held = { n: 9 };
    function read() { return held.n; }
    await 0;
    return read();
}

async function evalFallback() {
    var n = 4;
    await 0;
    return eval("n + 1");
}

async function argumentsFallback(n) {
    await 0;
    return arguments[0];
}

async function throwsAfterAwait() {
    await 0;
    throw new Error("after await");
}

var receiver = {
    base: 10,
    sum: function (first, middle, last) {
        return this.base + first.n + middle + last.n;
    }
};

async function savedCallArguments() {
    var result = receiver.sum({ n: 4 }, await 3, { n: 5 });
    return result + 1;
}

async function savedProperty() {
    var object = { value: { n: 17 } };
    return object[await "value"].n;
}

async function repeatedAwaits() {
    var total = 0;
    for (var i = 0; i < 8; i++) total += await i;
    return total;
}

async function savedBranch(flag) {
    var first = { n: 1 };
    var second = { n: 2 };
    await 0;
    if (flag) return first.n;
    return second.n;
}

var order = [];
var pending = pendingOrder(order);
order.push("after-call");
var thrownSeen = throwsAfterAwait().then(function () {
    return false;
}, function (error) {
    return error.message === "after await";
});

Promise.all([
    boundedLive(5),
    pending,
    tryFinallyFallback(),
    closureFallback(),
    evalFallback(),
    argumentsFallback(6),
    thrownSeen,
    savedCallArguments(),
    savedProperty(),
    repeatedAwaits(),
    savedBranch(true),
    savedBranch(false)
]).then(function (values) {
    check(values[0] === 34, "branch loop arithmetic and retained object");
    check(values[1] === 7, "pending await value");
    check(values[2] === 3, "rejection and finally fallback");
    check(values[3] === 9, "closure fallback");
    check(values[4] === 5, "eval fallback");
    check(values[5] === 6, "arguments fallback");
    check(values[6] === true, "throw after await");
    check(values[7] === 23, "receiver and argument window across await");
    check(values[8] === 17, "property receiver across await");
    check(values[9] === 28, "loop across repeated awaits");
    check(values[10] === 1 && values[11] === 2, "both branch successors retain objects");
    check(order.join(",") === "start,executor,after-call,resume", "pending await ordering");
    if (failures !== 0) throw new Error(failures + " async liveness failures");
    print("PASS async await saved-register liveness");
}, function (error) {
    throw error;
});
