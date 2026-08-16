// Narrowing with `in` and `instanceof` (TS Handbook, Narrowing).
type Bird = { fly(): void; feathers: number };
type Fish = { swim(): void; fins: number };
function livesIn(pet: Bird | Fish): string {
  if ("swim" in pet) return "water/" + pet.fins;
  return "air/" + pet.feathers;
}
class Circle {
  r: number;
  constructor(r: number) {
    this.r = r;
  }
  area(): number {
    return 3 * this.r * this.r;
  }
}
class Rect {
  w: number;
  h: number;
  constructor(w: number, h: number) {
    this.w = w;
    this.h = h;
  }
  area(): number {
    return this.w * this.h;
  }
}
function shape(s: Circle | Rect): string {
  return s instanceof Circle ? "circle" + s.area() : "rect" + s.area();
}
console.log(livesIn({ feathers: 2, fly() {} }), livesIn({ fins: 4, swim() {} }));
console.log(shape(new Circle(2)), shape(new Rect(2, 5)));
