// RegExpBuiltinExec re-reads the receiver after ToLength(lastIndex).
//
// Step 3 of §22.2.7.2 performs Get(R, "lastIndex") and then ToLength on the
// result, and both halves can run script: a getter on the receiver, then
// `valueOf` on whatever it returned. `RegExp.prototype.compile` called from
// there replaces the object's matcher and its flags in place. The spec reads
// `global` and `sticky` in steps 5-6, after that Get, so a match started here
// uses the pattern and flags the side effect left behind.
//
// `RegExp.prototype.exec` and the @@match, @@replace, @@split and @@matchAll
// paths all run the same operation, so they all observe it.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

// A recompile swaps in a pattern that matches where the old one did not.
function recompiling(re, pattern, flags) {
    return { valueOf: function () {
        if (flags === undefined) { re.compile(pattern); } else { re.compile(pattern, flags); }
        return 0;
    } };
}

['', 'y'].forEach(function (flag) {
    var re = new RegExp('a', flag);
    re.lastIndex = recompiling(re, 'b');
    ok(re[Symbol.match]('b') !== null, 'flags "' + flag + '": matches the recompiled pattern');

    var re2 = new RegExp('a', flag);
    re2.lastIndex = recompiling(re2, 'b');
    ok(re2.exec('b') !== null, 'flags "' + flag + '": exec matches the recompiled pattern');
});

// Gaining the global flag: RegExpBuiltinExec now writes lastIndex.
var g = new RegExp('a', '');
g.lastIndex = recompiling(g, 'a', 'g');
g[Symbol.match]('a');
eq(g.lastIndex, 1, '@@match writes lastIndex after the recompile adds "g"');

var g2 = new RegExp('a', '');
g2.lastIndex = recompiling(g2, 'a', 'g');
g2.exec('a');
eq(g2.lastIndex, 1, 'exec writes lastIndex after the recompile adds "g"');

// Losing the sticky flag: RegExpBuiltinExec must leave lastIndex alone, both
// when the new pattern matches and when it does not.
[['a', 0, 9000], ['b', 0, 9001], ['b', 10000, 9002]].forEach(function (c) {
    var pattern = c[0], ret = c[1], sentinel = c[2];
    var re = new RegExp('a', 'y');
    re.lastIndex = { valueOf: function () {
        re.compile(pattern, '');
        re.lastIndex = sentinel;
        return ret;
    } };
    re[Symbol.match]('a');
    eq(re.lastIndex, sentinel,
       '@@match leaves lastIndex alone once "y" is gone (pattern ' + pattern + ')');

    var re2 = new RegExp('a', 'y');
    re2.lastIndex = { valueOf: function () {
        re2.compile(pattern, '');
        re2.lastIndex = sentinel;
        return ret;
    } };
    re2.exec('a');
    eq(re2.lastIndex, sentinel,
       'exec leaves lastIndex alone once "y" is gone (pattern ' + pattern + ')');
});

// @@replace and @@split take the same path.
var rep = new RegExp('a', '');
rep.lastIndex = recompiling(rep, 'b');
eq('b'.replace(rep, 'X'), 'X', '@@replace uses the recompiled pattern');

// @@split is the exception: §22.2.6.14 builds the splitter from the
// receiver's source and flags before any matching, so a recompile during the
// match changes the receiver and not the RegExp doing the splitting.
var spl = new RegExp('a', '');
spl.lastIndex = recompiling(spl, 'b');
eq('1b2'.split(spl).join(','), '1b2', '@@split snapshots the pattern up front');

// --- RegExpExec accepts any receiver carrying a callable exec -------------
//
// §22.2.6.15 requires `this` to be an Object and nothing more: RegExpExec
// calls whatever `exec` it finds, and only a receiver with neither a callable
// `exec` nor a [[RegExpMatcher]] is a TypeError.

ok(RegExp.prototype.test.call({ exec: function () { return {}; } }, '') === true,
   'test accepts a non-RegExp with a callable exec');
ok(RegExp.prototype.test.call({ exec: function () { return function () {}; } }, '') === true,
   'exec may return any Object, including a function');
ok(RegExp.prototype.test.call({ exec: function () { return null; } }, '') === false,
   'a null exec result is no match');

var got = [];
RegExp.prototype.test.call({ exec: function (s) { got.push(s); return null; } }, 42);
eq(got.join(','), '42', 'test passes ToString(string) to exec');

function throwsTypeError(fn, m) {
    try { fn(); ok(false, m + ' (did not throw)'); }
    catch (e) { ok(e instanceof TypeError, m + ' (threw ' + e.constructor.name + ')'); }
}
throwsTypeError(function () { RegExp.prototype.test.call({}, ''); },
                'no exec and no matcher is a TypeError');
throwsTypeError(function () { RegExp.prototype.test.call({ exec: 1 }, ''); },
                'a non-callable exec falls through to the matcher check');
throwsTypeError(function () { RegExp.prototype.test.call(null, ''); },
                'a primitive receiver is a TypeError');
throwsTypeError(function () { RegExp.prototype.test.call({ exec: function () { return 1; } }, ''); },
                'exec returning a primitive is a TypeError');

// exec itself is stricter: it needs a real matcher.
throwsTypeError(function () { RegExp.prototype.exec.call({ exec: function () { return {}; } }, ''); },
                'RegExp.prototype.exec still requires a [[RegExpMatcher]]');

if (fail === 0) {
    print('PASS: RegExp exec re-entrancy (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
