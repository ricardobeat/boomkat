// Strictness belongs to a body, not to the lexer that reads it.
//
// The compiler shares one Lexer across nested compilation contexts, and the
// lexer carries two mode bits: which FutureReservedWords are keywords, and
// whether legacy octals are legal. A nested body that runs strict -- a "use
// strict" function, an arrow, a class body, a static block, a parameter
// default, a computed key -- has to set those bits and put them back, or the
// rest of the enclosing sloppy script is read under the wrong mode.
//
// This file is sloppy on purpose: every check below is something a sloppy
// script may do, placed after a construct that is strict inside.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

// Assigning a restricted name is legal in sloppy code and a SyntaxError in
// strict code, so it witnesses the reserved-name half of the mode. The witness
// is `arguments` rather than `eval`, because the checks further down call the
// real `eval` and must not have overwritten it.
var realEval = eval;
function assignArgumentsWorks(label) {
    arguments = label;
    ok(arguments === label, label);
}

function f1() { "use strict"; return 1; }
assignArgumentsWorks('after a "use strict" function declaration');

var f2 = function () { "use strict"; return 2; };
assignArgumentsWorks('after a "use strict" function expression');

var f3 = () => { "use strict"; return 3; };
assignArgumentsWorks('after a "use strict" arrow');

var f4 = { m() { "use strict"; return 4; } };
assignArgumentsWorks('after a "use strict" object method');

class C1 { m() { return 5; } }
assignArgumentsWorks('after a class declaration');

class C2 { static { var unused = 6; } }
assignArgumentsWorks('after a class with a static block');

var C3 = class { m() { return 7; } };
assignArgumentsWorks('after a class expression');

class C4 { ['computed']() { return 8; } }
assignArgumentsWorks('after a class with a computed method key');

function f5(a = 9) { return a; }
assignArgumentsWorks('after a parameter default');

// Legacy octals are the other half of the mode: legal in sloppy code, a
// SyntaxError in strict code.
ok(0777 === 511, 'a legacy octal literal still parses after strict bodies');

// A destructuring default is compiled in its own context, which must not
// leave the pattern that follows it being read as strict. `arguments` and
// `eval` are ordinary binding names in sloppy code.
var arguments0, eval0;
(function () {
    var o = {};
    ({ a = 1, arguments: arguments0 = 2 } = o);
    ok(arguments0 === 2, 'a default does not make the next property strict');
    var arr = [];
    var x, y;
    [x = 1, y = 2] = arr;
    ok(x === 1 && y === 2, 'array pattern defaults');
})();

// The same shape with restricted names as the targets themselves.
var e1, a1;
({ p = 1, q: e1 = 'e' } = {});
ok(e1 === 'e', 'a restricted-looking target after a default');

// Nested strict bodies restore the mode for the code after them, at every
// depth.
function outer() {
    function middle() { "use strict"; function inner() { return 1; } return inner(); }
    var n = 0777;
    return n;
}
ok(outer() === 511, 'a nested strict function restores the enclosing mode');

// Strictness still applies where it should: inside these bodies.
function throwsSyntaxError(src, m) {
    try { realEval(src); fail++; print('FAIL: ' + m + ' (did not throw)'); }
    catch (e) { ok(e instanceof SyntaxError, m); }
}
throwsSyntaxError('function s() { "use strict"; eval = 1; }',
                  'a strict function body still rejects an eval assignment');
throwsSyntaxError('class K { m() { eval = 1; } }',
                  'a class body is strict throughout');
throwsSyntaxError('class K { static { eval = 1; } }',
                  'a static block is strict');
throwsSyntaxError('function s() { "use strict"; return 0777; }',
                  'a strict function body still rejects a legacy octal');
throwsSyntaxError('class K { m() { return 0777; } }',
                  'a class body still rejects a legacy octal');

if (fail === 0) {
    print('PASS: strictness does not leak (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
