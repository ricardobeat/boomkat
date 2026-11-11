// Equality of strings that are not both interned compares their units: every length around the
// word size, a difference at each position, wide and narrow units, and the empty string.
var out = [];
function seq(a, b) { return a === b; }
function sneq(a, b) { return a !== b; }
function leq(a, b) { return a == b; }
function branch(a, b) { if (a === b) return 1; if (a != b) return 2; return 3; }
function build(n, ch) { var s = ""; for (var i = 0; i < n; i++) s += String.fromCharCode(ch + (i % 23)); return s; }
function flip(s, at) { return s.substring(0, at) + "~" + s.substring(at + 1); }
var hits = 0, checks = 0;
for (var round = 0; round < 40; round++) {
    for (var n = 0; n <= 34; n++) {
        var a = build(n, 65), b = build(n, 65);
        checks++;
        if (seq(a, b) && !sneq(a, b) && leq(a, b) && branch(a, b) === 1) hits++;
        if (seq(a, a + "x") || !sneq(a + "y", a) || branch(a, b + "z") !== 2) out.push("length " + n);
        for (var at = 0; at < n; at++) {
            var c = flip(a, at);
            checks++;
            if (!seq(c, b) && sneq(b, c) && !leq(c, b) && branch(c, b) === 2) hits++;
            if (!seq(c, flip(b, at))) out.push("same flip " + n + "/" + at);
        }
        var w = build(n, 0x3b1), w2 = build(n, 0x3b1);
        if (!seq(w, w2) || sneq(w, w2) || (n > 0 && seq(w, a)) || (n > 0 && seq(w, flip(w2, n - 1)))) out.push("wide " + n);
    }
}
out.push(hits === checks ? "ok " + checks : "bad " + hits + "/" + checks);
out.push(seq("", build(0, 65)), seq("ab", ["a", "b"].join("")), sneq("abc", ["a", "b"].join("")), seq(Symbol.iterator, Symbol.iterator));
console.log(out.join("\n"));
