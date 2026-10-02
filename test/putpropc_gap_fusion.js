// Member stores whose value expression sits between the key load and the store.
function check(cond, msg) { if (!cond) throw new Error(msg); }
var o = {}, p = { y: 7 }, i = 3, c = true;
o.a = i;                        check(o.a === 3, "global value");
o.b = i + p.y * 2;              check(o.b === 17, "arithmetic value");
o.c = (o.d = 5) + 1;            check(o.c === 6 && o.d === 5, "nested store");
o.e = c ? 1 : 2;                check(o.e === 1, "ternary value");
o.f = p.y;                      check(o.f === 7, "property value");
o.g = o.a = o.b;                check(o.g === 17 && o.a === 17, "chained store");
function f(q, v) { q.k = v + 1; q.m = q.k; return q; }
var r = f({}, 4);               check(r.k === 5 && r.m === 5, "function scope");
var s = { set z(v) { this.w = v * 2; } };
s.z = i;                        check(s.w === 6, "setter value");
var order = [];
var t = { get x() { order.push("get"); return 1; } };
var u = {};
u.v = t.x;                      check(order.length === 1 && u.v === 1, "getter order");
print("ok");
