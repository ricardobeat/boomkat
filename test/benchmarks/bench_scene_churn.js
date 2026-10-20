// Retained scene graph plus per-frame churn: the renderer / VDOM workload.
// A large tree stays alive for the whole run while every frame allocates
// temporary vectors, matrices and a view subtree, diffs it against the scene,
// and mutates a few retained nodes. A tracing collector re-marks the retained
// scene on every cycle; this measures what that costs per frame.
// ES5 only, so other engines can run it unchanged.

var SCENE_NODES = typeof SCENE_NODES_OVERRIDE === "number" ? SCENE_NODES_OVERRIDE : 100000;
var FRAMES = typeof SCENE_FRAMES_OVERRIDE === "number" ? SCENE_FRAMES_OVERRIDE : 300;
var VIEW_SIZE = 400;

function makeNode(id, parent) {
    return {
        id: id,
        name: "node-" + id,
        parent: parent,
        children: [],
        transform: [1, 0, 0, 1, id % 97, id % 89],
        style: { color: "#" + (id % 4096).toString(16), opacity: 1, visible: true }
    };
}

// Build a wide, shallow tree: each node gets up to 8 children.
var scene = [];
var root = makeNode(0, null);
scene.push(root);
for (var i = 1; i < SCENE_NODES; i++) {
    var parent = scene[(i - 1) >> 3];
    var node = makeNode(i, parent);
    parent.children.push(node);
    scene.push(node);
}

function vec(x, y) { return { x: x, y: y }; }

function mul(a, b) {
    return [
        a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]
    ];
}

function renderView(frame) {
    var items = [];
    for (var i = 0; i < VIEW_SIZE; i++) {
        var n = scene[(frame * 131 + i * 17) % SCENE_NODES];
        var world = mul(n.transform, n.parent ? n.parent.transform : root.transform);
        var p = vec(world[4], world[5]);
        items.push({ key: n.id, label: n.name + ":" + frame, pos: p, m: world });
    }
    return { type: "list", frame: frame, items: items };
}

function diff(prev, curr) {
    if (prev === null) return curr.items.length;
    var changes = 0;
    for (var i = 0; i < curr.items.length; i++) {
        var a = prev.items[i], b = curr.items[i];
        if (a.key !== b.key || a.pos.x !== b.pos.x || a.pos.y !== b.pos.y) changes++;
    }
    return changes;
}

var prev = null;
var totalChanges = 0;
var worst = 0;
var start = Date.now();
for (var f = 0; f < FRAMES; f++) {
    var t0 = Date.now();
    var view = renderView(f);
    totalChanges += diff(prev, view);
    prev = view;
    // Mutate a few retained nodes so the scene is not frozen.
    for (var k = 0; k < 20; k++) {
        var m = scene[(f * 7919 + k * 104729) % SCENE_NODES];
        m.transform = [1, 0, 0, 1, (m.transform[4] + 1) % 97, m.transform[5]];
        m.style = { color: m.style.color, opacity: (f % 10) / 10, visible: true };
    }
    var dt = Date.now() - t0;
    if (dt > worst) worst = dt;
}
var elapsed = Date.now() - start;

if (totalChanges <= 0) print("FAIL: no changes");
print("scene_churn: nodes=" + SCENE_NODES + " frames=" + FRAMES
      + " total=" + elapsed + "ms worst_frame=" + worst + "ms");
