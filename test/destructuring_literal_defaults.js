function equal(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

function literals(source) {
    const { integer = 2, text = "default", truth = true, falsity = false,
            empty = null, decimal = 1.25, big = 12345678901234567890n } = source;
    equal(integer, 2, "integer");
    equal(text, "default", "string");
    equal(truth, true, "true");
    equal(falsity, false, "false");
    equal(empty, null, "null");
    equal(decimal, 1.25, "decimal");
    equal(big, 12345678901234567890n, "bigint");
}
literals({});
literals({ integer: undefined, text: undefined });

function preservePresent(source) {
    let [a = 2, b = "fallback", c = true, d = false] = source;
    return a === null && b === "" && c === false && d === 0;
}
equal(preservePresent([null, "", false, 0]), true, "present values");

function parameter({ x = 2 }, [y = "text"]) { return x + y; }
equal(parameter({}, []), "2text", "parameter defaults");
equal(parameter({x: 4}, ["given"]), "4given", "present parameters");

var target = {};
({ missing: target.value = "member" } = {});
equal(target.value, "member", "member assignment");
var assigned;
[assigned = 31] = [];
equal(assigned, 31, "identifier assignment");

const [[first] = "ab"] = [];
equal(first, "a", "nested pattern default");
var nullThrew = false;
try { const { missing: { value } = null } = {}; }
catch (error) { nullThrew = error instanceof TypeError; }
equal(nullThrew, true, "nested null default");

var effects = 0;
function effect() { effects++; return 7; }
function lazy(source) {
    const { a = effect(), b = 2 } = source;
    return a + b;
}
equal(lazy({a: 5}), 7, "skip expression");
equal(effects, 0, "skipped side effect");
equal(lazy({}), 9, "evaluate expression");
equal(effects, 1, "one side effect");

function names() {
    const { fn = function () {}, arrow = () => 1 } = {};
    return fn.name + ":" + arrow.name;
}
equal(names(), "fn:arrow", "named evaluation");

function fresh() {
    const { array = [] } = {};
    return array;
}
equal(fresh() === fresh(), false, "fresh mutable default");
print("PASS destructuring literal defaults");
