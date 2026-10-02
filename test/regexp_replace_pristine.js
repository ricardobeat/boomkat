// RegExp.prototype[@@replace] over receivers that still have the intrinsic
// prototype, and the cases that must leave that path.
var failures = 0;
function t(name, got, want) {
  if (got !== want) { failures++; print("FAIL " + name + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want)); }
}
t("basic", "a-b-c".replace(/-/g, "+"), "a+b+c");
t("nonglobal", "a-b-c".replace(/-/, "+"), "a+b-c");
t("caps", "John Smith".replace(/(\w+)\s(\w+)/, "$2, $1"), "Smith, John");
t("undefcap", "ab".replace(/(x)?b/, "[$1]"), "a[]");
t("fn", "abc".replace(/b/g, function (m, p, s) { return m.toUpperCase() + p + s; }), "aB1abcc");
t("fncap", "ab".replace(/(x)?(a)/, function (m, x, a, p) { return typeof x + a + p; }), "undefineda0b");
t("empty", "abc".replace(/(?:)/g, "-"), "-a-b-c-");
t("emptyu", "a\u{1F600}b".replace(/(?:)/gu, "-"), "-a-\u{1F600}-b-");
t("emptyend", "".replace(/x*/g, "-"), "-");
t("dollar", "abc".replace(/b/, "$$|$&|$`|$'|$0|$1|$<x>"), "a$|b|a|c|$0|$1|$<x>c");
t("2digit", "abcdefghijkl".replace(/(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)/, "$11-$10-$1"), "k-j-al");
t("lastIndexG", (function () { var r = /a/g; r.lastIndex = 5; var s = "aaa".replace(r, "b"); return s + r.lastIndex; })(), "bbb0");
t("lastIndexN", (function () { var r = /a/; r.lastIndex = 2; var s = "aaa".replace(r, "b"); return s + r.lastIndex; })(), "baa2");
t("sticky", (function () { var r = /a/gy; return "aab".replace(r, "x") + r.lastIndex; })(), "xxb0");
t("stickyN", (function () { var r = /a/y; r.lastIndex = 1; return "aab".replace(r, "x") + r.lastIndex; })(), "axb2");
t("multi", "a\nb".replace(/^./gm, "X"), "X\nX");
t("nonascii", "héllo wörld".replace(/ö/, "o"), "héllo world");
t("nonasciipos", "héllo".replace(/l/g, function (m, p) { return p; }), "hé23o");
t("named", "ab".replace(/(?<x>a)/, "[$<x>]"), "[a]b");
t("namedfn", "ab".replace(/(?<x>a)/, function () { return typeof arguments[arguments.length - 1]; }), "objectb");
t("ownExec", (function () { var r = /a/; r.exec = function () { return null; }; return "aaa".replace(r, "b"); })(), "aaa");
t("ownProp", (function () { var r = /a/g; r.foo = 1; return "aa".replace(r, "b"); })(), "bb");
var saved = RegExp.prototype.exec;
RegExp.prototype.exec = function () { return null; };
t("protoExec", "aaa".replace(/a/g, "b"), "aaa");
RegExp.prototype.exec = saved;
t("restored", "aaa".replace(/a/g, "b"), "bbb");
var fl = Object.getOwnPropertyDescriptor(RegExp.prototype, "flags");
Object.defineProperty(RegExp.prototype, "flags", { get: function () { return "g"; }, configurable: true });
t("protoFlagsGetter", "aaa".replace(/a/g, "b"), "bbb");
Object.defineProperty(RegExp.prototype, "flags", fl);
var gd = Object.getOwnPropertyDescriptor(RegExp.prototype, "unicode");
var reads = 0;
Object.defineProperty(RegExp.prototype, "unicode", { get: function () { reads++; return false; }, configurable: true });
"aaa".replace(/a/g, "b");
Object.defineProperty(RegExp.prototype, "unicode", gd);
t("protoUnicodeGetterRead", reads > 0, true);
class R extends RegExp {}
t("subclass", "aaa".replace(new R("a", "g"), "b"), "bbb");
var cnt = 0;
class R2 extends RegExp { exec(s) { cnt++; return super.exec(s); } }
t("subclassExec", "aaa".replace(new R2("a", "g"), "b"), "bbb");
t("subclassExecCnt", cnt, 4);
t("frozen", (function () { var r = Object.freeze(/a/g); try { "a".replace(r, "b"); return "no"; } catch (e) { return e.constructor.name; } })(), "TypeError");
t("fnmutates", (function () { var r = /a/g; var n = 0; return "aaa".replace(r, function () { r.lastIndex = 1; n++; return "b"; }) + n; })(), "bbb3");
t("fnthrows", (function () { try { "a".replace(/a/g, function () { throw 7; }); } catch (e) { return e; } })(), 7);
t("toStringOnce", (function () { var c = 0; "aa".replace(/a/g, { toString: function () { c++; return "x"; } }); return c; })(), 1);
t("many", "x".repeat(100000).replace(/x/g, "yy").length, 200000);

// Every capture reaches a replacer function, past the old 34-argument limit.
var groups = [];
for (var i = 0; i < 100; i++) groups.push("(" + String.fromCharCode(97 + i % 26) + ")");
var big = new RegExp(groups.join(""));
var input = "";
for (var i = 0; i < 100; i++) input += String.fromCharCode(97 + i % 26);
t("fnManyCaps", input.replace(big, function () { return arguments.length + ":" + arguments[100] + ":" + arguments[101]; }), "103:" + input[99] + ":0");
t("tmplManyCaps", input.replace(big, "$99|$100|$01"), input[98] + "|" + input[9] + "0|a");
// The generic path (an own property forces it) agrees.
var big2 = new RegExp(groups.join("")); big2.tag = 1;
t("genericFnManyCaps", input.replace(big2, function () { return arguments.length + ":" + arguments[100]; }), "103:" + input[99]);
if (failures) throw new Error(failures + " failures");
print("ok");
