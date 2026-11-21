"use strict";
// Strict callees whose last call is a tail call (TAILCALL_CALL, TAILCALL_UNDEF_THIS) inlined into a
// hot caller: a Math function, a nested JS callee, and a Math call whose window lies beyond the
// caller's frame (the caller has few registers, the callee many). A cold call in the body, a callee
// that changes, and values that leave the int32 range exercise the exits.
// scripts/opt_exit_check.sh forces an exit at every point.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function powTail(c) { return (c < 0.04) ? c * 0.07 : Math.pow(c * 0.94 + 0.05, 2.4); }
function maxTail(v, a, b) { return Math.max(a, Math.min(b, v)); }
function nested(v) { if (Math.abs(v) > 1000) warn(v); return maxTail(v, -500, 500); }
function wide(a) { var p = a + 1, q = a + 2, r = a + 3, s = a + 4; return Math.pow(p * q, 0.5) + Math.sqrt(r * s); }
function plain(x) { return add1(x); }
var add1 = function (x) { return x + 1; };
var warned = 0;
function warn(v) { warned++; }

function drive(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += powTail((i & 255) / 255) + nested((i & 1023) - 512) + wide(i & 63) + plain(i);
    return s;
}

powTail(0.5); maxTail(1, 0, 2); nested(1); wide(1); plain(1);
show("a", drive(20000).toFixed(6));
show("warned", warned);
// The cold call runs.
show("b", nested(5000));
show("warned", warned);
// The nested callee of the inlined tail call changes.
add1 = function (x) { return x * 2; };
show("c", drive(20000).toFixed(6));
// Math.pow itself replaced: the inlined builtin's guard exits.
var savedPow = Math.pow;
Math.pow = function (a, b) { return a + b; };
show("d", drive(2000).toFixed(6));
Math.pow = savedPow;
show("e", drive(20000).toFixed(6));
print(out.join(" "));
