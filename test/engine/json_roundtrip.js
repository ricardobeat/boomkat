// JSON roundtrip
// Tests JSON.stringify and JSON.parse.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Roundtrip primitives
assert(JSON.parse(JSON.stringify(42)) === 42, "number roundtrip");
assert(JSON.parse(JSON.stringify("hello")) === "hello", "string roundtrip");
assert(JSON.parse(JSON.stringify(true)) === true, "bool roundtrip");
assert(JSON.parse(JSON.stringify(null)) === null, "null roundtrip");

// Object roundtrip
var obj = { name: "Duktape", version: 2.7, nested: { x: [1,2,3] } };
var json = JSON.stringify(obj);
var parsed = JSON.parse(json);
assert(parsed.name === "Duktape", "object string field");
assert(parsed.version === 2.7, "object number field");
assert(parsed.nested.x[2] === 3, "nested array value");

// Array roundtrip
var arr = [1, "two", true, null, [4,5]];
var parr = JSON.parse(JSON.stringify(arr));
assert(parr[0] === 1 && parr[1] === "two" && parr[2] === true, "array basics");
assert(parr[3] === null, "null in array");
assert(parr[4][1] === 5, "nested array");

// JSON.stringify with replacer
var s = JSON.stringify({a:1,b:2}, function(k,v){ return k === "b" ? undefined : v; });
assert(s === '{"a":1}', "replacer filters b, got " + s);

print("engine/json_roundtrip: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
