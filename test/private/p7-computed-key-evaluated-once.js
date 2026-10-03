// P7: a computed field key `[expr]` is evaluated exactly once, at class
// definition time — not once per instance construction.
var calls = 0;
function key() { calls++; return "k" + calls; }

class A {
    [key()] = 1;
}

new A();
new A();
new A();

if (calls !== 1) throw new Error("expected computed key evaluated once, got " + calls + " calls");

var a = new A();
if (a.k1 !== 1) throw new Error("expected property 'k1' to exist with value 1");

print("PASS");
