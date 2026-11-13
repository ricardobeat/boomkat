// A call made from an inlined body that the tier does not inline in turn (a loop in the callee, a
// polymorphic site, recursion) runs as a real call from records of the inlined frames. What the
// callee does must see those frames: a throw unwinds through them, a stack trace names them, a
// collection keeps what they hold, and an exit in the callee leaves them to their baseline code.
var out = [];
function Task(kind, v) { this.kind = kind; this.v = v; this.next = null; }
// A loop keeps each of these from being inlined: real calls.
function Work(n) { this.n = n; }
Work.prototype.run = function (t) { var s = 0; for (var i = 0; i < 2; i++) s += t.v + this.n; return s; };
function Idle(n) { this.n = n; }
Idle.prototype.run = function (t) { var s = 1; for (var i = 0; i < 1; i++) s = s * 3 + this.n; return s - t.v; };
function Boom(n) { this.n = n; }
Boom.prototype.run = function (t) {
    for (var i = 0; i < 1; i++) if (t.v === -1) throw new Error("boom " + this.n);
    return this.n;
};
function Deep(n) { this.n = n; }
Deep.prototype.run = function (t) {
    for (var i = 0; i < 1; i++) if (t.v === -2) return new Error("trace").stack;
    return this.n;
};

// Inlined into `drive`, each holding a real call.
function Tcb(task, t) { this.task = task; this.t = t; this.count = 0; }
Tcb.prototype.step = function () {
    this.count = this.count + 1;
    var r = this.task.run(this.t);
    return r + this.count;
};
// Two levels: `outer` inlines `step`, which calls for real.
Tcb.prototype.outer = function (k) { var a = this.step(); return a + k; };

// Recursive callee: never inlined into itself.
function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
function Wrap(x) { this.x = x; }
Wrap.prototype.f = function () { var y = this.x + 1; return fact(y) - y; };

// Keeps garbage coming so that collections land inside the calls.
var sink = [];
function churn(i) { sink[i & 63] = { a: [i, i + 1], b: "s" + (i & 7) }; }

function drive(list, rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) {
        var tcb = list[r % list.length];
        acc += tcb.step();
        acc += tcb.outer(r & 3);
        churn(r);
    }
    return acc;
}
function wraps(ws, rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) acc += ws[r & 1].f();
    return acc;
}

var tasks = [new Tcb(new Work(2), new Task(1, 5)), new Tcb(new Idle(3), new Task(2, 7)), new Tcb(new Work(4), new Task(1, 1))];
var total = 0;
for (var k = 0; k < 40; k++) total += drive(tasks, 500);
out.push(total);
var ws = [new Wrap(3), new Wrap(5)];
var wt = 0;
for (var k = 0; k < 40; k++) wt += wraps(ws, 300);
out.push(wt);

// A throw from the real call unwinds through the inlined frames, to a handler in the caller.
var bad = new Tcb(new Boom(9), new Task(3, -1));
var caught = [];
function guarded(list, rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) {
        try { acc += list[r % list.length].step(); } catch (e) { caught.push(e.message); }
    }
    return acc;
}
var mixed = [tasks[0], tasks[1]];
for (var k = 0; k < 20; k++) guarded(mixed, 300);
mixed.push(bad);
out.push(guarded(mixed, 9), caught.length, caught[0]);

// The stack trace from inside the real call names the inlined method.
var deep = new Tcb(new Deep(1), new Task(4, -2));
var traced = [tasks[0], tasks[1]];
for (var k = 0; k < 20; k++) drive(traced, 300);
traced.push(deep);
var trace = "";
function traceOnce() {
    for (var r = 0; r < 3; r++) { var v = traced[r].step(); if (typeof v === "string") trace = v; }
}
for (var k = 0; k < 3; k++) traceOnce();
// `step` is an anonymous function: its frame shows as the line of its real call.
out.push(/opt_inlined_real_calls\.js:27:/.test(trace), /traceOnce/.test(trace));

// The callee changes kind after the code was built: its exits leave the inlined frames to their
// baseline code, which must finish the step with the right count.
var late = new Tcb({ run: function (t) { return "x" + t.v; } }, new Task(5, 8));
var lateList = [tasks[0], late];
var strs = [];
for (var r = 0; r < 4; r++) strs.push(lateList[r & 1].step());
out.push(strs.join(","), late.count);
console.log(out.join(" "));
