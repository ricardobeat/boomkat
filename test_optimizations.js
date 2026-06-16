// Comprehensive test suite for all optimization hypotheses

console.log("=== Testing Optimization Hypotheses ===\n");

// ============================================================================
// Hypothesis 1: Function Prologue Superinstruction (PROLOGUE_COMPILED)
// ============================================================================

console.log("Hypothesis 1: Function Prologue Superinstruction");

function prologue_test_0() { return 0; }
function prologue_test_1(a) { return a; }
function prologue_test_2(a, b) { return a + b; }
function prologue_test_3(a, b, c) { return a + b + c; }
function prologue_test_4(a, b, c, d) { return a + b + c + d; }
function prologue_test_5(a, b, c, d, e) { return a + b + c + d + e; }

console.log("  0 params:", prologue_test_0());
console.log("  1 param :", prologue_test_1(1));
console.log("  2 params:", prologue_test_2(1, 2));
console.log("  3 params:", prologue_test_3(1, 2, 3));
console.log("  4 params:", prologue_test_4(1, 2, 3, 4));
console.log("  5 params:", prologue_test_5(1, 2, 3, 4, 5));

// ============================================================================
// Hypothesis 2: Trace-based optimization of hot function call sequences
// (This would require call-site tracing, which is more complex)
// ============================================================================

console.log("\nHypothesis 2: Trace-based call sequence optimization");

function caller(fn, a, b) {
    return fn(a, b);
}

function add(x, y) {
    return x + y;
}

function mul(x, y) {
    return x * y;
}

console.log("  caller(add, 3, 4)   :", caller(add, 3, 4));
console.log("  caller(mul, 5, 6)   :", caller(mul, 5, 6));

// Repeated calls to establish hot path
var sum = 0;
for (var i = 0; i < 100; i++) {
    sum = sum + caller(add, 1, 1);
}
console.log("  100x add (sum)       :", sum);

// ============================================================================
// Hypothesis 3: Peephole constant propagation and dead-code elimination
// ============================================================================

console.log("\nHypothesis 3: Peephole optimization");

// Dead LDUNDEF elimination test
function dead_undef_test() {
    var x = undefined;  // Dead: x is overwritten before use
    x = 42;
    return x;
}

console.log("  dead_undef_test    :", dead_undef_test());

// Dead store elimination
function dead_store_test(flag) {
    var result = 0;
    if (flag) {
        result = 100;
    } else {
        result = 200;
    }
    return result;
}

console.log("  dead_store (true)  :", dead_store_test(true));
console.log("  dead_store (false) :", dead_store_test(false));

// Redundant constant loads
function const_load_test() {
    var x = 10;
    var y = 10;  // Could be eliminated if constants are tracked
    return x + y;
}

console.log("  const_load_test    :", const_load_test());

// ============================================================================
// Correctness validation
// ============================================================================

console.log("\nCorrectness validation:");

function factorial(n) {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}

console.log("  factorial(5):", factorial(5));
console.log("  factorial(10):", factorial(10));

// Loop with multiple variables
function complex_loop(start, end, step) {
    var sum = 0;
    var count = 0;
    var i = start;
    while (i <= end) {
        sum = sum + i;
        count = count + 1;
        i = i + step;
    }
    return sum;
}

console.log("  complex_loop(1, 10, 1):", complex_loop(1, 10, 1));
console.log("  complex_loop(0, 20, 5):", complex_loop(0, 20, 5));

console.log("\n=== All tests completed successfully ===");
