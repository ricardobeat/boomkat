// Quick smoke test for console.{log,info,debug,trace,warn,error,dir,assert}.
// stdout vs stderr is verified by run.sh via file redirection.
console.log("log-1", 2, true, null, undefined);
console.info("info-1");
console.debug("debug-1");
console.trace("trace-1");
console.warn("warn-1");
console.error("error-1");
console.dir({a:1, b:[2,3]});
console.assert(true, "this should not appear");
console.assert(1, "this should not appear either");
console.assert(false, "msg1", 42);
console.assert(0);
console.assert();
console.log("after assert");

// Confirm return values are undefined.
var r1 = console.log();
var r2 = console.assert(true);
var r3 = console.warn();
console.log("return:", r1, r2, r3);

// Confirm each method is a function with .name/.length.
for (var k of ["log","info","debug","trace","warn","error","dir","assert"]) {
  console.log("name:", console[k].name, "len:", console[k].length);
}