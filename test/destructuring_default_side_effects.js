// A destructuring default evaluates in the scope that contains the pattern.
//
// The default is compiled into a zero-argument thunk that resolves its free
// names through the enclosing environment chain, so every binding it touches
// has to be environment-backed rather than held in a register. A write that
// lands in the thunk's own frame instead is lost the moment it returns, which
// is invisible from the value the destructuring produces -- only the side
// effect goes missing.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

// var, let and const declarations.
function varDecl() { var p = 'before'; var [x = (p = 'after')] = []; return p; }
function letDecl() { let p = 'before'; let [x = (p = 'after')] = []; return p; }
function constDecl() { let p = 'before'; const [x = (p = 'after')] = []; return p; }
eq(varDecl(), 'after', 'var array pattern default');
eq(letDecl(), 'after', 'let array pattern default');
eq(constDecl(), 'after', 'const array pattern default');

// Object patterns, both the shorthand and the `key: target` form.
function objShorthand() { var p = 'before'; var { a = (p = 'after') } = {}; return p; }
function objKeyed() { var p = 'before'; var { k: a = (p = 'after') } = {}; return p; }
eq(objShorthand(), 'after', 'object shorthand default');
eq(objKeyed(), 'after', 'object keyed default');

// Assignment destructuring, which binds nothing of its own.
function assignArray() { var p = 'before', x; [x = (p = 'after')] = []; return p; }
function assignObject() { var p = 'before', a; ({ a = (p = 'after') } = {}); return p; }
eq(assignArray(), 'after', 'array assignment default');
eq(assignObject(), 'after', 'object assignment default');

// A default that closes over the outer binding rather than writing it.
function readsOuter() {
    var t = 'outer';
    var [f = function () { return t; }] = [];
    t = 'changed';
    return f();
}
eq(readsOuter(), 'changed', 'a default closure reads the live outer binding');

// The default only runs when the value is undefined, so the side effect must
// not happen otherwise.
function notTaken() { var p = 'before'; var [x = (p = 'after')] = [1]; return p + '/' + x; }
function takenOnUndefined() { var p = 'before'; var [x = (p = 'after')] = [undefined]; return p; }
function takenOnMissingKey() { var p = 'before'; var { a = (p = 'after') } = { b: 1 }; return p; }
function notTakenOnNull() { var p = 'before'; var [x = (p = 'after')] = [null]; return p + '/' + x; }
eq(notTaken(), 'before/1', 'a present element skips the default');
eq(takenOnUndefined(), 'after', 'an explicit undefined takes the default');
eq(takenOnMissingKey(), 'after', 'a missing key takes the default');
eq(notTakenOnNull(), 'before/null', 'null does not take the default');

// Nested patterns.
function nestedArray() { var p = 'before'; var [[x = (p = 'after')] = []] = []; return p; }
function nestedObject() { var p = 'before'; var { a: { b = (p = 'after') } = {} } = {}; return p; }
eq(nestedArray(), 'after', 'a nested array default');
eq(nestedObject(), 'after', 'a nested object default');

// Several defaults in one pattern, each with its own effect, in order.
function ordered() {
    var log = [];
    var [a = log.push('a'), b = log.push('b'), c = log.push('c')] = [];
    return log.join(',');
}
eq(ordered(), 'a,b,c', 'defaults run left to right');

// The catch parameter is a pattern like any other, and its default evaluates
// in the scope outside the catch block, so a `let` in the block does not
// shadow what the default sees (§14.15.3 gives the parameter and the block
// separate Environment Records).
function catchScopes() {
    var probeParam, probeBlock;
    let x = 'outside';
    try { throw []; }
    catch ([_ = probeParam = function () { return x; }]) {
        probeBlock = function () { return x; };
        let x = 'inside';
    }
    return probeBlock() + '/' + probeParam();
}
eq(catchScopes(), 'inside/outside', 'catch parameter and body are separate scopes');

function catchWrites() {
    var p = 'before';
    try { throw []; } catch ([_ = (p = 'after')]) { }
    return p;
}
function catchObjWrites() {
    var p = 'before';
    try { throw {}; } catch ({ a = (p = 'after') }) { }
    return p;
}
eq(catchWrites(), 'after', 'catch array pattern default');
eq(catchObjWrites(), 'after', 'catch object pattern default');

// A parameter default writing an outer binding already worked; it must keep
// working, and must see the enclosing scope rather than the callee's.
var outerForParam = 'before';
function paramDefault(q = (outerForParam = 'after')) { return q; }
paramDefault();
eq(outerForParam, 'after', 'a parameter default writes the enclosing binding');

function paramReadsOuter() {
    var t = 'outer';
    function inner(v = t) { return v; }
    t = 'changed';
    return inner();
}
eq(paramReadsOuter(), 'changed', 'a parameter default reads the live outer binding');

// A default inside a loop runs on every iteration against the same binding.
function inLoop() {
    var n = 0;
    for (var i = 0; i < 3; i++) { var [x = (n = n + 1)] = []; }
    return n;
}
eq(inLoop(), 3, 'a default in a loop writes the same binding each time');

// Deep nesting still reaches the outermost function's binding.
function deep() {
    var p = 'before';
    function mid() { var [x = (p = 'after')] = []; }
    mid();
    return p;
}
eq(deep(), 'after', 'a default in a nested function writes the outer binding');

if (fail === 0) {
    print('PASS: destructuring default side effects (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
