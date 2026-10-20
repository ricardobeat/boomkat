// A retained graph enables nursery collection while auxiliary storage churns.
// `with` requires real environment cells even when captured slots are optimized.
var rounds = typeof AUX_ROUNDS_OVERRIDE === "number" ? AUX_ROUNDS_OVERRIDE : 100000;
var mode = typeof AUX_MODE_OVERRIDE === "string" ? AUX_MODE_OVERRIDE : "closure";
var retained = [];
for (var j = 0; j < 70000; j++) retained.push({value: j});

function capture(i) {
    with ({value: i}) {
        return function () { return value; };
    }
}

function check(sum) {
    if (sum !== rounds * (rounds - 1) / 2) throw new Error("checksum " + sum);
    if (retained[69999].value !== 69999) throw new Error("retained graph");
    if (typeof print === "function") print("auxiliary: " + mode + " rounds=" + rounds + " PASS");
}

async function step(i) { return await Promise.resolve(i); }

async function runAsync() {
    var sum = 0;
    for (var i = 0; i < rounds; i++) sum += await step(i);
    check(sum);
}

if (mode === "async") {
    runAsync();
} else {
    var sum = 0;
    for (var i = 0; i < rounds; i++) sum += capture(i)();
    check(sum);
}
