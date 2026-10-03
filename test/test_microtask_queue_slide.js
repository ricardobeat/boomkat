// A drain that keeps enqueuing its own successor slides the microtask queue
// down instead of growing it. Order and values must survive every slide, and
// jobs queued by other chains in between must keep their FIFO position.
var log = [];
var N = 5000;

function chain(tag, n) {
    var c = 0;
    function step(v) {
        if (c % 1000 === 0) log.push(tag + ":" + c + ":" + v);
        if (++c < n) return Promise.resolve(v + 1).then(step);
        return v;
    }
    return Promise.resolve(0).then(step);
}

async function loop(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s = await s + 1;
    return s;
}

var results = [];
Promise.all([chain("a", N), chain("b", N), loop(N)]).then(function (r) {
    results = r;
    var expected = [N - 1, N - 1, N];
    if (results.join() !== expected.join()) throw new Error("results " + results.join());
    // Both chains advance in lockstep, so a's entry always precedes b's.
    for (var i = 0; i < log.length; i += 2) {
        if (log[i][0] !== "a" || log[i + 1][0] !== "b") throw new Error("order " + log.join());
    }
    if (log.length !== 10) throw new Error("log length " + log.length);
    print("ok");
});
