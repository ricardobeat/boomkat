// Named groups whose names are not ASCII, referenced from a replace template.
var out = [
  /(?<𝒜>b)/u[Symbol.replace]("abc", "d$<𝒜>$`"),
  /(?<é>b)/[Symbol.replace]("abc", "d$<é>!"),
  "abc".replace(/(?<π>b)(?<x>c)/, "$<x>$<π>"),
  "abc".replace(/(?<é>b)/, "[$<e>]"),
  "aāb".replace(/(?<ā>ā)/g, "<$<ā>>"),
];
var want = ["adbac", "adb!c", "acb", "a[]c", "a<ā>b"];
if (JSON.stringify(out) !== JSON.stringify(want)) console.log("FAIL regexp replace named wide: " + JSON.stringify(out));
else console.log("regexp replace named wide: ok");
