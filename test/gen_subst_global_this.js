// this-substitution (ES5 §10.4.3) on dynamically-constructed GENERATOR bodies.
//
// FuncFlags.subst_global_this is set only on bodies built by the dynamic
// function constructors (Function/GeneratorFunction/AsyncFunction/
// AsyncGeneratorFunction), so `Function('return this')()` keeps returning the
// global object — a ubiquitous UMD idiom. Ordinary source-declared functions
// never substitute: their undefined receiver stays undefined.
//
// The generator initial-call path in vm_calls.c3 copied the caller-supplied
// receiver verbatim, with none of the subst_global_this coercion every other
// call path performs. That mattered more than a single missed call because
// GEN_START snapshots the activation's this_binding into gs.this_binding and
// every subsequent resume restores that snapshot: a substitution missed at
// creation is missed by the generator for its entire lifetime. So
// GeneratorFunction('yield this')().next().value yielded undefined where a
// plain Function('return this')() correctly returned the global.
//
// The negative cases below matter as much as the positive ones: a fix that
// substitutes unconditionally would hand source-declared generators the global
// object where the spec requires undefined.

var pass = 0;
var fail = 0;
var assert = function (cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } };

var GeneratorFunction = Object.getPrototypeOf(function* () {}).constructor;
var AsyncGeneratorFunction = Object.getPrototypeOf(async function* () {}).constructor;

// --- positive: dynamically-constructed bodies substitute the global ---------

var dynGen = GeneratorFunction('yield this;')().next().value;
assert(dynGen === globalThis,
    'GeneratorFunction("yield this") should yield the global object');

// The plain Function constructor (the already-working reference behaviour).
assert(new Function('return this;')() === globalThis,
    'Function("return this") should return the global object');

// Substitution must survive across multiple resumes, not just the first,
// because each resume restores gs.this_binding rather than recomputing it.
var multi = GeneratorFunction('yield this; yield this; yield this;')();
assert(multi.next().value === globalThis, 'dynamic generator resume 1 should see the global');
assert(multi.next().value === globalThis, 'dynamic generator resume 2 should see the global');
assert(multi.next().value === globalThis, 'dynamic generator resume 3 should see the global');

// An explicit non-null receiver is never overridden by the substitution.
var recv = { tag: 'recv' };
assert(GeneratorFunction('yield this;').call(recv).next().value === recv,
    'an explicit receiver must win over this-substitution');

// --- negative: source-declared generators must NOT substitute ---------------

function* srcGen() { yield this; }
assert(srcGen().next().value === undefined,
    'a source-declared generator with an undefined receiver must yield undefined');

var srcRecv = { tag: 'src' };
assert(srcGen.call(srcRecv).next().value === srcRecv,
    'a source-declared generator must keep its explicit receiver');

var obj = { *method() { yield this; } };
assert(obj.method().next().value === obj,
    'a shorthand generator method must yield its receiver');

// "use strict" in a dynamic body clears subst_global_this.
assert(GeneratorFunction('"use strict"; yield this;')().next().value === undefined,
    'a "use strict" dynamic generator body must not substitute');

// --- async generators: same rule, driven through the microtask queue --------

var agDone = false;
var agOk = false;
AsyncGeneratorFunction('yield this;')().next().then(function (r) {
    agDone = true;
    agOk = r.value === globalThis;
});

async function* srcAsyncGen() { yield this; }
var srcAgDone = false;
var srcAgOk = false;
srcAsyncGen().next().then(function (r) {
    srcAgDone = true;
    srcAgOk = r.value === undefined;
});

// Report from a later microtask so the two above have settled. Asserting that
// each callback actually RAN keeps a silently-skipped reaction from passing.
Promise.resolve().then(function () {}).then(function () {}).then(function () {
    assert(agDone, 'the async-generator reaction never ran');
    assert(agOk, 'AsyncGeneratorFunction("yield this") should yield the global object');
    assert(srcAgDone, 'the source async-generator reaction never ran');
    assert(srcAgOk, 'a source-declared async generator must yield undefined');

    print('gen_subst_global_this: ' + pass + ' passed, ' + fail + ' failed');
    if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
});
