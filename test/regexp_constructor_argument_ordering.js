// RegExp(pattern[, flags]), ES2024 §22.2.4.1: RegExpAlloc(newTarget) is
// step 3 and RegExpInitialize(O, P, F) -- which performs ToString(P) and
// ToString(F) -- is step 4. So reading newTarget.prototype (an observable,
// possibly-throwing user getter, via OrdinaryCreateFromConstructor) must
// happen BEFORE either argument is coerced to a string.
//
// builtin_regexp did this backwards: it stringified the pattern and flags
// arguments first and only allocated the result object (reading
// newTarget.prototype) at the very end, so
// `Reflect.construct(RegExp, [pattern, flags], weirdNewTarget)` observed the
// prototype-getter and ToString side effects in the wrong relative order.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Builds a newTarget whose "prototype" is an accessor, so the RegExpAlloc
// lookup is observable. `log` records the call order.
function makeNewTarget(log) {
    return Object.defineProperty(function () {}.bind(null), "prototype", {
        get: function () {
            log.push("prototype");
            return RegExp.prototype;
        },
    });
}

// --- case a: the flags argument's toString() must run AFTER the
//     newTarget.prototype getter (test262 staging/sm/RegExp/
//     constructor-ordering-2.js). Pattern here is a plain string, so only
//     the flags argument needs coercion. ---
{
    var log = [];
    var flags = { toString: function () { log.push("flags"); return "g"; } };
    var re = Reflect.construct(RegExp, ["a", flags], makeNewTarget(log));
    check("case a: order", log.join(","), "prototype,flags");
    check("case a: flags applied", re.flags, "g");
    check("case a: source applied", re.source, "a");
}

// --- case b: the pattern argument's toString() must ALSO run after the
//     prototype getter, when the pattern is not regexp-like and so takes
//     the plain string-coercion path. Pattern is coerced before flags. ---
{
    var log = [];
    var pattern = { toString: function () { log.push("pattern"); return "a"; } };
    var re = Reflect.construct(RegExp, [pattern, "g"], makeNewTarget(log));
    check("case b: order", log.join(","), "prototype,pattern");
    check("case b: source applied", re.source, "a");
    check("case b: flags applied", re.flags, "g");
}

// --- case c: an actual RegExp instance as the pattern (no pattern
//     stringification -- its source comes from the internal slot) still
//     must read newTarget.prototype before coercing an explicit flags
//     argument. ---
{
    var log = [];
    var flags = { toString: function () { log.push("flags"); return "g"; } };
    var re = Reflect.construct(RegExp, [/a/i, flags], makeNewTarget(log));
    check("case c: order", log.join(","), "prototype,flags");
    check("case c: source from the pattern regexp", re.source, "a");
    // The explicit flags argument replaces the source regexp's flags
    // entirely -- "i" must NOT be inherited.
    check("case c: explicit flags replace inherited ones", re.flags, "g");
}

// --- case d: both arguments need coercion -- prototype first, then
//     pattern, then flags. ---
{
    var log = [];
    var pattern = { toString: function () { log.push("pattern"); return "a"; } };
    var flags = { toString: function () { log.push("flags"); return "g"; } };
    var re = Reflect.construct(RegExp, [pattern, flags], makeNewTarget(log));
    check("case d: order", log.join(","), "prototype,pattern,flags");
    check("case d: source applied", re.source, "a");
    check("case d: flags applied", re.flags, "g");
}

// --- case e: a throwing prototype getter must pre-empt both coercions
//     entirely (step 3 is `? RegExpAlloc`, an abrupt completion). ---
{
    var log = [];
    var pattern = { toString: function () { log.push("pattern"); return "a"; } };
    var newTarget = Object.defineProperty(function () {}.bind(null), "prototype", {
        get: function () { log.push("prototype"); throw new TypeError("nope"); },
    });
    var threw = false;
    try {
        Reflect.construct(RegExp, [pattern, "g"], newTarget);
    } catch (e) {
        threw = e instanceof TypeError;
    }
    check("case e: prototype getter's throw propagates", threw, true);
    check("case e: pattern never coerced", log.join(","), "prototype");
}

// --- case f: flag inheritance for `new RegExp(re, ...)` must key off
//     whether a flags ARGUMENT was passed, not off the coerced flags
//     string being empty. `new RegExp(/a/i, "")` must drop the "i". ---
{
    var src = /a/gi;
    check("case f: no flags arg inherits", new RegExp(src).flags, "gi");
    check("case f: undefined flags arg inherits", new RegExp(src, undefined).flags, "gi");
    check("case f: empty flags arg does NOT inherit", new RegExp(src, "").flags, "");
    check("case f: explicit flags arg replaces", new RegExp(src, "m").flags, "m");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
