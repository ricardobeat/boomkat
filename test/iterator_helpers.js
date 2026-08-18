// Iterator helpers (ES2025 §27.1): Iterator.from/concat, the
// %IteratorPrototype% transforms (map/filter/take/drop/flatMap/reduce/
// toArray/forEach/some/every/find), laziness, early-exit closing, and the
// %IteratorHelperPrototype% protocol. test262 phase 21 covers the spec
// corners (prop-desc, weird-setter, ordering); this file is the fast
// regression net for the behaviors real code depends on.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}
function throwsType(name, fn) {
    try { fn(); t(name, "no-throw", "TypeError"); }
    catch (e) { t(name, e instanceof TypeError ? "TypeError" : e.constructor.name + ":" + e.message, "TypeError"); }
}
function throwsRange(name, fn) {
    try { fn(); t(name, "no-throw", "RangeError"); }
    catch (e) { t(name, e instanceof RangeError ? "RangeError" : e.constructor.name + ":" + e.message, "RangeError"); }
}
function arr(x) { return JSON.stringify(x); }

// 1. The Iterator constructor is abstract: both call forms throw.
t("typeof-Iterator", typeof Iterator, "function");
t("Iterator-has-from", typeof Iterator.from, "function");
t("Iterator-has-concat", typeof Iterator.concat, "function");
throwsType("new-Iterator-throws", function () { new Iterator(); });
throwsType("Iterator-call-throws", function () { Iterator(); });
t("Iterator-prototype-tag", Iterator.prototype[Symbol.toStringTag], "Iterator");

// 2. Iterator.from over an iterable reuses its iterator; over a bare
// iterator object it wraps it (%WrapForValidIteratorPrototype%).
t("from-array", arr(Iterator.from([1, 2, 3]).toArray()), "[1,2,3]");
throwsType("from-undefined", function () { Iterator.from(undefined); });
var wrap_next_calls = 0;
var plain = {
    next: function () { wrap_next_calls++; return { value: wrap_next_calls, done: wrap_next_calls > 2 }; }
};
var wrapped = Iterator.from(plain);
t("wrap-is-not-source", wrapped === plain, false);
t("wrap-next-1", wrapped.next().value, 1);
t("wrap-next-2", wrapped.next().value, 2);
t("wrap-next-done", wrapped.next().done, true);
// WrapForValidIterator.return forwards to the inner iterator's return,
// invoked with no argument, and passes its result through.
var wrap_return_arg = "unset", wrap_return_value = null;
var with_return = {
    next: function () { return { value: 1, done: true }; },
    return: function (v) { wrap_return_arg = v; return { value: "closed", done: true }; }
};
var wr = Iterator.from(with_return);
var wr_result = wr.return();
t("wrap-return-forwards", wrap_return_arg, undefined);
t("wrap-return-value", wr_result.value, "closed");

// 3. The transforms, over an array's value iterator.
t("map", arr([1, 2, 3].values().map(function (x) { return x * 2; }).toArray()), "[2,4,6]");
t("filter", arr([1, 2, 3, 4].values().filter(function (x) { return x % 2 === 0; }).toArray()), "[2,4]");
t("take", arr([1, 2, 3].values().take(2).toArray()), "[1,2]");
t("take-past-end", arr([1].values().take(5).toArray()), "[1]");
t("take-zero", arr([1, 2].values().take(0).toArray()), "[]");
t("drop", arr([1, 2, 3].values().drop(1).toArray()), "[2,3]");
t("drop-all", arr([1, 2].values().drop(2).toArray()), "[]");
t("drop-past-end", arr([1, 2].values().drop(99).toArray()), "[]");
t("flatMap", arr([1, 2].values().flatMap(function (x) { return [x, x * 10]; }).toArray()), "[1,10,2,20]");
t("toArray", arr([5, 6].values().toArray()), "[5,6]");
t("reduce-init", [1, 2, 3].values().reduce(function (a, b) { return a + b; }, 10), 16);
t("reduce-no-init", [1, 2, 3].values().reduce(function (a, b) { return a + b; }), 6);
throwsType("reduce-empty-no-init", function () { [].values().reduce(function (a, b) { return a + b; }); });

