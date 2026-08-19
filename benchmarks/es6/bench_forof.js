// for...of over the common source types. The iterator protocol allocates a
// {value, done} object per step unless an engine short-circuits it, and that
// allocation interacts with collection frequency once the live heap is large.
var N = 300000;

const arr = [];
for (let i = 0; i < N; i++) { arr.push(i); }

function overArray(a) {
    let s = 0;
    for (const x of a) { s += x; }
    return s;
}

// The index equivalent, as the floor: same reads, no iterator.
function byIndex(a) {
    let s = 0;
    for (let i = 0; i < a.length; i++) { s += a[i]; }
    return s;
}

function overSet(set) {
    let s = 0;
    for (const x of set) { s += x; }
    return s;
}

function overMap(map) {
    let s = 0;
    for (const [k, v] of map) { s += v; }
    return s;
}

function overString(str) {
    let n = 0;
    for (const c of str) { n++; }
    return n;
}

function* range(n) { for (let i = 0; i < n; i++) { yield i; } }
function overGenerator(n) {
    let s = 0;
    for (const x of range(n)) { s += x; }
    return s;
}

const set = new Set();
const map = new Map();
for (let i = 0; i < N / 3; i++) { set.add(i); map.set(i, i); }
let str = "";
for (let i = 0; i < 20000; i++) { str += "abcde"; }

var r = 0;
r += overArray(arr);
r += byIndex(arr);
r += overSet(set);
r += overMap(map);
r += overString(str);
r += overGenerator(N / 3);
if (r === 0) throw new Error("optimized away");
