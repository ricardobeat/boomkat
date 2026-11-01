// JSON over narrow (Latin-1) and wide (UTF-16) strings: output and parsed
// strings must hold the same units whichever width the pieces were built in.
if (typeof print == "undefined" && typeof console != "undefined") print = console.log;

function eq(actual, expected, label) {
  if (actual !== expected) {
    print("FAIL " + label + ": got " + JSON.stringify(escapeAll(String(actual))) +
          " expected " + JSON.stringify(escapeAll(String(expected))));
  }
}
function escapeAll(s) {
  var out = "";
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    out += c < 0x7f && c >= 0x20 ? s[i] : "<" + c.toString(16) + ">";
  }
  return out;
}
function units(s) {
  var out = [];
  for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i));
  return out.join(",");
}

var FILLERS = ["", "a", "abcdefg", "abcdefgh", "abcdefghi", "0123456789abcdef0123"];
var CASES = [
  // [input, expected stringify output]
  ["", '""'],
  ["abc", '"abc"'],
  ["caf\u00e9", '"caf\u00e9"'],
  ["\u00ff\u0080\u00a0", '"\u00ff\u0080\u00a0"'],
  ["\u0100", '"\u0100"'],
  ["\u65e5\u672c\u8a9e", '"\u65e5\u672c\u8a9e"'],
  ["\ud83d\ude00", '"\ud83d\ude00"'],
  ["a\ud83d\ude00b", '"a\ud83d\ude00b"'],
  ["\ud800", '"\\ud800"'],
  ["\udfff", '"\\udfff"'],
  ["\udc00\ud800", '"\\udc00\\ud800"'],
  ["\ud800\ud800\udc00", '"\\ud800\ud800\udc00"'],
  ["\ud800a", '"\\ud800a"'],
  ["a\udc00", '"a\\udc00"'],
  ["\ud83d", '"\\ud83d"'],
  ["\u00e9\ud800", '"\u00e9\\ud800"'],
  ["\u65e5\ud800\u672c", '"\u65e5\\ud800\u672c"'],
  ['"\\\n\t\u0001', '"\\"\\\\\\n\\t\\u0001"'],
  ["\u65e5\"\u672c", '"\u65e5\\"\u672c"'],
  ["\u00e9\n\u00e9", '"\u00e9\\n\u00e9"'],
  ["\u2028\u2029", '"\u2028\u2029"'],
  ["\u0000\u001f", '"\\u0000\\u001f"'],
  ["\u007f\u0080", '"\u007f\u0080"'],
];
for (var i = 0; i < CASES.length; i++) {
  for (var p = 0; p < FILLERS.length; p++) {
    for (var q = 0; q < FILLERS.length; q++) {
      var input = FILLERS[p] + CASES[i][0] + FILLERS[q];
      var want = CASES[i][1];
      want = '"' + FILLERS[p] + want.slice(1, -1) + FILLERS[q] + '"';
      eq(JSON.stringify(input), want, "stringify " + i + "/" + p + "/" + q);
      // Round trip: every case but the lone-surrogate ones comes back unchanged,
      // and those too, since the escapes parse back to the same units.
      var back = JSON.parse(JSON.stringify(input));
      eq(units(back), units(input), "roundtrip " + i + "/" + p + "/" + q);
      // As object key and value, with a narrow neighbour that stays narrow.
      var obj = {};
      obj[input] = input;
      obj.plain = "x";
      var text = JSON.stringify(obj);
      eq(text, '{' + want + ':' + want + ',"plain":"x"}', "object " + i + "/" + p + "/" + q);
      var parsed = JSON.parse(text);
      eq(units(Object.keys(parsed)[0]), units(input), "key " + i + "/" + p + "/" + q);
      eq(units(parsed[input]), units(input), "value " + i + "/" + p + "/" + q);
      eq(parsed.plain, "x", "plain " + i + "/" + p + "/" + q);
    }
  }
}

// The output widens only when a unit needs it. These compare equal as strings
// and as property keys whichever path built them.
var narrow = JSON.stringify({ a: "caf\u00e9", b: ["\u00ff"] });
eq(narrow, '{"a":"caf\u00e9","b":["\u00ff"]}', "latin1 object");
eq(narrow.length, 22, "latin1 length");
var lone = JSON.stringify(["\ud800", "x"]);
eq(lone, '["\\ud800","x"]', "lone in array");
eq(lone.length, 14, "lone length");
var key = {};
key[JSON.stringify("\ud800")] = 1;
eq(key['"\\ud800"'], 1, "escaped key identity");
var wide = JSON.stringify({ "\u65e5": "\u672c", n: 1 });
eq(wide, '{"\u65e5":"\u672c","n":1}', "wide object");
eq(JSON.stringify({ "\u65e5": 1 }) === '{"\u65e5":1}', true, "equality with literal");

// Indentation with a wide gap.
eq(JSON.stringify([1, { a: "\u00e9" }], null, "\u65e5"),
   '[\n\u65e51,\n\u65e5{\n\u65e5\u65e5"a": "\u00e9"\n\u65e5}\n]', "wide gap");
eq(JSON.stringify([1], null, "\u00e9"), '[\n\u00e91\n]', "latin1 gap");
eq(JSON.stringify({ a: [] }, null, 2), '{\n  "a": []\n}', "numeric gap");

