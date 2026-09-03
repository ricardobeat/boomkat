// RegExp(pattern[, flags]), ES2024 §22.2.4.1: the "return the pattern
// unchanged" shortcut (NewTarget undefined, pattern is regexp-like, no
// explicit flags argument, pattern.constructor === RegExp) is decided
// BEFORE ever reading pattern.source/pattern.flags -- those getters must
// not fire when the shortcut applies.
//
// Two distinct bugs were found together:
//  1. The shortcut's "no explicit flags argument" check used flags_len
//     (populated AFTER reading the regexp-like object's OWN .flags getter
//     in the fallback extraction path) instead of tracking whether the
//     CALLER passed an explicit flags argument. So `RegExp(obj)` with no
//     second argument, where obj.flags getter returned a non-empty string,
//     was wrongly treated as "flags were provided" and skipped the
//     shortcut's constructor check.
//  2. The shortcut check ran AFTER the source/flags extraction instead of
//     before it, so those getters always fired even when the shortcut was
//     about to return the pattern unchanged.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function makeObj(matchValue, constructorValue) {
    return {
        get [Symbol.match]() { return matchValue; },
        get constructor() { return constructorValue; },
        get source() { return "foo"; },
        get flags() { return "i"; },
        toString() { return "bar"; },
    };
}

// --- case 1: RegExp(obj), non-RegExp constructor -- shortcut must NOT
//     apply, but the constructor getter must still be consulted (it's
//     read to make that determination), and since no flags arg was given,
//     source/flags getters ARE read as part of the fallback path. ---
{
    var obj = makeObj(true, function () {});
    var seenGets = { match: false, ctor: false, source: false, flags: false };
    Object.defineProperties(obj, {
        [Symbol.match]: { get() { seenGets.match = true; return true; } },
        constructor: { get() { seenGets.ctor = true; return function () {}; } },
        source: { get() { seenGets.source = true; return "foo"; } },
        flags: { get() { seenGets.flags = true; return "i"; } },
    });
    var result = RegExp(obj).toString();
    check("case1: result", result, "/foo/i");
    check("case1: constructor getter was read", seenGets.ctor, true);
    check("case1: source getter was read", seenGets.source, true);
    check("case1: flags getter was read", seenGets.flags, true);
}

// --- case 2: RegExp(obj, "g") -- explicit flags argument means the
//     shortcut is never even considered (per spec it only applies when
//     flags is undefined), and the object's OWN .flags getter must NOT be
//     read (the explicit argument wins). ---
{
    var seenGets2 = { ctor: false, flags: false };
    var obj2 = {
        get [Symbol.match]() { return true; },
        get constructor() { seenGets2.ctor = true; return function () {}; },
        get source() { return "foo"; },
        get flags() { seenGets2.flags = true; return "i"; },
    };
    var result2 = RegExp(obj2, "g").toString();
    check("case2: result", result2, "/foo/g");
    check("case2: constructor getter NOT read (flags arg given)", seenGets2.ctor, false);
    check("case2: object's own flags getter NOT read (flags arg given)", seenGets2.flags, false);
}

// --- case 3: RegExp(obj) where obj.constructor === RegExp and @@match is
//     truthy -- the shortcut MUST apply: return obj itself, unchanged, and
//     source/flags must NEVER be read. ---
{
    var seenGets3 = { source: false, flags: false };
    var obj3 = {
        get [Symbol.match]() { return true; },
        get constructor() { return RegExp; },
        get source() { seenGets3.source = true; return "foo"; },
        get flags() { seenGets3.flags = true; return "i"; },
    };
    var result3 = RegExp(obj3);
    check("case3: shortcut returns the same object", result3, obj3);
    check("case3: source getter NOT read", seenGets3.source, false);
    check("case3: flags getter NOT read", seenGets3.flags, false);
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
