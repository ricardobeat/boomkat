// Functions that read `arguments` entered through the baseline call entry, which builds the
// object in the pushed frame: surplus and missing arguments, a mapped object that follows its
// formals, a strict one that does not, and locals that start undefined past the arguments.
function count() { var a = arguments; var s = a.length + ":"; for (var i = 0; i < a.length; i++) s += a[i] + ","; return s; }
function mapped(x, y) { x = "X"; return arguments[0] + arguments.length + arguments[2]; }
function strict(x) { "use strict"; x = "X"; return arguments[0] + arguments.length; }
function locals() { var u; var v = arguments[0]; return String(u) + v + arguments.length; }
function garbage(n) { var o = []; for (var i = 0; i < n; i++) o.push({ i: i }); return o.length; }
var want = "0:|3:1,2,3,|1:7,|9:1,2,3,4,5,6,7,8,9,|X3z|a1|undefinedq1";
for (var k = 0; k < 3000; k++) {
    var got = [count(), count(1, 2, 3), count(7), count(1, 2, 3, 4, 5, 6, 7, 8, 9), mapped("a", "b", "z"), strict("a"), locals("q")].join("|");
    if (got !== want) throw new Error("iteration " + k + ": " + got);
    if (k % 500 === 0) garbage(2000);
}
print("ok");
