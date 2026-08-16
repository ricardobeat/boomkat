var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// ES5 §10.4.3 (strict mode): a getter invoked on a primitive receiver must
// receive the primitive itself as `this`, not a ToObject box. This engine is
// strict-only, so every getter is a strict function and the rule is
// unconditional. (test262 10.4.3-1-104 / -106 pin the number case; this file
// sweeps all five primitive types plus data-prop fallbacks and chains.)

// --- 1. Number receiver keeps its identity and type ---
Object.defineProperty(Object.prototype, "g", { get: function () { return this; } });
assert((5).g === 5, "number getter this is the primitive");
assert(typeof (5).g === "number", "number getter this typeof number");
assert(!(Number.prototype.isPrototypeOf((5).g)), "number getter this is not boxed");

// --- 2. String receiver ---
assert(("a").g === "a", "string getter this is the primitive");
assert(typeof ("a").g === "string", "string getter this typeof string");

// --- 3. Boolean receiver ---
assert((true).g === true, "boolean getter this is the primitive");
assert(typeof (true).g === "boolean", "boolean getter this typeof boolean");

// --- 4. BigInt receiver ---
assert((1n).g === 1n, "bigint getter this is the primitive");
assert(typeof (1n).g === "bigint", "bigint getter this typeof bigint");

// --- 5. Symbol receiver: accessor on Symbol.prototype, primitive this ---
Object.defineProperty(Symbol.prototype, "s", { get: function () { return this; } });
var sym = Symbol("x");
assert(sym.s === sym, "symbol getter this is the primitive");
assert(typeof sym.s === "symbol", "symbol getter this typeof symbol");

// --- 6. Symbol.prototype.description still works (builtin getter) ---
assert(Symbol("desc").description === "desc", "Symbol.prototype.description reads the primitive");
assert(Symbol().description === undefined, "Symbol() description undefined");

// --- 7. Accessor defined directly on Number.prototype (not Object.prototype) ---
Object.defineProperty(Number.prototype, "np", { get: function () { return typeof this; } });
assert((7).np === "number", "Number.prototype accessor receives primitive");
// Must not leak onto objects: the own-object path passes the object.
var numObj = new Number(7);
assert(numObj.np === "object", "Number object accessor receives the object");

// --- 8. Data properties still resolve on primitives ---
assert((5).toFixed !== undefined, "number data method resolves");
assert(("abc").toUpperCase() === "ABC", "string data method works");
assert((true).toString() === "true", "boolean data method works");
assert((10n).toString() === "10", "bigint data method works");

// --- 9. Fused two-hop chain: primitive hop 1 getter feeds hop 2 ---
Object.defineProperty(Object.prototype, "chain", { get: function () { return { v: this }; } });
var ch = (42).chain;
assert(ch.v === 42, "two-hop chain preserves primitive this at hop 1");
assert(typeof ch.v === "number", "two-hop chain value type number");

// --- 10. A throwing getter on a primitive receiver propagates ---
Object.defineProperty(Object.prototype, "boom", { get: function () { throw new RangeError("prim"); } });
try {
    var b = (1).boom;
    assert(false, "throwing getter on primitive must throw");
} catch (e) {
    assert(e instanceof RangeError && e.message === "prim", "throwing getter error type/message");
}

// --- 11. Getter on string primitive via String.prototype ---
Object.defineProperty(String.prototype, "sg", { get: function () { return this.length; }, configurable: true });
assert(("hello").sg === 5, "String.prototype getter sees primitive this");
// Clean up so later String.prototype uses are unaffected.
delete String.prototype.sg;
assert(("x").sg === undefined, "deleted String.prototype getter gone");

print("test_strict_getter_this: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
