// A function's assignment to a global the script declares with var or function needs no
// resolution guard: the binding exists before any code runs and cannot be deleted. Names the
// script does not declare, or declares only through an Annex B block function, keep it.
var counter = 0;
function total() { return 1; }
function bump(n) { for (var i = 0; i < n; i++) counter = counter + 1; }
function rebind() { total = function () { return 2; }; }
bump(1000);
rebind();
if (counter !== 1000 || total() !== 2) throw new Error("declared " + counter + " " + total());
if (delete globalThis.counter || globalThis.counter !== 1000) throw new Error("not configurable");

function strictUndeclared() { "use strict"; undeclared = 1; }
var threw = false;
try { strictUndeclared(); } catch (e) { threw = e instanceof ReferenceError; }
if (!threw || "undeclared" in globalThis) throw new Error("strict undeclared");

// Deleted between two strict assignments: the second throws.
globalThis.loose = 1;
function strictLoose() { "use strict"; loose = 2; }
strictLoose();
delete globalThis.loose;
threw = false;
try { strictLoose(); } catch (e) { threw = e instanceof ReferenceError; }
if (!threw) throw new Error("strict deleted");

{ function blockFn() { return 3; } }
function setBlock() { blockFn = 4; }
setBlock();
if (blockFn !== 4) throw new Error("annex b");
console.log("ok");
