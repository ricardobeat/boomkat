// An inherited method read folded to its method under a slot watch, on an object the allocation
// sinking keeps in registers: the prototype replaced after warmup gives new objects the new method.
// Rebuilt after an exit, the body reads the entry that still names the old prototype.
function Pt(x, y) { this.x = x; this.y = y; }
Pt.prototype.len = function () { return this.x + this.y; };
function pts(n) { var s = 0; for (var i = 0; i < n; i++) { var p = new Pt(i, 1); s += p.len(); } return s; }
print(pts(3000));
Pt.prototype = { len: function () { return this.x * 2; } };
print(pts(3000));
print(pts(3000));
