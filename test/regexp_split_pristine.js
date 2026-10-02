// RegExp.prototype[@@split] over receivers with the intrinsic prototype and
// species constructor, and the cases that must leave that path.
var failures = 0;
function t(name, got, want) {
  var g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { failures++; print("FAIL " + name + ": got " + g + " want " + w); }
}
t("basic", "a,b,c".split(/,/), ["a", "b", "c"]);
t("spaces", "a  b   c".split(/\s+/), ["a", "b", "c"]);
t("caps", "a1b2c".split(/(\d)/), ["a", "1", "b", "2", "c"]);
t("undefcap", "ab".split(/(x)?b/), ["a", undefined, ""]);
t("undefcapHole", ("ab".split(/(x)?b/)).hasOwnProperty(1), true);
t("limit", "a,b,c,d".split(/,/, 2), ["a", "b"]);
t("limitCap", "a1b2c".split(/(\d)/, 2), ["a", "1"]);
t("limitCap3", "a1b2c".split(/(\d)/, 3), ["a", "1", "b"]);
t("limit0", "a,b".split(/,/, 0), []);
t("limitNeg", "a,b".split(/,/, -1), ["a", "b"]);
t("empty", "abc".split(/(?:)/), ["a", "b", "c"]);
t("emptyU", "a\u{1F600}b".split(/(?:)/u), ["a", "\u{1F600}", "b"]);
t("emptyNoU", "a\u{1F600}b".split(/(?:)/).length, 4);
t("emptySubject", "".split(/x/), [""]);
t("emptySubjectMatch", "".split(/x*/), []);
t("emptySubjectCap", "".split(/(?:)/), []);
t("leading", ",a".split(/,/), ["", "a"]);
t("trailing", "a,".split(/,/), ["a", ""]);
t("noMatch", "abc".split(/x/), ["abc"]);
t("endAnchor", "abc".split(/$/), ["abc"]);
t("startAnchor", "abc".split(/^/), ["abc"]);
t("lookbehind", "a1b2".split(/(?<=\d)/), ["a1", "b2"]);
t("multiline", "a\nb\nc".split(/^/m), ["a\n", "b\n", "c"]);
t("nonascii", "hé,wö".split(/,/), ["hé", "wö"]);
t("star", "abc".split(/b*/), ["a", "c"]);
t("ignoreCase", "aXbxc".split(/x/i), ["a", "b", "c"]);
t("stickyOwn", "a,b".split(/,/y), ["a", "b"]);
t("globalFlag", "a,b".split(/,/g), ["a", "b"]);
t("lastIndexUntouched", (function () { var r = /,/g; r.lastIndex = 3; "a,b".split(r); return r.lastIndex; })(), 3);
t("many", "x,".repeat(50000).split(/,/).length, 50001);
t("limitObj", "a,b,c".split(/,/, { valueOf: function () { return 2; } }), ["a", "b"]);
t("limitStr", "a,b,c".split(/,/, "2"), ["a", "b"]);
// Departures from the intrinsic setup.
// The splitter is a copy of the receiver, so an own exec is never called.
t("ownExec", (function () { var r = /,/; var n = 0; r.exec = function (s) { n++; return RegExp.prototype.exec.call(this, s); }; "a,b".split(r); return n; })(), 0);
class R extends RegExp { static get [Symbol.species]() { return RegExp; } }
t("subclassSpecies", "a,b".split(new R(",")), ["a", "b"]);
var ctorCalls = 0;
class R2 extends RegExp { constructor(p, f) { super(p, f); ctorCalls++; } }
"a,b".split(new R2(","));
t("subclassConstructed", ctorCalls, 2);
var saved = Object.getOwnPropertyDescriptor(RegExp, Symbol.species);
var speciesReads = 0;
Object.defineProperty(RegExp, Symbol.species, { get: function () { speciesReads++; return RegExp; }, configurable: true });
t("speciesOverride", "a,b".split(/,/), ["a", "b"]);
t("speciesRead", speciesReads, 1);
Object.defineProperty(RegExp, Symbol.species, saved);
var ctor = RegExp.prototype.constructor;
var gets = 0;
Object.defineProperty(RegExp.prototype, "constructor", { get: function () { gets++; return ctor; }, configurable: true });
t("protoConstructor", "a,b".split(/,/), ["a", "b"]);
t("protoConstructorRead", gets, 1);
Object.defineProperty(RegExp.prototype, "constructor", { value: ctor, writable: true, configurable: true });
var sourceReads = 0;
var sd = Object.getOwnPropertyDescriptor(RegExp.prototype, "source");
Object.defineProperty(RegExp.prototype, "source", { get: function () { sourceReads++; return sd.get.call(this); }, configurable: true });
"a,b".split(/,/);
Object.defineProperty(RegExp.prototype, "source", sd);
t("protoSourceRead", sourceReads, 0);
if (failures) throw new Error(failures + " failures");
print("ok");
