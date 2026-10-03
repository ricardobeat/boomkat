// P2: multiple distinct private fields coexist on the same instance.
class Point {
    #x = 1;
    #y = 2;
    #z = 3;
    sum() { return this.#x + this.#y + this.#z; }
    setX(v) { this.#x = v; }
}

var p = new Point();
if (p.sum() !== 6) throw new Error("expected sum 6, got " + p.sum());
p.setX(10);
if (p.sum() !== 15) throw new Error("expected sum 15 after setX, got " + p.sum());

print("PASS");
