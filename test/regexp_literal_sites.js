// Regexp literals evaluated in hot loops: each evaluation is a fresh RegExp
// with the literal's source, flags and lastIndex 0, sharing only the compiled
// program, and objects kept past the loop stay usable after collections.
var failures = 0;
function check(what, got, want) {
    if (got !== want) {
        failures++;
        console.log("FAIL " + what + ": got " + got + ", want " + want);
    }
}

function make(i) { var r = /a(b)c/gi; r.lastIndex = i & 3; return r; }
function single() { return /=/y; }
function astral() { return /\u{1F600}./u; }
var kept = [];
var prev = null;
for (var i = 0; i < 6000; i++) {
    var r = make(i);
    if (r === prev) check("fresh object", true, false);
    if (r.source !== "a(b)c" || r.flags !== "gi" || r.lastIndex !== (i & 3)) check("literal " + i, r.lastIndex, i & 3);
    var y = single();
    if (y.source !== "=" || !y.sticky || y.lastIndex !== 0) check("sticky literal", y.source, "=");
    if (astral().source !== "\\u{1F600}.") check("astral literal", astral().source, "\\u{1F600}.");
    if (i % 499 === 0) kept.push(r);
    prev = r;
    var junk = [{}, [i], "x" + i];
}
kept[0].lastIndex = 0;
check("kept exec", kept[0].exec("xABC")[1], "B");
check("kept count", kept.length, 13);
check("independent lastIndex", make(0).lastIndex, 0);
if (failures === 0) console.log("regexp literal sites: ok");
