// Default parameter tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: Simple default parameter
function f1(a, b = 10) {
    return a + b;
}
assert(f1(5) === 15, 'f1: default used');
assert(f1(5, 20) === 25, 'f1: explicit overrides default');
assert(f1(5, undefined) === 15, 'f1: undefined triggers default');

// Test 2: Multiple default parameters
function f2(a = 1, b = 2, c = 3) {
    return a + b + c;
}
assert(f2() === 6, 'f2: all defaults');
assert(f2(10) === 15, 'f2: first explicit');
assert(f2(10, 20) === 33, 'f2: first two explicit');
assert(f2(10, 20, 30) === 60, 'f2: all explicit');

// Test 3: Default referencing earlier parameter
function f3(a, b = a + 1) {
    return b;
}
assert(f3(5) === 6, 'f3: default references earlier param');
assert(f3(5, 100) === 100, 'f3: explicit overrides default');

// Test 4: Default with complex expression
function f4(a, b = a * 2 + 1) {
    return b;
}
assert(f4(3) === 7, 'f4: complex default expression');
assert(f4(3, 99) === 99, 'f4: explicit overrides complex default');

// Test 5: Default with string expression
function f5(name = 'World') {
    return 'Hello ' + name;
}
assert(f5() === 'Hello World', 'f5: string default');
assert(f5('Alice') === 'Hello Alice', 'f5: explicit string');

// Test 6: Default with boolean
function f6(flag = true) {
    return flag;
}
assert(f6() === true, 'f6: boolean default true');
assert(f6(false) === false, 'f6: explicit false');

// Test 7: Undefined passed explicitly triggers default
function f7(x = 42) {
    return x;
}
var u7;
assert(f7(u7) === 42, 'f7: undefined var triggers default');
assert(f7(undefined) === 42, 'f7: literal undefined triggers default');
assert(f7(null) === null, 'f7: null does NOT trigger default');

// Test 8: Multiple defaults referencing earlier params
function f8(a = 1, b = a + 1, c = b + 1) {
    return a + b + c;
}
assert(f8() === 6, 'f8: chain defaults: 1+2+3');
assert(f8(10) === 33, 'f8: chain defaults 10+11+12=33');

// Test 9: Default with function call
function addOne(x) { return x + 1; }
function f9(a = addOne(5)) {
    return a;
}
assert(f9() === 6, 'f9: default calls function');
assert(f9(100) === 100, 'f9: explicit overrides function call default');

// Test 10: Default parameters and inner function
function f10(a = 5) {
    function inner() {
        return a;
    }
    return inner();
}
assert(f10() === 5, 'f10: inner sees default');
assert(f10(20) === 20, 'f10: inner sees explicit');

// Test 11: Default in function expression
var f11 = function(a = 100) {
    return a;
};
assert(f11() === 100, 'f11: default in function expression');
assert(f11(50) === 50, 'f11: explicit in function expression');

// Test 12: First param with default, second without (not all args passed)
function f12(a = 10, b) {
    return a + (b === undefined ? 0 : b);
}
assert(f12() === 10, 'f12: only default used, second param undefined');
assert(f12(1) === 1, 'f12: first explicit, second undefined');
assert(f12(1, 2) === 3, 'f12: both explicit');
assert(f12(undefined, 5) === 15, 'f12: first undefined triggers default, second explicit');

// Report the counts without the bare word "FAIL:" — a zero-failure summary
// reading "FAIL: 0" is indistinguishable from a real failure to any harness
// that greps the output for FAIL, which made this file look permanently red.
print('passed: ' + pass + ', failed: ' + fail);
print(fail === 0 ? 'test_default_params OK' : 'test_default_params FAILED');
