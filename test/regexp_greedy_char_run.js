// Greedy * and + over a single character test consume the run at once and
// give characters back one at a time when the rest of the pattern fails.
function eq(actual, expected, message) {
    var a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(message + ': got ' + a + ', expected ' + e);
}
function m(re, s) {
    var r = re.exec(s);
    return r === null ? null : [r.index].concat(Array.prototype.slice.call(r));
}

eq(m(/a*ab/, 'aaab'), [0, 'aaab'], 'give back to the last char');
eq(m(/a+a/, 'a'), null, 'plus needs one more');
eq(m(/a+a/, 'aa'), [0, 'aa'], 'plus gives back to its minimum');
eq(m(/x*/, ''), [0, ''], 'empty run');
eq(m(/[a-z]*\d/, 'abc1'), [0, 'abc1'], 'class run');
eq(m(/[^#?]*(\?.*)?/, 'path?q#f'), [0, 'path?q#f', '?q#f'], 'negated class run');
eq(m(/(\w+):(\d*)/, 'host:80x'), [0, 'host:80', 'host', '80'], 'captures around runs');
eq(m(/.*b/, 'aaa\nab'), [4, 'ab'], 'dot stops at a line terminator');
eq(m(/[\s\S]*b/, 'a\nbc'), [0, 'a\nb'], 'any char class');
eq(m(/\s*$/, 'ab  '), [2, '  '], 'space run to the end');
eq(m(/\S+\s/, 'ab cd'), [0, 'ab '], 'non-space run');
eq(m(/A*b/i, 'aAab'), [0, 'aAab'], 'case-insensitive char run');
eq(m(/[A-C]+d/i, 'xabcD'), [1, 'abcD'], 'case-insensitive class run');
eq(m(/(?:a*)*b/, 'aab'), [0, 'aab'], 'run inside a quantified group');
eq(m(/(?:a*b)+c/, 'abaabc'), [0, 'abaabc'], 'run inside a repeated group');
eq(m(/(a*)\1b/, 'aaaab'), [0, 'aaaab', 'aa'], 'back reference after a run');
eq(m(/a*(?=b)/, 'aaab'), [0, 'aaa'], 'lookahead after a run');
eq(m(/(?<=a*)b/, 'aab'), [2, 'b'], 'run inside lookbehind');
eq(m(/(?<=x\d+)y/, 'x12y'), [3, 'y'], 'plus inside lookbehind');
eq(m(/a*?b/, 'aab'), [0, 'aab'], 'lazy run');
eq(m(/a{2,}b/, 'aaab'), [0, 'aaab'], 'counted run');

// Surrogates: a unicode run gives back whole code points.
eq(m(/.*\ude00/u, 'a😀'), null, 'unicode never splits a pair');
eq(m(/.*\ude00/, 'a😀'), [0, 'a😀'], 'non-unicode may split a pair');
eq(m(/[😀]+x/u, '😀😀x'), [0, '😀😀x'], 'astral class run');
eq(m(/\ude00*x/u, '😀x'), [2, 'x'], 'lone low surrogate run');
var r = /.+$/u;
r.lastIndex = 0;
eq(m(r, '😀\ud83d'), [0, '😀\ud83d'], 'run ending in a lone high surrogate');

// Global iteration and empty matches.
eq('a1bb22'.match(/[a-z]*/g), ['a', '', 'bb', '', '', ''], 'global empty runs');
eq('a  b   c'.split(/\s+/), ['a', 'b', 'c'], 'split on a run');
eq('  trim me  '.replace(/^\s+|\s+$/g, ''), 'trim me', 'trim');
var g = /\d+/g;
g.lastIndex = 2;
eq([g.exec('12345')[0], g.lastIndex], ['345', 5], 'global run from lastIndex');
var y = /\d+/y;
y.lastIndex = 1;
eq([y.exec('a12b')[0], y.lastIndex], ['12', 3], 'sticky run');

print('ok');
