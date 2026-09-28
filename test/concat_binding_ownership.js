var failures = 0;
function check(actual, expected, label) {
    if (actual !== expected) {
        print("FAIL " + label + ": " + actual + " !== " + expected);
        failures++;
    }
}
function fresh() {
    var value = "";
    for (var i = 0; i < 17; i++) value += "abcde";
    return value;
}

let lexical = "";
var prefixes = [];
for (let i = 0; i < 4000; i++) {
    lexical += "abcde";
    if (i % 1000 === 0) prefixes.push(lexical);
}
check(lexical.length, 20000, "lexical length");
for (var i = 0; i < prefixes.length; i++) {
    check(prefixes[i].length, (i * 1000 + 1) * 5, "retained prefix " + i);
}

const immutable = fresh();
var threw = false;
try { immutable += "X"; } catch (error) { threw = error instanceof TypeError; }
check(threw, true, "const throws");
check(immutable.length, 85, "const value survives failed write");

var changed = fresh();
var oldChanged;
changed += { valueOf: function () {
    oldChanged = changed;
    changed = "replacement";
    return "X";
} };
check(oldChanged.length, 85, "coercion alias stays immutable");
check(changed.length, 86, "compound assignment uses old value");

let snapshot = fresh();
var oldSnapshot;
for (let i = 0; i < 1; i++) {
    snapshot += { toString: function () {
        oldSnapshot = snapshot;
        snapshot = "replacement";
        return "X";
    } };
}
check(oldSnapshot.length, 85, "snapshot coercion alias");
check(snapshot.length, 86, "snapshot compound result");

const frozenSnapshot = fresh();
for (let i = 0; i < 1; i++) {
    threw = false;
    try { frozenSnapshot += "X"; } catch (error) { threw = error instanceof TypeError; }
    check(threw, true, "snapshot const throws");
}
check(frozenSnapshot.length, 85, "snapshot const unchanged");

globalThis.blockedConcat = fresh();
Object.defineProperty(globalThis, "blockedConcat", { writable: false, configurable: true });
blockedConcat += "X";
check(blockedConcat.length, 85, "non-writable global drops sloppy write");
threw = false;
try {
    (function () { "use strict"; blockedConcat += "X"; })();
} catch (error) { threw = error instanceof TypeError; }
check(threw, true, "non-writable global throws in strict mode");
check(blockedConcat.length, 85, "failed global write preserves bytes");
delete globalThis.blockedConcat;

var keyed = fresh();
var keys = {};
var map = new Map();
keys[keyed] = 1;
map.set(keyed, 2);
var originalKey = keyed;
for (let i = 0; i < 20; i++) keyed += "\uD83D\uDE00";
check(keys[originalKey], 1, "property key survives");
check(map.get(originalKey), 2, "map key survives");
check(keys[keyed], undefined, "grown property key differs");
check(keyed.length, 125, "UTF-16 length");
check(keyed.charCodeAt(85), 0xD83D, "surrogate index");
check(/abcde/.test(keyed), true, "regexp reads grown string");
check(JSON.parse(JSON.stringify(keyed)), keyed, "JSON reads grown string");

let self = fresh();
for (let i = 0; i < 3; i++) self += self;
check(self.length, 680, "overlapping append");

var holder = { value: fresh() };
var getterValue = holder.value;
Object.defineProperty(holder, "value", {
    get: function () { return getterValue; },
    set: function (v) { check(getterValue.length, 85, "setter sees old bytes"); },
    configurable: true
});
with (holder) { value += "X"; }
check(getterValue.length, 85, "with accessor alias");

// Direct eval may replace the binding after the left value has been read.
let evalValue = fresh();
var evalAlias;
for (let i = 0; i < 1; i++) {
    evalValue += eval("evalAlias = evalValue; evalValue = 'replacement'; 'X'");
}
check(evalAlias.length, 85, "eval alias stays immutable");
check(evalValue.length, 86, "eval compound result");

if (failures) throw new Error("concat binding ownership: " + failures);
print("concat binding ownership passed");
