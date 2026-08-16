// abstract classes: abstract methods without bodies, abstract properties,
// concrete members, and a subclass implementing the abstract surface.
abstract class Shape {
  abstract sides(): number;
  abstract readonly label: string;
  describe(): string {
    return this.label + ":" + this.sides();
  }
  static count(shapes: Shape[]): number {
    return shapes.reduce((n, s) => n + s.sides(), 0);
  }
}
class Tri extends Shape {
  readonly label = "tri";
  sides(): number {
    return 3;
  }
}
class Squ extends Shape {
  readonly label = "squ";
  sides(): number {
    return 4;
  }
}
const shapes: Shape[] = [new Tri(), new Squ()];
console.log(shapes.map((s) => s.describe()).join(" "));
console.log(Shape.count(shapes), shapes[0] instanceof Shape);
