// Cyclic SSA coverage: whole-body compilation of functions with backedges.
//
// The frameless callee path only takes over when a caller links a method call
// to a callee that is too large to inline, so the fixtures below carry enough
// locals to stay out of the inline tier. Independent reference loops assert
// the result, and the interpreter/JIT differential run compares the checksum.

function CyclicBox(a, b) { this.a = a; this.b = b; }

var pad = "var q0=0,q1=0,q2=0,q3=0,q4=0,q5=0,q6=0,q7=0,q8=0,q9=0," +
          "q10=0,q11=0,q12=0,q13=0,q14=0,q15=0,q16=0,q17=0,q18=0,q19=0," +
          "q20=0,q21=0,q22=0,q23=0,q24=0;";

CyclicBox.prototype.fieldSum = new Function("n", pad +
  "var s=q0,i=0; while(i<n){ s=s+this.a+this.b+i; i=i+1; } return s;");

CyclicBox.prototype.doubleSum = new Function("n", pad +
  "var s=q0+0.5,i=0; while(i<n){ s=s+1.5*this.a+i*0.25; i=i+1; } return s;");

CyclicBox.prototype.nested = new Function("n", pad +
  "var s=q0,i=0; while(i<n){ s=s+i;" +
  " if(n>1000){ var j=0; while(j<3){ s=s+(i&j); j=j+1; } } i=i+1; } return s;");

CyclicBox.prototype.multi = new Function("n", pad +
  "var s=q0,i=0; while(i<n){ s=s+i; i=i+1; }" +
  " i=0; while(i<n){ s=s-i*2; i=i+1; }" +
  " i=n; while(i>0){ s=s+(i<<1); i=i-1; } return s;");

var box = new CyclicBox(3, 5);

function refField(n) { var s = 0; for (var i = 0; i < n; i++) s += 8 + i; return s; }
function refDouble(n) { var s = 0.5; for (var i = 0; i < n; i++) s += 4.5 + i * 0.25; return s; }
function refMulti(n) {
  var s = 0;
  for (var i = 0; i < n; i++) s += i;
  for (var i = 0; i < n; i++) s -= i * 2;
  for (var i = n; i > 0; i--) s += i << 1;
  return s;
}
function refNested(n) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    s += i;
    if (n > 1000) for (var j = 0; j < 3; j++) s += i & j;
  }
  return s;
}

function drive() {
  var acc = 0;
  for (var i = 0; i < 20000; i++) {
    acc += box.fieldSum(8) % 1000003;
    acc += box.doubleSum(6) % 1000003;
    acc += box.multi(5) % 1000003;
  }
  return acc;
}

var a = drive();
// The inner loop stays cold until the threshold is crossed, so the outer loop
// becomes the hot backedge and compiles the nested body as one cyclic region.
var warm = box.nested(10);
var nested = 0;
for (var k = 0; k < 2000; k++) nested += box.nested(1001);

var expectDrive = 0;
for (var i = 0; i < 20000; i++) {
  expectDrive += refField(8) % 1000003;
  expectDrive += refDouble(6) % 1000003;
  expectDrive += refMulti(5) % 1000003;
}

if (a !== expectDrive) throw new Error("cyclic drive mismatch");
if (warm !== refNested(10)) throw new Error("cyclic warm mismatch " + warm);
if (nested !== refNested(1001) * 2000) throw new Error("cyclic nested mismatch");
print("sljit cyclic ssa ok " + a + " " + nested);
