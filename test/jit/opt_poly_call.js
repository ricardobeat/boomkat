// Polymorphic calls: a site whose feedback names two to four callees is built as a test of the
// callee per case, each followed by the inlined body, and the call itself for any other callee
// (OptBuild.poly_sites). Sites with 2, 3, 4 and 5 targets (the last stays a call), a callee met
// only after the caller was optimized, bound functions, natives and plain closures mixed in, a
// method replaced on a prototype, and a body with branches and an exit inside.
//
// The callers add a double (0.5) so that they carry operand feedback and are optimized without
// --opt-always.
var N = 1500;
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function A() { this.k = 1; }
A.prototype.run = function (x) { return x + this.k; };
function B() { this.k = 2; }
B.prototype.run = function (x) { return x + this.k * 2; };
function C() { this.k = 3; }
C.prototype.run = function (x) { if (x > 1000) return x - 999; return x + this.k; };
function D() { this.k = 4; }
D.prototype.run = function (x) { return x - this.k; };
function E() { this.k = 5; }
E.prototype.run = function (x) { return x * 2 % 1001; };

function drive(objs, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = objs[i % objs.length].run(s) + 0.25;
    return s;
}

var two = [new A(), new B()];
var three = [new A(), new B(), new C()];
var four = [new A(), new B(), new C(), new D()];
var five = [new A(), new B(), new C(), new D(), new E()];

function d2(n) { var s = 0.5; for (var i = 0; i < n; i++) s = two[i & 1].run(s) + 0.25; return s; }
function d3(n) { var s = 0.5; for (var i = 0; i < n; i++) s = three[i % 3].run(s) + 0.25; return s; }
function d4(n) { var s = 0.5; for (var i = 0; i < n; i++) s = four[i % 4].run(s) + 0.25; return s; }
function d5(n) { var s = 0.5; for (var i = 0; i < n; i++) s = five[i % 5].run(s) + 0.25; return s; }

for (var r = 0; r < 4; r++) {
    show("d2", d2(N));
    show("d3", d3(N));
    show("d4", d4(N));
    show("d5", d5(N));
}

// A new callee after the site was optimized with two: it takes the call path.
function late(objs, n) { var s = 0.5; for (var i = 0; i < n; i++) s = objs[i % objs.length].run(s) + 0.25; return s; }
for (var r = 0; r < 3; r++) show("late2", late(two, N));
show("late-new", late([new A(), new B(), new E()], N));
show("late-new4", late([new D(), new A(), new C(), new B()], N));
show("late2-again", late(two, N));

// Bound functions, natives and closures through one site (the bound and native ones are not
// inlined; their feedback names no compiled function, or the call goes through the slow path).
function plus1(x) { return x + 1; }
function times3(x) { return x * 3 % 10007; }
var bound = function (x) { return x + this.v; }.bind({ v: 7 });
var fns = [plus1, times3, bound, Math.floor, plus1, times3];
function mixed(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = fns[i % fns.length](s) + 0.25;
    return s;
}
for (var r = 0; r < 3; r++) show("mixed", mixed(N));
fns[3] = function (x) { return x - 2; };
show("mixed-swap", mixed(N));

// A method replaced on a prototype after optimization: the new closure fails its test.
function proto(n) { var s = 0.5; for (var i = 0; i < n; i++) s = three[i % 3].run(s) + 0.25; return s; }
for (var r = 0; r < 3; r++) show("proto", proto(N));
B.prototype.run = function (x) { return x + 100; };
show("proto-replaced", proto(N));
B.prototype.run = function (x) { return x + this.k * 2; };
show("proto-restored", proto(N));
// A shape change of the receivers (an own property shadowing the method).
three[0].run = function (x) { return x + 0.125; };
show("proto-own", proto(N));
delete three[0].run;
show("proto-deleted", proto(N));

// Exceptions thrown from an inlined case keep their stack and their value.
function Thrower() {}
Thrower.prototype.run = function (x) { if (x > 1e9) throw new Error("big " + x); return x + 1; };
var tobjs = [new A(), new Thrower()];
function guarded(n, big) {
    var s = 0.5;
    try {
        for (var i = 0; i < n; i++) s = tobjs[i & 1].run(i == n - 1 ? big : s);
    } catch (e) {
        return "caught " + e.message;
    }
    return s;
}
for (var r = 0; r < 3; r++) show("guarded", guarded(N, 0));
show("guarded-throw", guarded(N, 2e9));

print(out.join("\n"));
