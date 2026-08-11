// An error must keep its identity while a microtask queue is live.
//
// With a pending microtask, every uncaught error used to be replaced by the
// opaque string "VM error: vm::VM_ERROR (at execute)" — an internal error enum
// surfacing where the JS error belongs. ReferenceError, TypeError and even an
// explicit `throw new Error("...")` all collapsed onto it, so the message a
// user saw carried no information at all.
//
// Since essentially every real async program has a live microtask queue, this
// was the error reporting users would actually get. The top-level uncaught
// path is asserted from the shell in test/uncaught/; this file covers the
// catchable side, where identity and message must survive the same conditions.
// See plans/070-real-world-battle-testing.md.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}
function caught(fn) {
    try {
        fn();
    } catch (e) {
        return e;
    }
    return null;
}

// Keep a microtask pending for the whole file.
Promise.resolve().then(function () { /* deliberately empty */ });

(function () {
    var e = caught(function () { null.x; });
    assertEq(e instanceof TypeError, true, "TypeError identity survives");
    assertEq(typeof e.message === "string" && e.message.length > 0, true,
        "TypeError keeps a non-empty message");
    assertEq(e.message.indexOf("VM_ERROR") === -1, true,
        "TypeError message is not the internal VM error");
}());

(function () {
    var e = caught(function () { return undefinedGlobalForThisTest; });
    assertEq(e instanceof ReferenceError, true, "ReferenceError identity survives");
    assertEq(e.message.indexOf("VM_ERROR") === -1, true,
        "ReferenceError message is not the internal VM error");
}());

(function () {
    var e = caught(function () { throw new RangeError("explicit message"); });
    assertEq(e instanceof RangeError, true, "explicit RangeError identity survives");
    assertEq(e.message, "explicit message", "explicit message is preserved verbatim");
}());

(function () {
    var e = caught(function () { (1)(); });
    assertEq(e instanceof TypeError, true, "calling a non-function throws TypeError");
}());

// Identity must survive being thrown across an await boundary too.
(function () {
    var seen = null;
    (async function () {
        try {
            await null;
            throw new RangeError("after await");
        } catch (e) {
            seen = e;
        }
    }());
    Promise.resolve().then(function () {
        Promise.resolve().then(function () {
            assertEq(seen instanceof RangeError, true,
                "error thrown after await keeps its identity");
            assertEq(seen && seen.message, "after await",
                "error thrown after await keeps its message");
            report();
        });
    });
}());

// A rejected promise must deliver the original error object to its handler.
(function () {
    var marker = new TypeError("rejection payload");
    Promise.reject(marker).catch(function (e) {
        assertEq(e === marker, true, "rejection delivers the identical error object");
        assertEq(e.message, "rejection payload", "rejection preserves the message");
    });
}());

function report() {
    if (failures === 0) {
        print("PASS: error identity with a live microtask queue");
    } else {
        print("FAILURES: " + failures);
    }
}
