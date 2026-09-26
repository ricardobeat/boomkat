// A Script's top-level vars are global properties, so a script run in the
// middle of it (here through $262.evalScript) sees and changes their current
// values. Each case runs as its own Script so no other code in it affects how
// its vars compile.
var fail = 0;
function check(name, src, want) {
    var got = $262.evalScript(src);
    if (got !== want) { print("FAIL " + name + ": got " + got + " want " + want); fail++; }
}

check("an earlier script reads the current value",
    "$262.evalScript('function show() { return x1; }'); var x1 = 1; x1 = 2; show()", 2);
check("an earlier script's write is visible",
    "$262.evalScript('function bump() { y1 = 5; }'); var y1 = 1; bump(); y1", 5);
check("an object stored by another script",
    "var a1 = 1, b1 = 1; $262.evalScript('b1 = {v: 42}'); a1 = b1; b1 = 0; a1.v", 42);

print(fail === 0 ? "script_globals_across_scripts: all passed"
                 : "script_globals_across_scripts: " + fail + " FAILED");
