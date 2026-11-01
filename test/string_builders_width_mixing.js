// Builtins that assemble strings piece by piece must produce the same units
// whichever width (Latin-1 or UTF-16) the pieces and the result have.
if (typeof print == "undefined" && typeof console != "undefined") print = console.log;

function eq(actual, expected, label) {
  if (actual !== expected) print("FAIL " + label + ": got " + escapeAll(String(actual)) + " expected " + escapeAll(String(expected)));
}
function escapeAll(s) {
  var out = "";
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    out += c < 0x7f && c >= 0x20 ? s[i] : "<" + c.toString(16) + ">";
  }
  return out;
}

// fromCharCode / fromCodePoint
eq(String.fromCharCode(0x41, 0xe9, 0x65e5).length, 3, "fromCharCode length");
eq(String.fromCharCode(0x65e5, 0x41).charCodeAt(1), 0x41, "fromCharCode wide then narrow");
eq(String.fromCharCode(0xd83d, 0xde00), "\u{1F600}", "fromCharCode pair");
eq(String.fromCharCode(0xd800).charCodeAt(0), 0xd800, "fromCharCode lone");
eq(String.fromCodePoint(0x41, 0x1F600, 0xe9).length, 4, "fromCodePoint length");
eq(String.fromCodePoint(0x1F600).codePointAt(0), 0x1F600, "fromCodePoint astral");
eq(String.fromCodePoint(0xe9, 0xff), "éÿ", "fromCodePoint latin1");

// concat, repeat, pad
eq("a".concat("日", "b", "é"), "a日bé", "concat mixed");
eq("é".concat("ÿ"), "éÿ", "concat latin1");
eq("日".repeat(3), "日日日", "repeat wide");
eq("é".repeat(4), "éééé", "repeat latin1");
eq("ab".padStart(6, "日"), "日日日日ab", "padStart wide filler");
eq("日".padEnd(4, "xy"), "日xyx", "padEnd narrow filler");
eq("é".padEnd(3, "ÿ"), "éÿÿ", "padEnd latin1");

// String.raw
eq(String.raw({ raw: ["a", "日", "é"] }, 1, "日"), "a1日日é", "String.raw");

// replace / replaceAll with substitutions
eq("aXb".replace("X", "日"), "a日b", "replace narrow with wide");
eq("a日b".replace("日", "X"), "aXb", "replace wide with narrow");
eq("a日b".replace("日", "[$&]"), "a[日]b", "replace $&");
eq("a日b".replace("日", "$`|$'"), "aa|bb", "replace $` and $'");
eq("é-é".replaceAll("é", "日"), "日-日", "replaceAll latin1 to wide");
eq("日-日".replaceAll("日", "e"), "e-e", "replaceAll wide to narrow");
eq("日日".replace(/日/g, "$&$&"), "日日日日", "regexp replace $&");
eq("ab".replace(/(?<n>a)/, "$<n>日"), "a日b", "named capture substitution");
eq("a日".replace(/(a)(日)/, "$2$1"), "日a", "numbered captures");
eq("abc".replace(/b/, function () { return "日"; }), "a日c", "replace callback wide");
eq("x".replace(/x/, "$<n>"), "$<n>", "no named groups keeps $<");
eq("日日".replace(/日/g, function () { return "e"; }), "ee", "regexp callback narrow from wide");

// A custom exec that matches behind the end of the previous match drops the
// text of that substitution, which can leave an all-narrow buffer behind.
(function () {
  var re = /./g;
  var calls = 0;
  re.exec = function (s) {
    calls++;
    if (calls == 1) return Object.assign(["bc"], { index: 1, groups: undefined });
    if (calls == 2) return Object.assign(["a"], { index: 0, groups: undefined });
    return null;
  };
  eq(re[Symbol.replace]("abc", "日"), "a日", "overlapping match dropped");
})();

// RegExp source and toString
eq(new RegExp("/").source, "\\/", "source slash");
eq(new RegExp("\n").source, "\\n", "source LF");
eq(new RegExp("\r").source, "\\r", "source CR");
eq(new RegExp(" ").source, "\\u2028", "source LS");
eq(new RegExp(" ").source, "\\u2029", "source PS");
eq(new RegExp("\\\n").source, "\\n", "source backslash LF");
eq(new RegExp("[/]").source, "[/]", "source slash in class");
eq(new RegExp("日/é").source, "日\\/é", "source wide");
eq(new RegExp("").source, "(?:)", "source empty");
eq(String(new RegExp("日", "gi")), "/日/gi", "toString wide");
eq(String(new RegExp("é", "g")), "/é/g", "toString latin1");
eq(new RegExp("a", "g").flags, "g", "flags");
eq(/a/y[Symbol.split]("bab").length, 2, "split via sticky copy");

// split / join round trip across widths
var parts = "日,a,é,,b".split(",");
eq(parts.length, 5, "split length");
eq(parts.join("|"), "日|a|é||b", "join mixed");
eq(parts[2], "é", "split latin1 piece");
eq(parts.join("日").length, 8, "join wide separator length");
eq("日éa".split("").join("-"), "日-é-a", "split empty separator");
eq(["a", "b"].join("é"), "aéb", "join latin1 separator");
eq(["日"].join(), "日", "join single");
eq(["a", null, undefined, "日"].join("ÿ"), "aÿÿÿ日", "join holes");
var big = [];
for (var i = 0; i < 1000; i++) big.push(i % 2 ? "日" : "ab");
eq(big.join("").length, 1500, "join large");
eq("a b c".split(" ").length, 3, "split length narrow");
var many = ("x,".repeat(100000)).split(",");
eq(many.length, 100001, "split many");
eq(many[99999], "x", "split many element");
many.push("y");
eq(many.length, 100002, "push after split");
eq(Object.keys("a,b".split(",")).join(), "0,1", "split keys");
