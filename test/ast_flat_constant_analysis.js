// Run as a sloppy script, a strict script, and a module; also compare the
// debug CLI's --no-optimize mode. Keep arithmetic association observable.
function same(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(String(actual) + ' !== ' + String(expected));
}

same(Function('return ' + Array(256).fill('1').join('+'))(), 256);
same(Function('return ' + Array(128).fill('(1e16 + (-1e16 + 1))').join('+'))(), 0);
same((1e16 + -1e16) + 1, 1);
same(1e16 + (-1e16 + 1), 0);
same(-0 || -0, -0);
same(-0 && 123, -0);
same(-0 ?? 123, -0);
same(null ?? -0, -0);
same((0 / 0) || -0, -0);
same((0 / 0) && 123, NaN);
same((0 / 0) ?? 123, NaN);
same((0 / 0) ? 123 : -0, -0);
same(!(3 < 4), false);
same(!null, true);
same(!false, true);

var effects = 0;
function effect(value) { effects++; return value; }
same((3 > 2) ? effect(7) : 0, 7);
same((3 < 2) ? 0 : effect(8), 8);
same(true && effect(9), 9);
same(false || effect(10), 10);
same(null ?? effect(11), 11);
same(effects, 5);
same(false && effect(12), false);
same(true || effect(13), true);
same(0 ?? effect(14), 0);
same(true ? 15 : effect(16), 15);
same(effects, 5);
same((effect(0), 2) + 3, 5);
same(effects, 6);

// Selected operators still perform GetValue and never supply a call receiver.
var object = { method: function () { 'use strict'; return this; } };
same((true ? (object.method) : 0)(), undefined);
same((false ? 0 : (object.method))(), undefined);
same((true && (object.method))(), undefined);
same((false || (object.method))(), undefined);
same((null ?? (object.method))(), undefined);
same((true ? (object.method) : 0)`tag`, undefined);
same(delete (true ? object.method : 0), true);
same(typeof object.method, 'function');
function indirectEval() {
    var onlyLocal = 1;
    return (true ? eval : 0)('typeof onlyLocal');
}
same(indirectEval(), 'undefined');
function stableLocal() {
    var value = 5;
    same((true ? value : 0) + (value = 9), 14);
    value = 5;
    same((true && value) + (value = 9), 14);
    value = 5;
    same((false || value) + (value = 9), 14);
    value = 5;
    same((null ?? value) + (value = 9), 14);
}
stableLocal();
var coercions = 0;
var coercible = { valueOf: function () { coercions++; return 4; } };
same((true ? coercible : 0) + 2, 6);
same(coercions, 1);

// NamedEvaluation applies to the original expression syntax.
var conditionalFunction = true ? function () {} : 0;
var logicalFunction = true && function () {};
var nullishFunction = null ?? function () {};
var conditionalClass = true ? class {} : 0;
same(conditionalFunction.name, '');
same(logicalFunction.name, '');
same(nullishFunction.name, '');
same(conditionalClass.name, '');
var sourceFunction = true ? function () { return 3 + 4; } : 0;
same(sourceFunction.toString().indexOf('return 3 + 4;') >= 0, true);
same(sourceFunction(), 7);

// Unknown discarded syntax must still be compiled for early errors.
function syntaxError(source) {
    var threw = false;
    try { Function(source); } catch (e) { threw = e instanceof SyntaxError; }
    same(threw, true);
}
syntaxError('return true ? 1 : /[/;');
syntaxError('return false && /[/;');
syntaxError('return true ? 1 : object.#missing;');
syntaxError('"use strict"; return true ? 1 : (eval = 2);');
syntaxError('class A { field = true ? 1 : arguments; }');
same(Function('var eval; return true ? 1 : (eval = 2)')(), 1);

// No statement branch removal: var declarations retain their hoisting.
function hoisted() { if (false) { var value = 3; } return value; }
same(hoisted(), undefined);
print('flat constant analysis ok');
