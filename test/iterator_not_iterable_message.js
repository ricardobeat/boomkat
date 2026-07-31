// GetIterator failure reporting.
//
// for-of and array destructuring compile the iterator protocol to a plain
// GETPROP + CALL, so a source with no @@iterator reported "undefined is not a
// function" — describing the engine's internal lookup rather than the user's
// mistake, and implying something was called. Every iteration form must instead
// say the value is not iterable, and must keep the separate "not a function"
// wording for the different mistake of a present-but-non-callable @@iterator.
//
// Message TEXT is asserted only where it is engine-independent: this file
// checks the error TYPE everywhere, the "is not iterable" / "is not a function"
// distinction, and that no message leaks an internal key. It deliberately does
// NOT assert V8's source-text reconstruction ("([1] , [2])[0]"), which node
// produces from its own CallPrinter.
//
// Runs unmodified under node; counts must match.
var failures = 0;
function check(cond, msg) {
    if (!cond) {
        failures++;
        print("FAIL: " + msg);
    }
}

// Returns {type, message} for the error a thunk throws, or null if none.
function grab(f) {
    try { f(); return null; }
    catch (e) { return { type: e.constructor.name, message: String(e.message) }; }
}

function expectNotIterable(label, f) {
    var e = grab(f);
    if (e === null) { failures++; print("FAIL: " + label + " did not throw"); return; }
    check(e.type === "TypeError", label + " throws TypeError (got " + e.type + ")");
    check(/is not (async )?iterable/.test(e.message),
        label + ' says "is not iterable" (got: ' + e.message + ")");
    // The old message. Its return would mean the protocol lookup is leaking again.
    check(!/is not a function/.test(e.message),
        label + " does not blame a function call (got: " + e.message + ")");
    // The message must not be a raw property-access failure. node mentions the
    // @@iterator key parenthetically in some forms, so the check targets the
    // "Cannot read properties of X" shape specifically, which is what a
    // missing pre-check on a null/undefined source produced.
    check(!/Cannot read propert/.test(e.message),
        label + " is not a raw property-read failure (got: " + e.message + ")");
}

// A present but NON-CALLABLE @@iterator is a different mistake, and node keeps
// a different wording for it. Do not flatten the two.
function expectNotAFunction(label, f) {
    var e = grab(f);
    if (e === null) { failures++; print("FAIL: " + label + " did not throw"); return; }
    check(e.type === "TypeError", label + " throws TypeError (got " + e.type + ")");
    check(/is not (a function|iterable)/.test(e.message),
        label + " reports the bad @@iterator (got: " + e.message + ")");
}

// --- Non-iterable sources, across every iteration form ---
expectNotIterable("for-of number",        function () { for (var x of 5) {} });
expectNotIterable("for-of undefined",     function () { for (var x of undefined) {} });
expectNotIterable("for-of null",          function () { for (var x of null) {} });
expectNotIterable("for-of plain object",  function () { for (var x of {}) {} });
expectNotIterable("for-of boolean",       function () { for (var x of true) {} });

expectNotIterable("destructuring number",    function () { var [a] = 5; });
expectNotIterable("destructuring undefined", function () { var [a] = undefined; });
expectNotIterable("destructuring null",      function () { var [a] = null; });
expectNotIterable("destructuring object",    function () { var [a] = {}; });

expectNotIterable("spread number",    function () { return [...5]; });
expectNotIterable("spread undefined", function () { return [...undefined]; });
expectNotIterable("spread null",      function () { return [...null]; });
expectNotIterable("spread object",    function () { return [...{}]; });

expectNotIterable("yield* number", function () {
    function* g() { yield* 5; }
    return [...g()];
});
expectNotIterable("yield* object", function () {
    function* g() { yield* {}; }
    return [...g()];
});

// The bug report's own case: the operand is the value 2, not the array literal.
expectNotIterable("for-of comma-expression operand", function () {
    for (var x of ([1], [2])[0]) {}
});

// --- Present but non-callable @@iterator: the OTHER wording ---
expectNotAFunction("for-of non-callable @@iterator", function () {
    for (var x of { [Symbol.iterator]: 1 }) {}
});
expectNotAFunction("destructuring non-callable @@iterator", function () {
    var [a] = { [Symbol.iterator]: 1 };
});

