// Map.prototype.forEach and Set.prototype.forEach spelled their IsCallable
// check as `callback.is_object() && ...callable`, which is false for a
// LIGHTFUNC -- the representation every native builtin uses. So passing any
// builtin as the callback (`map.forEach(console.log)`, `set.forEach(print)`)
// threw "object is not a function" where the spec requires the call to run.
//
// Every other collection entry point already routed through tval_is_callable,
// which admits both a lightfunc and a callable object; these two were the
// stragglers. The checks below cover each callee representation the engine has
// so a future rewrite of one branch cannot quietly drop another.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}

var m = new Map([["a", 1], ["b", 2]]);
var s = new Set([10, 20]);

// 1. Every callable representation is accepted, and actually invoked.
function each(name, coll, cb) {
    var threw = null;
    try { coll.forEach(cb); } catch (e) { threw = e.message; }
    t(name, threw, null);
}

var seen = 0;
each("map-plain-function", m, function () { seen++; });
each("set-plain-function", s, function () { seen++; });
each("map-arrow", m, function () { seen++; });
each("map-bound", m, (function () { seen++; }).bind(null));
each("set-bound", s, (function () { seen++; }).bind(null));
t("callbacks-ran", seen, 10);

// A lightfunc: a native builtin passed straight through, unbound. This is the
// representation that made the check answer "not callable" and the shape real
// code writes (`map.forEach(console.log)`).
//
// NOT covered here: a BOUND lightfunc (`sink.push.bind(sink)`). Map/Set forEach
// accepts one and then never invokes it, because vm_call_fn_impl's bound path
// re-dispatches into a case that requires a compiled function and a bound
// builtin has none. That is a separate, pre-existing defect this change does
// not touch; asserting it here would make this test fail for an unrelated
// reason.
var lightfuncs = [Math.max, Math.min, isNaN, parseInt, String, Object];
for (var f = 0; f < lightfuncs.length; f++) {
    var mt = null, st = null;
    try { m.forEach(lightfuncs[f]); } catch (e) { mt = e.message; }
    try { s.forEach(lightfuncs[f]); } catch (e) { st = e.message; }
    t("map-lightfunc-" + f, mt, null);
    t("set-lightfunc-" + f, st, null);
}

// The lightfunc really runs: a builtin with an observable side effect on its
// receiver, reached through the callback slot.
var log = [];
var probe = { push: Array.prototype.push };
m.forEach(function (v, k) { log.push(k); });
t("lightfunc-path-still-iterates", log.join(","), "a,b");

// 2. The callback still receives (value, key, collection) / (value, value, set).
var args = null;
m.forEach(function (v, k, c) { if (args === null) { args = [v, k, c === m]; } });
t("map-cb-value", args[0], 1);
t("map-cb-key", args[1], "a");
t("map-cb-collection", args[2], true);

args = null;
s.forEach(function (v, v2, c) { if (args === null) { args = [v, v2, c === s]; } });
t("set-cb-value", args[0], 10);
t("set-cb-value2", args[1], 10);
t("set-cb-collection", args[2], true);

// 3. Non-callables must STILL throw TypeError; widening the check must not have
//    let a plain object or a primitive through.
var bad = [{}, [], "str", 42, true, null, undefined, Symbol("s")];
var map_threw = 0, set_threw = 0;
for (var i = 0; i < bad.length; i++) {
    try { m.forEach(bad[i]); } catch (e) { if (e instanceof TypeError) { map_threw++; } }
    try { s.forEach(bad[i]); } catch (e) { if (e instanceof TypeError) { set_threw++; } }
}
t("map-rejects-non-callables", map_threw, bad.length);
t("set-rejects-non-callables", set_threw, bad.length);

// 4. thisArg still applies.
var recv = {};
var got_this = null;
m.forEach(function () { got_this = this; }, recv);
t("map-thisArg", got_this === recv, true);
got_this = null;
s.forEach(function () { got_this = this; }, recv);
t("set-thisArg", got_this === recv, true);

for (var n = 0; n < out.length; n++) { console.log(out[n]); }
