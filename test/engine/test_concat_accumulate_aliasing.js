// In-place concat accumulation must be unobservable.
//
// `s += chunk` extends a uniquely-referenced accumulator in place instead of
// copying it, which is what keeps such loops linear. That mutation is only
// sound while nothing else can see the string, so every way an older value
// could be observed has to keep yielding the old bytes: an alias captured
// mid-loop, `===` against an equal fresh string, indexOf, a property key, a
// Map key, and self-append.
//
// Each case is run for a string chunk, an integer chunk (which reaches the
// accumulator through the ADD STRING+FASTINT path and the fused ADDI path),
// and a double chunk.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// Pad past the interning threshold so the accumulator path actually engages;
// below it every result is interned and copied.
var P = "";
for (var i = 0; i < 40; i++) { P += "pad"; }

// --- alias captured mid-loop must not observe later growth ---
function aliasCase(name, chunk) {
    var s = P, alias = null;
    for (var i = 0; i < 5; i++) {
        s += chunk;
        if (i === 2) { alias = s; }
    }
    check("alias/" + name, alias, P + chunk + chunk + chunk);
    check("final/" + name, s, P + chunk + chunk + chunk + chunk + chunk);
    check("aliasLen/" + name, alias.length, P.length + 3 * String(chunk).length);
}
aliasCase("str", "X");
aliasCase("int", 1);
aliasCase("double", 1.5);
aliasCase("bool", true);

// The same shape with a literal integer, which fuses into ADDI.
var sA = P, aliasA = null;
for (var i = 0; i < 5; i++) { sA += 7; if (i === 2) { aliasA = sA; } }
check("alias/addi", aliasA, P + "777");
check("final/addi", sA, P + "77777");

// --- identity against an equal fresh string ---
function identityCase(name, chunk) {
    var s = P;
    for (var i = 0; i < 4; i++) { s += chunk; }
    var fresh = P + chunk + chunk + chunk + chunk;
    check("eq/" + name, s === fresh, true);
    check("eqRev/" + name, fresh === s, true);
}
identityCase("str", "X");
identityCase("int", 1);
identityCase("double", 1.5);

// --- indexOf on a grown accumulator ---
function indexOfCase(name, chunk) {
    var s = P;
    for (var i = 0; i < 4; i++) { s += chunk; }
    var c = String(chunk);
    check("indexOf/" + name, s.indexOf(c), P.length);
    check("lastIndexOf/" + name, s.lastIndexOf(c), s.length - c.length);
    check("indexOfMissing/" + name, s.indexOf("zz"), -1);
    check("slice/" + name, s.slice(P.length), c + c + c + c);
}
indexOfCase("str", "X");
indexOfCase("int", 1);
indexOfCase("double", 1.5);

// --- use as a property key, before and after further growth ---
function propKeyCase(name, chunk) {
    var s = P;
    for (var i = 0; i < 3; i++) { s += chunk; }
    var o = {};
    o[s] = "v1";
    var keyAtTime = s;
    for (var i = 0; i < 3; i++) { s += chunk; }
    // The key recorded earlier must still address the same property, and the
    // grown accumulator must be a different key.
    check("propKey/" + name, o[keyAtTime], "v1");
    check("propKeyGrown/" + name, o[s], undefined);
    o[s] = "v2";
    check("propKeyBoth/" + name, o[keyAtTime] + "," + o[s], "v1,v2");
    check("propKeyCount/" + name, Object.keys(o).length, 2);
    check("propKeyIn/" + name, keyAtTime in o, true);
}
propKeyCase("str", "X");
propKeyCase("int", 1);
propKeyCase("double", 1.5);

// --- use as a Map key ---
function mapKeyCase(name, chunk) {
    var s = P;
    for (var i = 0; i < 3; i++) { s += chunk; }
    var m = new Map();
    m.set(s, "v1");
    var keyAtTime = s;
    for (var i = 0; i < 3; i++) { s += chunk; }
    check("mapKey/" + name, m.get(keyAtTime), "v1");
    check("mapKeyGrown/" + name, m.get(s), undefined);
    m.set(s, "v2");
    check("mapKeySize/" + name, m.size, 2);
    // A freshly built equal string must hit the same entry.
    var fresh = P;
    for (var i = 0; i < 3; i++) { fresh += chunk; }
    check("mapKeyFresh/" + name, m.get(fresh), "v1");
}
mapKeyCase("str", "X");
mapKeyCase("int", 1);
mapKeyCase("double", 1.5);

// --- self-append must not read the buffer it writes ---
var selfS = P;
for (var i = 0; i < 3; i++) { selfS += "X"; }
var beforeSelf = selfS;
selfS += selfS;
check("selfAppend", selfS, beforeSelf + beforeSelf);
check("selfAppendLen", selfS.length, beforeSelf.length * 2);
check("selfAppendHalf", selfS.slice(0, beforeSelf.length), beforeSelf);
check("selfAppendPrev", beforeSelf, P + "XXX");

// Self-append reached through a second variable holding the same string.
var s2 = P;
for (var i = 0; i < 3; i++) { s2 += "Y"; }
var same = s2;
s2 += same;
check("selfAppendAlias", s2, P + "YYY" + P + "YYY");
check("selfAppendAliasOther", same, P + "YYY");

// --- accumulator handed to a function mid-loop ---
var captured = [];
var s3 = P;
for (var i = 0; i < 5; i++) {
    s3 += "Z";
    captured.push(s3);
}
for (var i = 0; i < 5; i++) {
    var want = P;
    for (var j = 0; j <= i; j++) { want += "Z"; }
    check("captured[" + i + "]", captured[i], want);
}

// --- JSON round-trip of a grown accumulator ---
var s4 = P;
for (var i = 0; i < 4; i++) { s4 += 1; }
check("json", JSON.parse(JSON.stringify({ k: s4 })).k, P + "1111");

// --- concatenation is not commutative through the fused paths ---
var s5 = P;
for (var i = 0; i < 3; i++) { s5 += 9; }
check("appendOrder", s5.slice(-3), "999");
check("appendOrderHead", s5.slice(0, 3), "pad");

if (failures === 0) {
    print("PASS: concat accumulation is unobservable");
} else {
    print("FAILED: " + failures + " check(s)");
}
