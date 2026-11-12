// An inlined constructor's add that meets a setter the prototype gained leaves optimized code
// after the add helper declines: the exit must publish the add's value, which the helper's call
// clobbers unless it is saved with the values live past the add (OptCg.spill_live).
function Base() {}
function Mid() {}
Mid.prototype = Object.create(Base.prototype);
function P(v) { this.a = v; this.b = v + 1; this.c = v + 2; }
P.prototype = Object.create(Mid.prototype);
var bad = [];
function make(n, check) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    var o = new P(i);
    s += o.a + o.b + o.c;
    if (check && o.a + o.b + o.c != i + 2 * (i + 1) + i + 2) bad.push(i + ":" + o.a + "/" + o.b + "/" + o.c + "/" + o._b + "/" + Object.keys(o).join(""));
  }
  return s;
}
make(20000, false);
Object.defineProperty(Base.prototype, "b", { set: function (v) { this._b = v * 2; }, get: function () { return this._b; }, configurable: true });
print(make(20000, true), bad.length, bad.slice(0, 5).join(","), bad.slice(-3).join(","));
