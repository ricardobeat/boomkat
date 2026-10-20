// Retained fixed-shape numeric objects, representative of VDOM points/items.
function makePoint(i) {
    return { x: i, y: i + 1, width: i + 2, height: i + 3 };
}

var points = [];
var checksum = 0;
var start = Date.now();
for (var i = 0; i < 200000; i++) {
    var point = makePoint(i);
    points.push(point);
    checksum += point.x + point.y + point.width + point.height;
}
print("init_slot_probe: objects=200000 total=" + (Date.now() - start)
      + "ms checksum=" + checksum + " retained=" + points.length);
