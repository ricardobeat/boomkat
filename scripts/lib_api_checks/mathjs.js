var math = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("add", math.add(2, 3));
rec("sqrt", math.sqrt(16));
rec("evaluate", math.evaluate("2 + 3 * 4"));
rec("matrix_multiply", math.multiply([[1, 2], [3, 4]], [[5, 6], [7, 8]]));
rec("mean", math.mean([1, 2, 3, 4, 5]));

console.log(lines.join("\n"));
console.log(lines.length + " mathjs API checks recorded, 0 threw");
