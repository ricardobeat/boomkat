// Element stores of numbers in an inlined body address the callee's receiver, which lives in the
// caller's window at the callee's register base. A store that read the receiver register unshifted
// wrote into whatever the caller held in the register of that number (here the caller's first
// parameter). The callee also builds an object literal whose slots are filled in the inlined body.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function mkMerge() {
    return function (cs) {
        return ((cs[((cs[1]) + 5)] = (cs[4])), (cs[1] = (cs[3])), (cs[3] = (-1)), (cs[4] = (-1)));
    };
}
function mkBox() {
    return function (a, b) { var o = { x: a, y: b, z: a + b }; return o.z + o.x; };
}
var merges = [mkMerge()];
var boxes = [mkBox()];
// Run each callee once so that the call sites record them before they tier up.
merges[0]([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
boxes[0](1, 2);

function run(guard, sets, n) {
    var total = 0;
    var m = merges[0];
    var b = boxes[0];
    for (var r = 0; r < n; r++) {
        for (var k = 0; k < sets.length; k++) {
            var cs = sets[k];
            cs[1] = -3; cs[3] = 7; cs[4] = 7; cs[2] = -1;
            var head = cs[4];
            m(cs);
            total += head + cs[1] + cs[2] + cs[3] + cs[4];
            total += b(k, r & 7);
        }
    }
    // A wide call later in the body makes the frame larger than the merge call's window.
    if (n > 1000) total += Math.max(total, n, r, guard[0], guard[1], guard[2], guard[3], guard[4], sets.length, total + 1, total + 2, total + 3, total + 4, total + 5);
    return total;
}
var guard = [11, 22, 33, 44, 55];
var sets = [];
for (var j = 0; j < 4; j++) sets.push([4, -3, -1, 7, 7, false, false, false, false, false, false, false, -1]);
var t = 0;
for (var i = 0; i < 3000; i++) t += run(guard, sets, 1);
t += run(guard, sets, 200);
show("total", t);
show("guard", guard.join(","));
show("sets", sets.map(function (s) { return s.join(","); }).join("|"));
console.log(out.join("\n"));
