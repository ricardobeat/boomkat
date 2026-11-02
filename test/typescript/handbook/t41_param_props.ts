// A parameter property is assigned to the instance when the constructor runs.
class Point {
  constructor(public x: number, public y: number) {}
  sum(): number {
    return this.x + this.y;
  }
}
const point = new Point(1, 2);
console.log(point.x, point.y, point.sum());

class Base {
  greet(): string {
    return "base";
  }
}
class Derived extends Base {
  constructor(public label: string) {
    super();
    this.seen = true;
  }
  seen: boolean;
}
const derived = new Derived("d");
console.log(derived.label, derived.seen, derived.greet());