// A cached key layout (same shape, repeated) mixing narrow and wide keys.
var rows = [];
for (var r = 0; r < 4; r++) rows.push({ id: r, "\u540d\u524d": "n" + r, caf\u00e9: "\u00e9" + r });
eq(JSON.stringify(rows),
   '[{"id":0,"\u540d\u524d":"n0","caf\u00e9":"\u00e90"},{"id":1,"\u540d\u524d":"n1","caf\u00e9":"\u00e91"},' +
   '{"id":2,"\u540d\u524d":"n2","caf\u00e9":"\u00e92"},{"id":3,"\u540d\u524d":"n3","caf\u00e9":"\u00e93"}]', "shape plan wide");
var narrowRows = [];
for (var r = 0; r < 3; r++) narrowRows.push({ id: r, caf\u00e9: "x" });
eq(JSON.stringify(narrowRows), '[{"id":0,"caf\u00e9":"x"},{"id":1,"caf\u00e9":"x"},{"id":2,"caf\u00e9":"x"}]', "shape plan latin1");

// Long strings cross every buffer growth and width switch.
var big = "";
for (var n = 0; n < 3000; n++) big += n % 500 === 499 ? "\ud83d\ude00" : "ab\u00e9";
var round = JSON.parse(JSON.stringify({ big: big }));
eq(round.big === big, true, "big round trip");
var bigNarrow = "ab\u00e9".repeat(5000);
eq(JSON.parse(JSON.stringify(bigNarrow)) === bigNarrow, true, "big narrow round trip");
eq(JSON.stringify(bigNarrow).length, 15002, "big narrow length");
var tail = "x".repeat(2000) + "\u65e5";
eq(JSON.stringify(tail), '"' + tail + '"', "wide only at the end");
eq(JSON.stringify(tail).length, 2003, "wide at the end length");

// Parsing escapes.
eq(units(JSON.parse('"\\u00e9"')), "233", "escape latin1");
eq(units(JSON.parse('"\\u0100"')), "256", "escape wide");
eq(units(JSON.parse('"a\\u0100b"')), "97,256,98", "escape wide mid");
eq(units(JSON.parse('"\\ud83d\\ude00"')), "55357,56832", "escaped pair");
eq(units(JSON.parse('"\\ud83d"')), "55357", "escaped lone high");
eq(units(JSON.parse('"\\ude00x"')), "56832,120", "escaped lone low");
eq(units(JSON.parse('"\\u00e9\\n\\"\\\\\\/\\b\\f\\r\\t"')), "233,10,34,92,47,8,12,13,9", "escape set");
eq(units(JSON.parse('"\u65e5\\u0041"')), "26085,65", "wide literal then escape");
eq(units(JSON.parse('"\\u0041\u65e5"')), "65,26085", "escape then wide literal");
eq(JSON.parse('"\\u0041"') === "A", true, "narrowed escape equals literal");
eq(JSON.parse('{"\\u00e9":1}').caf === undefined, true, "escaped key");
eq(JSON.parse('{"\\u00e9":1}')["\u00e9"], 1, "escaped key lookup");
eq(JSON.parse('{"\u65e5":1}')["\u65e5"], 1, "wide key lookup");
eq(JSON.parse('["\u65e5", "a", "\u00e9"]').join(""), "\u65e5a\u00e9", "mixed array");
eq(JSON.parse('"\ud83d\ude00"').length, 2, "raw astral");
eq(JSON.parse(' \t\n\r"\u65e5" \n').length, 1, "whitespace around wide");
eq(JSON.parse("[1.5e3, -0, 12345678901234567890, 0.1]").join(), "1500,0,12345678901234567000,0.1", "numbers in wide-free text");
eq(JSON.parse('["\u65e5", 1.5e3, -7, true, null, {"k": 12}]').length, 6, "numbers after wide text");
eq(JSON.parse('["\u65e5", 1.5e3]')[1], 1500, "number after wide text");
eq(1 / JSON.parse('["\u65e5", -0]')[1], -Infinity, "negative zero after wide text");

// Syntax errors are still errors over wide text.
var bad = ['"\u65e5', '"\u65e5\\x"', '["\u65e5",]', '{"\u65e5":}', '"\u65e5\n"', '\u65e5', '[1,2', '"\\u12"', '"\\ud83d\\u"'];
for (var b = 0; b < bad.length; b++) {
  var threw = false;
  try { JSON.parse(bad[b]); } catch (e) { threw = e instanceof SyntaxError; }
  eq(threw, true, "syntax error " + b);
}

// Reviver sees the source text of primitives over wide input.
var seen = [];
JSON.parse('{"\u65e5":"\u672c","n":12.50,"e":"\u00e9"}', function (k, v, ctx) {
  if (ctx && ctx.source !== undefined) seen.push(k + "=" + ctx.source);
  return v;
});
eq(seen.join("|"), '\u65e5="\u672c"|n=12.50|e="\u00e9"', "reviver source");

// A number longer than any stack buffer.
var longNum = "1" + "0".repeat(400);
eq(JSON.parse(longNum), Infinity, "long number");
eq(JSON.parse("0." + "0".repeat(400) + "1"), 0, "long fraction");
eq(JSON.parse("[" + "9".repeat(40) + "]")[0], 1e40, "forty digits");
