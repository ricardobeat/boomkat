// Bench 7: Closures
function makeCounter(start) {
    var n = start;
    return function() { n = n + 1; return n; };
}
var c1 = makeCounter(0);
var c2 = makeCounter(100);
var sum = 0;
for (var i = 0; i < 50000; i++) {
    sum += c1();
    sum += c2();
}
