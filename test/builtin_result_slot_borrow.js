// `*ctx.result` aliases the callee (or `this`) slot on entry to every builtin,
// holding a RAW, non-incref'd copy of it. A builtin that wrote its result with
// Heap.tval_copy_ref therefore decref'd a reference the slot never owned, so a
// builtin reachable through an intrinsic accessor dropped one reference off
// ITSELF on every call.
//
// `get Error.prototype.stack` was such a builtin. Three indirect calls drove its
// function object's refcount to zero, it was freed to the object pool, and the
// next closure allocation was handed the same memory -- leaving
// Error.prototype's accessor cell pointing at an unrelated JS function. Reading
// `.stack` then CALLED that function; in a real bundle the recycled function was
// a try/catch wrapper that itself annotated `.stack`, so it recursed until
// "Maximum call stack size exceeded".
//
// Reflect.get is the probe rather than a plain `err.stack`: the GETPROP path
// invokes the getter through a convention that stores into a real register
// (which owns its value), while Reflect.get routes through vm_call_fn_impl,
// where the result slot IS the borrowed callee slot. Nothing crashes when the
// bug is present -- the engine just starts answering undefined -- so every check
// below is an identity or type assertion.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}

var d0 = Object.getOwnPropertyDescriptor(Error.prototype, "stack");
t("stack-is-accessor", typeof d0.get, "function");
t("getter-name", d0.get.name, "get stack");

// 1. Far more indirect invocations than the getter's initial refcount. Without
//    the fix the 4th and every later read answered undefined.
var e = new Error("boom");
var non_string = 0;
for (var i = 0; i < 64; i++) {
    if (typeof Reflect.get(Error.prototype, "stack", e) !== "string") { non_string++; }
}
t("reflect-get-always-string", non_string, 0);

// 2. The accessor cell still names the SAME function object. This is where the
//    identity broke once the getter had been freed and its memory reused.
var d1 = Object.getOwnPropertyDescriptor(Error.prototype, "stack");
t("getter-identity-stable", d1.get === d0.get, true);
t("getter-still-callable", typeof d1.get, "function");
t("getter-still-named", d1.get.name, "get stack");
t("setter-identity-stable", d1.set === d0.set, true);

// 3. Allocating closures between reads is what consumed the recycled memory in
//    the original failure, so interleave the two.
var fns = [];
for (var j = 0; j < 64; j++) {
    Reflect.get(Error.prototype, "stack", new Error("j" + j));
    fns.push(function () { return j; });
}
var d2 = Object.getOwnPropertyDescriptor(Error.prototype, "stack");
t("getter-survives-closure-churn", d2.get === d0.get, true);
t("plain-read-still-string", typeof (new Error("z")).stack, "string");

// 4. The end-to-end shape: a wrapper that rethrows after annotating `.stack`.
//    With the getter recycled into a JS function this recursed without bound.
function wrap(inner) {
    var tail = "";
    try { throw new Error(); } catch (err) { if (err.stack) { tail = err.stack; } }
    return function (arg) {
        try { return inner(arg); }
        catch (err) { throw (err.stack += "\n  ---\n" + tail, err); }
    };
}
var caught = null;
try { wrap(function () { throw new Error("inner"); })(1); } catch (err) { caught = err; }
t("wrapper-threw", caught !== null, true);
t("wrapper-message", caught && caught.message, "inner");
t("wrapper-stack-annotated", typeof caught.stack === "string" && caught.stack.indexOf("---") >= 0, true);

// 5. Date.prototype.toJSON and @@toPrimitive stored their results the same
//    wrong way. Reached directly here rather than through Reflect.apply, which
//    has its own separate instance of the borrowed-result-slot bug (calling a
//    Date method through it still decays after three calls) that this change
//    does not address.
var dt = new Date(0);
var dtoJSON = Date.prototype.toJSON;
var bad_json = 0;
for (var k = 0; k < 64; k++) {
    if (typeof dt.toJSON() !== "string") { bad_json++; }
}
t("date-toJSON-always-string", bad_json, 0);
t("date-toJSON-identity-stable", Date.prototype.toJSON === dtoJSON, true);

var toPrim = Date.prototype[Symbol.toPrimitive];
var bad_prim = 0;
for (var m = 0; m < 64; m++) {
    if (typeof dt[Symbol.toPrimitive]("string") !== "string") { bad_prim++; }
}
t("date-toPrimitive-always-string", bad_prim, 0);
t("date-toPrimitive-identity-stable", Date.prototype[Symbol.toPrimitive] === toPrim, true);

for (var n = 0; n < out.length; n++) { console.log(out[n]); }
