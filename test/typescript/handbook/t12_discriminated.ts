// Discriminated unions: a literal `kind` field picks the variant, checked by
// switch and by equality, including a member with a payload array.
type Shape =
  | { kind: "circle"; radius: number }
  | { kind: "square"; side: number }
  | { kind: "poly"; sides: number[] };
function describe(s: Shape): string {
  switch (s.kind) {
    case "circle":
      return "r" + s.radius;
    case "square":
      return "s" + s.side;
    case "poly":
      return "p" + s.sides.length;
  }
}
function isRound(s: Shape): boolean {
  return s.kind === "circle";
}
const shapes: Shape[] = [
  { kind: "circle", radius: 2 },
  { kind: "square", side: 3 },
  { kind: "poly", sides: [1, 2, 3] },
];
for (const s of shapes) console.log(describe(s));
console.log(isRound(shapes[0]), isRound(shapes[1]));
