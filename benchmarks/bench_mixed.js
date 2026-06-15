// Bench 8: Mixed workload — realistic game-script pattern
function clamp(v, lo, hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

var entities = [];
for (var i = 0; i < 500; i++) {
    entities.push({
        x: i * 1.5,
        y: i * 0.7,
        hp: 100,
        alive: true
    });
}

var dt = 0.016;
for (var tick = 0; tick < 100; tick++) {
    for (var i = 0; i < entities.length; i++) {
        var e = entities[i];
        e.x = e.x + dt * 10;
        e.y = e.y + dt * 5;
        e.x = clamp(e.x, 0, 1000);
        e.y = clamp(e.y, 0, 1000);
        if (e.hp <= 0) e.alive = false;
    }
}
