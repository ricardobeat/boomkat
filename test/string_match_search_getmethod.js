// ES2015 §21.1.3.11 (match) and §21.1.3.15 (search) step 2: when the argument
// is neither undefined nor null, GetMethod(argument, @@match / @@search). A
// property that is present but not callable is a TypeError; null or undefined
// means "not found" and falls through to RegExpCreate.
//
// Regression: match and search implemented only the callable half. A
// non-callable @@match fell through silently and matched against the
// stringified argument instead of throwing. replace and split were correct,
// which is why the normative suites passed: they cover the protocol on those
// two and on RegExp receivers, never on a plain object handed to match.

function check(name, cond) {
    print((cond ? "ok   " : "FAIL ") + name);
}

function makeWith(sym, value) {
    var o = {};
    o[sym] = value;
    o.toString = function () { return "-"; };
    return o;
}

var methods = [
    ["match", Symbol.match],
    ["search", Symbol.search],
    ["replace", Symbol.replace],
    ["split", Symbol.split]
];

// A present-but-not-callable protocol method throws TypeError.
var notCallable = [[1, "1"], [true, "true"], ["", '""'], [{}, "{}"], [[], "[]"],
                   [Symbol.iterator, "symbol"]];

for (var i = 0; i < methods.length; i++) {
    var name = methods[i][0];
    var sym = methods[i][1];
    for (var j = 0; j < notCallable.length; j++) {
        var threw = null;
        try {
            "a-a"[name](makeWith(sym, notCallable[j][0]));
        } catch (e) {
            threw = e;
        }
        check(name + " throws TypeError for non-callable @@" + name +
              " (" + notCallable[j][1] + ")",
              threw instanceof TypeError);
    }
}

// null and undefined mean "not found": no throw, fall through to RegExpCreate
// against the stringified argument.
for (var k = 0; k < methods.length; k++) {
    var m = methods[k][0];
    var s = methods[k][1];
    var nullish = [null, undefined];
    for (var n = 0; n < nullish.length; n++) {
        var ok = true;
        try {
            "a-a"[m](makeWith(s, nullish[n]));
        } catch (e) {
            ok = false;
        }
        check(m + " falls through for " + String(nullish[n]) + " @@" + m, ok);
    }
}

// The fall-through path still works: a nullish @@match stringifies the
// argument and matches it as a pattern.
var res = "a-a".match(makeWith(Symbol.match, null));
check("match fall-through produces a match", res !== null && res[0] === "-");
check("match fall-through reports the index", res !== null && res.index === 1);

// A callable protocol method is still invoked, and its receiver is the argument.
var receiver = null;
var arg = makeWith(Symbol.match, function (str) { receiver = this; return "called:" + str; });
check("callable @@match is invoked", "a-a".match(arg) === "called:a-a");
check("callable @@match receives the argument as this", receiver === arg);

// A throwing getter for the protocol property propagates its own error rather
// than being swallowed by the fall-through.
var boom = {};
Object.defineProperty(boom, Symbol.search, { get: function () { throw new RangeError("getter"); } });
var got = null;
try { "a-a".search(boom); } catch (e) { got = e; }
check("a throwing @@search getter propagates", got instanceof RangeError);

print("=== DONE ===");
