var _ = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("map", _.map([1, 2, 3], function (n) { return n * 2; }));
rec("filter", _.filter([1, 2, 3, 4], function (n) { return n % 2 === 0; }));
rec("reduce", _.reduce([1, 2, 3, 4], function (a, b) { return a + b; }, 0));
rec("pluck", _.pluck([{ a: 1 }, { a: 2 }], "a"));
rec("uniq", _.uniq([1, 2, 2, 3, 1]));
rec("isEqual", _.isEqual({ x: [1, 2] }, { x: [1, 2] }));
rec("debounce_is_fn", typeof _.debounce(function () {}, 10));
rec("throttle_is_fn", typeof _.throttle(function () {}, 10));

console.log(lines.join("\n"));
console.log(lines.length + " underscore API checks recorded, 0 threw");
