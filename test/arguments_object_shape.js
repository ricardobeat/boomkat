// Every call path builds the same arguments object: an explicit undefined
// argument is present, and length precedes callee.
function assert(c, m) { if (!c) throw new Error(m); }
var seen = [];
[undefined].forEach(function () { seen.push(0 in arguments, arguments.length); });
assert(seen.join() === "true,3", "builtin callback: " + seen.join());
function has0() { return 0 in arguments; }
assert(has0(undefined) && has0.call(null, undefined), "direct call");
assert(Reflect.construct(function () { this.v = 0 in arguments; }, [undefined]).v, "construct");
var o = { set p(v) { seen = [0 in arguments, arguments.length]; } };
o.p = undefined;
assert(seen.join() === "true,1", "setter");
function keys(a, b) { a = 9; return Object.getOwnPropertyNames(arguments).join() + "|" + arguments[0]; }
for (var i = 0; i < 3; i++) assert(keys(1, 2) === "0,1,length,callee|9", "mapped: " + keys(1, 2));
function strict() { "use strict"; return Object.getOwnPropertyNames(arguments).join(); }
assert(strict(1) === "0,length,callee" && strict(1) === "0,length,callee", "unmapped");
function spread() { return [...arguments].join(); }
assert(spread(1, 2) === "1,2" && spread(1, 2) === "1,2", "iterator");
console.log("ok");
