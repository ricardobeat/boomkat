// String concatenation only
var str = "";
for (var i = 0; i < 2000; i++) {
    str += String(i) + "-";
}
if (str.length < 0) print("never");
