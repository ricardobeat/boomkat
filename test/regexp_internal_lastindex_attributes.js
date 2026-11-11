// Every RegExp the engine creates owns lastIndex as a writable, non-enumerable,
// non-configurable data property (RegExpAlloc step 2). That includes the ones
// String.prototype.match/matchAll/search build from a string pattern, which a
// patched RegExp.prototype method sees as its receiver, and literals evaluated
// repeatedly, which share one shape after the first.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

function check(rx, what) {
    var d = Object.getOwnPropertyDescriptor(rx, 'lastIndex');
    ok(d && d.value === 0, what + ': lastIndex is 0');
    ok(d && d.writable === true, what + ': writable');
    ok(d && d.enumerable === false, what + ': non-enumerable');
    ok(d && d.configurable === false, what + ': non-configurable');
    ok(Object.keys(rx).length === 0, what + ': no enumerable own keys');
    ok(Object.getOwnPropertyNames(rx).join() === 'lastIndex', what + ': only lastIndex');
}

var methods = [['match', Symbol.match], ['matchAll', Symbol.matchAll], ['search', Symbol.search]];
for (var m = 0; m < methods.length; m++) {
    var name = methods[m][0], sym = methods[m][1];
    var orig = RegExp.prototype[sym];
    var seen = null;
    RegExp.prototype[sym] = function () { seen = this; return null; };
    'abc'[name]('b');
    RegExp.prototype[sym] = orig;
    ok(seen instanceof RegExp, name + ': receiver is a RegExp');
    if (seen) check(seen, name + ' from a string');
}

for (var i = 0; i < 5; i++) {
    var lit = /x/g;
    check(lit, 'literal #' + i);
    lit.lastIndex = 7;
    ok(lit.lastIndex === 7, 'literal #' + i + ': lastIndex writable');
}
check(new RegExp('y'), 'constructed');

print(fail === 0 ? 'PASS ' + pass : 'FAIL ' + fail);
