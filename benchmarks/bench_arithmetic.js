// Arithmetic operations benchmark
var N = 2000000;
var a = 12345;
var b = 67890;
var c = 0;
var i;

// Addition
for (i = 0; i < N; i++) { c = a + b; }

// Subtraction
for (i = 0; i < N; i++) { c = a - b; }

// Multiplication
for (i = 0; i < N; i++) { c = a * b; }

// Division
for (i = 0; i < N; i++) { c = a / b; }

// Modulus
for (i = 0; i < N; i++) { c = a % 127; }

// Bitwise
for (i = 0; i < N; i++) { c = a & b; }
for (i = 0; i < N; i++) { c = a | b; }
for (i = 0; i < N; i++) { c = a ^ b; }
for (i = 0; i < N; i++) { c = a << 3; }
for (i = 0; i < N; i++) { c = a >> 3; }

print(c);
