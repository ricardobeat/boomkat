// String operations benchmark
var N = 250000;
var s = "Hello, World!";
var result = "";
var i;

// String concatenation
for (i = 0; i < N; i++) {
    result = s + " " + i;
}

// String comparison
var eq = false;
for (i = 0; i < N; i++) {
    eq = (s == "Hello, World!");
}

print(result + " " + eq);
