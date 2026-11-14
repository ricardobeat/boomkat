// Short array literals built inline in hot code while the collector marks a
// large live graph: an object allocated during marking is shaded gray, so the
// strings and objects stored into it at creation survive, whether the array is
// kept in an old container, in a fresh one, or only in a register.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }

var graph = [];
for (var g = 0; g < 60000; g++) graph.push({ id: g, next: null });
for (var g = 1; g < graph.length; g++) graph[g].next = graph[g - 1];

var old = [];
function make(i) {
    var s = 'v' + i;
    var o = { n: i };
    return [s, o, i, s + '!'];
}
function fill(n, keep) {
    var t = 0;
    for (var i = 0; i < n; i++) {
        var a = make(i);
        t += a.length;
        if (i % keep === 0) old.push(a);
        var b = [a, [a[0]], { x: a[1] }];
        if (b[2].x.n !== i) t = -1e9;
    }
    return t;
}
for (var r = 0; r < 40; r++) check('total ' + r, fill(5000, 97) === 20000);
for (var k = 0; k < old.length; k++) {
    var a = old[k], i = a[2];
    if (a[0] !== 'v' + i || a[1].n !== i || a[3] !== 'v' + i + '!') { check('kept ' + k, false); break; }
}
var n = 0;
for (var p = graph[graph.length - 1]; p; p = p.next) n++;
check('graph', n === graph.length);
print(bad.length ? 'FAIL ' + bad.join(', ') : 'ok');