var seen;
seen = [];
[1, 2].values().forEach(function (v, i) { seen.push(v + ":" + i); });
t("forEach", seen.join(","), "1:0,2:1");
t("some-true", [1, 2, 3].values().some(function (x) { return x === 2; }), true);
t("some-false", [1, 2].values().some(function (x) { return x > 9; }), false);
t("some-empty", [].values().some(function () { return true; }), false);
t("every-true", [1, 2].values().every(function (x) { return x > 0; }), true);
t("every-false", [1, 2].values().every(function (x) { return x > 1; }), false);
t("every-empty", [].values().every(function () { return false; }), true);
t("find-hit", [1, 2, 3].values().find(function (x) { return x > 1; }), 2);
t("find-miss", [1, 2].values().find(function (x) { return x > 9; }), undefined);

// 4. Chaining. Each stage returns a fresh helper, so a chain stays lazy
// end to end and one pull through the tail pulls once through the head.
t("chain", arr([1, 2, 3, 4, 5].values()
    .map(function (x) { return x + 1; })
    .filter(function (x) { return x % 2 === 0; })
    .drop(1)
    .take(2)
    .toArray()), "[4,6]");

// 5. Laziness: nothing is pulled from the source until a next()/terminal
// step asks for it, and terminal steps that stop early stop pulling.
var pulled = 0;
function lazySource() {
    return {
        next: function () { pulled++; return { value: pulled, done: pulled > 3 }; },
        return: function () { return { done: true }; }
    };
}
pulled = 0;
var lazy = Iterator.from(lazySource()).map(function (x) { return x * 10; });
t("lazy-before-next", pulled, 0);
t("lazy-first-pull", lazy.next().value, 10);
t("lazy-one-pull", pulled, 1);

// 6. take/drop argument validation: negative and NaN limits throw
// RangeError; fractional limits truncate toward zero.
throwsRange("take-negative", function () { [1].values().take(-1); });
throwsRange("take-nan", function () { [1].values().take(NaN); });
throwsRange("drop-negative", function () { [1].values().drop(-1); });
throwsRange("drop-nan", function () { [1].values().drop(NaN); });
t("take-fractional", arr([1, 2, 3].values().take(1.5).toArray()), "[1]");
t("drop-fractional", arr([1, 2, 3].values().drop(0.9).toArray()), "[1,2,3]");
t("drop-infinite", arr([1, 2].values().drop(1e100).toArray()), "[]");

// 7. Callback validation happens up front, before any source pull.
throwsType("map-non-callable", function () { [1].values().map(42); });
throwsType("filter-non-callable", function () { [1].values().filter("x"); });
throwsType("flatMap-non-callable", function () { [1].values().flatMap(null); });
throwsType("forEach-non-callable", function () { [1].values().forEach(1); });
throwsType("some-non-callable", function () { [1].values().some({}); });
throwsType("every-non-callable", function () { [1].values().every([]); });
throwsType("find-non-callable", function () { [1].values().find(undefined); });
throwsType("reduce-non-callable", function () { [1].values().reduce(true, 0); });

// 8. flatMap: the mapper must return an iterable, and its elements are
// consumed one at a time before the next outer pull. String primitives
// are rejected on purpose (GetIteratorFlattenable with
// primitive-strings-allowed false), so the string case must throw.
throwsType("flatMap-non-iterable-result", function () { [1].values().flatMap(function (x) { return x; }).toArray(); });
throwsType("flatMap-string-result", function () { ["ab"].values().flatMap(function (s) { return s; }).toArray(); });
t("flatMap-strings", arr(["ab", "c"].values().flatMap(function (s) { return s.split(""); }).toArray()), "[\"a\",\"b\",\"c\"]");
t("flatMap-empty-inner", arr([1, 2].values().flatMap(function () { return []; }).toArray()), "[]");

