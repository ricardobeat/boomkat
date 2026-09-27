// A constructor invoked by native code must keep every suspended caller's
// environment rooted, including lexical scopes the constructor cannot see.
function checkThrow(fn) {
    let sentinel = { value: 42 };
    let caught = false;
    try {
        fn();
    } catch (e) {
        caught = true;
        if (eval("sentinel").value !== 42) throw new Error("lost caller scope");
    }
    if (!caught) throw new Error("constructor did not throw");
}

var calls = 0;
function Custom() {
    calls++;
    for (var i = 0; i < 100; i++) ({ value: i });
    throw new Error("constructor");
}
checkThrow(function () { Uint8Array.from.call(Custom, []); });
checkThrow(function () { Uint8Array.of.call(Custom, 1); });
if (calls !== 2) throw new Error("constructor call count");
print("PASS: native constructors preserve suspended caller scopes");
