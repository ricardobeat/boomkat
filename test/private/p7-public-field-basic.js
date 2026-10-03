// P7: basic public class field declaration and initialization.
class Point {
    x = 1;
    y = 2;
}

var p = new Point();
if (p.x !== 1) throw new Error("expected x=1, got " + p.x);
if (p.y !== 2) throw new Error("expected y=2, got " + p.y);

p.x = 10;
if (p.x !== 10) throw new Error("expected x=10 after write, got " + p.x);

print("PASS");
