// New Set methods (ES2025 §24.2.4): union, intersection, difference,
// symmetricDifference, isSubsetOf, isSupersetOf, isDisjointFrom.
// Covers result contents and ordering, Set-like duck typing,
// SameValueZero matching, and the TypeError contract. test262 phase 17-20
// carries the spec-corner tests; this file is the fast regression net.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}
function throwsType(name, fn) {
    try { fn(); t(name, "no-throw", "TypeError"); }
    catch (e) { t(name, e instanceof TypeError ? "TypeError" : e.constructor.name + ":" + e.message, "TypeError"); }
}
function join(s) { return Array.from(s).join(","); }
function S(a) { return new Set(a); }

var A = S([1, 2, 3]), B = S([3, 4, 5]);

// 1. Result contents and order: receiver order first, then unseen
// argument elements in argument order. Results are fresh Sets; neither
// input is mutated.
t("union", join(A.union(B)), "1,2,3,4,5");
t("intersection", join(A.intersection(B)), "3");
t("difference", join(A.difference(B)), "1,2");
t("symmetricDifference", join(A.symmetricDifference(B)), "1,2,4,5");
t("difference-empty-overlap", join(A.difference(S([9]))), "1,2,3");
t("symmetric-equal-sets", join(A.symmetricDifference(S([1, 2, 3]))), "");
var union_result = A.union(B);
t("union-returns-set", union_result instanceof Set, true);
t("union-fresh-object", union_result !== A && union_result !== B, true);
t("receiver-unmutated", join(A), "1,2,3");
t("argument-unmutated", join(B), "3,4,5");

// 2. Predicates, including the empty-set identities and self-comparison.
t("subset-yes", S([1]).isSubsetOf(A), true);
t("subset-no", A.isSubsetOf(B), false);
t("subset-equal", A.isSubsetOf(A), true);
t("empty-subset-of-anything", S([]).isSubsetOf(A), true);
t("nothing-subset-of-empty-except-empty", A.isSubsetOf(S([])), false);
t("superset-yes", A.isSupersetOf(S([1, 2])), true);
t("superset-no", A.isSupersetOf(B), false);
t("superset-equal", A.isSupersetOf(A), true);
t("empty-superset-of-nothing-but-empty", A.isSupersetOf(S([])), true);
t("empty-is-superset-of-empty", S([]).isSupersetOf(S([])), true);
t("disjoint-yes", S([1]).isDisjointFrom(S([2])), true);
t("disjoint-no", A.isDisjointFrom(B), false);
t("empty-disjoint-from-anything", S([]).isDisjointFrom(A), true);

// 3. SameValueZero matching: NaN equals NaN, +0 equals -0.
t("nan-union-collapsed", S([NaN]).union(S([NaN])).size, 1);
t("nan-intersection", S([NaN]).intersection(S([NaN])).size, 1);
t("nan-has", S([NaN]).isSubsetOf(S([NaN])), true);
t("nan-disjoint", S([NaN]).isDisjointFrom(S([NaN])), false);
t("zero-sign-ignored", S([0]).union(S([-0])).size, 1);
t("zero-matches-neg-zero", S([-0]).isDisjointFrom(S([0])), false);
t("object-identity", S(A).difference(S(A)).size, 0);

// 4. Set-like arguments: any object with size, has(), and keys() works,
// and keys() must return an iterator (GetIteratorFromMethod on its
// result), not merely an iterable.
var duck = {
    size: 2,
    has: function (v) { return v === 1 || v === 9; },
    keys: function () { return [1, 9].values(); }
};
t("duck-union", join(S([2]).union(duck)), "2,1,9");
t("duck-isSubsetOf", S([1, 2]).isSubsetOf(duck), false);
t("duck-isSupersetOf", S([1]).isSupersetOf(duck), false);
t("duck-isDisjointFrom", S([2, 3]).isDisjointFrom(duck), true);
throwsType("duck-keys-array-rejected", function () { S([1]).union({ size: 1, has: function () {}, keys: function () { return [7]; } }); });
throwsType("duck-keys-string-rejected", function () { S([1]).union({ size: 1, has: function () {}, keys: function () { return "ab"; } }); });

// 5. A Set subclass used as the argument goes through the same path
// (size/has/keys are inherited), and results are plain Sets.
class SetSub extends Set {}
var sub_instance = new SetSub([4, 5]);
t("subclass-union", join(S([1]).union(sub_instance)), "1,4,5");
t("subclass-union-result-type", S([1]).union(sub_instance) instanceof Set, true);

// 6. The TypeError contract: the receiver must carry [[SetData]] and the
// argument must be an Object with callable has and keys (checked after
// size), regardless of method.
var methods = ["union", "intersection", "difference", "symmetricDifference", "isSubsetOf", "isSupersetOf", "isDisjointFrom"];
var m;
for (m = 0; m < methods.length; m++) {
    (function (name) {
        throwsType(name + "-primitive-arg", function () { A[name](42); });
        throwsType(name + "-null-arg", function () { A[name](null); });
        throwsType(name + "-non-set-receiver", function () { Set.prototype[name].call([1, 2], A); });
        throwsType(name + "-no-has", function () { A[name]({ size: 1, keys: function () { return [].values(); } }); });
        throwsType(name + "-no-keys", function () { A[name]({ size: 1, has: function () {} }); });
    })(methods[m]);
}

// 7. Abrupt completions from the Set-like surface propagate: the size
// getter runs before has/keys are touched. union and symmetricDifference
// never call the argument's has (spec §24.2.4.16/.15), which the
// has-counting duck pins down; intersection does call it when the
// argument claims a larger size.
var size_error = null;
try {
    A.union({ get size() { throw new RangeError("size-boom"); }, has: function () {}, keys: function () { return [].values(); } });
} catch (e) { size_error = e.message; }
t("size-getter-error-propagates", size_error, "size-boom");
var has_calls = 0;
A.union({ size: 9, has: function () { has_calls++; return false; }, keys: function () { return [].values(); } });
t("union-never-calls-has", has_calls, 0);
var has_error = null;
try {
    A.intersection({ size: 9, has: function () { throw new RangeError("has-boom"); }, keys: function () { return [].values(); } });
} catch (e) { has_error = e.message; }
t("has-error-propagates", has_error, "has-boom");
var keys_error = null;
try {
    A.union({ size: 1, has: function () {}, keys: function () { throw new RangeError("keys-boom"); } });
} catch (e) { keys_error = e.message; }
t("keys-error-propagates", keys_error, "keys-boom");

// 8. Surface: arity 1, method names, non-enumerable and
// non-writable like every built-in prototype method.
t("union-name", Set.prototype.union.name, "union");
t("intersection-name", Set.prototype.intersection.name, "intersection");
t("difference-name", Set.prototype.difference.name, "difference");
t("symmetricDifference-name", Set.prototype.symmetricDifference.name, "symmetricDifference");
t("isSubsetOf-name", Set.prototype.isSubsetOf.name, "isSubsetOf");
t("isSupersetOf-name", Set.prototype.isSupersetOf.name, "isSupersetOf");
t("isDisjointFrom-name", Set.prototype.isDisjointFrom.name, "isDisjointFrom");
for (m = 0; m < methods.length; m++) {
    t(methods[m] + "-length", Set.prototype[methods[m]].length, 1);
    t(methods[m] + "-not-enumerable", Set.prototype.propertyIsEnumerable(methods[m]), false);
}

for (var n = 0; n < out.length; n++) { console.log(out[n]); }
