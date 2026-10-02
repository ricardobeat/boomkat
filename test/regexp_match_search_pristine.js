// RegExp.prototype[@@match] and [@@search] over receivers with the intrinsic
// prototype, and the cases that must leave that path.
var failures = 0;
function t(name, got, want) {
  var g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { failures++; print("FAIL " + name + ": got " + g + " want " + w); }
}
t("matchG", "a1b22c333".match(/\d+/g), ["1", "22", "333"]);
t("matchGNone", "abc".match(/\d/g), null);
t("matchGEmpty", "abc".match(/x*/g), ["", "", "", ""]);
t("matchGEmptyU", "a\u{1F600}".match(/(?:)/gu).length, 3);
t("matchGCaps", "a1b2".match(/(\w)(\d)/g), ["a1", "b2"]);
t("matchGNonAscii", "héllo wörld".match(/\w+/g), ["h", "llo", "w", "rld"]);
t("matchGLastIndex", (function () { var r = /a/g; r.lastIndex = 2; "aaa".match(r); return r.lastIndex; })(), 0);
t("matchGHole", "aXa".match(/a/g).length, 2);
t("match", "a1b".match(/(\d)/).slice(), ["1", "1"]);
t("matchIndex", "a1b".match(/(\d)/).index, 1);
t("matchInput", "a1b".match(/(\d)/).input, "a1b");
t("matchNone", "abc".match(/\d/), null);
t("matchLastIndexN", (function () { var r = /a/; r.lastIndex = 2; "aaa".match(r); return r.lastIndex; })(), 2);
t("matchSticky", "aab".match(/a/y).index, 0);
t("matchStickyG", "aab".match(/a/gy), ["a", "a"]);
t("matchGMany", "x".repeat(100000).match(/x/g).length, 100000);
t("matchOwnExec", (function () { var r = /a/g; var n = 0; r.exec = function () { n++; return null; }; "aaa".match(r); return n; })(), 1);
t("search", "abc".search(/c/), 2);
t("searchNone", "abc".search(/x/), -1);
t("searchNonAscii", "héllo".search(/l/), 2);
t("searchIgnoresG", "abab".search(/b/g), 1);
t("searchSticky", "abc".search(/b/y), -1);
t("searchStickyHit", "abc".search(/a/y), 0);
t("searchLastIndexKept", (function () { var r = /b/g; r.lastIndex = 3; "abc".search(r); return r.lastIndex; })(), 3);
t("searchOwnExec", (function () { var r = /a/; r.exec = function () { return null; }; return "a".search(r); })(), -1);
var saved = RegExp.prototype.exec;
RegExp.prototype.exec = function () { return null; };
t("protoExecMatch", "aaa".match(/a/g), null);
t("protoExecSearch", "aaa".search(/a/), -1);
RegExp.prototype.exec = saved;
t("restored", "aaa".match(/a/g).length, 3);
class R extends RegExp { exec(s) { return null; } }
t("subclassExec", "aaa".match(new R("a", "g")), null);
if (failures) throw new Error(failures + " failures");
print("ok");
