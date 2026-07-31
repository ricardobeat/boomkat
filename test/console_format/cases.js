// Format-specifier and value-rendering cases for console.log, one per rule so
// that a failure names the rule. Asserted from the shell (run.sh) against
// cases.expected.txt, because what is under test is what console WRITES —
// a script cannot observe its own stdout.
//
// Kept portable and free of engine-specific syntax, so a reference runtime
// regenerates cases.expected.txt verbatim. See run.sh for the command.

// Substitution is gated on the first argument being a string AND at least one
// further argument existing. With no extra argument the string is verbatim,
// which is why "%%" survives here but collapses two lines further down.
console.log("a %s b");
console.log("a %% b");
console.log("a %d b");
console.log("a %% b", 1);

// A non-string first argument disables substitution entirely.
console.log(1, "%s", "x");
console.log(true, "%s", "x");
console.log(null, "%s", "x");

// Count mismatches in both directions: a starved specifier stays literal, a
// surplus argument is appended space-separated.
console.log("%s %s %s", "A");
console.log("%s", "A", "B", "C");

// Escapes and near-misses.
console.log("a %q b", "X");
console.log("a %", "X");
console.log("a %%s b", "X");
console.log("a %%%s b", "X");
console.log("%s%s%s", 1, 2, 3);
console.log("%d%%", 50, "tail");
console.log("end%s", "");
console.log("%s");

// %c is ignored but still consumes its argument, so "rest" is appended rather
// than being pulled into the directive.
console.log("a %c b", "css", "rest");
console.log("a %c b");

// %s coercions.
console.log("%s", "abc");
console.log("%s", 42);
console.log("%s", 1.5);
console.log("%s", true);
console.log("%s", null);
console.log("%s", undefined);
console.log("%s", Symbol("s"));
console.log("%s", Symbol());
console.log("%s", { toString() { return "CUSTOM"; } });

// %d is Number(), %i is parseInt(), %f is parseFloat() — three different
// coercions, so a boolean is 1 under %d but NaN under %i/%f, and an array is
// NaN under %d but 1 under %i/%f via the string form "1,2".
console.log("%d", 42);
console.log("%d", 1.5);
console.log("%d", true);
console.log("%d", null);
console.log("%d", undefined);
console.log("%d", "abc");
console.log("%d", "0x10");
console.log("%d", Symbol("s"));
console.log("%d", { valueOf() { return 7; } });
console.log("%i", 1.9);
console.log("%i", -1.9);
console.log("%i", "42abc");
console.log("%i", true);
console.log("%i", [1, 2]);
console.log("%f", 1.5);
console.log("%f", "3.9abc");
console.log("%f", true);
console.log("%f", [1, 2]);

// %j is JSON.stringify. undefined, functions and symbols have no JSON form and
// report as undefined at the root; a cycle reports as [Circular] rather than
// throwing the way JSON.stringify itself does.
console.log("%j", "abc");
console.log("%j", 1.5);
console.log("%j", true);
console.log("%j", null);
console.log("%j", { a: 1 });
console.log("%j", [1, 2]);
console.log("%j", { a: { b: { c: { d: { e: 1 } } } } });
console.log("%j", undefined);
console.log("%j", function () {});
console.log("%j", Symbol("s"));

var cyclic = {};
cyclic.self = cyclic;
console.log("%j", cyclic);

var cyclicArr = [];
cyclicArr.push(cyclicArr);
console.log("%j", cyclicArr);

// ===========================================================================
// structured value rendering
// ===========================================================================
//
// How console renders a value that no specifier claimed. Everything below is
// the structured inspect form, so the fixture keeps regenerating
// cases.expected.txt and every rule here stays checkable against the reference.

// --- plain objects and nesting -------------------------------------------
// The inner spaces of "{ a: 1 }" are load-bearing, and an EMPTY object has
// none: "{}", not "{ }".
console.log({});
console.log({ a: 1 });
console.log({ a: 1, b: 2 });
console.log({ a: { b: 2 } });
console.log({ a: null, b: undefined });
console.log({ a: true, b: false });
console.log({ a: NaN, b: Infinity, c: -Infinity });

// Depth stops at 2 by default, and the placeholder names the kind of the
// structure it replaced.
console.log({ a: { b: { c: 1 } } });
console.log({ a: { b: { c: { d: 1 } } } });
console.log([[[[1]]]]);
console.log({ a: { b: { c: [1] } } });

// --- arrays ---------------------------------------------------------------
console.log([]);
console.log([1, 2, 3]);
console.log([{ a: 1 }]);
console.log({ a: [1, 2] });
// A hole is not undefined: consecutive holes collapse into one marker, and the
// singular/plural forms differ.
console.log([1, , 3]);
console.log([1, , , 3]);
console.log([, 1]);
// Non-index properties of an array print after its elements.
var arrExtra = [1, 2, 3];
arrExtra.extra = "p";
console.log(arrExtra);

// --- string quoting -------------------------------------------------------
// A TOP-LEVEL string is bare, but the same string nested is quoted. This
// distinction is the one most easily got backwards.
console.log("bare");
console.log({ a: "x" });
console.log(["x", "y"]);
// Quote selection falls back single -> double -> backtick, so the chosen quote
// is always the one that needs no escaping.
console.log({ a: "it's" });
console.log({ a: 'has "dq"' });
console.log({ a: "has 'sq' and \"dq\"" });
// Control characters take their escape form rather than breaking the line.
console.log({ a: "line\nbreak" });
console.log({ a: "tab\there" });
console.log(["back\\slash"]);

