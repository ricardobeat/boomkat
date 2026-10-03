// Every built-in iterator result is an ordinary {value, done} object.
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }

function check(r, value, done, label) {
    assertEq(Object.getPrototypeOf(r), Object.prototype, label + " prototype");
    assertEq(Object.keys(r).join(","), "value,done", label + " key order");
    assertEq(r.value, value, label + " value");
    assertEq(r.done, done, label + " done");
    var d = Object.getOwnPropertyDescriptor(r, "value");
    assertEq(d.writable && d.enumerable && d.configurable, true, label + " attributes");
}

function* g() { yield "a"; return "r"; }
var gi = g();
check(gi.next(), "a", false, "yield");
check(gi.next(), "r", true, "return");
check(gi.next(), undefined, true, "completed");
check(g().return("x"), "x", true, "return() on a fresh generator");

var ai = [7].values();
check(ai.next(), 7, false, "array iterator");
check(ai.next(), undefined, true, "array iterator end");
var me = new Map([[1, 2]]).entries().next();
assertEq(me.value.join(","), "1,2", "map entry");
assertEq(Object.getPrototypeOf(me), Object.prototype, "map result prototype");
check("ab"[Symbol.iterator]().next(), "a", false, "string iterator");
var mi = "a".matchAll(/a/g).next();
assertEq(mi.value[0], "a", "matchAll value");
assertEq(Object.getPrototypeOf(mi), Object.prototype, "matchAll prototype");

// Strings held by a result survive collection of everything else.
var held = [];
for (var i = 0; i < 2000; i++) {
    var r = (function* () { yield "s" + i; })().next();
    held.push(r);
}
assertEq(held[1999].value, "s1999", "held string");
assertEq(held[0].value, "s0", "first held string");
print("ok");
