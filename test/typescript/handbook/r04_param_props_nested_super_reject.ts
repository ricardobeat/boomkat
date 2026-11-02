// A derived constructor with parameter properties must call super() as a
// statement of its own body (TS2401): the assignments follow that call.
class Base { constructor(public a: number) {} }
class Derived extends Base {
  constructor(public b: number) {
    if (b) { super(1); } else { super(2); }
  }
}
console.log(new Derived(1).b);
