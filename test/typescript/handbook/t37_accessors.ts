// Class accessors with type annotations, optional methods, declare-field
// shorthand in a class, and an interface declaring get/set pairs.
interface Screen {
  get size(): number;
  set size(v: number);
}
class Monitor implements Screen {
  declare model: string;
  private _size = 0;
  get size(): number {
    return this._size;
  }
  set size(v: number) {
    this._size = v;
  }
  maybe?(): string {
    return "ran";
  }
  get doubled(): number {
    return this._size * 2;
  }
}
const m = new Monitor();
m.model = "M24";
m.size = 12;
console.log(m.model, m.size, m.doubled, m.maybe?.());
console.log(typeof Object.getOwnPropertyDescriptor(Monitor.prototype, "size")?.get);
