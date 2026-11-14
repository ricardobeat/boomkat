// An inherited method read that optimized code folds to the method under a watch of the
// prototype's slot sees the slot replaced, the prototype's own prototype swapped, and the
// method deleted from the owner and found further up the chain.
function P(x) { this.x = x; }
P.prototype.get = function () { return this.x; };
function run(o) { var s = 0; for (var i = 0; i < 100000; i++) s += o.get(); return s; }
var o = new P(1);
var got = [run(o)];
P.prototype.get = function () { return 2 * this.x; };
got.push(run(o));
Object.setPrototypeOf(P.prototype, {});
P.prototype.get = function () { return 3; };
got.push(run(o));
delete P.prototype.get;
Object.getPrototypeOf(P.prototype).get = function () { return 4; };
got.push(run(o));
if (got.join() !== "100000,200000,300000,400000") throw new Error("stale method: " + got.join());
print("ok");
