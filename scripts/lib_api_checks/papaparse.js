var Papa = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var parsed = Papa.parse("a,b,c\n1,2,3\n4,5,6", { header: true });
rec("rows", parsed.data);
rec("fields", parsed.meta.fields);
rec("errors", parsed.errors.length);

var unparsed = Papa.unparse([{ x: 1, y: 2 }, { x: 3, y: 4 }]);
rec("unparse", unparsed);

console.log(lines.join("\n"));
console.log(lines.length + " papaparse API checks recorded, 0 threw");
