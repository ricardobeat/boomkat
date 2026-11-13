// A field store proves its receiver a plain object, which stays known across calls while the
// register holds it: later reads and stores test only its shape, and an inherited method read skips
// the class test. Each case gives the register something else (a proxy, an array, a string wrapper)
// on another path, after a call, at a join or on a loop's back edge, which must be tested again.
var out = [];
function P(v) { this.v = v; this.w = 0; }
P.prototype.get = function () { return this.v; };
// A loop keeps it from being inlined: a real call.
function noop(x) { for (var i = 0; i < 1; i++) x = x | 0; return x; }

// Stored, called, read: the read takes the fact.
function afterCall(o, k) {
    o.w = k;
    noop(k);
    return o.v + o.w + o.get();
}

// The register is given another object after the call.
function rebound(o, other, k) {
    o.w = k;
    noop(k);
    o = (k & 1) ? other : o;
    return o.v;
}

// Plain on one way into a join only.
function joined(o, k) {
    if (k & 1) o.w = k;
    noop(k);
    return o.get() + 0;
}

// The loop's register changes object on the back edge.
function looped(list, n) {
    var s = 0;
    var o = list[0];
    for (var i = 0; i < n; i++) {
        o.w = i;
        noop(i);
        s += o.get();
        o = list[(i + 1) % list.length];
    }
    return s;
}

var handler = { get: function (t, k) { return k === "get" ? function () { return 1000; } : (k === "v" ? 500 : t[k]); },
                set: function (t, k, v) { t[k] = v; return true; } };
var plainA = new P(1), plainB = new P(2);
var proxied = new Proxy(new P(3), handler);
var arr = [9]; arr.v = 7; arr.w = 0; arr.get = function () { return -this.v; };
var boxed = new String("s"); boxed.v = 11; boxed.w = 0;
boxed.get = function () { return this.v * 2; };

var acc = 0;
for (var r = 0; r < 4000; r++) {
    acc += afterCall(plainA, r & 7);
    acc += rebound(plainA, plainB, r);
    acc += joined(plainB, r);
    acc += looped([plainA, plainB], 3);
}
out.push(acc);
// The same sites, now meeting what is not a plain object.
var late = 0;
for (var r = 0; r < 200; r++) {
    late += afterCall(r & 1 ? proxied : plainA, r & 7);
    late += rebound(plainA, r & 2 ? arr : proxied, r);
    late += joined(r & 1 ? boxed : arr, r);
    late += looped([plainA, proxied, arr, boxed], 5);
}
out.push(late, plainA.w, plainB.w, arr.w, boxed.w);
console.log(out.join(" "));
