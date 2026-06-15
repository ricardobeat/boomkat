// Bench 3: Many small function calls
function add(a, b) { return a + b; }
function mul(a, b) { return a * b; }
var x = 0;
for (var i = 0; i < 50000; i++) {
    x = add(x, 1);
    x = mul(x, 2);
    x = x | 0;
}
