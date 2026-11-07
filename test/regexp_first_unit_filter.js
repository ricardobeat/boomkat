// Unsticky regexps skip start positions whose code unit cannot begin a match.
// These cases exercise the boundary of that filter.
function eq(actual, expected, message) {
    var a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(message + ': got ' + a + ', expected ' + e);
}
function m(re, s) {
    var r = re.exec(s);
    return r === null ? null : [r.index].concat(Array.prototype.slice.call(r));
}

// Classes, alternation and optional prefixes.
eq(m(/[0-9]+px/, 'width: 120px'), [7, '120px'], 'digit class');
eq(m(/(?:foo|bar)baz/, 'xxbarbaz'), [2, 'barbaz'], 'alternation');
eq(m(/a?b/, 'xxb'), [2, 'b'], 'optional first char');
eq(m(/\s+x/, 'ab \t x'), [2, ' \t x'], 'space class');
eq(m(/\S+/, '   hi'), [3, 'hi'], 'non-space class');
eq(m(/[^a]b/, 'aab'), null, 'negated class');
eq(m(/[^a]b/, '\u0100b'), [0, '\u0100b'], 'negated class wide unit');
eq(m(/.z/, '\nz yz'), [3, 'yz'], 'dot');
eq(m(/x*/, 'abc'), [0, ''], 'empty match');
eq(m(/(?=b)\w/, 'abc'), [1, 'b'], 'lookahead');
eq(m(/(?<=a)b/, 'bab'), [2, 'b'], 'lookbehind');
eq(m(/(?<!a)b/, 'abcb'), [3, 'b'], 'negative lookbehind');
eq(m(/\bfoo/, 'xfoo foo'), [5, 'foo'], 'word boundary');
eq(m(/^b/m, 'a\nb'), [2, 'b'], 'multiline anchor');
eq(m(/(a)\1/, 'xaab'), [1, 'aa', 'a'], 'back reference');
eq(/(?<y>\d{4})-(?<m>\d\d)/.exec('on 2024-05').groups.m, '05', 'named groups');
eq(m(/(x)?y|(z)/, 'zy'), [0, 'z', null, 'z'], 'captures reset per position');

// Case folding, including units >= 256 that fold into Latin-1.
eq(m(/K/i, 'xk'), [1, 'k'], 'icase literal');
eq(m(/[a-c]z/i, 'xxBZ'), [2, 'BZ'], 'icase class');
eq(m(/s/iu, 'x\u017f'), [1, '\u017f'], 'long s folds to s');
eq(m(/k/iu, 'x\u212a'), [1, '\u212a'], 'kelvin folds to k');
eq(m(/\u00e9t/i, 'x\u00c9T'), [1, '\u00c9T'], 'icase latin-1');

// Wide strings and surrogates.
eq(m(/[\u0400-\u04ff]+/, 'abc\u0416\u0417'), [3, '\u0416\u0417'], 'cyrillic range');
eq(m(/\ud83d\ude00/u, 'a\ud83d\ude00'), [1, '\ud83d\ude00'], 'astral literal');
eq(m(/\ude00/u, '\ud83d\ude00'), null, 'unicode never starts mid-pair');
eq(m(/\ude00/, '\ud83d\ude00'), [1, '\ude00'], 'non-unicode may start mid-pair');
eq(m(/[\ude00x]/u, '\ud83d\ude00x'), [2, 'x'], 'unicode class skips a pair');
eq(m(/./u, '\ud83d\ude00'), [0, '\ud83d\ude00'], 'unicode dot');
eq(m(/b/, '\u0100ab'), [2, 'b'], 'latin-1 char in a wide string');

// Global and sticky lastIndex.
var g = /\d+/g;
var s = 'a1b22c333';
eq([g.exec(s)[0], g.lastIndex, g.exec(s)[0], g.lastIndex, g.exec(s)[0], g.exec(s), g.lastIndex],
   ['1', 2, '22', 5, '333', null, 0], 'global lastIndex');
var y2 = /\d/y;
y2.lastIndex = 0;
eq(y2.exec('a1'), null, 'sticky does not search');
eq(y2.lastIndex, 0, 'sticky failure resets lastIndex');
y2.lastIndex = 1;
eq(y2.exec('a1')[0], '1', 'sticky at position');

// String methods.
eq('a1b22c'.replace(/[0-9]+/g, '#'), 'a#b#c', 'replace');
eq('a, b,c'.split(/,\s*/), ['a', 'b', 'c'], 'split');
eq('x1y2'.match(/\d/g), ['1', '2'], 'match');
eq('hello world'.search(/o\s/), 4, 'search');
eq(Array.from('a1b2'.matchAll(/[a-z](\d)/g), function (r) { return r[1]; }), ['1', '2'], 'matchAll');
eq('aaa'.replace(/(?:)/g, '-'), '-a-a-a-', 'empty pattern');

// A long run of non-candidates before the match.
var long = new Array(2001).join('.') + 'X';
eq(m(/[XY]$/, long), [2000, 'X'], 'long skip');

// Whole-literal patterns and literal searches in both string widths.
eq(m(/d1/, 'xd2d1'), [3, 'd1'], 'literal');
eq(m(/d1/, '‰xd2d1'), [4, 'd1'], 'literal in a wide string');
eq(m(/^d1/, 'xd1'), null, 'anchored literal');
eq(m(/^d1/m, 'x\nd1'), [2, 'd1'], 'multiline literal');
eq(m(/^d1/m, 'xd1'), null, 'multiline literal needs a line start');
var my = /^a/my;
my.lastIndex = 1;
eq(my.test(' a'), false, 'sticky multiline literal within a line');
eq(m(/Qngr\(/, 'a"Qngr('), [2, 'Qngr('], 'escaped literal');
var lg = /ab/g;
eq([lg.exec('abxab').index, lg.lastIndex, lg.exec('abxab').index, lg.lastIndex, lg.exec('abxab'), lg.lastIndex],
   [0, 2, 3, 5, null, 0], 'global literal');
var ly = /ab/y;
ly.lastIndex = 1;
eq(ly.exec('xxab'), null, 'sticky literal does not search');
ly.lastIndex = 2;
eq(ly.exec('xxab').index, 2, 'sticky literal at position');
ly.lastIndex = 2;
eq(ly.exec('xx‰ab'), null, 'sticky literal wide mismatch');
ly.lastIndex = 3;
eq(ly.exec('xx‰ab').index, 3, 'sticky literal wide');
eq('a=b=c'.split(/=/), ['a', 'b', 'c'], 'literal split');
eq('a=b=c‰'.replace(/=/g, '-'), 'a-b-c‰', 'literal replace wide');
var wideLong = new Array(40).join('‰x"') + '"\\/Qngr(';
eq(/"\\\/Qngr\(/.exec(wideLong).index, 39 * 3, 'wide literal after many partial candidates');
eq(/(^|x)"\\\/Qngr\(\d/.exec(wideLong), null, 'required literal present but no match');
eq(m(/\ud83d/u, '😀'), null, 'unicode literal never splits a pair');

print('ok');
