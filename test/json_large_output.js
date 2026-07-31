// JSON.stringify must never return success carrying truncated output, and
// JSON.parse must accept everything JSON.stringify produces.
//
// On a baseline built at d6b92443 four separate fixed buffers clipped the
// result and reported success anyway:
//   - a 16384-byte output buffer,
//   - a 4096-byte per-string escape buffer (strings clipped at 4095 chars),
//   - 1024-byte per-key escape buffers,
//   - a 64-entry property-key snapshot (objects clipped at 64 keys).
// A fifth, in JSON.parse, rejected any string literal over 1024 bytes as a
// SyntaxError, so a document this engine produced would not parse back.
//
// Expected values are node's. Runs unmodified under node with `--import` a
// shim defining print().

var failures = 0;
var checks = 0;

function eq(name, actual, expected) {
  checks++;
  if (actual !== expected) {
    failures++;
    print("FAIL: " + name + " => " + JSON.stringify(actual) +
          " (expected " + JSON.stringify(expected) + ")");
  }
}

function mkObj(n) {
  var o = {};
  for (var i = 0; i < n; i++) o["k" + i] = i;
  return o;
}

// --- object size: the 64-key snapshot cap ----------------------------------
// Every key must survive, not just the first 64. Lengths are node's.
eq("1 key length", JSON.stringify(mkObj(1)).length, 8);
eq("100 keys length", JSON.stringify(mkObj(100)).length, 881);
eq("2000 keys length", JSON.stringify(mkObj(2000)).length, 23781);
eq("5000 keys length", JSON.stringify(mkObj(5000)).length, 62781);
eq("2000 keys parse back", Object.keys(JSON.parse(JSON.stringify(mkObj(2000)))).length, 2000);

// The 65th key is the first one the old cap dropped.
eq("65 keys parse back", Object.keys(JSON.parse(JSON.stringify(mkObj(65)))).length, 65);

// --- string size: the 4096-byte escape buffer ------------------------------
// 4095 was the first length that stopped round-tripping.
var s4095 = new Array(4096).join("a");
eq("4095-char string", JSON.stringify(s4095).length, 4097);
eq("4095-char round trip", JSON.parse(JSON.stringify(s4095)), s4095);

var s20000 = new Array(20001).join("b");
eq("20000-char string", JSON.stringify(s20000).length, 20002);
eq("20000-char round trip", JSON.parse(JSON.stringify(s20000)), s20000);

// Escapes expand, so the output outruns the input well before 4096 bytes.
var esc = "";
for (var i = 0; i < 3000; i++) esc += 'a"b\\c\n\t';
eq("escape-heavy length", JSON.stringify(esc).length, 33002);
eq("escape-heavy round trip", JSON.parse(JSON.stringify(esc)), esc);

// --- key size: the 1024-byte key buffer ------------------------------------
var longKey = new Array(5001).join("K");
var keyObj = {};
keyObj[longKey] = 1;
eq("5000-char key", JSON.stringify(keyObj).length, 5006);
eq("5000-char key round trip", Object.keys(JSON.parse(JSON.stringify(keyObj)))[0], longKey);

// --- JSON.parse's own 1024-byte string buffer ------------------------------
// Valid JSON, never produced by stringify here, must still parse.
var lit = '"' + new Array(3001).join("z") + '"';
eq("3000-char literal parses", JSON.parse(lit).length, 3000);
var escLit = '"' + new Array(1500).join("\\n") + '"';
eq("1499 escapes parse", JSON.parse(escLit).length, 1499);

// --- unicode and surrogates survive the growable path ----------------------
var uni = "héllo — 日本語 🎉 ∑";
eq("unicode round trip", JSON.parse(JSON.stringify(uni)), uni);
var uniLong = "";
for (var i = 0; i < 2000; i++) uniLong += "日🎉";
eq("long unicode round trip", JSON.parse(JSON.stringify(uniLong)), uniLong);
eq("lone high surrogate", JSON.stringify("\ud800"), '"\\ud800"');
eq("lone low surrogate", JSON.stringify("\udfff"), '"\\udfff"');
eq("surrogate pair", JSON.stringify("🎉"), '"🎉"');

