// A destructuring default in a `for await` head may contain `yield`.
//
// The generator suspends while evaluating the default, and the value passed to
// the resuming next() becomes the bound value. See commit 659b5ced.
//
// The bindings are DECLARED. This engine is strict-only, so assigning to an
// undeclared identifier is a ReferenceError — as it is in node under an
// explicit "use strict". An earlier version of this file omitted the
// declarations and relied on the sloppy-mode implicit global; it "passed" in
// qjs and bare node only because those ran it as sloppy, while every
// assertion here sat inside a loop body that consequently never ran. The
// rejections it produced were correct behaviour being mistaken for a bug.
//
// Assertions therefore live OUTSIDE the loop body as well, so a body that
// never executes cannot report a pass.
var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL: " + msg);
    }
}

var bodyRuns = 0;

async function* arrayDefault() {
    var value;
    for await ([value = yield "array"] of [[]]) {
        bodyRuns++;
        assert(value === 11, "array default takes the resume value");
    }
}

async function* objectDefault() {
    var value;
    for await ({value = yield "object"} of [{}]) {
        bodyRuns++;
        assert(value === 22, "object default takes the resume value");
    }
}

var arrayIterator = arrayDefault();
var objectIterator = objectDefault();

// The generator must suspend AT the yield inside the default, handing out the
// yielded operand — not skip it or run the body early.
arrayIterator.next().then(function (r) {
    assert(r.value === "array", "array generator yields the default's operand");
    assert(r.done === false, "array generator is still running");
    return arrayIterator.next(11);
}).then(function (r) {
    assert(r.done === true, "array generator completes after the body runs");
    return objectIterator.next();
}).then(function (r) {
    assert(r.value === "object", "object generator yields the default's operand");
    return objectIterator.next(22);
}).then(function (r) {
    assert(r.done === true, "object generator completes after the body runs");
    // The guard against the earlier false pass: both loop bodies must have
    // actually executed.
    assert(bodyRuns === 2, "both loop bodies ran (got " + bodyRuns + ")");
    print("=== Results: " + pass + " pass, " + fail + " fail ===");
}).catch(function (e) {
    print("FAIL: unexpected rejection: " + e);
    print("=== Results: " + pass + " pass, " + (fail + 1) + " fail ===");
});
