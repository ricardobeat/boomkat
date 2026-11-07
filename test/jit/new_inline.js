// NEW_OBJ of a simple constructor built inline in baseline code (Asm.emit_new_inline): argument
// counts, value kinds, prototypes and their chains changing after the site is armed, setters and
// read-only properties appearing on the chain, closures of one body with different prototypes,
// constructors that return, throw or are not simple, new.target and subclasses, and collections
// that begin and finish inside allocation loops. Every phase prints; jit_check compares the
// output with the interpreter's.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function keys(o) { return Object.keys(o).join(","); }

function P2(a, b) { this.a = a; this.b = b; }
function P0() {}
function P1(a) { this.a = a; }
function P4(a, b, c, d) { this.a = a; this.b = b; this.c = c; this.d = d; }
function P5(a, b, c, d, e) { this.a = a; this.b = b; this.c = c; this.d = d; this.e = e; }
function Swap(a, b) { this.x = b; this.y = a; this.z = b; }
function Ret(a) { this.a = a; return { r: a }; }
function Thrower(a) { this.a = a; if (a === 7777) throw new Error("boom"); }
function Late(a, b) { this.a = a; this.b = b; }
Late.prototype.m = function () { return this.a + this.b; };

function n0() { return new P0(); }
function n1(i) { return new P1(i); }
function n2(i) { return new P2(i, i + 1); }
function n2miss(i) { return new P2(i); }
function n2extra(i) { return new P2(i, i + 1, i + 2, "extra"); }
function n4(i) { return new P4(i, i + 1, i + 2, i + 3); }
function n5(i) { return new P5(i, i + 1, i + 2, i + 3, i + 4); }
function nswap(i) { return new Swap(i, "s" + i); }
function nstr(i) { return new P2("k" + i, "v" + i); }
function nobj(i) { return new P2({ i: i }, [i]); }
function nmixed(i) { return new P2(i + 0.5, null); }
function nret(i) { return new Ret(i); }
function nthrow(i) { return new Thrower(i); }
function nlate(i) { return new Late(i, 1); }

function run(f, n) {
  var last;
  for (var i = 0; i < n; i++) last = f(i);
  return last;
}
function show(label, o) { print(label + " " + keys(o) + " " + JSON.stringify(o)); }

// Warm every site, then read the results.
var N = 3000;
show("p0", run(n0, N));
show("p1", run(n1, N));
show("p2", run(n2, N));
show("p2miss", run(n2miss, N));
show("p2extra", run(n2extra, N));
show("p4", run(n4, N));
show("p5", run(n5, N));
show("swap", run(nswap, N));
show("str", run(nstr, N));
show("obj", run(nobj, N));
show("mixed", run(nmixed, N));
show("ret", run(nret, N));
show("late", run(nlate, N));
check("proto", Object.getPrototypeOf(run(n2, 10)) === P2.prototype);
check("late m", run(nlate, 10).m() === 10);
check("instanceof", run(n2, 10) instanceof P2);

// Throwing constructor: the object is dropped, nothing leaks into the next one.
var thrown = 0;
for (var i = 0; i < N; i++) {
  try { nthrow(i === 2999 ? 7777 : i); } catch (e) { thrown++; }
}
check("thrown", thrown === 1);
show("thrower", nthrow(1));

// A prototype object replaced after the sites are armed.
var oldProto = P2.prototype;
P2.prototype = { marker: 1 };
var o = run(n2, 10);
check("replaced proto", Object.getPrototypeOf(o) === P2.prototype && o.marker === 1);
show("replaced", run(n2, N));
P2.prototype = oldProto;
check("restored proto", Object.getPrototypeOf(run(n2, 10)) === oldProto);
// A non-object prototype falls back to the default one.
P2.prototype = 5;
check("number proto", Object.getPrototypeOf(run(n2, 10)) === Object.prototype);
P2.prototype = oldProto;

// A setter that appears on the chain takes the store from the object.
var seen = [];
Object.defineProperty(P1.prototype, "a", { set: function (v) { seen.push(v); }, configurable: true });
o = run(n1, 5);
check("setter ran", seen.length === 5 && keys(o) === "");
show("setter", o);
delete P1.prototype.a;
check("setter gone", keys(run(n1, 5)) === "a");

// The same on Object.prototype, further up the chain.
Object.defineProperty(Object.prototype, "b", { set: function (v) { seen.push("op" + v); }, configurable: true });
seen = [];
o = run(n2, 3);
check("op setter", keys(o) === "a" && seen.length === 3);
delete Object.prototype.b;
check("op setter gone", keys(run(n2, 3)) === "a,b");

// A read-only property on the chain: the store is silently dropped in sloppy code.
Object.defineProperty(P4.prototype, "c", { value: 1, writable: false, configurable: true });
o = run(n4, 5);
check("readonly", keys(o) === "a,b,d" && o.c === 1);
delete P4.prototype.c;
check("readonly gone", keys(run(n4, 5)) === "a,b,c,d");

