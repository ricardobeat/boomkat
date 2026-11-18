// Builtin getters read at getter sites and builtin constructors under NEW_OBJ, which compiled code
// runs without the thunk (vm::jit_call_builtin, vm::jit_new_builtin), warmed past the compile
// threshold: throws from either, a getter on a receiver it rejects, a constructor that runs JS
// (Promise's executor) or reads its argument's getters, a subclass, and sites that turn from a
// builtin to a JS function and back.
const N = 3000;
const print = globalThis.print ?? console.log;
const out = [];

// Map.prototype.size at GETPROPC sites: plain, through `this`, and on a receiver it rejects.
class Box extends Map { count() { return this.size; } }
function sizes(m) { return m.size; }
let s = 0;
const big = new Map([[1, 1], [2, 2], [3, 3]]);
const box = new Box([[1, 1]]);
for (let i = 0; i < N; i++) s += sizes(big) + box.count();
out.push(s);
const fake = Object.create(Map.prototype);
for (let i = 0; i < 3; i++) {
  try { sizes(fake); out.push("no throw"); } catch (e) { out.push(e.constructor.name); }
}

// A getter that calls back into JS: RegExp.prototype.flags reads the other flag getters.
const re = /a/gi;
function flags(r) { return r.flags; }
let f = "";
for (let i = 0; i < N; i++) f = flags(re);
Object.defineProperty(re, "global", { get() { return false; } });
out.push(f, flags(re));

// A site whose accessor turns from a builtin getter to a JS one and back.
const proto = { get v() { return 1; } };
const nativeV = Object.getOwnPropertyDescriptor(Map.prototype, "size").get;
const objs = [Object.create(proto)];
function readV(o) { return o.v; }
let rv = 0;
for (let i = 0; i < N; i++) rv += readV(objs[0]);
Object.defineProperty(proto, "v", { get: nativeV, configurable: true });
try { readV(objs[0]); } catch (e) { out.push("swapped " + e.constructor.name); }
Object.defineProperty(Map.prototype, "v", { get: nativeV, configurable: true });
for (let i = 0; i < N; i++) rv += readV(big);
delete Map.prototype.v;
out.push(rv);

// Builtin constructors: plain, throwing, reading their argument, and running JS.
function make(kind, arg) {
  switch (kind) {
    case 0: return new Map(arg);
    case 1: return new Set(arg);
    case 2: return new Uint8Array(arg);
    case 3: return new Date(arg);
    case 4: return new Promise(arg);
  }
}
let total = 0;
for (let i = 0; i < N; i++) {
  total += make(0, [[i, i]]).size + make(1, [i]).size + make(2, 4).length + (make(3, 0).getTime() === 0 ? 1 : 0);
}
out.push(total);
for (const bad of [5, { [Symbol.iterator]: 1 }]) {
  try { make(0, bad); out.push("no throw"); } catch (e) { out.push("map " + e.constructor.name); }
}
try { make(2, -1); } catch (e) { out.push("u8 " + e.constructor.name); }
let ran = 0;
for (let i = 0; i < N; i++) make(4, (res) => { ran++; res(i); });
out.push(ran);
try { make(4, () => { throw new RangeError("inner"); }).catch((e) => out.push("rejected " + e.message)); } catch (e) { out.push("sync " + e.message); }
try { make(4, 1); } catch (e) { out.push("promise " + e.constructor.name); }
const iterGetter = { *[Symbol.iterator]() { ran++; yield ran; } };
for (let i = 0; i < 10; i++) make(1, iterGetter);
out.push(ran);

// new on a builtin that is not a constructor, and a site that turns to a JS class.
function construct(C, a) { return new C(a); }
for (let i = 0; i < N; i++) construct(Map);
try { construct(Math.max); } catch (e) { out.push("max " + e.constructor.name); }
class Own { constructor(a) { this.a = a; } }
out.push(construct(Own, 7).a, construct(Map, [[1, 2]]).get(1));

Promise.resolve().then(() => print(out.join(" ")));
