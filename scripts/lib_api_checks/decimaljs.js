var Decimal = module.exports.Decimal || module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("add", new Decimal("0.1").plus("0.2").toString());
rec("mul", new Decimal("2.5").times("4").toString());
rec("div", new Decimal("1").dividedBy("3").toDecimalPlaces(10).toString());
rec("pow", new Decimal("2").pow(10).toString());
rec("cmp", new Decimal("0.1").plus("0.2").equals("0.3"));

console.log(lines.join("\n"));
console.log(lines.length + " decimal.js API checks recorded, 0 threw");
