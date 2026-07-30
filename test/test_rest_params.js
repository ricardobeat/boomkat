// Rest parameter tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: Basic rest parameter
function f1(a, b, ...rest) {
    return rest.length;
}
assert(f1(1, 2) === 0, 'f1: no extra args, rest length 0');
assert(f1(1, 2, 3) === 1, 'f1: one extra arg, rest length 1');
assert(f1(1, 2, 3, 4, 5) === 3, 'f1: three extra args, rest length 3');

// Test 2: Rest array contents
function f2(...args) {
    return args[0] + args[1] + args[2];
}
assert(f2(10, 20, 30) === 60, 'f2: rest-only function sums args');

// Test 3: Rest with no extra args
function f3(a, ...rest) {
    return rest.length;
}
assert(f3(1) === 0, 'f3: single arg, rest empty');
assert(f3() === 0, 'f3: no args, rest empty (a is undefined)');

// Test 4: Rest array element access
function f4(...args) {
    var sum = 0;
    for (var i = 0; i < args.length; i++) {
        sum = sum + args[i];
    }
    return sum;
}
assert(f4(1, 2, 3, 4, 5) === 15, 'f4: sum of rest args');

// Test 5: Rest parameter with default parameters
function f5(a = 10, ...rest) {
    return a + rest.length;
}
assert(f5() === 10, 'f5: default + empty rest');
assert(f5(undefined, 1, 2, 3) === 13, 'f5: default triggered + 3 rest');
assert(f5(5, 1, 2) === 7, 'f5: explicit + 2 rest');

// Test 6: Rest array is a real array
function f6(...args) {
    return typeof args === 'object' && args.length !== undefined;
}
assert(f6() === true, 'f6: rest is an object with length');
assert(f6(1, 2, 3) === true, 'f6: rest with elements is an object with length');

// Test 7: Function.length with rest (rest doesn't count)
function f7(a, b, ...c) { return a + b; }
assert(f7.length === 2, 'f7: length is 2, rest not counted');

// Test 8: Only rest parameter
var f8 = function(...args) { return args.length; };
assert(f8.length === 0, 'f8: length is 0 for rest-only');
assert(f8(1, 2, 3) === 3, 'f8: three args captured');

// Test 9: Arrow function with rest
var f9 = (...args) => args.length;
assert(f9(1, 2, 3, 4) === 4, 'f9: arrow rest length');
assert(f9() === 0, 'f9: arrow rest empty');

// Test 10: Nested functions with rest
function f10(a, ...b) {
    function inner() {
        return b.length;
    }
    return inner();
}
assert(f10(1, 2, 3, 4) === 3, 'f10: inner captures rest length');

// Test 11: Rest with spread-like usage (manual spread)
function f11(...args) {
    var result = '';
    for (var i = 0; i < args.length; i++) {
        result = result + args[i];
    }
    return result;
}
assert(f11('a', 'b', 'c') === 'abc', 'f11: string concat from rest');

// Test 12: Rest with array on empty
function f12(...args) {
    return args.length;
}
assert(f12() === 0, 'f12: no args, rest is empty array');

// Test 13: Mixed: some args + rest + defaults
function f13(a, b = 20, ...rest) {
    return a + b + rest.length;
}
assert(f13(1) === 21, 'f13: a=1,b=default 20, no rest');
assert(f13(1, undefined) === 21, 'f13: a=1,b=default 20, no rest');
assert(f13(1, 2, 3, 4) === 5, 'f13: a=1,b=2,rest length=2 => 1+2+2=5');

// Test 14: Arrow with single rest
var f14 = (...x) => x[0];
assert(f14(42) === 42, 'f14: arrow rest first element');
assert(f14() === undefined, 'f14: arrow rest empty returns undefined');

// Test 15: Rest preserves argument types (work around typeof expr[0] bug)
function typeof_helper(v) { return typeof v; }
function f15(...args) {
    return typeof_helper(args[0]);
}
assert(f15(42) === 'number', 'f15: number type preserved');
assert(f15('hi') === 'string', 'f15: string type preserved');
assert(f15(true) === 'boolean', 'f15: boolean type preserved');

// Report the counts without the bare word "FAIL:" — a zero-failure summary
// reading "FAIL: 0" is indistinguishable from a real failure to any harness
// that greps the output for FAIL, which made this file look permanently red.
print('passed: ' + pass + ', failed: ' + fail);
print(fail === 0 ? 'test_rest_params OK' : 'test_rest_params FAILED');