// The chain gets longer, then changes under the prototype.
var mid = { fromMid: 1 };
Object.setPrototypeOf(P5.prototype, mid);
o = run(n5, 5);
check("longer chain", o.fromMid === 1 && keys(o) === "a,b,c,d,e");
Object.defineProperty(mid, "e", { set: function (v) { seen.push("mid" + v); }, configurable: true });
seen = [];
o = run(n5, 4);
check("mid setter", keys(o) === "a,b,c,d" && seen.length === 4);
Object.setPrototypeOf(P5.prototype, Object.prototype);
check("chain restored", keys(run(n5, 4)) === "a,b,c,d,e");

// Closures of one body with their own prototypes.
function factory(tag) {
  function C(a, b) { this.a = a; this.b = b; }
  C.prototype.tag = tag;
  return C;
}
var C1 = factory("one"), C2 = factory("two");
function mk(C, i) { return new C(i, i); }
var tags = [];
for (var i = 0; i < N; i++) tags.push(mk(i % 2 ? C1 : C2, i).tag);
check("closure tags", tags[0] === "two" && tags[1] === "one" && tags[2999] === "one");
// A prototype that gains a setter after each closure was armed.
Object.defineProperty(C1.prototype, "b", { set: function (v) { seen.push("c1" + v); }, configurable: true });
seen = [];
o = mk(C1, 9);
check("closure setter", keys(o) === "a" && seen.length === 1);
o = mk(C2, 9);
check("other closure", keys(o) === "a,b");
// Another function in the same site.
function Other(a, b) { this.q = a; this.r = b; }
var sites = [P2, Other, C1, C2];
function mixed(i) { return new sites[i & 3](i, i); }
var ks = [];
for (var i = 0; i < N; i++) ks.push(keys(mixed(i)));
check("mixed ctors", ks[0] === "a,b" && ks[1] === "q,r" && ks[2] === "a" && ks[3] === "a,b");

// Subclasses and new.target.
class Base { constructor(a) { this.a = a; } }
class Sub extends Base { constructor(a) { super(a); this.s = 1; } }
function nbase(i) { return new Base(i); }
function nsub(i) { return new Sub(i); }
show("base", run(nbase, N));
show("sub", run(nsub, N));
check("sub proto", Object.getPrototypeOf(run(nsub, 3)) === Sub.prototype);
function NT() { this.nt = new.target === NT; }
function nnt() { return new NT(); }
check("new.target", run(nnt, N).nt === true);
var viaReflect = Reflect.construct(P2, [1, 2], Other);
check("reflect", Object.getPrototypeOf(viaReflect) === Other.prototype);

// A callee that is not a constructor, or not a function.
var items = [P2, function () {}, () => 1, Math.max, {}, 5, undefined];
var errs = 0;
for (var i = 0; i < N; i++) {
  try { new items[i % items.length](i, i); } catch (e) { errs++; }
}
check("non-ctors throw", errs > 0);

// Allocation pressure with collections in the middle, holding every tenth object.
var keep = [];
var total = 0;
for (var i = 0; i < 200000; i++) {
  var p = new P2(i, "s" + (i & 255));
  var q = new P4(p, i, [i], null);
  total += q.b - q.a.a;
  if (i % 10 === 0) keep.push(q);
}
check("pressure total", total === 0);
var sum = 0;
for (var j = 0; j < keep.length; j++) sum += keep[j].a.a + keep[j].b;
check("kept alive", sum === 2 * 199990 * 20000 / 2 - 0 || sum > 0);
print("kept " + keep.length + " " + sum);
// Objects built inline hold their fields through a full collection.
var held = run(n4, 5);
for (var i = 0; i < 200000; i++) new P2(i, i);
check("held fields", held.a === 4 && held.d === 7);
show("held", held);

// Strings the stores count must outlive their other holders and the collections between.
function mkstr(i) { return new P2("a" + i + "x", "b" + (i * 2) + "y"); }
var strs = [];
for (var i = 0; i < 100000; i++) {
  var s = mkstr(i);
  if (i % 7 === 0) strs.push(s);
  if (i % 3 === 0) new P2("junk" + i, "junk" + i);
}
var okstr = true;
for (var j = 0; j < strs.length; j++) {
  var i = j * 7;
  if (strs[j].a !== "a" + i + "x" || strs[j].b !== "b" + (i * 2) + "y") okstr = false;
}
check("strings survive", okstr);
// The argument of one store read by two (Swap), and a store naming a missing argument.
function sw(i) { return new Swap("p" + i); }
o = run(sw, N);
check("swap missing", o.x === undefined && o.y === "p2999" && o.z === undefined);

print("bad: " + bad.join(" | "));
