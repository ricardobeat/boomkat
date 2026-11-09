// TYPEOF inside an inlined callee: the operand's interned name is stored by the callee's own code
// (OptOp.TYPEOF), including in a spliced body with several returns, in a nested inlined body, and
// for an operand a field read left in a machine register.
var out = [];
function show(label, v) { out.push(label + "=" + String(v)); }

function ty(v) { return typeof v; }
function isnum(v) { return typeof v === "number"; }
function pick(v) {
    if (typeof v === "number") return 1;
    if (typeof v === "string") return 2;
    if (typeof v === "undefined") return 3;
    return 4;
}
function tag(o) { return typeof o.v; }
function nested(v) { return ty(v) + "/" + isnum(v); }
function cotype(a, b) { return typeof a === typeof b; }

var sym = Symbol("s");
function fn() {}
var vals = [0, -0, 1, 1.5, NaN, Infinity, "s", "", sym, 10n, true, null, undefined, {}, [], fn, new Date(0),
    new Number(1), new Proxy({}, {}), /x/];
var names = [];

function warm(f, a, b) { for (var i = 0; i < 4000; i++) f(a, b); }
warm(ty, 1); warm(isnum, 1); warm(pick, 1); warm(nested, 1); warm(cotype, 1, 2);

// The callee stays hot through the caller, so the optimizer inlines it with its TYPEOF inside.
function drive(f, unary, name) {
    var s = 0;
    for (var i = 0; i < 6000; i++) {
        var r = unary ? f(i % 3) : (f(i % 3, (i % 5) + 1) ? 1 : 0);
        s += typeof r === "string" ? r.length : (r === true || r === 1 ? 1 : 0);
    }
    show(name + ".warm", s);
}
drive(ty, true, "ty");
drive(isnum, true, "isnum");
drive(pick, true, "pick");
drive(nested, true, "nested");
drive(cotype, false, "cotype");

for (var i = 0; i < vals.length; i++) names.push(ty(vals[i]));
show("ty", names.join(","));
var flags = [];
for (var i = 0; i < vals.length; i++) flags.push(isnum(vals[i]) ? 1 : 0);
show("isnum", flags.join(","));
var picks = [];
for (var i = 0; i < vals.length; i++) picks.push(pick(vals[i]));
show("pick", picks.join(","));
var pairs = [];
for (var i = 0; i < vals.length; i++) {
    pairs.push(tag({ v: vals[i] }));
    pairs.push(nested(vals[i]));
}
show("tag", pairs.join(","));
var same = [];
for (var i = 0; i < vals.length; i++) {
    for (var j = 0; j < vals.length; j += 5) same.push(cotype(vals[i], vals[j]) ? 1 : 0);
}
show("cotype", same.join(","));

// A callee of an inlined callee: two frames deep, both bodies holding a TYPEOF.
function inner(v) { return typeof v; }
function outer(v) { return inner(v) + "!"; }
warm(outer, 1);
var deep = [];
for (var i = 0; i < vals.length; i++) deep.push(outer(vals[i]));
show("deep", deep.join(","));

// The same callee driven from a loop that mixes the fast path and every other kind.
function mixed(v) { return typeof v + (typeof v === "object" ? "*" : ""); }
warm(mixed, 1);
var mixed_out = [];
var acc = 0;
for (var i = 0; i < 20000; i++) mixed_out.push(mixed(vals[i % vals.length]));
for (var i = 0; i < mixed_out.length; i++) acc += mixed_out[i].length;
show("mixed", acc);
show("mixed.last", mixed_out.slice(-4).join(","));

print(out.join("\n"));