// 9. Closing the source: some/every/find close the underlying iterator
// when they answer early, and a throwing callback closes it while the
// error propagates.
var close_count = 0;
function source() {
    var i = 0;
    return {
        next: function () { i++; return { value: i, done: i > 5 }; },
        return: function () { close_count++; return { done: true }; }
    };
}
function sourceOverIterable() { return Iterator.from(source()); }
close_count = 0;
sourceOverIterable().some(function (x) { return x === 2; });
t("some-closes", close_count, 1);
sourceOverIterable().every(function (x) { return x < 2; });
t("every-closes", close_count, 2);
sourceOverIterable().find(function (x) { return x === 3; });
t("find-closes", close_count, 3);
var for_each_msg = null;
try {
    sourceOverIterable().forEach(function (x) { if (x === 2) throw new Error("feboom"); });
} catch (e) { for_each_msg = e.message; }
t("forEach-throw-propagates", for_each_msg, "feboom");
close_count = 0;
var threw_msg = null;
try {
    sourceOverIterable().map(function (x) { if (x === 2) throw new Error("mapboom"); return x; }).toArray();
} catch (e) { threw_msg = e.message; }
t("map-throw-propagates", threw_msg, "mapboom");
t("map-throw-closes", close_count, 1);

// 10. Iterator.concat: static, zero or more object arguments, each used
// through its own iterator. Primitives are rejected per spec step 2.a.
t("concat-empty", arr(Iterator.concat().toArray()), "[]");
t("concat-two", arr(Iterator.concat([1, 2].values(), new Set([3]).values()).toArray()), "[1,2,3]");
t("concat-mixed", arr(Iterator.concat(new Map([["a", 1]]).values(), [9].values()).toArray()), "[1,9]");
throwsType("concat-primitive", function () { Iterator.concat("ab"); });
throwsType("concat-number", function () { Iterator.concat(42); });

// 11. Helper protocol: a helper is itself an iterator (its @@iterator
// returns this), its return() closes the source exactly once, and every
// next() after that reports done.
var helper = [1, 2].values().map(function (x) { return x; });
t("helper-iterator-self", helper[Symbol.iterator]() === helper, true);
t("helper-tag", Object.getPrototypeOf(helper)[Symbol.toStringTag], "Iterator Helper");
close_count = 0;
var closable = Iterator.from({
    next: function () { return { value: 1, done: false }; },
    return: function () { close_count++; return { done: true }; }
}).take(5);
t("helper-return-done", closable.return().done, true);
closable.return();
t("helper-return-idempotent", close_count, 1);
t("helper-next-after-return", closable.next().done, true);

// 12. The shared transforms sit on %IteratorPrototype%, so every built-in
// iterator family reaches them: generators, Map/Set iterators, string
// iterators, and for-of sources.
function* gen() { yield 1; yield 2; }
t("generator-map", arr(gen().map(function (x) { return x * 3; }).toArray()), "[3,6]");
t("map-values-map", arr(new Map([["a", 1]]).values().map(function (v) { return v + 1; }).toArray()), "[2]");
t("set-values-drop", arr(new Set([1, 2]).values().drop(1).toArray()), "[2]");
t("string-map", arr("hi"[Symbol.iterator]().map(function (c) { return c + c; }).toArray()), "[\"hh\",\"ii\"]");

// 13. The @@toStringTag setter: assigning through a subobject defines an
// own data property (CreateDataPropertyOrThrow); assigning on
// %IteratorPrototype% itself throws, emulating a non-writable property.
var tagged = Object.create(Iterator.prototype);
tagged[Symbol.toStringTag] = "Fake";
t("tag-setter-own", tagged[Symbol.toStringTag], "Fake");
t("tag-setter-untouched", Iterator.prototype[Symbol.toStringTag], "Iterator");
try { Iterator.prototype[Symbol.toStringTag] = "x"; t("tag-setter-home", "no-throw", "TypeError"); }
catch (e) { t("tag-setter-home", e instanceof TypeError ? "TypeError" : e.constructor.name, "TypeError"); }

for (var n = 0; n < out.length; n++) { console.log(out[n]); }
