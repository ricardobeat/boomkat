// Element and global reads of inlined bodies whose registers lie beyond the caller's frame
// (Richards' Scheduler.release, `var tcb = this.blocks[id]; if (tcb == null) ...`): OBJECT nodes,
// tested against null, used as receivers and returned, or numbers when arithmetic asks. After warmup
// the elements become holes, strings, doubles and typed-array numbers.
var out = [];
var LIMIT = 3;
function Tcb(p) { this.priority = p; this.held = true; }
Tcb.prototype.notHeld = function () { this.held = false; };
function Sched(n) { this.blocks = []; for (var i = 0; i < n; i++) this.blocks[i] = new Tcb(i); this.cur = this.blocks[0]; }
Sched.prototype.release = function (id) {
    var tcb = this.blocks[id];
    if (tcb == null) return tcb;
    tcb.notHeld();
    if (tcb.priority > this.cur.priority) return tcb;
    return this.cur;
};
Sched.prototype.weight = function (id) { return this.blocks[id] + LIMIT; };
function Task(s) { this.s = s; this.v = 0; }
Task.prototype.run = function (k) {
    var t = this.s.release(k % 6);
    this.v += t == null ? 1 : t.priority;
    return t;
};
Task.prototype.sum = function (k) { return this.s.weight(k) * 2; };

var s = new Sched(5);
var task = new Task(s);
var n = 0;
for (var i = 0; i < 20000; i++) { task.run(i); s.cur = s.blocks[i % 5]; }
out.push("warm " + task.v);
var ns = { blocks: [1, 2, 3.5, 4] };
var t2 = new Task(Object.assign(Object.create(Sched.prototype), ns));
var w = 0;
for (var i = 0; i < 20000; i++) w += t2.sum(i % 4);
out.push("weight " + w);
s.blocks[2] = undefined; out.push("undef " + (task.run(2) === undefined) + " " + task.v);
delete s.blocks[3]; out.push("hole " + (task.run(3) === undefined) + " " + task.v);
s.blocks[1] = "str"; try { task.run(1); out.push("str " + task.v); } catch (e) { out.push("str threw " + e.constructor.name); }
s.blocks[4] = { priority: 2.5, notHeld: function () {} }; out.push("dbl " + task.run(4).priority + " " + task.v);
ns.blocks[1] = "x"; out.push("strw " + t2.sum(1));
ns.blocks[2] = null; out.push("nullw " + t2.sum(2));
t2.s.blocks = new Int8Array([5, 6, 7, 8]); out.push("typed " + t2.sum(3));
LIMIT = 0.5; out.push("limit " + t2.sum(0));
LIMIT = "z"; out.push("limitstr " + t2.sum(0));
s.blocks[1] = new Tcb(1); t2.s.blocks = [1, 2, 3, 4]; LIMIT = 3;
for (var i = 0; i < 3000; i++) { task.run(i); w += t2.sum(i % 4); }
out.push("again " + task.v + " " + w);
print(out.join("\n"));
