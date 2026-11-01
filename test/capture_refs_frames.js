// Closures of one function capture different bindings. Each frame must read
// its own closure's captures across calls, returns and tail calls between
// instances.
var pass = 0, fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) pass++;
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function make(tag) {
    var self = { tag: tag, peer: null };
    self.walk = function (n) {
        if (n === 0) return tag;
        var r = self.peer.walk(n - 1);
        return tag + r;
    };
    self.tail = function (n, acc) {
        if (n === 0) return acc;
        return self.peer.tail(n - 1, acc + tag);
    };
    return self;
}
var a = make('a'), b = make('b');
a.peer = b; b.peer = a;
for (var i = 0; i < 200; i++) {
    eq(a.walk(5), 'ababab', 'alternating calls ' + i);
    eq(b.tail(4, ''), 'baba', 'alternating tail calls ' + i);
}

function counter(start) {
    var n = start;
    return function (other) { var mine = n; if (other) other(null); return mine + n; };
}
var c1 = counter(1), c2 = counter(100);
for (var i = 0; i < 500; i++) eq(c1(c2) + c2(c1), 2 + 200, 'nested closure reads ' + i);

print('capture_refs_frames: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
