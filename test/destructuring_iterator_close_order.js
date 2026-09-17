// A nested array pattern closes its own iterator when that pattern ends.
//
// IteratorClose is scoped to one ArrayBindingPattern (§8.6.2): the pattern
// closes the iterator it opened as soon as it is finished, before the
// enclosing pattern takes its next step. Closing every iterator together at
// the end of the whole destructuring puts the inner closes after outer steps
// that the spec orders before them, and runs them outermost-first when a
// pattern ends with a nested pattern.
//
// The outermost pattern's own iterator is different: it closes after the
// destructuring, on any completion, which is what the IteratorClose guard
// around the whole operation already does.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

var log;
function eqLog(want, m) {
    var got = log.join(',');
    ok(got === want, m + '\n    got  ' + got + '\n    want ' + want);
}

// An iterator that records every step and every close under its own name.
function it(name, vals) {
    return {
        [Symbol.iterator]: function () {
            var i = 0;
            return {
                next: function () {
                    log.push(name + '.next');
                    return i < vals.length ? { value: vals[i++], done: false } : { done: true };
                },
                return: function () { log.push(name + '.ret'); return { done: true }; }
            };
        }
    };
}
function run(f) { log = []; f(); }

// A nested pattern closes before the outer pattern steps again.
run(function () { var [[a], b] = it('o', [it('i', [1, 2]), 9]); });
eqLog('o.next,i.next,i.ret,o.next,o.ret', 'inner closes before the next outer step');

// It closes even when it is the last element.
run(function () { var [a, [b]] = it('o', [9, it('i', [1, 2])]); });
eqLog('o.next,o.next,i.next,i.ret,o.ret', 'a trailing nested pattern closes, then the outer');

// Siblings each close as they end.
run(function () { var [[a], [b]] = it('o', [it('i1', [1, 2]), it('i2', [3, 4])]); });
eqLog('o.next,i1.next,i1.ret,o.next,i2.next,i2.ret,o.ret', 'siblings close in turn');

// Nesting closes innermost first.
run(function () { var [[[a]]] = it('o', [it('m', [it('i', [1, 2])])]); });
eqLog('o.next,m.next,i.next,i.ret,m.ret,o.ret', 'three levels close inside out');

// An empty nested pattern still opens and closes its iterator.
run(function () { var [[]] = it('o', [it('i', [1])]); });
eqLog('o.next,i.ret,o.ret', 'an empty nested pattern opens and closes');

// A trailing elision is a step, and the pattern closes after it.
run(function () { var [[a, ,]] = it('o', [it('i', [1, 2, 3])]); });
eqLog('o.next,i.next,i.next,i.ret,o.ret', 'an elision is the pattern\'s last step');

// A rest exhausts its iterator, so there is nothing left to close.
run(function () { var [[...r]] = it('o', [it('i', [1, 2])]); });
eqLog('o.next,i.next,i.next,i.next,o.ret', 'a rest exhausts rather than closes');

// An array pattern nested inside an object pattern closes the same way.
run(function () { var [{ p: [a] }] = it('o', [{ p: it('i', [1, 2]) }]); });
eqLog('o.next,i.next,i.ret,o.ret', 'an array inside an object pattern closes');

// Assignment patterns follow the same rule as declarations.
var x, y;
run(function () { [[x], y] = it('o', [it('i', [1, 2]), 9]); });
eqLog('o.next,i.next,i.ret,o.next,o.ret', 'assignment pattern, inner closes first');

// So do function parameters.
function params([[a], b]) { return a; }
run(function () { params(it('o', [it('i', [1, 2]), 9])); });
eqLog('o.next,i.next,i.ret,o.next,o.ret', 'parameter pattern, inner closes first');

// A pattern that consumed every value but never saw `done` has not exhausted
// its iterator, so it still closes it. Only a step that reports done leaves
// nothing to close.
run(function () { var [[a, b]] = it('o', [it('i', [1, 2])]); });
eqLog('o.next,i.next,i.next,i.ret,o.ret', 'taking every value still closes');
run(function () { var [[a, b, c]] = it('o', [it('i', [1])]); });
eqLog('o.next,i.next,i.next,o.ret', 'a done step leaves nothing to close');

// A throw still closes every open iterator, innermost first.
run(function () {
    try {
        var [[a, b]] = it('o', [it('i', [1, 2, 3])]);
        throw new Error('x');
    } catch (e) {}
});
ok(log.join(',') === 'o.next,i.next,i.next,i.ret,o.ret',
   'a throw after the pattern leaves nothing open (got ' + log.join(',') + ')');

// The values still land where they belong.
var got = [];
(function () { var [[a, b], c] = [[1, 2], 3]; got = [a, b, c]; })();
ok(got.join(',') === '1,2,3', 'nested values bind correctly (got ' + got.join(',') + ')');

var deep;
(function () { var [[[v]]] = [[[7]]]; deep = v; })();
ok(deep === 7, 'a deeply nested value binds correctly (got ' + deep + ')');

var withRest;
(function () { var [[a, ...r]] = [[1, 2, 3]]; withRest = a + ':' + r.join(','); })();
ok(withRest === '1:2,3', 'a nested rest binds correctly (got ' + withRest + ')');

if (fail === 0) {
    print('PASS: nested iterator close order (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
