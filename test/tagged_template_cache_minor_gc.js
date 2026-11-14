// A tagged template's strings array is cached in the constant pool the first
// time the site runs. A minor collection must keep it alive and stable.
function tag(strings) { return strings; }
function site() { return tag`a${1}b`; }
var first = site();
var junk = [];
for (var i = 0; i < 200000; i++) junk.push({ i: i });
junk = null;
for (var j = 0; j < 200000; j++) ({ j: j });
var again = site();
if (first !== again) throw new Error("template object changed identity");
if (again.raw[0] !== "a" || again[1] !== "b") throw new Error("template object corrupted: " + JSON.stringify(again));
print("ok");
