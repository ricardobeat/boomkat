var d3 = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("sum", d3.sum([1, 2, 3, 4]));
rec("max", d3.max([3, 1, 4, 1, 5]));
rec("min", d3.min([3, 1, 4, 1, 5]));
rec("mean", d3.mean([1, 2, 3, 4]));
rec("ascending_sort", [3, 1, 2].sort(d3.ascending));
rec("extent", d3.extent([5, 2, 8, 1]));
rec("bisect", d3.bisect([1, 3, 5, 7, 9], 5));

console.log(lines.join("\n"));
console.log(lines.length + " d3-array API checks recorded, 0 threw");
