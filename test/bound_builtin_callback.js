// Regression: a bound function whose target is a native builtin was silently
// never invoked when the call entered through Heap.call_fn (vm_call_fn_impl),
// the generic native-to-JS call path behind Map/Set.prototype.forEach,
// Array.prototype.map, Promise reactions, and friends.
//
// The path dispatched the bound function's BOUND_CALL builtin through a
// stack-allocated register window, and builtin_bound_call answered with its
// frame-mode re-dispatch: it rewrote the window with decref/incref slot
// surgery that is balanced only against real frame registers (here it drained
// one reference from the bound function per call) and asked the caller to
// re-run the call against the unwrapped target. The caller's re-dispatch only
// understood compiled functions, so a bound builtin or lightfunc target fell
// through and the call returned undefined without running anything.
//
// vm_call_fn_impl now unwraps bound functions itself (prepend the bound args,
// re-target, recurse), the same shape as the [[Construct]] unwrap.
//
// Expected values checked against node.

var pass = 0, fail = 0;
function ck(name, got, want) {
    if (got === want) { pass++; }
    else { fail++; console.log("FAIL " + name + ": got " + got + ", want " + want); }
}

// --- Bound Array.prototype.push (BUILTIN_FN object target) as a callback ---
var arr = [];
var bound = arr.push.bind(arr, 1);
var m = new Map([["a", 1]]);
m.forEach(bound);
// forEach calls callback(value, key, map); the bound arg prepends, so each
// call pushes 4 entries.
ck("map-forEach-bound-builtin length", arr.length, 4);
ck("map-forEach-bound-builtin [0]", arr[0], 1);
ck("map-forEach-bound-builtin [1]", arr[1], 1);
ck("map-forEach-bound-builtin [2]", arr[2], "a");
ck("map-forEach-bound-builtin [3] is map", arr[3] === m, true);

var s = new Set(["x"]);
var arr2 = [];
s.forEach(arr2.push.bind(arr2, 0));
ck("set-forEach-bound-builtin length", arr2.length, 4);
ck("set-forEach-bound-builtin [2]", arr2[2], "x");
ck("set-forEach-bound-builtin [3] is set", arr2[3] === s, true);

// --- Bound raw lightfunc target (Math.max) reached through call_fn --------
var outs = [];
m.forEach(function (v, k) { outs.push(Math.max.bind(null, 7)(v)); });
ck("bound-lightfunc nested in callback", outs.join(","), "7");

// The bound lightfunc itself as the callback.
var seen = [];
var s2 = new Set([3, 9]);
s2.forEach(function (v) { seen.push(Math.min.bind(null, 5)(v)); });
ck("bound-lightfunc values", seen.join(","), "3,5");

// --- Direct call of a bound builtin, no collection involved ----------------
var d = [];
var dp = d.push.bind(d, "a", "b");
ck("direct bound push return", dp("c"), 3);
ck("direct bound push contents", d.join(","), "a,b,c");

// --- Nested bind: inner bound args come first ------------------------------
var n = [];
var nf = n.push.bind(n, "x").bind(null, "y");
nf("z");
ck("nested bind order", n.join(","), "x,y,z");

// --- Bound compiled function through the same path (already worked) --------
var hits = 0;
m.forEach((function () { hits++; }).bind(null));
ck("bound compiled fn still invoked", hits, 1);

// --- Array.prototype.map with a bound callback -----------------------------
// Math.max.bind(null, 2) directly as a .map callback would pass the index
// and array extra args that coerce to NaN, which is the same in node.
// The test wraps it to isolate the bound-call from the extra map args.
var mapped = [1, 2, 3].map(function (v) { return Math.max.bind(null, 2)(v); });
ck("map bound lightfunc", mapped.join(","), "2,2,3");

// --- Return value of forEach stays undefined with a bound callback ---------
ck("forEach returns undefined", m.forEach(bound), undefined);

// --- Reference drain: the same bound function, many calls ------------------
// The old dispatch dropped one reference from the bound function per call, so
// enough repetitions freed it mid-loop. 2000 iterations with allocation
// churn in between to give the collector something to recycle into.
var drain = [];
var dbound = drain.push.bind(drain, 0);
var m1 = new Map([["k", 1]]);
for (var i = 0; i < 2000; i++) {
    m1.forEach(dbound);
    var churn = [];
    for (var j = 0; j < 10; j++) churn.push({ v: j });
}
ck("repeated bound callback count", drain.length, 8000);
ck("repeated bound callback first", drain[0], 0);
ck("repeated bound callback last is map", drain[drain.length - 1] === m1, true);

console.log("bound_builtin_callback: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error(fail + " failures");
