// for...of over the common source types. The iterator protocol allocates a
// {value, done} object per step unless an engine short-circuits it, and that
// allocation interacts with collection frequency once the live heap is large.
var N = 300000;

var buildStart = Date.now();
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

print("PHASE buildArray " + (Date.now()-buildStart));
var buildCollections = Date.now();
const set = new Set();
const map = new Map();
for (let i = 0; i < N / 3; i++) { set.add(i); map.set(i, i); }
print("PHASE buildCollections " + (Date.now()-buildCollections));
var buildString=Date.now();
let str = "";
for (let i = 0; i < 20000; i++) { str += "abcde"; }

print("PHASE buildString " + (Date.now()-buildString));
var r = 0;
var t = Date.now();
r += overArray(arr);
print("PHASE overArray(arr) " + (Date.now()-t));
var t = Date.now();
r += byIndex(arr);
print("PHASE byIndex(arr) " + (Date.now()-t));
var t = Date.now();
r += overSet(set);
print("PHASE overSet(set) " + (Date.now()-t));
var t = Date.now();
r += overMap(map);
print("PHASE overMap(map) " + (Date.now()-t));
var t = Date.now();
r += overString(str);
print("PHASE overString(str) " + (Date.now()-t));
var t = Date.now();
r += overGenerator(N / 3);
print("PHASE overGenerator(N / 3) " + (Date.now()-t));
if (r === 0) throw new Error("optimized away");

print("CHECK "+r);
