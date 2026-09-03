// An array rest element whose preceding elements already exhausted the
// iterator must bind an empty array WITHOUT calling .next() again
// (ES2024 13.3.3.8 IteratorBindingInitialization: once [[Done]] is true the
// rest is [] and no further IteratorStep happens), and must NOT call
// .return(), because IteratorClose is skipped for an already-done iterator.
//
// Regression: the two rest-collection loops entered unconditionally. The
// element before the rest had latched [[done]] by clearing the iterator
// register to undefined, so the loop called .next() with an undefined
// `this` and threw "TypeError: this is not an object".

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Counting iterable: records every next()/return() call.
var log;
function mk(n) {
    var i = 0;
    return { [Symbol.iterator]: function () {
        return {
            next: function () {
                log.push("next");
                return i < n ? { done: false, value: i++ } : { done: true, value: undefined };
            },
            return: function () { log.push("return"); return { done: true }; }
        };
    } };
}

// --- the exhausted case, across every shape that reaches a rest element ---
log = []; var [a1, ...c1] = [];
check("declaration binds undefined", a1, undefined);
check("declaration rest is empty", c1.length, 0);

log = []; var [a2, b2, ...c2] = [1];
check("two elements, one value", b2, undefined);
check("two elements rest empty", c2.length, 0);

var a3, c3;
log = []; [a3, ...c3] = [];
check("assignment form binds undefined", a3, undefined);
check("assignment form rest empty", c3.length, 0);

log = [];
function param([a, ...c]) { return a + ":" + c.length; }
check("parameter form", param([]), "undefined:0");

log = []; var [a4 = 9, ...c4] = [];
check("default still applies", a4, 9);
check("rest after default is empty", c4.length, 0);

log = []; var o = {}; var a5;
[a5, ...o.rest] = [];
check("member-expression rest target", o.rest.length, 0);

log = []; var [[a6, ...c6] = []] = [];
check("nested pattern rest", c6.length, 0);

log = []; var [, a7, ...c7] = [1];
check("elision then rest", c7.length, 0);

// Non-array iterables take the generic iterator path rather than the
// array fast path, so they exercise the other rest-collection copy.
log = []; var [a8, ...c8] = "";
check("empty string", c8.length, 0);

log = []; var [a9, ...c9] = new Set();
check("empty Set", c9.length, 0);

function* empty() {}
log = []; var [a10, ...c10] = empty();
check("exhausted generator", c10.length, 0);

// --- the observable protocol: exactly one next(), and no return() ---
log = []; var [x1, ...y1] = mk(0);
check("exhausted: one next() call", log.join(","), "next");

log = []; var [x2, ...y2] = mk(2);
check("two values: three next() calls", log.join(","), "next,next,next");
check("two values collected", y2.join(), "1");

log = []; var [x3] = mk(3);
check("partial element closes iterator", log.join(","), "next,return");

// --- non-exhausted rest must still collect everything ---
var [n1, ...n2] = [1, 2, 3];
check("rest collects remaining", n2.join(), "2,3");
var [...n3] = [];
check("bare rest on empty", n3.length, 0);
var [n4, ...n5] = [1];
check("rest exactly at end", n5.length, 0);
check("element before rest", n4, 1);

if (failures === 0) { print("destructure_rest_exhausted_iterator: all checks passed"); }
