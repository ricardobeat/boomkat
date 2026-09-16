// @@replace measures the match in code units, not bytes.
//
// Step 14.h of §22.2.6.11 computes endOfLastMatch as position plus the length
// of `matched` in code units. `matched` comes from the exec result and is a
// string in its own right: with an exec override it need not occur in the
// input at all, and even when it does, its encoded size says nothing about
// how much of the input the match covers. The `$\`` and `$'` substitutions
// and the unmatched tail are all cut from the input at that offset, so a
// length taken from the wrong string slices it mid-character.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) {
    ok(a === b, m + ' (got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b) + ')');
}

function fakeRegExp(result) {
    return { exec: function () { return result; } };
}

// An exec override whose match is shorter in bytes than the input character
// it sits on. `$&` is the match, `$\`` the prefix, `$'` the suffix, and $2/$3
// have no capture so they stay literal.
var ascii = ['A', 'B'], wide = ['あ', 'い'];
var inputs = ['C', 'う'];
var template = "[$&$`$'$1$2$3$]";

inputs.forEach(function (s) {
    eq(RegExp.prototype[Symbol.replace].call(fakeRegExp(ascii), s, template),
       '[AB$2$3$]', 'ascii match over input ' + JSON.stringify(s));
    eq(RegExp.prototype[Symbol.replace].call(fakeRegExp(wide), s, template),
       '[あい$2$3$]', 'wide match over input ' + JSON.stringify(s));
});

// The result carries no stray code units past its visible text.
var r = RegExp.prototype[Symbol.replace].call(fakeRegExp(ascii), 'う', template);
eq(r.length, 9, 'no trailing units on the substituted result');
ok(r.indexOf('�') === -1, 'no replacement characters in the result');

// $` and $' are cut at the same offsets. A match declared at index 1 of a
// three-character input leaves one character either side.
var mid = { exec: function () { var a = ['X']; a.index = 1; return a; } };
eq(RegExp.prototype[Symbol.replace].call(mid, 'あいう', "<$`|$&|$'>"),
   'あ<あ|X|う>う',
   'prefix and suffix cut on character boundaries');

// A match longer than the input clamps to the end rather than running past it.
var over = { exec: function () { var a = ['LONGMATCH']; a.index = 0; return a; } };
eq(RegExp.prototype[Symbol.replace].call(over, 'あ', "[$&|$']"),
   '[LONGMATCH|]', 'a match past the end clamps the suffix to empty');

// A functional replacer receives the code-unit position and the untouched
// input, and the tail after the match is cut at the same place.
var seen = null;
var fnRx = { exec: function () { var a = ['Y']; a.index = 1; return a; } };
var out = RegExp.prototype[Symbol.replace].call(fnRx, 'あいう', function (m, pos, str) {
    seen = { m: m, pos: pos, len: str.length };
    return '#';
});
eq(seen.pos, 1, 'the replacer gets a code-unit position');
eq(seen.len, 3, 'the replacer gets the full input');
eq(out, 'あ#う', 'the tail after a functional replace starts on a character boundary');

// Surrogate pairs count as two code units.
var pair = '😀';
var sp = { exec: function () { var a = [pair]; a.index = 0; return a; } };
eq(RegExp.prototype[Symbol.replace].call(sp, pair + 'z', "[$&|$']"),
   '[' + pair + "|z]z", 'a surrogate pair match spans two code units');

// A real RegExp over two-byte text takes the same substitution path.
eq('あbう'.replace(/b/, "[$`|$&|$']"), 'あ[あ|b|う]う',
   'a real match on two-byte input');
eq('あいう'.replace(/い/g, "<$`$'>"), 'あ<あう>う',
   'global replace on two-byte input');

if (fail === 0) {
    print('PASS: @@replace substitution offsets (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
