// Array.prototype.join / toLocaleString on a cyclic array must terminate.
//
// A self-referencing element converts via Array.prototype.toString, which
// calls join again on the same array, so without a cycle guard this recurses
// until the C stack is exhausted. On a baseline built at d6b92443 this file
// does NOT report a failed assertion — it dies with SIGSEGV (exit 139) before
// printing anything, so grade it on the exit status and on the final PASS line
// rather than on a diff of the output.
//
// Expected values are node's: an array already being joined contributes the
// empty string to the level that re-enters it, and the same in-progress set is
// shared between join and toLocaleString.
//
// Runs unmodified under node with `--import` a shim defining print().

var failures = 0;
var checks = 0;

function eq(name, actual, expected) {
  checks++;
  if (actual !== expected) {
    failures++;
    print("FAIL: " + name + " => " + JSON.stringify(actual) +
          " (expected " + JSON.stringify(expected) + ")");
  }
}

// --- direct self-reference: every rendering path ---------------------------
function selfRef() { var a = []; a.push(a); return a; }

eq("String(self)", String(selfRef()), "");
eq("self.join()", selfRef().join(), "");
eq("self.join('-')", selfRef().join("-"), "");
eq("self.toString()", selfRef().toString(), "");
eq("self.toLocaleString()", selfRef().toLocaleString(), "");
eq("`${self}`", `${selfRef()}`, "");

// --- mutual recursion a -> b -> a ------------------------------------------
function mutual() { var a = [], b = []; a.push(b); b.push(a); return a; }
eq("String(mutual)", String(mutual()), "");
eq("mutual.join('-')", mutual().join("-"), "");
eq("mutual.toLocaleString()", mutual().toLocaleString(), "");

// --- cycle at depth: the outer levels still render -------------------------
var deep = [1, [2, [3, [4]]]];
deep[1][1][1].push(deep);
eq("deep cycle", String(deep), "1,2,3,4,");

// --- cycle routed through a user object's toString -------------------------
var viaObj = [];
viaObj.push({ toString: function () { return String(viaObj); } });
eq("cycle via toString", String(viaObj), "");

// --- the in-progress set is shared between join and toLocaleString ---------
var tlsToJoin = [];
tlsToJoin.push({ toLocaleString: function () { return tlsToJoin.join(); } });
eq("toLocaleString -> join", tlsToJoin.toLocaleString(), "");

var joinToTls = [];
joinToTls.push({ toString: function () { return joinToTls.toLocaleString(); } });
eq("join -> toLocaleString", joinToTls.join(), "");

// --- sparse array holding a cycle: holes still count as separators ---------
var sparse = [];
sparse[5] = sparse;
sparse.length = 10;
eq("sparse cycle", String(sparse), ",,,,,,,,,");

// --- a frozen cyclic array takes the same path -----------------------------
var frozen = [];
frozen.push(frozen);
Object.freeze(frozen);
eq("frozen cycle", String(frozen), "");

// --- a Proxy around a cyclic array -----------------------------------------
var proxied = [];
var proxy = new Proxy(proxied, {});
proxied.push(proxy);
eq("proxy cycle", String(proxy), "");

// --- generic join on a cyclic array-LIKE (not an Array) --------------------
var arrayLike = { length: 1 };
arrayLike[0] = arrayLike;
arrayLike.join = Array.prototype.join;
arrayLike.toString = Array.prototype.toString;
eq("array-like cycle", arrayLike.join(), "");

// --- the guard must not fire on mere REPETITION, only on recursion ---------
var shared = [1, 2];
eq("repeated sibling", String([shared, shared]), "1,2,1,2");

var mixed = [1, 2];
mixed.push(mixed, 3);
eq("cycle among values", String(mixed), "1,2,,3");

// --- the set unwinds: a later render of the same array is unaffected -------
var reused = [];
reused.push(reused);
String(reused);
eq("unrelated after cycle", String([1, [2], 3]), "1,2,3");
reused.pop();
reused.push(7);
eq("same array after cycle broken", String(reused), "7");

// --- a throw mid-join must not leave the array marked as in-progress -------
// Otherwise a later, legitimate join of the same array silently returns "".
var throwing = [1, 2];
throwing.push({ toString: function () { throw new Error("boom"); } });
var caught = false;
try { throwing.join(); } catch (e) { caught = e.message === "boom"; }
eq("throw propagates", caught, true);
throwing.pop();
eq("join after throw", throwing.join(), "1,2");

var innerThrows = [1, { toString: function () { throw new Error("inner"); } }];
var outerOk = [
  { toString: function () { try { return innerThrows.join(); } catch (e) { return "E"; } } },
  9
];
eq("outer survives inner throw", outerOk.join(), "E,9");
innerThrows.pop();
eq("inner joins after its throw", innerThrows.join(), "1");

// --- non-cyclic nesting still renders in full ------------------------------
var nested = [1];
for (var i = 0; i < 50; i++) nested = [nested, i];
eq("deep non-cyclic length", String(nested).length, 141);

if (failures !== 0) {
  throw new Error(failures + " of " + checks + " cyclic-join checks failed");
}
print("PASS: array cyclic join/toLocaleString (" + checks + " checks)");
