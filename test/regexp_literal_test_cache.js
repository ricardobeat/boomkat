// `/lit/.test(x)` compiles to RETEST, which matches through the function's
// literal cache without creating a RegExp. A function whose only literals are
// RETEST sites must still get the cache, and the fast path must give way to
// the generic one once RegExp.prototype changes.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function count(list) {
    var n = 0;
    for (var i = 0; i < list.length; i++) {
        if (/^b[a-z]*k$/i.test(list[i])) n++;
    }
    return n;
}
function wide(s) { return /été/.test(s); }
function coerced(v) { return /^1,2$/.test(v); }

var words = ["book", "Back", "bk", "bok!", "cook", "", "BRICK"];
for (var r = 0; r < 200; r++) check("count " + r, count(words), 4);
check("wide subject", wide("un été chaud \u{1F600}"), true);
check("wide miss", wide("ete"), false);
check("non-string argument", coerced([1, 2]), true);
check("undefined argument", /^undefined$/.test(), true);

// Once `exec` is replaced, `test` runs it for real.
var calls = 0;
var exec = RegExp.prototype.exec;
RegExp.prototype.exec = function (s) { calls++; return exec.call(this, s); };
check("after exec override", count(words), 4);
check("override saw every call", calls, words.length);
RegExp.prototype.exec = exec;
check("restored", count(words), 4);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