// --- large arrays and nesting ----------------------------------------------
eq("5000-element array", JSON.stringify(new Array(5000).fill(12345)).length, 30001);
eq("nested big objects", JSON.stringify({ a: mkObj(1000), b: mkObj(1000) }).length, 21573);
var deep = [];
for (var i = 0; i < 100; i++) deep = [deep, i];
eq("deep nesting round trip", JSON.stringify(JSON.parse(JSON.stringify(deep))), JSON.stringify(deep));

// --- the replacer and space arguments take the same path -------------------
eq("replacer function", JSON.stringify(mkObj(500), function (k, v) {
  return typeof v === "number" ? v * 2 : v;
}).length, 5336);
eq("replacer array", JSON.stringify(mkObj(500), ["k1", "k2", "k300"]),
   '{"k1":1,"k2":2,"k300":300}');
eq("space 2", JSON.stringify(mkObj(300), null, 2).length, 4282);
eq("space tab", JSON.stringify(mkObj(300), null, "\t").length, 3982);
eq("space sample", JSON.stringify({ a: { b: [1, 2] } }, null, 2),
   '{\n  "a": {\n    "b": [\n      1,\n      2\n    ]\n  }\n}');

// --- values with special serializations are unchanged ----------------------
eq("Infinity and NaN", JSON.stringify({ a: Infinity, b: -Infinity, c: NaN }),
   '{"a":null,"b":null,"c":null}');
eq("Date toJSON", JSON.stringify({ d: new Date(0) }), '{"d":"1970-01-01T00:00:00.000Z"}');
eq("Map and Set", JSON.stringify({ m: new Map([[1, 2]]), s: new Set([1, 2]) }), '{"m":{},"s":{}}');
eq("nested undefined/function/symbol",
   JSON.stringify({ a: undefined, b: function () {}, c: Symbol("x"), d: 1 }), '{"d":1}');
eq("root undefined", JSON.stringify(undefined), undefined);
eq("root function", JSON.stringify(function () {}), undefined);
eq("nulls and bools", JSON.stringify({ a: null, b: true, c: false }),
   '{"a":null,"b":true,"c":false}');
eq("numbers", JSON.stringify({ a: 0, b: -0, c: 1e21, d: 1e-7, e: 1.5, f: -3 }),
   '{"a":0,"b":0,"c":1e+21,"d":1e-7,"e":1.5,"f":-3}');

// BigInt throws rather than serializing.
var bigintThrew = false;
try { JSON.stringify({ a: 1n }); } catch (e) { bigintThrew = e instanceof TypeError; }
eq("BigInt throws TypeError", bigintThrew, true);

// A cycle is still a TypeError, not a truncated document.
var cyc = {};
cyc.self = cyc;
var cycThrew = false;
try { JSON.stringify(cyc); } catch (e) { cycThrew = e instanceof TypeError; }
eq("cycle throws TypeError", cycThrew, true);

// --- round-trip identity over the whole battery ----------------------------
var roundTrips = [
  mkObj(1), mkObj(100), mkObj(2000), mkObj(5000),
  s4095, s20000, esc, keyObj, uni, uniLong, deep,
  new Array(3000).fill(7), { a: null, b: true, c: 1.5 }
];
for (var i = 0; i < roundTrips.length; i++) {
  var once = JSON.stringify(roundTrips[i]);
  var twice = JSON.stringify(JSON.parse(once));
  eq("round trip stable #" + i, twice, once);
}

if (failures !== 0) {
  throw new Error(failures + " of " + checks + " JSON size checks failed");
}
print("PASS: JSON large output (" + checks + " checks)");
