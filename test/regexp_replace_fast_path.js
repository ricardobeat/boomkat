// String.prototype.replace with a RegExp takes a direct path while the RegExp
// and RegExp.prototype are unmodified. Every observable result must match the
// generic @@replace protocol, and any change must send it back there.
function eq(actual, expected, message) {
    var a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(message + ': got ' + a + ', expected ' + e);
}
function warm(re, s, r) { for (var i = 0; i < 50; i++) s.replace(re, r); }

// Replacement strings.
eq('hello world'.replace(/o/, '0'), 'hell0 world', 'first match');
eq('hello world'.replace(/o/g, '0'), 'hell0 w0rld', 'global');
eq('hello world'.replace(/o/g, ''), 'hell wrld', 'empty replacement');
eq('hello world'.replace(/o/g), 'hellundefined wundefinedrld', 'missing replacement');
eq('abc'.replace(/b/, '[$&]'), 'a[b]c', '$&');
eq('abc'.replace(/b/, '[$`]'), 'a[a]c', '$`');
eq('abc'.replace(/b/, "[$']"), 'a[c]c', "$'");
eq('abc'.replace(/b/, '[$$]'), 'a[$]c', '$$');
eq('abc'.replace(/(a)(b)(c)/, '$3$2$1'), 'cba', '$n');
eq('abc'.replace(/(a)(x)?(c)?/, '[$1|$2|$3]'), '[a||]bc', 'unmatched groups');
eq('abc'.replace(/(?<x>b)/, '[$<x>]'), 'a[b]c', 'named group');
eq('abc'.replace(/b/, '$1$0$<x>'), 'a$1$0$<x>c', 'no such group');
eq('abc'.replace(/b/, 5), 'a5c', 'number replacement');
eq('abc'.replace(/b/, null), 'anullc', 'null replacement');
eq('abc'.replace(/b/, {toString: function () { return 'X'; }}), 'aXc', 'object replacement');

// Function replacers.
var seen;
eq('abcd'.replace(/(b)(x)?(c)/, function () { seen = [].slice.call(arguments); return '-'; }), 'a-d', 'function');
eq(seen, ['bc', 'b', undefined, 'c', 1, 'abcd'], 'function arguments');
eq('abab'.replace(/b/g, function (m, i) { return i; }), 'a1a3', 'function with offset');
eq('abc'.replace(/(?<n>b)/, function () { seen = arguments[arguments.length - 1]; return '!'; }), 'a!c', 'named function');
eq(seen, {n: 'b'}, 'groups argument');

// No match returns the receiver; the pattern's state is as the generic path leaves it.
var s = 'unchanged';
eq(s.replace(/zzz/, 'x'), s, 'no match');
eq(s.replace(/zzz/g, 'x'), s, 'no global match');
var g = /a/g; g.lastIndex = 3;
eq('banana'.replace(g, 'o'), 'bonono', 'global ignores lastIndex');
eq(g.lastIndex, 0, 'global leaves lastIndex 0');
var n = /a/; n.lastIndex = 3;
eq('banana'.replace(n, 'o'), 'bonana', 'non-global ignores lastIndex');
eq(n.lastIndex, 3, 'non-global keeps lastIndex');
var y = /a/y; y.lastIndex = 1;
eq('banana'.replace(y, 'o'), 'bonana', 'sticky matches at lastIndex');
eq(y.lastIndex, 2, 'sticky advances lastIndex');
eq('banana'.replace(y, 'o'), 'banana', 'sticky second attempt misses at 2');
eq(y.lastIndex, 0, 'sticky failure resets lastIndex');
var yg = /a/gy;
eq('aaba'.replace(yg, 'x'), 'xxba', 'sticky global stops at the first miss');
eq(yg.lastIndex, 0, 'sticky global lastIndex');

// Empty matches and unicode.
eq('abc'.replace(/(?:)/g, '-'), '-a-b-c-', 'empty matches');
eq('😀'.replace(/(?:)/gu, '-'), '-😀-', 'empty match steps by code point with u');
eq('😀'.replace(/(?:)/g, '-'), '-\ud83d-\ude00-', 'empty match steps by unit without u');
eq('aሴb'.replace(/ሴ/, 'x'), 'axb', 'wide input');
eq('  x  '.replace(/^\s*|\s*$/g, ''), 'x', 'trim');
eq('x'.replace(/^\s*|\s*$/g, ''), 'x', 'trim, nothing to trim');
eq('  '.replace(/^\s*|\s*$/g, '-'), '--', 'trim, all space');

