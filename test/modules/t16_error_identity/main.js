// Test 16: a module that fails evaluation caches its error, and EVERY later
// import of it re-reports that identical object (ECMA-262 16.2.1.5.3: the
// [[EvaluationError]] is stored on the module and re-thrown, never recomputed).
//
// Regression: link_module returned an ERRORED module to LINKED, so the second
// import re-ran the body and produced a NEW error object. Observable as
// `e1 !== e2` even though both had the same shape, and as the module's side
// effects running twice.

let e1;
await import("./throws.js").catch((e) => { e1 = e; });
let e2;
await import("./throws.js").catch((e) => { e2 = e; });

if (e1 === undefined) throw new Error("first import did not reject");
if (e1 !== e2) throw new Error("evaluation error was not cached: e1 !== e2");

// The body must not have run a second time: mutating the cached object is
// visible through the later import precisely because it is the same object.
e1.tag = "mutated";
if (e2.tag !== "mutated") throw new Error("errors are distinct objects");
