// The module cache keeps the namespace object for every later import(); a
// collection must not free it when no binding holds it.
await import('./dep.js');
var junk = [];
for (var i = 0; i < 300000; i++) { junk.push({ i: i }); if (junk.length > 1000) junk = []; }
var ns = await import('./dep.js');
if (ns.answer !== 42 || ns.twice(4) !== 8 || Object.keys(ns).join() !== "answer,twice") {
    throw "namespace object was collected: " + Object.keys(ns).join();
}
