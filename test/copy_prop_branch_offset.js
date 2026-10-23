// A copy feeding a compare-and-branch is propagated away only when the copy's
// register is dead afterwards. The branch's A field is a jump offset, so an
// offset equal to the copy's register number must not read as a write to it.
var failures = 0;
var ops = ["!=", "==", "<", "<=", ">", ">=", "!==", "==="];
for (var nl = 0; nl < 16; nl++) {
    for (var body = 1; body < 16; body++) {
        for (var oi = 0; oi < ops.length; oi++) {
            var locals = "";
            for (var i = 0; i < nl; i++) locals += "var l" + i + " = " + i + ";";
            var then = "";
            for (var j = 0; j < body; j++) then += "t = 1 / t;";
            var src = locals + "var t = 0; t = a[1]; if (t " + ops[oi] + " y) { " + then + " } else { t = y; } return t;";
            var f = new Function("a", "y", src);
            var pairs = [[2, 4], [4, 2], [4, 4]];
            for (var k = 0; k < pairs.length; k++) {
                var x = pairs[k][0], y = pairs[k][1];
                var t = x;
                if (eval("x " + ops[oi] + " y")) { for (var j2 = 0; j2 < body; j2++) t = 1 / t; } else { t = y; }
                var got = f([0, x], y);
                if (got !== t) { failures++; print("FAIL nl=" + nl + " body=" + body + " op=" + ops[oi] + " x=" + x + " y=" + y + " got " + got + " want " + t); }
            }
        }
    }
}
if (failures) throw new Error(failures + " failures");
print("ok");
