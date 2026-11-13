// A polymorphic call made from an inlined body: each callee its feedback names is inlined in the
// body as a case behind a test of the callee, and any other callee takes the call, made for real
// from the inlined frames (OptBuild.poly_children). The cases hold a loop, a branch, a field store
// and a throw; a callee met after the code was built takes the call; garbage keeps collections
// landing in the cases' loops.
var out = [];
function Packet(v) { this.v = v; this.link = null; this.n = 0; }
Packet.prototype.addTo = function (q) {
    this.link = null;
    if (q === null) return this;
    var p = q, next;
    while ((next = p.link) !== null) p = next;
    p.link = this;
    return q;
};

function Work(n) { this.n = n; this.q = null; }
Work.prototype.run = function (p) {
    var s = 0;
    for (var i = 0; i < 3; i++) s += p.v + this.n;
    p.n = s;
    return s;
};
function Idle(n) { this.n = n; this.q = null; }
Idle.prototype.run = function (p) {
    if (p.v & 1) return this.n * 3;
    this.q = p.addTo(this.q);
    if (this.q.link !== null && this.q.link.link !== null) this.q = null;
    return -this.n;
};
function Boom(n) { this.n = n; }
Boom.prototype.run = function (p) {
    if (p.v === -1) throw new Error("boom " + this.n);
    return this.n + p.v;
};

// Inlined into `drive`; its call to task.run is the nested polymorphic site.
function Tcb(task, p) { this.task = task; this.p = p; this.count = 0; }
Tcb.prototype.step = function () {
    this.count = this.count + 1;
    var r = this.task.run(this.p);
    return r + this.count;
};

var sink = [];
function churn(i) { sink[i & 63] = { a: [i, i + 1], b: "s" + (i & 7) }; }

function drive(list, rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) {
        var tcb = list[r % list.length];
        acc += tcb.step();
        tcb.p.v = (tcb.p.v + 1) & 15;
        churn(r);
    }
    return acc;
}

var tcbs = [new Tcb(new Work(2), new Packet(5)), new Tcb(new Idle(3), new Packet(6)),
            new Tcb(new Work(4), new Packet(1)), new Tcb(new Boom(7), new Packet(2))];
var total = 0;
for (var k = 0; k < 40; k++) total += drive(tcbs, 400);
out.push(total, tcbs[0].p.n, tcbs[1].task.q === null);

// A callee the feedback did not name when the code was built takes the call from the body.
var late = new Tcb({ run: function (p) { var s = ""; for (var i = 0; i < 2; i++) s += p.v; return s; } }, new Packet(3));
var withLate = tcbs.concat([late]);
var strs = [];
for (var r = 0; r < 10; r++) strs.push(String(drive(withLate, 5)));
out.push(strs.join(","), late.count);

// A throw from an inlined case unwinds through the inlined frames to the caller's handler.
var caught = [];
function guarded(list, rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) {
        try { acc += list[r % list.length].step(); } catch (e) { caught.push(e.message); }
    }
    return acc;
}
for (var k = 0; k < 20; k++) guarded(tcbs, 200);
tcbs[3].p.v = -1;
out.push(guarded(tcbs, 9), caught.length, caught[0]);
console.log(out.join(" "));
