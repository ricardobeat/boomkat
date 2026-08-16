// Generic classes: type parameters on the class, a typed field, methods
// using the parameter, static members outside it, and a subclass fixing one.
class Box<T> {
  contents: T;
  static created: number = 0;
  constructor(initial: T) {
    this.contents = initial;
    Box.created++;
  }
  swap(next: T): T {
    const old = this.contents;
    this.contents = next;
    return old;
  }
  peek(fn: (v: T) => string): string {
    return fn(this.contents);
  }
}
class NumberBox extends Box<number> {
  doubled(): number {
    return this.contents * 2;
  }
}
const b = new Box<string>("a");
const n = new NumberBox(21);
console.log(b.swap("b"), b.contents, b.peek((v) => "[" + v + "]"));
console.log(n.doubled(), n.swap(42), Box.created);
