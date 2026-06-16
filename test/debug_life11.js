function makeLife(w, h) {
    var obj = {};
    obj.w = w;
    obj.h = h;
    obj.cells = [];
    for (var i = 0; i < w * h; i++) obj.cells[i] = 0;
    return obj;
}

var a = makeLife(2, 3);
var b = makeLife(4, 5);
console.log("a: w=" + a.w + " h=" + a.h + " len=" + a.cells.length);
console.log("b: w=" + b.w + " h=" + b.h + " len=" + b.cells.length);
