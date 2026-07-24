// Function call overhead benchmark
var N = 2500000;

function empty() { return; }
function identity(x) { return x; }
function add2(a, b) { return a + b; }

var i;
var sum = 0;

// Empty function call
for (i = 0; i < N; i++) { empty(); }

// Identity function call
for (i = 0; i < N; i++) { sum += identity(42); }

// Two-argument function call
for (i = 0; i < N; i++) { sum += add2(3, 7); }

print(sum);
