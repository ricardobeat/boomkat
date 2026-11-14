// An accumulator held in a compiler cell (a function with closures) appends in
// place only while no other holder can see the string: values a closure
// returned, saved in registers, arrays and objects keep their contents.
function fail(message) { throw new Error(message); }

function accumulate(n) {
    var s = "";
    var get = function () { return s; };
    var saved = [], kept = { v: "" }, last = "";
    for (var i = 0; i < n; i++) {
        s += String.fromCharCode(97 + i % 26);
        if (i % 10 === 0) saved.push(get());
        if (i % 7 === 0) last = get();
        if (i % 13 === 0) kept.v = s;
    }
    return [s.length, saved.map(function (x) { return x.length; }).join(","), last.length, kept.v.length, get() === s];
}

for (var round = 0; round < 3; round++) {
    var r = accumulate(200);
    if (r[0] !== 200) fail("length " + r[0]);
    var lengths = r[1].split(",");
    for (var k = 0; k < lengths.length; k++) if (+lengths[k] !== k * 10 + 1) fail("saved " + k + " " + lengths[k]);
    if (r[2] !== 197) fail("last " + r[2]);
    if (r[3] !== 196) fail("kept " + r[3]);
    if (r[4] !== true) fail("cell read");
}

function named(n) {
    var out = "";
    var f = function inner() { return out.length; };
    for (var i = 0; i < n; i++) out += "ab";
    return out.length + f();
}
if (named(100) !== 400) fail("named " + named(100));
