// `~x` inline on fastints and on the numbers whose ToInt32 is their truncation; every other
// operand (a large double, NaN, a string, an object, a BigInt) through the general path.
var out = [];
function not(x) { return ~x; }
function twice(x) { return ~~x; }
function mixed(a, b) { return (~a & b) | (~b >>> 28); }
var ints = [0, 1, -1, 7, 2147483647, -2147483648, 4294967296, 4294967295, -4294967297, 281474976710655];
var nums = [0.5, -0.5, 1.9, -1.9, 2147483647.5, 2147483648, -2147483649, 1e21, NaN, Infinity, -Infinity, -0];
var rest = [true, false, null, undefined, "12", "x", "", [5], {}, { valueOf: function () { return 9; } }];
for (var round = 0; round < 60; round++) {
    var row = [];
    for (var i = 0; i < ints.length; i++) row.push(not(ints[i]), twice(ints[i]), mixed(ints[i], round));
    for (var j = 0; j < nums.length; j++) row.push(not(nums[j]), twice(nums[j]));
    for (var k = 0; k < rest.length; k++) row.push(not(rest[k]));
    if (round === 0 || round === 59) out.push(row.join());
}
out.push(typeof not(5n), String(not(5n)), String(not(-1n)));
var acc = 0;
for (var n = 0; n < 5000; n++) acc = (acc + ~n) | 0;
out.push(acc);
console.log(out.join("\n"));
