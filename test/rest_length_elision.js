function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + " !== " + expected);
}
function count(...args) { return args.length; }
function fixed(a, b, ...args) { return args.length + a; }
function branch(...args) {
    if (args.length > 2) return args.length * 2;
    return args.length + 1;
}
function unused(...args) { return 7; }
function hasSeveral(...args) { return args.length > 1; }
function tail(a, b, c) { "use strict"; return count(a, b, c); }
for (var i = 0; i < 100; i++) {
    equal(count(), 0);
    equal(count(undefined), 1);
    equal(count(1, 2, 3, 4, 5), 5);
    equal(fixed(4), 4);
    equal(fixed(4, 0, "a", {}), 6);
    equal(branch(), 1); equal(branch(1, 2, 3), 6);
    equal(unused("unused" + i), 7);
    equal(hasSeveral(), false); equal(hasSeveral(1, 2), true);
    equal(count.call(null, "a", "b"), 2);
    equal(count.apply(null, [undefined, {}, "c"]), 3);
    equal(Reflect.apply(fixed, null, [4, 0, 1, 2, 3]), 7);
    equal(count.bind(null, 1, 2)(3), 3);
    equal(tail("one" + i, "two" + i, "three" + i), 3);
}
equal([1, 2].map(count).join(","), "3,3");
equal(new count(1, 2) instanceof count, true);

function escapes(...args) { return args; }
function mutable(...args) { args.length = 10; return args.length; }
function replaced(...args) { args = [1, 2]; return args.length; }
function captured(...args) { return () => args.length; }
function evaluated(...args) { return eval("Array.isArray(args)"); }
function argumentsUsed(...args) { return args.length + arguments.length; }
function defaulted(a = 4, ...args) { return a + args.length; }
function indexed(...args) { return args[0] + args.length; }
const arrow = (...args) => args.length;
equal(mutable(1), 10); equal(replaced(1), 2);
equal(captured(1, 2)(), 2); equal(evaluated(1), true);
equal(argumentsUsed(1, 2), 4); equal(defaulted(undefined, 1, 2), 6);
equal(indexed(4, 5), 6); equal(arrow(1, 2), 2);
function RestObject(...args) { this.args = args; }
const constructed = Reflect.construct(RestObject, [undefined, "x"]);
equal(constructed.args.length, 2);
equal(constructed.args.hasOwnProperty(0), true);
const returned = escapes.apply(null, [undefined, "x"]);
equal(returned.length, 2); equal(returned.hasOwnProperty(0), true);
function* generator(...args) { yield args.length; }
equal(generator(1, 2).next().value, 2);
print("PASS rest length elision");
