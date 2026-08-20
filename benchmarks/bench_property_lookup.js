// Property lookup chain benchmark (prototype chain depth)
var N = 1600000;

// Deep prototype chain
function A() { this.a = 1; }
function B() { this.b = 2; }
function C() { this.c = 3; }
function D() { this.d = 4; }
function E() { this.e = 5; }

B.prototype = new A();
C.prototype = new B();
D.prototype = new C();
E.prototype = new D();

var obj = new E();

// Lookup own property
var sum = 0;
for (var i = 0; i < N; i++) { sum += obj.e; }

// Lookup from prototype chain (depth 1)
for (var i = 0; i < N; i++) { sum += obj.d; }

// Lookup from prototype chain (depth 2)
for (var i = 0; i < N; i++) { sum += obj.c; }

// Lookup from prototype chain (depth 3)
for (var i = 0; i < N; i++) { sum += obj.b; }

// Lookup from prototype chain (depth 4)
for (var i = 0; i < N; i++) { sum += obj.a; }

print(sum);
