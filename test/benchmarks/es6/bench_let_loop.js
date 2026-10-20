// `let` loop bindings. Each iteration of a `for (let i ...)` gets a fresh
// binding, which is only observable when a closure captures it -- but the
// environment record is allocated either way.
var N = 3000000;

function letLoop(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += i; }
    return s;
}

// A block-scoped body binding on top of the loop binding.
function letBody(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { let t = i * 2; s += t; }
    return s;
}

// The `var` equivalent, as the floor.
function varLoop(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { s += i; }
    return s;
}

// The case per-iteration bindings exist for: each closure must see its own `i`.
function letCaptured(n) {
    const fns = [];
    for (let i = 0; i < n; i++) { fns.push(() => i); }
    return fns[n - 1]();
}

var r = 0;
r += letLoop(N);
r += letBody(N);
r += varLoop(N);
r += letCaptured(200000);
if (r === 0) throw new Error("optimized away");
