// Calls reuse register windows that held initializer strings in the prior turn.
function mul(a, b) {
    return [
        a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5]
    ];
}
function vec(x, y) { return { x: x, y: y }; }
var node = { id: 1, name: 'literal', transform: [1, 0, 0, 1, 2, 3] };
function render(frame) {
    var items = [];
    for (var i = 0; i < 400; i++) {
        var n = node;
        var world = mul(n.transform, n.transform);
        var p = vec(world[4], world[5]);
        items.push({ key: n.id, label: n.name + ':' + frame, pos: p, m: world });
    }
    return { type: 'list', frame: frame, items: items };
}
for (var i = 0; i < 100; i++) render(i);
