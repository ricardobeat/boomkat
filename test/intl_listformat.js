function eq(a, b, m) { if (a !== b) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }
var cases = {
  "conjunction long": ["", "A", "A and B", "A, B, and C", "A, B, C, and D"],
  "conjunction short": ["", "A", "A & B", "A, B, & C", "A, B, C, & D"],
  "conjunction narrow": ["", "A", "A, B", "A, B, C", "A, B, C, D"],
  "disjunction long": ["", "A", "A or B", "A, B, or C", "A, B, C, or D"],
  "unit long": ["", "A", "A, B", "A, B, C", "A, B, C, D"],
  "unit narrow": ["", "A", "A B", "A B C", "A B C D"],
};
for (var key in cases) {
  var p = key.split(" ");
  var f = new Intl.ListFormat("en", { type: p[0], style: p[1] });
  var want = cases[key];
  for (var n = 0; n <= 4; n++) eq(f.format(["A", "B", "C", "D"].slice(0, n)), want[n], key + " " + n);
}
eq(JSON.stringify(new Intl.ListFormat("en").formatToParts(["x", "y", "z"])),
   '[{"type":"element","value":"x"},{"type":"literal","value":", "},{"type":"element","value":"y"},{"type":"literal","value":", and "},{"type":"element","value":"z"}]', "parts");
eq(new Intl.ListFormat().format(new Set(["a", "b"])), "a and b", "set");
eq(new Intl.ListFormat().format(undefined), "", "undefined");
var closed = false;
var it = { [Symbol.iterator]() { return { next() { return { done: false, value: 1 }; }, return() { closed = true; return {}; } }; } };
try { new Intl.ListFormat().format(it); throw 0; } catch (e) { eq(e instanceof TypeError, true, "non-string"); }
eq(closed, true, "iterator closed");
eq(JSON.stringify(new Intl.ListFormat("en-US", { type: "unit" }).resolvedOptions()), '{"locale":"en-US","type":"unit","style":"long"}', "resolved");
