// Annex B.3.5: a `var` in a catch body that names the catch parameter
// initializes the parameter, not the function-level binding.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

check("initializer reaches the parameter", (function () {
    var seen;
    try { throw 1; } catch (e) { var e = 2; seen = e; }
    return seen;
})(), 2);
check("function-level binding stays undefined", (function () {
    try { throw 1; } catch (e) { var e = 2; }
    return e;
})(), undefined);
check("hoisted before the catch", (function () {
    var e = "outer";
    try { throw 1; } catch (e) { var e = 2; }
    return e;
})(), "outer");
check("closure sees the parameter", (function () {
    var f;
    try { throw 1; } catch (e) { var e = 3; f = function () { return e; }; }
    return f();
})(), 3);
print("ok");
