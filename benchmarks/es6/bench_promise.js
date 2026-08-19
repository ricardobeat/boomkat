// Promises and async/await. Every resolution queues a microtask, and every
// await suspends and resumes a frame, so this measures the microtask drain and
// the generator-style suspend/resume machinery rather than any I/O.
var N = 100000;

function chainThen(n) {
    let p = Promise.resolve(0);
    for (let i = 0; i < n; i++) { p = p.then(v => v + 1); }
    return p;
}

async function awaitLoop(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s = await s + 1; }
    return s;
}

async function awaitResolved(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += await Promise.resolve(1); }
    return s;
}

function allOfMany(n) {
    const ps = [];
    for (let i = 0; i < n; i++) { ps.push(Promise.resolve(i)); }
    return Promise.all(ps);
}

// Rejection handling: the catch path allocates and settles differently.
async function rejections(n) {
    let caught = 0;
    for (let i = 0; i < n; i++) {
        try { await Promise.reject(new Error("x")); } catch (e) { caught++; }
    }
    return caught;
}

chainThen(N);
awaitLoop(N);
awaitResolved(N / 2);
allOfMany(N);
rejections(N / 10);
