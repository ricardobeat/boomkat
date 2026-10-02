// String.prototype.replace / replaceAll and RegExp.prototype[@@replace] build
// results of any length: inputs, replacements and match counts far past the
// size of any scratch buffer.
var pass = 0, fail = 0;
function t(name, got, want) {
  if (got === want) { pass++; } else { fail++; print("FAIL: " + name + ": got " + got + ", want " + want); }
}

var L = 20000, s = "x".repeat(L);

// String search value.
t("str replace", s.replace("x", "yy").length, L + 1);
t("str replace long replacement", "a".replace("a", s).length, L);
t("str replace $& long", "a".replace("a", s + "$&").length, L + 1);
t("str replace $` $'", ("a" + s + "b").replace(s, "[$`|$']"), "a[a|b]b");
t("replaceAll", s.replaceAll("x", "yy").length, 2 * L);
t("replaceAll shrink", s.replaceAll("x", "y").length, L);
t("replaceAll $&", s.replaceAll("x", "$&$&").length, 2 * L);

// RegExp search value: more matches than any fixed match table holds.
t("re replace", s.replace(/x/, "yy").length, L + 1);
t("re replace g", s.replace(/x/g, "yy").length, 2 * L);
t("re replace g content", s.replace(/x/g, "ab") === "ab".repeat(L), true);
t("re replace $&", s.replace(/x/g, "$&$&").length, 2 * L);
t("re replace $1", s.replace(/(x)/g, "$1$1").length, 2 * L);
t("re replace named", s.replace(/(?<c>x)/g, "$<c>$<c>").length, 2 * L);
t("re replace long replacement", "a".replace(/a/, s + "$&").length, L + 1);
t("re replace fn", s.replace(/x/g, function () { return "yy"; }).length, 2 * L);
t("re replace sticky", s.replace(/x/y, "z").length, L);
t("re replace backref", s.replace(/(x)\1/g, "$1").length, L / 2);
t("re replace lookbehind", s.replace(/(?<=x)x/g, "y").length, L);

// Replacement order and capture handling.
t("re fn args", "abc".replace(/(b)/, function (m, c, pos, str) { return [m, c, pos, str].join("|"); }), "ab|b|1|abcc");
t("re $0 literal", "abc".replace(/(b)/, "[$0$1$2$01$10]"), "a[$0b$2bb0]c");
t("re $<> without groups", "abc".replace(/b/, "[$<n>]"), "a[$<n>]c");

// A match starting before endOfLastMatch still evaluates its substitution.
var reads = 0, n = 0, re = /./g;
re.exec = function () {
  if (n >= 2) return null;
  var r = n === 0 ? ["abc"] : ["b"];
  r.index = n === 0 ? 0 : 1;
  Object.defineProperty(r, "groups", { get: function () { reads++; return undefined; } });
  n++;
  return r;
};
t("overlapping match", "abcd".replace(re, "<$&>"), "<abc>d");
t("overlapping match reads groups", reads, 2);

print(pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("replace_long_strings failed");
