// exec and test run ToString on their argument, which throws for a Symbol,
// on every path: the builtins and a literal's cached test (RETEST).

var failures = 0;
function throwsTypeError(name, f) {
    var threw = false;
    try { f(); } catch (e) { threw = e instanceof TypeError; }
    if (!threw) { print("FAIL: " + name); failures++; }
}

throwsTypeError("test", function () { /a/.test(Symbol("a")); });
throwsTypeError("exec", function () { /a/.exec(Symbol("a")); });
var rx = /a/g;
throwsTypeError("test of a stored regexp", function () { rx.test(Symbol("a")); });

var thrown = 0;
for (var i = 0; i < 300; i++) {
    try { /a/.test(i % 100 === 7 ? Symbol() : "a"); } catch (e) { if (e instanceof TypeError) thrown++; }
}
if (thrown !== 3) { print("FAIL: literal test in a loop threw " + thrown + " times"); failures++; }

if (failures > 0) throw new Error(failures + " check(s) failed");
print("OK");
