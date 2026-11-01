// indexOf, lastIndexOf, includes, startsWith, endsWith, replace and replaceAll
// against a code-unit reference search, over ASCII, BMP and astral text.
var pass = 0, fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) pass++;
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function matchesAt(s, n, i) {
    for (var j = 0; j < n.length; j++) if (s.charCodeAt(i + j) !== n.charCodeAt(j)) return false;
    return true;
}
function refIndexOf(s, n, from) {
    from = Math.min(Math.max(from, 0), s.length);
    for (var i = from; i + n.length <= s.length; i++) if (matchesAt(s, n, i)) return i;
    return -1;
}
function refLastIndexOf(s, n, from) {
    for (var i = Math.min(Math.max(from, 0), s.length - n.length); i >= 0; i--) if (matchesAt(s, n, i)) return i;
    return -1;
}

var haystacks = ['hello world, hello world', 'héllo wörld, hello world \u{1F600} hello', 'aaaaab', 'ab'.repeat(40) + 'c', ''];
var needles = ['hello', 'o', 'wörld', 'xyz', '', '\u{1F600}', 'aab', 'abc', 'o w', 'hello world, hello world!'];
haystacks.forEach(function (s) {
    needles.forEach(function (n) {
        for (var p = -2; p <= s.length + 2; p++) {
            var tag = JSON.stringify(s.slice(0, 12)) + ' ' + JSON.stringify(n) + ' @' + p;
            eq(s.indexOf(n, p), refIndexOf(s, n, p), 'indexOf ' + tag);
            eq(s.lastIndexOf(n, p), refLastIndexOf(s, n, p), 'lastIndexOf ' + tag);
            eq(s.includes(n, p), refIndexOf(s, n, p) >= 0, 'includes ' + tag);
            var at = Math.min(Math.max(p, 0), s.length);
            eq(s.startsWith(n, p), at + n.length <= s.length && matchesAt(s, n, at), 'startsWith ' + tag);
            eq(s.endsWith(n, p), at - n.length >= 0 && matchesAt(s, n, at - n.length), 'endsWith ' + tag);
        }
        if (n !== '') {
            var parts = [], from = 0, i;
            while ((i = refIndexOf(s, n, from)) >= 0) { parts.push(s.slice(from, i)); from = i + n.length; }
            parts.push(s.slice(from));
            eq(s.replaceAll(n, '-'), parts.join('-'), 'replaceAll ' + JSON.stringify(n));
            eq(s.replace(n, '-'), parts.length > 1 ? parts[0] + '-' + parts.slice(1).join(n) : s, 'replace ' + JSON.stringify(n));
        }
    });
});
eq('abc'.replaceAll('', '-'), '-a-b-c-', 'replaceAll with an empty search');
eq('a\u{1F600}b'.replaceAll('', '.'), '.a.\ud83d.\ude00.b.', 'empty search steps by code unit');

print('string_search: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
