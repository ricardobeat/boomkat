// Classes: typed fields with and without initializers, readonly, modifiers
// on methods (readonly fields, override-able), implements, constructor
// overload signatures, method overloads, and a generic class implementing a
// generic interface.
interface Store<T> {
  get(): T;
  put(v: T): void;
}
class Cell<T> implements Store<T> {
  private val: T;
  readonly tag: string = "cell";
  constructor(v: T) {
    this.val = v;
  }
  get(): T {
    return this.val;
  }
  put(v: T): void {
    this.val = v;
  }
}
class Timer {
  constructor(ms: number);
  constructor(s: string);
  constructor(x: any) {
    this.created = typeof x === "number" ? x : parseInt(x, 10);
  }
  created: number;
  scaled(f: number): number;
  scaled(f: string): number;
  scaled(f: any): number {
    return this.created * (typeof f === "number" ? f : 2);
  }
}
const c = new Cell<string>("v");
c.put("w");
const t = new Timer("30");
console.log(c.get(), c.tag, t.created, t.scaled(3), new Timer(5).scaled("x"));
