// delete then re-add, shared shapes across objects, delete to empty, delete from private shapes
function assert(c, m) { if (!c) { throw new Error("FAIL: " + m); } }

// 1. Basic delete: values shift, reads answer correctly.
var o = { a: 1, b: 2, c: 3, d: 4 };
delete o.b;
assert(o.a === 1 && o.c === 3 && o.d === 4, "shift after middle delete");
assert(o.b === undefined, "deleted key gone");

// 2. Delete first, last, middle.
var o2 = { a: 1, b: 2, c: 3 };
delete o2.a;
assert(o2.b === 2 && o2.c === 3 && o2.a === undefined, "delete first");
var o3 = { a: 1, b: 2, c: 3 };
delete o3.c;
assert(o3.a === 1 && o3.b === 2 && o3.c === undefined, "delete last");
var o4 = { a: 1, b: 2, c: 3, d: 4, e: 5 };
delete o4.c;
assert(o4.a === 1 && o4.b === 2 && o4.d === 4 && o4.e === 5, "delete middle of 5");

// 3. Delete to empty returns to root shape.
var o5 = { a: 1, b: 2 };
delete o5.a; delete o5.b;
assert(o5.a === undefined && o5.b === undefined, "delete to empty");
o5.x = 9;
assert(o5.x === 9, "reuse after empty");

// 4. Non-configurable delete throws (strict), configurable succeeds.
var o6 = {};
Object.defineProperty(o6, "k", { value: 1, configurable: false });
var threw = false;
try { delete o6.k; } catch (e) { threw = (e instanceof TypeError); }
assert(threw, "non-configurable delete throws TypeError");
assert(o6.k === 1, "non-configurable survives");
Object.defineProperty(o6, "j", { value: 2, configurable: true, enumerable: true, writable: true });
assert(delete o6.j === true && o6.j === undefined, "configurable deletes");

// 5. Two objects sharing a transition chain: delete from one must not affect the other.
function mk() { var t = {}; t.p0 = 0; t.p1 = 1; t.p2 = 2; t.p3 = 3; t.p4 = 4; return t; }
var s1 = mk(), s2 = mk();
delete s1.p2;
assert(s1.p0 === 0 && s1.p1 === 1 && s1.p3 === 3 && s1.p4 === 4 && s1.p2 === undefined, "s1 delete");
assert(s2.p2 === 2 && s2.p0 === 0 && s2.p4 === 4, "s2 untouched by s1 delete");

// 6. Delete/insert churn: hash rebuilds, reads stay correct.
var ch = {};
for (var i = 0; i < 300; i++) ch["k" + i] = i;
for (var i = 0; i < 300; i += 2) delete ch["k" + i];
for (var i = 0; i < 300; i++) {
  var want = (i % 2 === 0) ? undefined : i;
  assert(ch["k" + i] === want, "churn read k" + i);
}
ch["fresh"] = 42;
assert(ch["fresh"] === 42, "insert after churn");

// 7. Delete with accessor and non-writable flags preserved.
var acc = {};
Object.defineProperty(acc, "g", { get: function(){ return 7; }, configurable: true, enumerable: true });
Object.defineProperty(acc, "h", { value: 3, writable: false, configurable: true, enumerable: true });
acc.other = 1;
delete acc.other;
assert(acc.g === 7, "accessor survives sibling delete");
assert(acc.h === 3, "non-writable survives sibling delete");

// 8. Enumerate after delete: deleted keys absent.
var e = { a: 1, b: 2, c: 3, d: 4 };
delete e.b;
delete e.d;
var keys = [];
for (var k in e) keys.push(k);
assert(keys.join(",") === "a,c", "enumeration after deletes: " + keys);

// 9. delete returns true for absent key.
assert(delete e.zzz === true, "delete absent returns true");

// 10. for-in with delete during iteration (snapshot semantics).
var f = { a: 1, b: 2, c: 3, d: 4 };
var seen = [];
for (var k in f) { seen.push(k); delete f.d; }
assert(seen.join(",") === "a,b,c", "deleted key skipped mid-iteration: " + seen);

print("all delete_prop tests passed");