// Changes after warmup send the call back through the protocol.
(function () {
    var re = /o/g;
    warm(re, 'foo', 'x');
    var calls = 0;
    var orig = RegExp.prototype.exec;
    RegExp.prototype.exec = function (str) { calls++; return orig.call(this, str); };
    eq('foo'.replace(re, 'x'), 'fxx', 'result through the replaced exec');
    eq(calls > 0, true, 'a replaced RegExp.prototype.exec is called');
    RegExp.prototype.exec = orig;
    calls = 0;
    eq('foo'.replace(re, 'x'), 'fxx', 'restored exec');
    eq(calls, 0, 'the restored exec is not wrapped');
})();
(function () {
    var re = /o/;
    warm(re, 'foo', 'x');
    var d = Object.getOwnPropertyDescriptor(RegExp.prototype, Symbol.replace);
    var hit = 0;
    RegExp.prototype[Symbol.replace] = function (s, r) { hit++; return 'custom'; };
    eq('foo'.replace(re, 'x'), 'custom', 'a replaced @@replace is used');
    eq(hit, 1, '@@replace called once');
    Object.defineProperty(RegExp.prototype, Symbol.replace, d);
    eq('foo'.replace(re, 'x'), 'fxo', 'restored @@replace');
})();
(function () {
    var re = /o/;
    warm(re, 'foo', 'x');
    re.exec = function (s) { return null; };
    eq('foo'.replace(re, 'x'), 'foo', 'an own exec is used');
    var own = /o/;
    warm(own, 'foo', 'x');
    own[Symbol.replace] = function () { return 'own'; };
    eq('foo'.replace(own, 'x'), 'own', 'an own @@replace is used');
})();
(function () {
    var re = /o/g;
    warm(re, 'foo', 'x');
    var d = Object.getOwnPropertyDescriptor(RegExp.prototype, 'flags');
    Object.defineProperty(RegExp.prototype, 'flags', { get: function () { return ''; }, configurable: true });
    eq('foo'.replace(re, 'x'), 'fxo', 'a changed flags getter is honored');
    Object.defineProperty(RegExp.prototype, 'flags', d);
    eq('foo'.replace(re, 'x'), 'fxx', 'restored flags getter');
})();

// A replacement object's toString can change the pattern before it matches.
(function () {
    var re = /o/;
    warm(re, 'foo', 'x');
    var orig = RegExp.prototype.exec;
    var r = 'foo'.replace(re, { toString: function () {
        RegExp.prototype.exec = function () { return null; };
        return 'x';
    } });
    RegExp.prototype.exec = orig;
    eq(r, 'foo', 'toString that replaces exec');
})();

// Subclasses and other receivers.
(function () {
    class R extends RegExp {
        [Symbol.replace](s, r) { return 'sub:' + s; }
    }
    eq('abc'.replace(new R('b'), 'x'), 'sub:abc', 'subclass @@replace');
    class Q extends RegExp {}
    eq('abc'.replace(new Q('b'), 'x'), 'axc', 'plain subclass');
    class E extends RegExp { exec(s) { return null; } }
    eq('abc'.replace(new E('b'), 'x'), 'abc', 'subclass exec');
    var o = { [Symbol.replace](s, r) { return s + '|' + r; } };
    eq('abc'.replace(o, 'x'), 'abc|x', 'plain object with @@replace');
    var re = /b/;
    Object.setPrototypeOf(re, Object.create(RegExp.prototype));
    eq('abc'.replace(re, 'x'), 'axc', 'receiver with another prototype');
})();

// Symbols and throwing coercions.
(function () {
    var threw = false;
    try { 'abc'.replace(/b/, Symbol('s')); } catch (e) { threw = e instanceof TypeError; }
    eq(threw, true, 'symbol replacement throws');
    threw = false;
    try { 'abc'.replace(/b/, { toString: function () { throw new RangeError('x'); } }); } catch (e) { threw = e instanceof RangeError; }
    eq(threw, true, 'replacement toString throws');
    threw = false;
    try { 'abc'.replace(/b/, function () { throw new SyntaxError('x'); }); } catch (e) { threw = e instanceof SyntaxError; }
    eq(threw, true, 'replacer throws');
})();

// Receiver coercion.
eq(String.prototype.replace.call(12345, /3/, 'x'), '12x45', 'number receiver');
eq(String.prototype.replace.call({ toString: function () { return 'abc'; } }, /b/, 'x'), 'axc', 'object receiver');
