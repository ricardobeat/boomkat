// One read site, several receiver shapes, and the property on a prototype.
// The inline cache keeps one arm per receiver shape, so every arm has to
// resolve the property from the live prototype rather than from the first
// receiver that filled the site.

var failures = 0;
function check(name, got, want) {
  if (got !== want) {
    failures++;
    print("FAIL " + name + ": got " + got + ", want " + want);
  }
}

function Base() {}
Base.prototype.shared = function () { return "shared"; };

function A() { this.one = 1; }
A.prototype = Object.create(Base.prototype);
A.prototype.kind = function () { return "A"; };

function B() { this.one = 1; this.two = 2; }
B.prototype = Object.create(Base.prototype);
B.prototype.kind = function () { return "B"; };

function C() { this.one = 1; this.two = 2; this.three = 3; }
C.prototype = Object.create(Base.prototype);
C.prototype.kind = function () { return "C"; };

var a = new A();
var b = new B();
var c = new C();

function pick(i) {
  if (i % 3 === 0) return a;
  if (i % 3 === 1) return b;
  return c;
}

function runKind(n) {
  var last = "";
  for (var i = 0; i < n; i++) {
    var o = pick(i);
    last = o.kind();
  }
  return last;
}

function runShared(n) {
  var last = "";
  for (var i = 0; i < n; i++) {
    var o = pick(i);
    last = o.shared();
  }
  return last;
}

check("warm", runKind(3000), "C");
check("shared", runShared(3000), "shared");

// A prototype's layout change invalidates every arm at once.
Base.prototype.shared = function () { return "shared2"; };
check("replaced", runShared(3000), "shared2");
B.prototype.kind = function () { return "B2"; };
check("replaced-arm", runKind(3000), "C");

// An own property shadows the inherited one, and the receiver's shape changes.
a.kind = function () { return "own"; };
check("own-shadow", runKind(3000), "C");

// A repointed link invalidates the arm that recorded it.
var saved = b.kind;
Object.setPrototypeOf(b, { kind: function () { return "repointed"; } });
check("repointed", runKind(3000), "C");
Object.setPrototypeOf(b, B.prototype);
B.prototype.kind = function () { return "B3"; };
check("restored", runKind(3000), "C");

// Two receivers with the same layout but different prototypes must not share
// an owner.
function Same() { this.one = 1; }
var proto1 = { kind: function () { return "p1"; } };
var proto2 = { kind: function () { return "p2"; } };
var s1 = Object.create(proto1);
var s2 = Object.create(proto2);
s1.one = 1;
s2.one = 1;
function runSame(n) {
  var last = "";
  for (var i = 0; i < n; i++) {
    var o = (i & 1) ? s1 : s2;
    last = o.kind();
  }
  return last;
}
check("same-shape-a", runSame(3000), "p1");
check("same-shape-b", runSame(3001), "p2");

// An accessor added later takes over the inherited data slot.
C.prototype.kind = function () { return "C"; };
check("arm-still-good", runKind(3003), "C");
Object.defineProperty(C.prototype, "kind", {
  get: function () { return function () { return "getter"; }; },
});
check("accessor", runKind(3003), "getter");

// A site that stays polymorphic over own data reads after the megamorphic
// cache takes over must still answer every shape.
function make(n) {
  var o = {};
  for (var i = 0; i < n; i++) o["k" + i] = i;
  o.value = n;
  return o;
}
var many = [];
for (var i = 0; i < 12; i++) many.push(make(i));
function runOwn(n) {
  var total = 0;
  for (var i = 0; i < n; i++) total += many[i % many.length].value;
  return total;
}
check("own-many", runOwn(12000), 66000);

print(failures === 0 ? "jit_proto_read_shapes: PASS" : "jit_proto_read_shapes: FAIL");
