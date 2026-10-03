// P6: `#x in obj` is an ergonomic brand check — true for a branded
// instance, false for an unrelated object (no throw for a plain object).
class A {
    #x = 1;
    static has(o) { return #x in o; }
}

if (A.has(new A()) !== true) throw new Error("expected true for a branded instance");
if (A.has({}) !== false) throw new Error("expected false for an unrelated plain object");

print("PASS");
