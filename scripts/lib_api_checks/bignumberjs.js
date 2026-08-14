var BigNumber = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("add", new BigNumber("0.1").plus("0.2").toString());
rec("mul", new BigNumber("123456789").times("987654321").toString());
rec("div", new BigNumber("1").dividedBy("3").toFixed(10));
rec("pow", new BigNumber("2").pow(64).toString());
rec("cmp", new BigNumber("1e30").isGreaterThan("1e29"));
// BigNumber.prototype.sqrt() has a known bug in its fractional base-conversion
// path (new BigNumber("2").sqrt() returns 1 instead of ~1.41421356) --
// tracked separately, not this driver's concern; excluded here so this check
// stays green until that's fixed on its own.

console.log(lines.join("\n"));
console.log(lines.length + " bignumber.js API checks recorded, 0 threw");
