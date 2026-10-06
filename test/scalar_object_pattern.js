function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + " !== " + expected);
}
var order = [];
function record(value) { order.push(value); return value; }
function basic() {
    const {b: y, a: x} = {a: record(1), b: record(2), unused: record(3)};
    equal(x, 1); equal(y, 2); equal(order.join(","), "1,2,3");
    const {a, a: again} = {a: record(4), a: record(5)};
    equal(a, 5); equal(again, 5);
    const {f: fn, c: ctor} = {f: function () {}, c: class {}};
    equal(fn.name, "f"); equal(ctor.name, "c");
    const {read, value} = {read: () => value, value: 9};
    equal(read(), 9);
}
basic();
var tdz = false;
try { const {x, y} = {x: 1, y: eval("x")}; }
catch (e) { tdz = e instanceof ReferenceError; }
equal(tdz, true);

var escaped;
function fail() { throw 1; }
try { const {x, y} = {x: (escaped = () => x, 1), y: fail()}; }
catch (e) { equal(e, 1); }
tdz = false;
try { escaped(); } catch (e) { tdz = e instanceof ReferenceError; }
equal(tdz, true);

const {a: missing} = {};
equal(missing, undefined);
const {a: getter} = {get a() { return 10; }};
equal(getter, 10);
const {a: inherited} = {__proto__: {a: 11}};
equal(inherited, 11);
const {a: fallback = 12} = {a: undefined};
equal(fallback, 12);
const {["a"]: computed} = {["a"]: 13};
equal(computed, 13);
const {a: spread} = {...{a: 14}};
equal(spread, 14);
const {a: {b: nested}} = {a: {b: 15}};
equal(nested, 15);
const {a: kept, ...rest} = {a: 16, b: 17};
equal(kept, 16); equal(rest.b, 17);

var held = [];
function retain() {
    const {text, object} = {text: "value" + held.length, object: {id: held.length}};
    held.push(() => text + ":" + object.id);
}
for (var i = 0; i < 300; i++) retain();
for (var i = 0; i < held.length; i++) equal(held[i](), "value" + i + ":" + i);
print("PASS scalar object pattern");
