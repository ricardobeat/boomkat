// Destructuring patterns in declaration, catch, and loop heads.
//
// The BoundNames of a lexical pattern may not repeat, and a let/const
// declaration or ForDeclaration may not bind `let` (ES2024 §14.3.1.1,
// §14.7.5.1), but sloppy code may bind `yield`. A bare for-in/of head pattern assigns to member targets whose
// value is read by a getter that runs a call of its own.
//
// Runs unmodified under node as a sloppy script.
if (typeof print === 'undefined') { var print = function (s) { console.log(s); }; }
var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

function outcome(src) {
    try { return String((0, eval)(src)); } catch (e) { return e.name; }
}

check("sloppy yield in a for-of let pattern", outcome("for (let [yield] of [[1]]) var r = yield; r"), "1");
check("sloppy yield in a catch pattern", outcome("try { throw [2] } catch ([yield]) { yield }"), "2");
check("let bound by a let pattern", outcome("let [let] = [1]"), "SyntaxError");
check("let bound by a const pattern", outcome("const {let} = {let: 1}"), "SyntaxError");
check("let bound by a for-of let pattern", outcome("for (let [let] of [[1]]);"), "SyntaxError");
check("repeated name in a let pattern", outcome("let [q, q] = [1, 2]"), "SyntaxError");
check("repeated name in a catch pattern", outcome("try {} catch ([q, q]) {}"), "SyntaxError");
check("repeated name in a var pattern", outcome("var [q, q] = [1, 2]; q"), "2");

function nine() { var a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9; return a + b + c + d + e + f + g + h + i; }
var src = { get a() { return nine(); }, get b() { return nine() * 2; } };
function memberTargets() {
    var o = { k: {} }, key = "q", out = [];
    for ({a: o.k[key], b: o.x} of [src]) out.push(o.k.q, o.x);
    for ([o.y, o.k[key + "2"]] of [[nine(), nine()]]) out.push(o.y, o.k.q2);
    for ({length: o.z} in {abc: 1}) out.push(o.z);
    return out.join(",");
}
check("bare for-in/of member targets read through getters", memberTargets(), "45,90,45,45,3");

print("destructuring_head_patterns: " + passed + " passed");
