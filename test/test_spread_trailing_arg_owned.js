// A non-spread argument after a spread reaches the callee through PUTARG. The
// argument slot owns its reference, so the callee's return sweep releases it
// without freeing a value the caller still holds. A string built per call and
// then passed on from the callee exposed the underflow: the caller's temporary
// was freed while its register still pointed at it.

function sink(a) { return a.length; }
function pass(a, b, c, d) { var s = d + "x"; return sink(s) + d.length; }

let total = 0;
let expected = 0;
for (let i = 0; i < 20000; i++) {
  total += pass(1, ...[0, 0], "a" + i);
  expected += String(i).length * 2 + 3;
}
if (total !== expected) throw new Error("string trailing arg: " + total + " != " + expected);

// A heap object that the caller holds only in a temporary register.
function inspect(a, b, o) { var t = [o, o]; return t.length + o.n; }
let objTotal = 0;
for (let i = 0; i < 20000; i++) {
  objTotal += inspect(0, ...[1], { n: i });
}
if (objTotal !== 2 * 20000 + (20000 * 19999) / 2) throw new Error("object trailing arg: " + objTotal);

// A callee that throws unwinds with the argument slot still owned.
function thrower(a, b, c) { var s = c + "!"; throw new Error(s); }
let caught = 0;
for (let i = 0; i < 5000; i++) {
  try {
    thrower(...[0], 1, "e" + i);
  } catch (e) {
    if (e.message !== "e" + i + "!") throw new Error("message: " + e.message);
    caught++;
  }
}
if (caught !== 5000) throw new Error("caught " + caught);

// The same shape through a method call and a constructor.
const holder = {
  join(a, b, c) { return a + b + c; },
};
let joined = "";
for (let i = 0; i < 2000; i++) {
  joined = holder.join(...["x", "y"], "z" + i);
}
if (joined !== "xyz1999") throw new Error("method: " + joined);

function Pair(a, b, c) { this.v = a + b + c; }
let made = null;
for (let i = 0; i < 2000; i++) {
  made = new Pair(...["p", "q"], "r" + i);
}
if (made.v !== "pqr1999") throw new Error("construct: " + made.v);

print("ok");
