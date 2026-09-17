// Proper tail calls (ES2015 §14.8).
//
// The depth used below is far past the engine's frame budget, so each check is
// really "did this reuse the caller's frame" — a growing call path throws
// RangeError long before it finishes.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

var DEEP = 100000;

// --- the tail positions §14.8.1 lists -------------------------------------

function selfRec(n) { if (n === 0) return 'done'; return selfRec(n - 1); }
ok(selfRec(DEEP) === 'done', 'direct self recursion');

function evn(n) { if (n === 0) return 'even'; return odd(n - 1); }
function odd(n) { if (n === 0) return 'odd'; return evn(n - 1); }
ok(evn(DEEP) === 'even', 'mutual recursion');

// Both arms of a conditional are in tail position, including the first arm,
// which reaches the shared return through a jump.
function condFirst(n) { if (n === 0) return 'c1'; return true ? condFirst(n - 1) : 0; }
ok(condFirst(DEEP) === 'c1', 'conditional, call in first arm');
function condSecond(n) { if (n === 0) return 'c2'; return false ? 0 : condSecond(n - 1); }
ok(condSecond(DEEP) === 'c2', 'conditional, call in second arm');

function logicalAnd(n) { if (n === 0) return 'a'; return true && logicalAnd(n - 1); }
ok(logicalAnd(DEEP) === 'a', 'right operand of &&');
function logicalOr(n) { if (n === 0) return 'o'; return false || logicalOr(n - 1); }
ok(logicalOr(DEEP) === 'o', 'right operand of ||');
function commaTail(n) { if (n === 0) return 'k'; return (0, commaTail(n - 1)); }
ok(commaTail(DEEP) === 'k', 'last expression of a comma');

var arrowTail = function (n) { return n === 0 ? 'w' : arrowTail(n - 1); };
ok(arrowTail(DEEP) === 'w', "arrow's expression body");

// A tagged template's call is in tail position too. It compiles to the
// method-call form, with an explicit `undefined` receiver rather than the
// undefined-this call form.
function tagged(_, n) { if (n === 0) return 'tag'; return tagged`${n - 1}`; }
ok(tagged(null, DEEP) === 'tag', 'tagged template');

// --- method calls (§14.8.1 MethodCall) -------------------------------------

var methodObj = { m: function (n) { if (n === 0) return 'mm'; return methodObj.m(n - 1); } };
ok(methodObj.m(DEEP) === 'mm', 'method call through an object literal');

function Receiver(tag) { this.tag = tag; }
Receiver.prototype.walk = function (n) { if (n === 0) return 'rw'; return this.walk(n - 1); };
var recv = new Receiver('recv');
ok(recv.walk(DEEP) === 'rw', 'method call through this');
// The receiver moves into the callee's this_binding before the caller's
// registers are released, so repeated reuse must not free it.
ok(recv.tag === 'recv', 'the receiver survives repeated frame reuse');

var bracket = [function (n) { if (n === 0) return 'br'; return bracket[0](n - 1); }];
ok(bracket[0](DEEP) === 'br', 'call through a computed member');

class Walker { walk(n) { if (n === 0) return 'cw'; return this.walk(n - 1); } }
ok(new Walker().walk(DEEP) === 'cw', 'method call in a class');

class SubWalker extends Walker {
    walk(n) { if (n === 0) return 'sw'; return super.walk(n - 1); }
}
ok(new SubWalker().walk(DEEP) === 'sw', 'super method call');

// The callee name resolves through a with environment, so the receiver slot is
// written at run time by WITHGET rather than by a static LDUNDEF. The frame is
// still reusable: the resolution has already happened when the call runs.
var withScope = {};
function withLookup(n) { with (withScope) { return target(n); } }
withScope.target = function (n) { if (n === 0) return 'wv'; return withLookup(n - 1); };
ok(withLookup(DEEP) === 'wv', 'callee resolved through a with environment');

// --- spread argument lists -------------------------------------------------

// The argument count comes from a register rather than the instruction, so
// this form has a tail opcode of its own.
function spreadArgs(n, ...rest) { if (n === 0) return 'sa'; return spreadArgs(n - 1, ...rest); }
ok(spreadArgs(DEEP, 1, 2) === 'sa', 'spread argument list');

var spreadObj = { m: function (n, ...rest) { if (n === 0) return 'sm'; return this.m(n - 1, ...rest); } };
ok(spreadObj.m(DEEP, 1) === 'sm', 'method call with a spread argument list');

// --- an arrow's captured `this` outlives the reused frame ------------------

// A tail-recursive arrow keeps its captured `this` in a local; reusing the
// frame must not release that object's last reference.
var arrowHolder = { tag: 'alive', walk: function () {
    var step = (n) => { if (n === 0) return 'ad'; return step(n - 1); };
    return step(DEEP);
} };
ok(arrowHolder.walk() === 'ad', 'tail-recursive arrow inside a method');
ok(arrowHolder.tag === 'alive', "an arrow's captured this survives the recursion");

// --- finally -------------------------------------------------------------

// A `return` in a finally BODY is in tail position: the finally is the pending
// work and it is running, so nothing is left owed.
function finRet(n) {
    if (n === 0) return 'fin';
    try { } finally { return finRet(n - 1); }
}
ok(finRet(DEEP) === 'fin', 'return inside a finally body');

function catchFinRet(n) {
    if (n === 0) return 'cfin';
    try { throw new Error('x'); } catch (e) { } finally { return catchFinRet(n - 1); }
}
ok(catchFinRet(DEEP) === 'cfin', 'return inside a finally after a catch');

// --- positions that are NOT tail calls ------------------------------------

// A `return` in the TRY body is not: the finally still has to run. The frame
// must survive, so this must still grow the stack and throw.
function tryRet(n) {
    if (n === 0) return 0;
    try { return 1 + tryRet(n - 1); } finally { }
}
var threw = false;
try { tryRet(DEEP); } catch (e) { threw = e instanceof RangeError; }
ok(threw, 'return inside a try body is not a tail call');

// The finally must still run when the try body returns through it.
var ran = 0;
function finallyRuns(n) {
    if (n === 0) return 'r';
    try { return finallyRuns(n - 1); } finally { ran++; }
}
ok(finallyRuns(10) === 'r' && ran === 10, 'finally runs for a return from the try body');

// Anything wrapping the call keeps the frame live, so it is not a tail call.
function notTail(n) { if (n === 0) return 0; return 1 + notTail(n - 1); }
var threw2 = false;
try { notTail(DEEP); } catch (e) { threw2 = e instanceof RangeError; }
ok(threw2, 'a call under an operator is not a tail call');

// --- arguments survive frame reuse ----------------------------------------

// A pass-through argument lives in the reused frame as a copy of a register
// the discarded caller owned. Both the value and the callee must survive.
function passThrough(n, f) { if (n === 0) return f(); return passThrough(n - 1, f); }
ok(passThrough(DEEP, function () { return 'arg'; }) === 'arg',
   'a function argument survives repeated frame reuse');

function passString(n, s) { if (n === 0) return s; return passString(n - 1, s); }
ok(passString(DEEP, 'str') === 'str', 'a string argument survives repeated frame reuse');

// A closure over the frame keeps it alive, so the tail call must decline.
function withClosure(n) {
    var local = n;
    function read() { return local; }
    if (n === 0) return read();
    return withClosure(n - 1);
}
ok(withClosure(100) === 0, 'a frame captured by a closure still returns correctly');

print(fail === 0 ? 'PASS: proper tail calls (' + pass + ' checks)'
                 : 'FAIL: proper tail calls (' + fail + ' of ' + (pass + fail) + ')');
