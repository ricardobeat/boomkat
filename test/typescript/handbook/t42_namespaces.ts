// A namespace is a runtime object whose members are the namespace's exports.
namespace Shapes {
  export const origin = { x: 0, y: 0 };
  export function distance(a: number, b: number): number {
    return Math.abs(a - b);
  }
  export class Box {
    constructor(public size: number) {}
  }
  export enum Kind {
    Round,
    Square,
  }
  export namespace Nested {
    export const depth = 2;
  }
  const hidden = "no";
}
console.log(Shapes.origin.x, Shapes.distance(3, 7), new Shapes.Box(4).size);
console.log(Shapes.Kind.Round, Shapes.Nested.depth, Shapes.hidden);
