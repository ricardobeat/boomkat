// Booleans and objects that cross a join in registers in optimized code: the results of inlined
// predicates, `!`, a conditional's two objects, and their uses as values.
function P(s, id) { this.state = s; this.id = id; this.a = { v: 1 }; this.b = { v: 2 }; this.flag = null; }
P.prototype.held = function () { return (this.state & 1) != 0 || this.state == 2; };
P.prototype.both = function () { return this.state > 0 && this.id < 5; };
P.prototype.not = function () { return !(this.state > 1); };
P.prototype.notnot = function () { return !!(this.state < 2.5); };
P.prototype.pick = function () { return this.state > 1 ? this.a : this.b; };
P.prototype.mixed = function () { return this.state > 1 || this.id; };
P.prototype.half = function () { return this.id / 2 < this.state || this.id / 2 != this.id / 2; };
function run(ps) {
    var n = 0;
    for (var i = 0; i < ps.length; i++) {
        var p = ps[i];
        if (p.held()) n += 1;
        if (p.both()) n += 10;
        if (!p.not()) n += 100;
        if (p.notnot()) n += 3;
        n += p.pick().v * 1000;
        if (p.mixed()) n += 10000;
        if (p.half()) n += 7;
        var h = p.held();
        if (h === true) n += 100000;
        if (typeof h !== "boolean") n = -1;
        n += h + 1;
        var m = p.not();
        p.flag = m;
        if (p.flag !== m) n = -2;
        if ("" + m !== (m ? "true" : "false")) n = -3;
    }
    return n;
}
var ps = [];
for (var i = 0; i < 8; i++) ps.push(new P(i & 3, i));
var r = [];
var t = 0;
for (var k = 0; k < 20000; k++) t += run(ps);
r.push(t);
// The numbers then turn into doubles, NaN and a string: the comparisons leave or go the float way.
ps[1].state = 1.5; ps[2].state = NaN; ps[3].id = 0.5;
t = 0;
for (var k = 0; k < 20000; k++) t += run(ps);
r.push(t);
ps[4].state = "2";
t = 0;
for (var k = 0; k < 2000; k++) t += run(ps);
r.push(t, typeof ps[0].flag, ps[2].flag, ps[4].flag);
print(r.join(" "));
