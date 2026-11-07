// The native call protocol across call shapes: hot sites calling through the
// baseline's direct call entry and returning through its inline pop, mixed with
// shapes it declines (arguments, defaults, rest, accessors, bound functions,
// native callbacks), deep recursion, throws through native frames and stack
// overflow. Results match the interpreter.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function add(a, b) { var t = a; if (t > 1e9) t = 0; return t + b; }
function P(x) { this.x = x; }
P.prototype.get = function (k) { var y = this.x; if (k < 0) y = 2; return y + k; };
P.prototype.self = function () { return this; };
function mk(i) { return { v: i, w: [i] }; }
function useArgs() { return arguments.length + (arguments[0] | 0); }
function defs(a, b = 7) { return a + b; }
function rest(a, ...r) { return a + r.length; }
function locals(a) { var b = 1, c = 2, d = 3, e = 4, f = 5, g = 6, h = 7, i = 8, j = 9, k = 10, l = 11, m = 12, n = 13; return a + b + c + d + e + f + g + h + i + j + k + l + m + n; }
var acc = { _v: 1, get v() { return this._v + 1; }, set v(x) { this._v = x; } };
var bound = add.bind(null, 100);
function rec(n) { if (n === 0) return 0; return 1 + rec(n - 1); }
function thrower(i) { if (i % 97 === 3) throw new Error("t" + i); return i; }
function catcher(i) { try { return thrower(i); } catch (e) { return -1; } }
function str(i) { var s = "k" + i; return s; }
function forever(n) { return forever(n + 1) + 1; }

var o = new P(3);
var s = 0, objs = 0, strs = 0, caught = 0;
for (var i = 0; i < 3000; i++) {
    s = add(s, i) | 0;
    s = (s + o.get(i)) | 0;
    if (o.self() !== o) s = -1;
    var m = mk(i);
    objs += m.v + m.w[0];
    s = (s + useArgs(i, 2) + useArgs()) | 0;
    s = (s + defs(i) + defs(i, 1) + rest(i, 1, 2, 3) + rest(i)) | 0;
    s = (s + locals(i)) | 0;
    acc.v = i;
    s = (s + acc.v) | 0;
    s = (s + bound(i)) | 0;
    caught += catcher(i);
    strs += str(i).length;
}
show("s", s);
show("objs", objs);
show("strs", strs);
show("caught", caught);
show("rec", rec(2500));
show("map", [1, 2, 3, 4].map(function (x) { return add(x, x); }).join(","));
var arr = [];
for (var i = 0; i < 200; i++) arr.push((i * 7919) % 211);
arr.sort(function (a, b) { return add(a, -b); });
show("sorted", arr[0] + "," + arr[100] + "," + arr[199]);
var thrownOut = 0;
for (var i = 0; i < 2000; i++) { try { thrower(i); } catch (e) { thrownOut++; } }
show("thrownOut", thrownOut);
try { forever(0); show("overflow", "none"); } catch (e) { show("overflow", e instanceof RangeError); }
// Calls still work after the overflow unwound every native frame.
var after = 0;
for (var i = 0; i < 2000; i++) after = add(after, o.get(1));
show("after", after);
print(out.join("\n"));

// Large frames take the looped undefined fill; alternate populated and empty
// locals to catch stale slots at both the paired extent and its odd tail.
function largeEven(a) {
    var b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z;
    if (a < 0) { b=c=d=e=f=g=h=i=j=k=l=m=n=o=p=q=r=s=t=u=v=w=x=y=z=a; }
    return (b === undefined ? 1 : b) + (z === undefined ? 1 : z);
}
function largeOdd(a) {
    var b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,zz;
    if (a < 0) { b=c=d=e=f=g=h=i=j=k=l=m=n=o=p=q=r=s=t=u=v=w=x=y=z=zz=a; }
    return (b === undefined ? 1 : b) + (zz === undefined ? 1 : zz);
}
var largeTotal = 0;
for (var i = 0; i < 3000; i++) {
    largeTotal += largeEven(-1) + largeEven(1) + largeOdd(-1) + largeOdd(1);
}
print("large=" + largeTotal);
