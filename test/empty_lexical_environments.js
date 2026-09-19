function assertEqual(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

function nestedExits() {
    let sum = 0;
    let cleanups = 0;
    outer: for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
            let value = i * 10 + j;
            try {
                if (i === 2) break outer;
                if (j === 1) continue;
                sum += value;
            } finally {
                let increment = 1;
                cleanups += increment;
            }
        }
    }
    return sum + cleanups * 100;
}
assertEqual(nestedExits(), 940, "nested break/continue/finally");

var cleanupValue = 0;
function returnThroughFinally() {
    let value = 7;
    try {
        let inner = value + 1;
        return inner;
    } finally {
        let finalValue = value + 2;
        cleanupValue = finalValue;
    }
}
assertEqual(returnThroughFinally(), 8, "return value");
assertEqual(cleanupValue, 9, "finally value");

function throwThroughFinally() {
    try {
        let value = 17;
        throw value;
    } finally {
        let finalValue = 23;
        cleanupValue = finalValue;
    }
}
var thrown;
try { throwThroughFinally(); } catch (error) { thrown = error; }
assertEqual(thrown, 17, "throw value");
assertEqual(cleanupValue, 23, "throw cleanup");

function constScope() {
    const fixed = 4;
    { let temporary = 2; }
    fixed = 5;
}
var constError = false;
try { constScope(); } catch (error) { constError = error instanceof TypeError; }
assertEqual(constError, true, "const environment survives");

var shadowed = 99;
function tdzScope() {
    { let temporary = 2; }
    { let shadowed = shadowed; }
}
var tdzError = false;
try { tdzScope(); } catch (error) { tdzError = error instanceof ReferenceError; }
assertEqual(tdzError, true, "TDZ environment survives");

function capturedScopes() {
    let closures = [];
    for (let i = 0; i < 3; i++) {
        let value = i * 2;
        closures.push(function () { return value; });
    }
    return closures[0]() + closures[1]() * 10 + closures[2]() * 100;
}
assertEqual(capturedScopes(), 420, "captured block identity");

function evalScope() {
    let value = 7;
    { let value = 11; return eval("value"); }
}
assertEqual(evalScope(), 11, "eval block binding");
print("PASS empty lexical environments");
