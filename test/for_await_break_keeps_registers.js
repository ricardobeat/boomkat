// Leaving a `for await` loop early closes the iterator without writing into a register the
// function's locals use.
async function* gen() { yield 1; yield 2; yield 3; }

async function brk() {
    var out = [];
    for await (const v of gen()) { out.push(v); if (v === 2) break; }
    return out.join();
}

async function ret() {
    var seen = 0;
    for await (const v of gen()) { seen += v; if (v === 2) return seen; }
    return -1;
}

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) { failures++; print("FAIL " + name + ": expected " + expected + ", got " + actual); }
}

brk().then(function (r) {
    check("break", r, "1,2");
    return ret();
}).then(function (r) {
    check("return", r, 3);
    if (failures === 0) print("ok");
});
