// Direct eval is keyed on the callee being a Reference named "eval".
//
// EvaluateCall (§13.3.6.1) asks whether the callee evaluated to a Reference
// whose name is "eval" and which resolves to %eval%. Parentheses are
// transparent to that -- CoverParenthesizedExpression evaluates to the inner
// expression's own Reference -- so `(eval)(x)` is direct and sees the calling
// scope. A comma or a conditional produces a value rather than a Reference, so
// `(0, eval)(x)` and `(c ? eval : null)(x)` are indirect and run in global
// scope, whichever branch of the conditional supplies the function.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

var t = 'global';

// Parentheses keep the Reference.
function grouped() { var t = 'local'; return (eval)('t'); }
function doubleGrouped() { var t = 'local'; return ((eval))('t'); }
eq(grouped(), 'local', '(eval) is direct');
eq(doubleGrouped(), 'local', '((eval)) is direct');

// A comma yields a value.
function comma() { var t = 'local'; return (1, eval)('t'); }
function commaChain() { var t = 'local'; return (1, 2, eval)('t'); }
eq(comma(), 'global', '(1, eval) is indirect');
eq(commaChain(), 'global', '(1, 2, eval) is indirect');

// A conditional yields a value, from either branch.
function ternTrue() { var t = 'local'; return (true ? eval : null)('t'); }
function ternEmptyString() { var t = 'local'; return ('' ? null : eval)('t'); }
function ternZero() { var t = 'local'; return (0 ? null : eval)('t'); }
function ternNaN() { var t = 'local'; return (0 / 0 ? null : eval)('t'); }
eq(ternTrue(), 'global', 'eval as the consequent is indirect');
eq(ternEmptyString(), 'global', 'eval as the alternate is indirect ("")');
eq(ternZero(), 'global', 'eval as the alternate is indirect (0)');
eq(ternNaN(), 'global', 'eval as the alternate is indirect (NaN)');

// Reading eval into a variable loses the Reference too.
function viaVariable() { var t = 'local'; var e = eval; return e('t'); }
eq(viaVariable(), 'global', 'a copied eval is indirect');

// A plain call is direct.
function plain() { var t = 'local'; return eval('t'); }
eq(plain(), 'local', 'a bare eval call is direct');

// A property access is never the `eval` Reference.
function viaProperty() {
    var t = 'local';
    var o = { eval: eval };
    return o.eval('t');
}
eq(viaProperty(), 'global', 'o.eval is indirect');

// Direct eval sees let and const bindings of the calling block, not just var.
function letScope() {
    let u = 'block';
    return (eval)('u');
}
eq(letScope(), 'block', '(eval) sees a let binding');

// An indirect eval cannot see them at all.
function indirectCannotSee() {
    let hidden = 'block';
    try { (0, eval)('hidden'); return 'saw it'; }
    catch (e) { return e instanceof ReferenceError ? 'hidden' : 'other'; }
}
eq(indirectCannotSee(), 'hidden', 'an indirect eval cannot see a block binding');

// Directness is a property of the call site, not of the body. One function can
// hold both kinds, in either order, and each keeps its own scope.
function directThenIndirect() {
    var t = 'local';
    return eval('t') + '/' + (0, eval)('t');
}
function indirectThenDirect() {
    var t = 'local';
    var i = (0, eval)('t');
    return eval('t') + '/' + i;
}
function manyMixed() {
    var t = 'local';
    return [(0, eval)('t'), eval('t'), (eval)('t'), (0, eval)('t'), eval('t')].join(',');
}
eq(directThenIndirect(), 'local/global', 'direct then indirect in one body');
eq(indirectThenDirect(), 'local/global', 'indirect then direct in one body');
eq(manyMixed(), 'global,local,local,global,local', 'five mixed calls in one body');

// The same holds for a call with spread arguments, which compiles to a
// different call instruction.
function spreadDirect() { var t = 'local'; var a = ['t']; return eval(...a); }
function spreadIndirect() { var t = 'local'; var a = ['t']; return (0, eval)(...a); }
eq(spreadDirect(), 'local', 'a spread direct eval sees the calling scope');
eq(spreadIndirect(), 'global', 'a spread indirect eval does not');

// A direct eval in a loop stays direct on every iteration.
function inLoop() {
    var t = 'local', out = [];
    for (var i = 0; i < 3; i++) { out.push(eval('t')); out.push((0, eval)('t')); }
    return out.join(',');
}
eq(inLoop(), 'local,global,local,global,local,global', 'a loop keeps each call site');

// Both forms still evaluate their argument and return its value.
eq((0, eval)('1 + 1'), 2, 'an indirect eval still evaluates');
eq((eval)('1 + 1'), 2, 'a grouped eval still evaluates');
eq(eval('1 + 1'), 2, 'a direct eval still evaluates');

// A non-string argument passes through untouched, either way.
var obj = {};
ok(eval(obj) === obj, 'a direct eval returns a non-string unchanged');
ok((0, eval)(obj) === obj, 'an indirect eval returns a non-string unchanged');

if (fail === 0) {
    print('PASS: direct eval is a Reference (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
