interface A { a(): number }
interface B { b(): string }
class Impl implements A, B {
    a(): number { return 42; }
    b(): string { return "b!"; }
}
let x = new Impl();
print(x.a());
print(x.b());