// --- An @@iterator that returns a non-object is its own TypeError ---
function expectResultNotObject(label, f) {
    var e = grab(f);
    if (e === null) { failures++; print("FAIL: " + label + " did not throw"); return; }
    check(e.type === "TypeError", label + " throws TypeError (got " + e.type + ")");
    check(/is not an object/.test(e.message),
        label + ' says "is not an object" (got: ' + e.message + ")");
}
expectResultNotObject("for-of non-object iterator result", function () {
    for (var x of { [Symbol.iterator]: function () { return 42; } }) {}
});
expectResultNotObject("destructuring non-object iterator result", function () {
    var [a] = { [Symbol.iterator]: function () { return 42; } };
});
expectResultNotObject("spread non-object iterator result", function () {
    return [...{ [Symbol.iterator]: function () { return 42; } }];
});

// --- An @@iterator getter that throws propagates ITS error, unchanged ---
var boom = grab(function () {
    for (var x of { get [Symbol.iterator]() { throw new RangeError("boom"); } }) {}
});
check(boom !== null && boom.type === "RangeError" && boom.message === "boom",
    "a throwing @@iterator getter propagates its own error");

// --- Things that ARE iterable must still iterate ---
var acc = [];
for (var c of "ab") acc.push(c);
check(acc.join("") === "ab", "string is still iterable");
acc = [];
for (var n of [1, 2, 3]) acc.push(n);
check(acc.join(",") === "1,2,3", "array is still iterable");
var [p, q] = [7, 8];
check(p === 7 && q === 8, "array destructuring still works");
check([...[1, 2]].join(",") === "1,2", "spread still works");
check([..."ab"].join(",") === "a,b", "string spread still works");
function* gen() { yield* [1, 2]; }
check([...gen()].join(",") === "1,2", "yield* still works");
var m = new Map([["k", "v"]]);
acc = [];
for (var e of m) acc.push(e[0] + "=" + e[1]);
check(acc.join(",") === "k=v", "Map is still iterable");

// --- for-await-of: same rules, via GET_ITER_ASYNC ---
// Graded off Promise.all so the report cannot run before the jobs settle.
var awaitChecks = [];
function expectAsyncNotIterable(label, v) {
    awaitChecks.push(
        (async function () { for await (var x of v) {} })().then(
            function () { failures++; print("FAIL: " + label + " did not throw"); },
            function (e) {
                check(e instanceof TypeError, label + " throws TypeError");
                check(/is not (async )?iterable/.test(String(e.message)),
                    label + ' says "is not iterable" (got: ' + e.message + ")");
                check(!/Cannot read propert/.test(String(e.message)),
                    label + " is not a raw property-read failure (got: " + e.message + ")");
            }));
}
expectAsyncNotIterable("for-await number", 5);
expectAsyncNotIterable("for-await plain object", {});

// null/undefined under for-await are asserted on TYPE only: node reports these
// as a raw property read on @@asyncIterator, while this engine names the value.
// Ours is the better message, but the shared assertion is the error type.
function expectAsyncTypeError(label, v) {
    awaitChecks.push(
        (async function () { for await (var x of v) {} })().then(
            function () { failures++; print("FAIL: " + label + " did not throw"); },
            function (e) { check(e instanceof TypeError, label + " throws TypeError"); }));
}
expectAsyncTypeError("for-await null", null);
expectAsyncTypeError("for-await undefined", undefined);

// A sync-iterable primitive must still iterate under for-await: the source is
// boxed so String.prototype[@@iterator] is reachable.
awaitChecks.push((async function () {
    var got = [];
    for await (var c of "ab") got.push(c);
    check(got.join("") === "ab", "for-await over a string still iterates");
})());
awaitChecks.push((async function () {
    var got = [];
    for await (var n of [1, 2]) got.push(n);
    check(got.join(",") === "1,2", "for-await over an array still iterates");
})());

Promise.all(awaitChecks).then(report, function (e) {
    failures++;
    print("FAIL: for-await harness itself threw: " + e);
    report();
});

function report() {
if (failures === 0) {
    print("PASS");
} else {
    print("FAILURES: " + failures);
}
}
