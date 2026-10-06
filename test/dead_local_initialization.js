function check(actual, expected) {
    if (actual !== expected) throw new Error(actual + " !== " + expected);
}

function assigned(a) {
    var x = a, y = x + 1;
    return y;
}
function conditional(flag) {
    if (flag) var x = 3;
    return x;
}
function earlyRead() {
    var before = x;
    var x = 4;
    return before;
}
function caught() {
    var x;
    try { throw 1; x = 9; } catch (e) { return x; }
}
function captured() {
    function read() { return x; }
    var before = read();
    var x = 5;
    check(read(), 5);
    return before;
}
function dynamic() {
    var before = eval("x");
    var x = 6;
    return before;
}
function mapped(a) {
    var a;
    check(arguments[0], 7);
    a = 8;
    return arguments[0];
}
for (var i = 0; i < 20; i++) {
    check(assigned(i), i + 1);
    check(conditional(true), 3);
    check(conditional(false), undefined);
    check(earlyRead(), undefined);
    check(caught(), undefined);
    check(captured(), undefined);
    check(dynamic(), undefined);
    check(mapped(7), 8);
}
print("PASS dead local initialization");
