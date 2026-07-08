// Class-level TS: generic type parameters, implements clause,
// modifiers, method annotations.
interface Greeter {
    greet(name: string): string;
}

class Base<T> implements Greeter {
    greet(name: string): string {
        return "hello, " + name;
    }
}

class Impl extends Base<string> {
    kind(): string {
        return "impl";
    }
}

let x = new Impl();
print(x.greet("world"));
print(x.kind());
