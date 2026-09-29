// A loop counter no closure captures stays in a register; one a closure
// captures (or that shares a spelling with a closure's free variable) stays
// visible through the environment.
function uncaptured() {
    var c = 0;
    function inc() { c++; }
    for (var i = 0; i < 10; i++) inc();
    return c + i;
}
if (uncaptured() !== 20) throw new Error("uncaptured " + uncaptured());

function captured() {
    var fns = [];
    for (var i = 0; i < 3; i++) fns.push(function () { return i; });
    return fns[0]() + fns[1]() + fns[2]();
}
if (captured() !== 9) throw new Error("captured " + captured());

function innerReads() {
    var n = 0;
    for (var i = 0; i < 5; i++) n += i;
    var f = function () { return i; };
    return f() * 100 + n;
}
if (innerReads() !== 510) throw new Error("innerReads " + innerReads());

function nestedDeep() {
    var i = 0;
    for (var k = 0; k < 4; k++) i++;
    return (function () { return (function () { return i; })(); })() + k;
}
if (nestedDeep() !== 8) throw new Error("nestedDeep " + nestedDeep());

function shadowed() {
    var i = 7;
    for (var j = 0; j < 3; j++) j;
    return (function () { var i = 1; for (i = 0; i < 2; i++); return i; })() + i;
}
if (shadowed() !== 9) throw new Error("shadowed " + shadowed());