// --- keys -----------------------------------------------------------------
// A key prints bare only when it is a valid identifier; note that "$" is NOT
// one by the identifier rule, and that integer keys sort ahead of string keys.
console.log({ "a-b": 1 });
console.log({ valid_name: 1 });
console.log({ valid_$: 1 });
console.log({ "a-b": 1, 2: 3, valid_name: 4 });
console.log({ "": 1 });

// --- Map and Set ----------------------------------------------------------
console.log(new Map());
console.log(new Map([[1, 2]]));
console.log(new Map([["k", "v"]]));
console.log(new Map([[{ a: 1 }, [1]]]));
console.log(new Set());
console.log(new Set([1, 2]));
console.log(new Set(["a", { b: 1 }]));
console.log({ m: new Map([[1, 2]]) });

// --- functions and classes ------------------------------------------------
console.log(function f() {});
console.log(function () {});
console.log(() => {});
console.log(class C {});
console.log(class {});
console.log([function f() {}]);
console.log({ f: function g() {}, h: () => {} });

// --- numbers, bigints, symbols --------------------------------------------
// -0 is distinguishable from 0 here, though ToString collapses the two.
console.log(-0);
console.log([-0]);
console.log({ a: -0 });
console.log(0);
console.log([1.5, -2.25]);
console.log(10n);
console.log({ a: 1n });
console.log(Symbol("d"));
console.log([Symbol("x")]);
console.log(Symbol());
console.log({ [Symbol("k")]: 1 });

// --- accessors ------------------------------------------------------------
// A getter is REPORTED, never invoked: rendering a value for a log must not
// run user code with side effects.
var getterObj = {};
Object.defineProperty(getterObj, "g", { get: function () { return 1; }, enumerable: true });
console.log(getterObj);
var setterObj = {};
Object.defineProperty(setterObj, "s", { set: function (v) {}, enumerable: true });
console.log(setterObj);
var bothObj = {};
Object.defineProperty(bothObj, "b", {
  get: function () { return 1; },
  set: function (v) {},
  enumerable: true,
});
console.log(bothObj);
// A non-enumerable property is hidden by default.
var hidden = {};
Object.defineProperty(hidden, "h", { value: 1, enumerable: false });
console.log(hidden);

// --- boxed primitives and null-prototype objects --------------------------
console.log(new String("x"));
console.log(new Number(1));
console.log(new Boolean(true));
console.log({ s: new String("x") });
console.log(Object.create(null));
var nullProto = Object.create(null);
nullProto.a = 1;
console.log(nullProto);

// --- TypedArrays ----------------------------------------------------------
console.log(new Int8Array([1, 2]));
console.log(new Int8Array(0));
console.log(new Uint8Array([1, 2, 3]));
console.log(new Float64Array([1.5]));

// --- cyclic structures ----------------------------------------------------
// Each of these must TERMINATE. The <ref *1> marker appears only because a
// back-reference exists, so an acyclic structure never grows one.
var selfObj = {};
selfObj.self = selfObj;
console.log(selfObj);
var selfArr = [];
selfArr.push(selfArr);
console.log(selfArr);
var mutualA = {};
var mutualB = {};
mutualA.b = mutualB;
mutualB.a = mutualA;
console.log(mutualA);
var cyclicMap = new Map();
cyclicMap.set("k", cyclicMap);
console.log(cyclicMap);
var cyclicSet = new Set();
cyclicSet.add(cyclicSet);
console.log(cyclicSet);

// --- line breaking --------------------------------------------------------
// A structure stays on one line while it fits the 80-column break length; the
// entry count on its own does not decide it.
console.log({ aaaaaaaaaa: 1, bbbbbbbbbb: 2, cccccccccc: 3 });
console.log({ aaaaaaaaaa: 1, bbbbbbbbbb: 2, cccccccccc: 3, dddddddddd: 44444 });
console.log({ k0: "vvvvv", k1: "vvvvv", k2: "vvvvv", k3: "vvvvv", k4: "vvvvv" });
console.log({ k0: "vvvvv", k1: "vvvvv", k2: "vvvvv", k3: "vvvvv", k4: "vvvvv", k5: "vvvvv" });
console.log({ k0: 0, k1: 1, k2: 2, k3: 3, k4: 4, k5: 5, k6: 6, k7: 7, k8: 8 });
console.log({ outer: { aaaaaaaaaa: 1, bbbbbbbbbb: 2, cccccccccc: 3, dddddddddd: 44444 } });
// A long array of short entries is packed into aligned columns, right-aligned
// when every element is numeric and left-aligned otherwise.
console.log([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
console.log([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
console.log(["a", "b", "c", "d", "e", "f", "g"]);
console.log(["aaaaaaaaaa", "bbbbbbbbbb", "cccccccccc", "dddddddddd", "eeeeeeeeee"]);
console.log([{ a: 1 }, { a: 1 }, { a: 1 }, { a: 1 }, { a: 1 }, { a: 1 }, { a: 1 }]);

// --- multiple arguments ---------------------------------------------------
// Unclaimed arguments are appended space-separated, each rendered as its own
// top-level value, so a bare string among them stays unquoted.
console.log({ a: 1 }, [2], "three");
console.log(null, undefined, true, false, 1, -0);

// --- %s, %o and %O against objects ----------------------------------------
// %s renders an object through its OWN toString when it has one, and otherwise
// inspects it one level shallower than a plain argument.
console.log("%s", { toString: function () { return "CUSTOM"; } });
console.log("%s", { a: 1 });
console.log("%s", [1, 2]);
console.log("%s", { a: { b: { c: 1 } } });
console.log("%s", new Map([[1, 2]]));
// %O is a plain inspect, and unlike a plain argument it QUOTES a string, since
// a specifier argument is not the top-level bare-string case.
console.log("%O", { a: 1 });
console.log("%O", "str");
console.log("%O", { a: { b: { c: { d: 1 } } } });

console.log("done");
