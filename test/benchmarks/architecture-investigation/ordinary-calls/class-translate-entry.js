var N = 1000000;

class Point {
    constructor(x, y) { this.x = x; this.y = y; }
    translate(dx, dy) { this.x += dx; this.y += dy; return this; }
}

function methodCalls(n) {
    var point = new Point(0, 0);
    for (var i = 0; i < n; i++) point.translate(1, 1);
    return point.x + point.y;
}

var start = Date.now();
var result = methodCalls(N);
print('PHASE translate-method ' + (Date.now() - start));
if (result !== 2 * N) throw new Error('translate checksum mismatch');
