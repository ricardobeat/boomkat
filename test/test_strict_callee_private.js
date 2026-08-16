var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// ES2017 §9.4.4.7: the strict arguments object's `callee` is a non-configurable
// accessor whose get and set are both %ThrowTypeError%, so reads, writes and
// deletes all throw TypeError, and the descriptor reflects the accessor shape.
// test262 10.6-13-c-3-s / 10.6-14-c-4-s pin the descriptor and the write.
// (This engine is strict-only, so every arguments object is unmapped.)

function args() { return arguments; }
var a = args();

// --- 1. Descriptor shape ---
var d = Object.getOwnPropertyDescriptor(a, "callee");
assert(d.configurable === false, "callee non-configurable");
assert(d.enumerable === false, "callee non-enumerable");
assert(d.hasOwnProperty("value") === false, "callee has no value");
assert(d.hasOwnProperty("writable") === false, "callee has no writable");
assert(d.hasOwnProperty("get") === true, "callee has get");
assert(d.hasOwnProperty("set") === true, "callee has set");
assert(typeof d.get === "function", "callee get is a function");
assert(typeof d.set === "function", "callee set is a function");

// --- 2. Reads and writes throw TypeError ---
assert.throws = function (fn, msg) {
    try { fn(); fail++; print("FAIL: " + msg + " (no throw)"); }
    catch (e) { if (e instanceof TypeError) pass++; else { fail++; print("FAIL: " + msg + " (wrong type " + e + ")"); } }
};
assert.throws(function () { return a.callee; }, "callee read throws");
assert.throws(function () { a.callee = {}; }, "callee write throws");
assert.throws(function () { delete a.callee; }, "callee delete throws");

// --- 3. The thrower is the shared %ThrowTypeError% intrinsic ---
var fp_caller_get = Object.getOwnPropertyDescriptor(Function.prototype, "caller").get;
assert(fp_caller_get === d.get, "callee get === Function.prototype.caller get");
assert(d.get === d.set, "callee get === callee set");

// --- 4. The intrinsic is frozen and anonymous ---
assert(Object.isFrozen(d.get), "ThrowTypeError frozen");
assert(Object.isExtensible(d.get) === false, "ThrowTypeError non-extensible");
assert(d.get.name === "", "ThrowTypeError name empty");
var lenDesc = Object.getOwnPropertyDescriptor(d.get, "length");
assert(lenDesc.value === 0 && lenDesc.writable === false
    && lenDesc.enumerable === false && lenDesc.configurable === false,
    "ThrowTypeError length descriptor");

// --- 5. One intrinsic per realm (across multiple arguments objects) ---
var b = args();
var d2 = Object.getOwnPropertyDescriptor(b, "callee");
assert(d2.get === d.get, "same intrinsic across arguments objects");

// ES2022 §13.3.3.3 PrivateFieldSet: a private write must find the field
// (own data property or prototype accessor) or throw TypeError; it must
// never silently create a property. test262
// privatefieldset-typeerror-1 pins the write-before-init case.

// --- 6. Chained private write before field declaration throws ---
class C {
    y = this.#x = 1;
    #x;
}
assert.throws(function () { new C(); }, "chained private write before init throws");

// --- 7. Parenthesized form also throws ---
class C2 {
    y = (this.#x = 1);
    #x;
}
assert.throws(function () { new C2(); }, "parenthesized private write before init throws");

// --- 8. Reading before init throws (already worked, kept as guard) ---
class C3 {
    y = this.#x;
    #x = 5;
}
assert.throws(function () { new C3(); }, "private read before init throws");

// --- 9. Writes to initialized fields still work ---
class C4 {
    m() { this.#x = 9; return this.#x; }
    #x;
}
var c4 = new C4();
assert(c4.m() === 9, "private write after init works");

// --- 10. Private accessor writes still route through the setter ---
var setterRan = false;
class C5 {
    m() { this.#g = 7; return this.#g; }
    get #g() { return 3; }
    set #g(v) { setterRan = (v === 7); }
}
var c5 = new C5();
assert(c5.m() === 3, "private accessor write returns getter value");
assert(setterRan, "private accessor write ran the setter");

print("test_strict_callee_private: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
