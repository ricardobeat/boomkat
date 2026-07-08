type A = { a: number };
type B = { b: string };
let ab: A & B = { a: 1, b: "x" };
print(ab.a);
print(ab.b);
