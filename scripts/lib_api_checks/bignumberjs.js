var BigNumber = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("add", new BigNumber("0.1").plus("0.2").toString());
rec("mul", new BigNumber("123456789").times("987654321").toString());
rec("div", new BigNumber("1").dividedBy("3").toFixed(10));
rec("pow", new BigNumber("2").pow(64).toString());
rec("cmp", new BigNumber("1e30").isGreaterThan("1e29"));
// sqrt and base-24 construction: the prior plan 072 description flagged these
// as broken ("Invalid array length" / sqrt returning 1 instead of ~1.41421356),
// traced to a NaN reaching array_set_length_desc via src/vm/vm_property.c3. As
// of commit 6377fc14 the bug does not reproduce on either boomkat or qjs
// with the vendored 9.3.1 bundle (both engines return sqrt(2) =
// 1.4142135623730950488 and new BigNumber("1.1", 24) = 1.04166666666666666667).
// Covered here so a regression would surface in the api-check diff against qjs.
rec("sqrt", new BigNumber("2").sqrt().toString());
rec("base24", new BigNumber("1.1", 24).toString());

console.log(lines.join("\n"));
console.log(lines.length + " bignumber.js API checks recorded, 0 threw");
