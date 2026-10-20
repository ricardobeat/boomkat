// Allocation-free numeric probe for the class workload. This is hand-written
// scalar JavaScript, not an engine optimization or a semantics-preserving
// rewrite for arbitrary constructors/getters. It measures the remaining loop
// and arithmetic dispatch once allocation, construction and getters disappear.
var N = 1000000;
function scalarBase(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += i * i + i * i;
    return s;
}
function scalarDerived(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += (i * i + i * i) + i * i;
    return s;
}
print(scalarBase(N));
print(scalarDerived(N / 2));
